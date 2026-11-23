#!/bin/bash
# ============================================================
# MODULE: placement_guard
# DESC: 修正平台组件 master placement 与 PVC 节点亲和冲突(移除不可调度的 master nodeSelector)
# PHASE: addon
# DEFAULT: 1
# REPEAT: 1
# REQUIRES: k8s_deploy
# 说明:
#   · 背景(2026-11-23 MetaX 裸金属实机): platform_placement(私有 release 模块)把
#     cubestack-operator/controller-manager/cubepilot/portal 等平台 Deployment 钉到 master;
#     但 cubepilot-api 的 RWO PVC 已被 PV nodeAffinity 绑定到 worker02 → 新 Pod 永远 Pending
#     (0/5 nodes available: PV node affinity × master nodeSelector)。
#   · 本模块是**通用安全网**: 扫描所有带 master nodeSelector 的 Deployment; 若其 PVC 的 PV
#     明确把卷绑定在非 master 节点, 移除该 Deployment 的 master nodeSelector, 让 Pod 回到
#     PVC 所在节点。幂等; 没有冲突的组件不动。
#   · 文件序号 55 排在私有 platform_placement(54)之后, 随全量/单组件计划执行。
#   · 不记录 installed_component(纯修正动作, 无独立集群资产)。
# 用法: sudo ./deploy-cluster.sh --steps placement_guard
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

init_remote_kubectl || exit 1

say "平台组件 placement 守卫: 检查 master nodeSelector × PVC 节点亲和 ..."
_work="$(mktemp -d -t cubestack-placement-guard.XXXXXX)"
trap 'rm -rf "${_work}"' EXIT

# 一次性取数据(小/中型集群足够; 不逐 Deployment 发请求)
SSH "${K}" get nodes -l node-role.kubernetes.io/control-plane -o name > "${_work}/masters" 2>/dev/null || true
sed -i 's#^node/##' "${_work}/masters"
if [ ! -s "${_work}/masters" ]; then
    # 不知道哪些是 master 时不能贸然移除 selector(可能误伤正常平台组件)
    warn "无法获取 master 节点列表(SSH/kubectl 失败), 跳过 placement guard"
    exit 0
fi
SSH "${K}" get deploy -A -o json > "${_work}/deploys.json" 2>/dev/null || echo '{"items":[]}' > "${_work}/deploys.json"
SSH "${K}" get pvc -A -o json > "${_work}/pvcs.json" 2>/dev/null || echo '{"items":[]}' > "${_work}/pvcs.json"
SSH "${K}" get pv -o json > "${_work}/pvs.json" 2>/dev/null || echo '{"items":[]}' > "${_work}/pvs.json"

python3 - "${_work}/masters" "${_work}/deploys.json" "${_work}/pvcs.json" "${_work}/pvs.json" \
    > "${_work}/fix.tsv" <<'PY'
import json
import sys

masters = {line.strip() for line in open(sys.argv[1]) if line.strip()}
deploys = json.load(open(sys.argv[2]))
pvcs = json.load(open(sys.argv[3]))
pvs = json.load(open(sys.argv[4]))

pv_by_name = {p["metadata"]["name"]: p for p in pvs.get("items", [])}
pvc_by_ns = {}
for p in pvcs.get("items", []):
    ns = (p.get("metadata") or {}).get("namespace")
    name = (p.get("metadata") or {}).get("name")
    pvc_by_ns[(ns, name)] = p


def pv_hosts(pv):
    out = set()
    na = (((pv or {}).get("spec") or {}).get("nodeAffinity") or {}).get("required") or {}
    for term in na.get("nodeSelectorTerms") or []:
        for expr in term.get("matchExpressions") or []:
            if expr.get("key") == "kubernetes.io/hostname" and expr.get("operator") == "In":
                out.update(expr.get("values") or [])
        for field in term.get("matchFields") or []:
            if field.get("key") == "metadata.name" and field.get("operator") == "In":
                out.update(field.get("values") or [])
    return out


for d in deploys.get("items", []):
    meta = d.get("metadata") or {}
    ns, name = meta.get("namespace"), meta.get("name")
    spec = (((d.get("spec") or {}).get("template") or {}).get("spec") or {})
    sel = spec.get("nodeSelector") or {}
    if sel.get("node-role.kubernetes.io/control-plane") != "":
        continue
    for vol in spec.get("volumes") or []:
        claim = (vol.get("persistentVolumeClaim") or {}).get("claimName")
        if not claim:
            continue
        pvc = pvc_by_ns.get((ns, claim)) or {}
        pv_name = (pvc.get("spec") or {}).get("volumeName") or ""
        pv = pv_by_name.get(pv_name) or {}
        hosts = pv_hosts(pv)
        bad = sorted(h for h in hosts if h not in masters)
        if bad:
            print(f"{ns}\t{name}\t{claim}\t{','.join(bad)}")
            break
PY

if [ ! -s "${_work}/fix.tsv" ]; then
    ok "无冲突(带 master selector 且 PVC 绑定非 master 的 Deployment 不存在)"
    exit 0
fi

_fixed=0
while IFS=$'\t' read -r _ns _name _pvc _hosts; do
    [ -n "${_ns}" ] || continue
    warn "  [${_ns}/deploy/${_name}] PVC ${_pvc} 绑定非 master 节点 ${_hosts}; 移除 master nodeSelector"
    printf '%s' '{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":null}}}}}' \
        | SSH "${K}" -n "${_ns}" patch deploy "${_name}" --type=strategic --patch-file=/dev/stdin >/dev/null 2>&1 \
        || { err "  patch ${_ns}/${_name} 失败"; exit 1; }
    _fixed=$((_fixed + 1))
done < "${_work}/fix.tsv"

while IFS=$'\t' read -r _ns _name _pvc _hosts; do
    [ -n "${_ns}" ] || continue
    SSH "${K}" -n "${_ns}" rollout status "deploy/${_name}" --timeout=120s >/dev/null 2>&1 \
        || warn "  ${_ns}/${_name} 120s 内未就绪(检查 PVC 所在节点/Pod 事件)"
done < "${_work}/fix.tsv"

ok "placement guard 完成: 修正 ${_fixed} 个 Deployment"
