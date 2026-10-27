#!/bin/bash
# ============================================================
# cubestack-placement.sh — CubeStack operator/平台组件 master placement
# ------------------------------------------------------------
# 目标(2026-10-27): master cordon 后, CubeStack operator 及其平台组件仍能调度到 master。
#   只处理 **Deployment**(控制面/门户/监控/网关控制器), 不碰:
#     · Envoy Gateway 数据面 proxy Deployment(envoy-envoy-gateway-system-*)
#     · model bundle / sglang / vllm 推理负载(GPU 阶段处理)
#     · 任何 DaemonSet / StatefulSet
#   做法: PodTemplate 加 master nodeSelector + control-plane/unschedulable tolerations。
#
# 注意: 这些 Deployment 由 CubeStack operator/各组件控制器调和; 若 operator 后续回写
#   Deployment, 需要重量 --steps node_pool。未设置 CubeStackCluster.spec.global 的 placement,
#   以免把 model bundle 推理负载也钉到 master。
#
# 用法:
#   sudo ./cubestack-placement.sh --apply
#   sudo ./cubestack-placement.sh --check
#   sudo ./cubestack-placement.sh --remove
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/../../lib-common.sh"
load_config

ACTION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)  ACTION="apply"; shift ;;
        --check)  ACTION="check"; shift ;;
        --remove) ACTION="remove"; shift ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1(可用 --apply/--check/--remove)" >&2; exit 2 ;;
    esac
done
[ -n "${ACTION}" ] || { echo "需要 --apply/--check/--remove" >&2; exit 2; }

init_remote_kubectl || exit 1

# <type>|<namespace>|<name> —— 只放平台控制面/门户/监控/网关控制器 Deployment。
_CB_WORKLOADS=(
    "deploy|cubestack-system|cubestack-operator"
    "deploy|cubestack-system|cubestack-controller-manager"
    "deploy|cubestack-system|cubepilot-api"
    "deploy|cubestack-system|cubepilot-operator"
    "deploy|cubestack-system|cubestack-portal"
    "deploy|envoy-gateway-system|envoy-gateway"          # 控制器; 数据面 proxy 不动
    "deploy|ai-gateway-system|ai-gateway-controller"
    "deploy|lws-system|lws-controller-manager"
    "deploy|cuberouter|cuberouter"
    "deploy|cuberouter|cuberouter-cloudnative-pg"
    "deploy|cuberouter|redis-operator"
    "deploy|monitoring|kube-prometheus-grafana"
    "deploy|monitoring|kube-prometheus-kube-prome-operator"
    "deploy|monitoring|kube-prometheus-kube-state-metrics"
    "deploy|monitoring|perses-operator-controller-manager"
)

_PATCH='{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node.kubernetes.io/unschedulable","operator":"Exists","effect":"NoSchedule"}]}}}}'
_UNPATCH='{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":null}}}}}'

_exists() { SSH "${K} -n $2 get $1 $3 >/dev/null 2>&1"; }
_patch_one() { SSH "${K} -n $2 patch $1 $3 --type=strategic -p '$4'" >/dev/null 2>&1; }

_check_one() {
    local _type="$1" _ns="$2" _name="$3" _json
    if ! _exists "${_type}" "${_ns}" "${_name}"; then
        say "  [${_ns}/${_type}/${_name}] 不存在, 跳过"; return 0
    fi
    _json="$(SSH "${K}" -n ${_ns} get ${_type} ${_name} -o json 2>/dev/null || true)"
    # ★ 2026-10-27: 必须**只检查 nodeSelector/tolerations 字段** —— tolerations 里也含
    #   control-plane/unschedulable 字符串, 旧实现 grep 整个 JSON 会对"只有 tolerations、
    #   没有 nodeSelector"的 Deployment 误报 OK(容器 c 实测: Pod 实际全在 worker)。
    if ! printf '%s' "${_json}" | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)["spec"]["template"]["spec"]
except Exception:
    sys.exit(1)
sel = s.get("nodeSelector") or {}
tols = s.get("tolerations") or []
ok = sel.get("node-role.kubernetes.io/control-plane") == "" and any(
    t.get("key") == "node.kubernetes.io/unschedulable" and t.get("effect") == "NoSchedule"
    for t in tols
)
sys.exit(0 if ok else 1)
'; then
        err "  [${_ns}/${_type}/${_name}] placement 不完整(需 master nodeSelector + unschedulable toleration)"; return 1
    fi
    ok "  [${_ns}/${_type}/${_name}] placement OK"
}

FAILED=0
case "${ACTION}" in
    apply)
        say "CubeStack operator/平台组件 master placement(Deployment) ..."
        for _w in "${_CB_WORKLOADS[@]}"; do
            IFS='|' read -r _t _n _name <<< "${_w}"
            if ! _exists "${_t}" "${_n}" "${_name}"; then
                say "  [${_n}/${_t}/${_name}] 不存在, 跳过"; continue
            fi
            if _patch_one "${_t}" "${_n}" "${_name}" "${_PATCH}"; then
                ok "  [${_n}/${_t}/${_name}] 已加 master nodeSelector + tolerations"
            else
                err "  [${_n}/${_t}/${_name}] patch 失败"; FAILED=1
            fi
        done
        ;;
    check)
        say "校验 CubeStack operator/平台组件 master placement ..."
        for _w in "${_CB_WORKLOADS[@]}"; do
            IFS='|' read -r _t _n _name <<< "${_w}"
            _check_one "${_t}" "${_n}" "${_name}" || FAILED=1
        done
        ;;
    remove)
        say "移除 CubeStack 平台组件 master nodeSelector(tolerations 保留) ..."
        for _w in "${_CB_WORKLOADS[@]}"; do
            IFS='|' read -r _t _n _name <<< "${_w}"
            if ! _exists "${_t}" "${_n}" "${_name}"; then
                say "  [${_n}/${_t}/${_name}] 不存在, 跳过"; continue
            fi
            if _patch_one "${_t}" "${_n}" "${_name}" "${_UNPATCH}"; then
                ok "  [${_n}/${_t}/${_name}] 已移除 master nodeSelector"
            else
                warn "  [${_n}/${_t}/${_name}] remove patch 失败(不阻断)"
            fi
        done
        ;;
esac

if [ "${FAILED}" -ne 0 ]; then
    err "CubeStack 平台组件 placement ${ACTION} 存在失败项"; exit 1
fi
ok "CubeStack 平台组件 placement ${ACTION} 完成"
