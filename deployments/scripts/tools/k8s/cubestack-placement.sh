#!/bin/bash
# ============================================================
# cubestack-placement.sh — CubeStack operator/平台组件 master placement
# ------------------------------------------------------------
# 目标(2026-10-27): master cordon 后, CubeStack operator 及其平台组件仍能调度到 master。
#   处理两类对象:
#     · Deployment(控制面/门户/监控/网关控制器/文档站): 直接 patch PodTemplate;
#     · 由 operator 从 CR 调和的 StatefulSet/Deployment(Prometheus/Alertmanager/Perses/
#       RedisReplication/CNPG Cluster):
#       直接 patch CR 的 nodeSelector/tolerations; CNPG 的调度字段在 spec.affinity 下;
#       RedisReplication 的 Sentinel 走独立的 spec.sentinel.nodeSelector/tolerations。
#   不碰:
#     · Envoy Gateway 数据面 proxy Deployment(envoy-envoy-gateway-system-*)
#     · model bundle / sglang / vllm 推理负载(GPU 阶段处理)
#     · 任何 DaemonSet, 也不直接 patch 由 CR 调和的 StatefulSet。
#   做法: Deployment PodTemplate / CR spec 加 master nodeSelector +
#         control-plane/unschedulable tolerations。
#
# 注意: 这些对象由 CubeStack operator/各组件控制器调和; 若 operator 后续回写,
#   需重跑 --steps node_pool。未设置 CubeStackCluster.spec.global 的 placement,
#   以免把 model bundle 推理负载也钉到 master。
#
# 用法:
#   sudo ./cubestack-placement.sh --apply
#   sudo ./cubestack-placement.sh --check
#   sudo ./cubestack-placement.sh --remove   # 同时清理 CubeStackCluster components.*.values
#                                            # 中持久化的 master nodeSelector(防调和/升级恢复)
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
    "deploy|cubestack-system|cubestack-docs"              # 资产型组件, 无 values 注入路径
)

# <resource>|<namespace>|<name>|<pod>|<pvc-prefix> —— operator 从 CR 调和的 StatefulSet。
# 直接 patch CR(而不是 STS 模板), 否则 operator 下一次调理会把模板覆盖回去。
# 第 4 列 = 现有 Pod 名(单 Pod 场景); 第 5 列 = PVC 名前缀(多副本场景);
# 二者都用于 placement 前检查 local-path PV 是否已绑在 worker, 二选一。
_CB_CRS=(
    "prometheuses.monitoring.coreos.com|monitoring|kube-prometheus-kube-prome-prometheus|prometheus-kube-prometheus-kube-prome-prometheus-0|"
    "alertmanagers.monitoring.coreos.com|monitoring|kube-prometheus-kube-prome-alertmanager|alertmanager-kube-prometheus-kube-prome-alertmanager-0|"
    "perses.perses.dev|monitoring|perses|perses-0|"
    # RedisReplication 的 Redis/Sentinel pods 都由这个 CR 调和; 3 副本/3 sentinel 的
    # PVC 前缀都是 cuberouter-redis-。
    "redisreplications.redis.redis.opstreelabs.in|cuberouter|cuberouter-redis||cuberouter-redis-"
)

# CNPG Cluster 的调度字段在 spec.affinity.nodeSelector/tolerations(不是 spec.nodeSelector)。
# <resource>|<namespace>|<name>|<pvc-prefix>
_CB_CRS_AFFINITY=(
    "clusters.postgresql.cnpg.io|cuberouter|cuberouter-postgres|cuberouter-postgres-"
)

# RedisReplication 的 Sentinel STS **不继承** spec.nodeSelector; 它有独立的
# spec.sentinel.nodeSelector/tolerations(CRD 已确认)。不补这一层时 sentinel 会留在 worker。
# 末尾 PVC 前缀与 Redis 数据副本相同: sentinel 的 local-path 卷同样不能跨节点迁移。
_CB_CRS_SENTINEL=(
    "redisreplications.redis.redis.opstreelabs.in|cuberouter|cuberouter-redis|cuberouter-redis-"
)

_PATCH='{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node.kubernetes.io/unschedulable","operator":"Exists","effect":"NoSchedule"}]}}}}'
_UNPATCH='{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":null}}}}}'
# CRD 的 merge patch 只能走 --type=merge(strategic 不适用于自定义资源)。
# ⚠ apply 不能再用静态 CR patch: JSON merge patch 对数组是**整体替换**, 只含 installer
#   两条 toleration 的 patch 会删掉用户为其它污点设置的条目 → Pod 可能 Pending。
#   现由 _patch_cr_placement 读取现有 tolerations 后合并(2026-11-11 CodeRabbit)。
# unpatch 只删本工具写入的 key, 保留 CR 上其它用户自定义 nodeSelector 条目。
_CR_UNPATCH='{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":null}}}'
# 只清本工具写入的 nodeSelector key; CNPG 的 affinity 还含 podAntiAffinityType 等字段,
# merge patch 会保留它们, 也不会删除用户自定义的其它 selector。
_CR_AFFINITY_UNPATCH='{"spec":{"affinity":{"nodeSelector":{"node-role.kubernetes.io/control-plane":null}}}}'
_CR_SENTINEL_UNPATCH='{"spec":{"sentinel":{"nodeSelector":{"node-role.kubernetes.io/control-plane":null}}}}'

# 三态存在性探测: 0=存在; 1=不存在; 2=查询失败(API/RBAC/SSH)。
# ★ remove/apply/check 都必须区分"不存在"与"查不到": 查询失败时跳过循环会让残留的
#   master selector 被报成回滚成功, 或让 apply/check 在未实际下发时静默通过。
_EXISTS_ERR=""
_exists() {   # <type> <ns> <name>
    local out rc=0
    _EXISTS_ERR=""
    out="$(SSH "${K} -n $2 get $1 $3" 2>&1)" || rc=$?
    [ "${rc}" -eq 0 ] && return 0
    case "${out}" in
        *NotFound*|*"not found"*) return 1 ;;
        *"doesn't have a resource type"*) return 1 ;;   # CRD 未安装(组件未启用)
    esac
    _EXISTS_ERR="$(printf '%s' "${out}" | tail -1 || true)"
    return 2
}
_patch_one() { SSH "${K} -n $2 patch $1 $3 --type=strategic -p '$4'" >/dev/null 2>&1; }
_patch_cr_one() { SSH "${K} -n $2 patch $1 $3 --type=merge -p '$4'" >/dev/null 2>&1; }

# 合并式 CR placement patch: 读取现有 tolerations, 保留用户条目后追加 installer 的两条。
# JSON merge patch 对数组是整体替换 —— 直接下发静态 patch 会删掉用户为其它污点设置的
# toleration, 使调和出的 Pod 在新污点下 Pending(2026-11-11 CodeRabbit)。
# <path>: spec | spec.affinity | spec.sentinel(期望的 nodeSelector 所在层级)。
_patch_cr_placement() {   # <type> <ns> <name> <path> <ok-label>
    local _type="$1" _ns="$2" _name="$3" _path="$4" _label="$5" _json _patch
    _json="$(SSH "${K}" -n "${_ns}" get "${_type}" "${_name}" -o json 2>/dev/null)" || {
        err "  [${_ns}/${_type}/${_name}] 读取 CR 失败, 无法安全合并 tolerations"; FAILED=1; return 1; }
    _patch="$(printf '%s' "${_json}" | PATHNAME="${_path}" python3 -c '
import json, os, sys
KEY = "node-role.kubernetes.io/control-plane"
INSTALLER = [
    {"key": KEY, "operator": "Exists", "effect": "NoSchedule"},
    {"key": "node.kubernetes.io/unschedulable", "operator": "Exists", "effect": "NoSchedule"},
]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
cur = d
root = {}
node = root
for k in os.environ["PATHNAME"].split("."):
    cur = cur.get(k) if isinstance(cur, dict) else None
    node = node.setdefault(k, {})
raw = cur.get("tolerations") if isinstance(cur, dict) else None
tols = [t for t in raw if isinstance(t, dict)] if isinstance(raw, list) else []
seen = {(t.get("key"), t.get("operator"), t.get("effect")) for t in tols}
for t in INSTALLER:
    sig = (t["key"], t["operator"], t["effect"])
    if sig not in seen:
        tols.append(t)
        seen.add(sig)
node["nodeSelector"] = {KEY: ""}
node["tolerations"] = tols
print(json.dumps(root, separators=(",", ":")))
' 2>/dev/null)" || {
        err "  [${_ns}/${_type}/${_name}] 解析 CR 失败, 未 patch"; FAILED=1; return 1; }
    if _patch_cr_one "${_type}" "${_ns}" "${_name}" "${_patch}"; then
        ok "  [${_ns}/${_type}/${_name}] ${_label}"
    else
        err "  [${_ns}/${_type}/${_name}] patch 失败"; FAILED=1; return 1
    fi
}

# CR 的 spec 是否带 master nodeSelector: 0=带; 1=不带; 2=读取/解析失败。
_has_master_selector_cr() {   # <type> <ns> <name>
    local _out _rc=0
    _out="$(SSH "${K}" -n $2 get $1 $3 -o json 2>/dev/null)" || _rc=$?
    [ "${_rc}" -eq 0 ] || return 2
    printf '%s' "${_out}" | python3 -c '
import json, sys
try:
    sel = json.load(sys.stdin)["spec"].get("nodeSelector") or {}
except Exception:
    sys.exit(2)
sys.exit(0 if "node-role.kubernetes.io/control-plane" in sel else 1)
'
}

# 按 PVC 名前缀列出当前集群的 PVC(多副本 StatefulSet 的 local-path 守护)。
# 返回: 0=成功(无匹配则无输出); 2=查询/解析失败(调用方必须按"未知"处理)。
_cr_pvcs_by_prefix() {   # <ns> <prefix>
    local _out _rc=0
    _out="$(SSH "${K}" -n "$1" get pvc -o json 2>/dev/null)" || _rc=$?
    [ "${_rc}" -eq 0 ] || return 2
    if ! printf '%s' "${_out}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
p = sys.argv[1]
for i in d.get("items", []):
    n = (i.get("metadata") or {}).get("name", "")
    if n.startswith(p):
        print(n)
' "$2"; then
        return 2
    fi
}

# apply/check 的三态存在性处理: 0=存在(继续); 1=已跳过(不存在或查询失败)。
# ★ 不能用 `if ! _exists`: 那会把查询失败(API/RBAC/SSH 抖动)当成"不存在"并静默跳过,
#   apply 明明没下发 placement 却以 0 退出。查询失败统一置 FAILED, 由脚本末尾非 0 退出。
_require_exists() {   # <phase> <type> <ns> <name>
    local _phase="$1" _type="$2" _ns="$3" _name="$4" _ex=0
    _exists "${_type}" "${_ns}" "${_name}" || _ex=$?
    case "${_ex}" in
        0) return 0 ;;
        1) say "  [${_ns}/${_type}/${_name}] 不存在, 跳过"; return 1 ;;
        *) err "  [${_ns}/${_type}/${_name}] ${_phase}查询失败, 跳过(无法确认对象状态): ${_EXISTS_ERR:-未知错误}"
           FAILED=1; return 1 ;;
    esac
}

# local-path 等 nodeAffinity PV 守护: 0=可以 placement; 1=已跳过(已打印原因)。
# 无法确认 PVC/PV/节点绑定时保守跳过并置 FAILED —— 不把"查不到"当成"安全"。
# <label> 只用于日志; json 为工作负载/CR Pod 的 -o json 输出。
_pvc_guard_json() {   # <ns> <label> <object-json>
    local _pvcs _bound _rc=0
    _pvcs="$(printf '%s' "$3" | placement_pod_pvcs || true)"
    [ -n "${_pvcs}" ] || return 0
    _bound="$(placement_pvc_worker_bound "$1" ${_pvcs})" || _rc=$?
    case "${_rc}" in
        0) warn "  [$2] PVC ${_bound} 绑定在 worker(local-path), 跳过 placement(否则 Pending; 需共享存储或重建 PVC)"; return 1 ;;
        2) err "  [$2] 无法确认 PVC 绑定(查询失败), 跳过 placement(避免 Pending/误迁移)"; FAILED=1; return 1 ;;
    esac
    return 0
}

_pvc_guard_prefix() {   # <ns> <pvc-prefix> <label>
    local _pvcs _bound _rc=0
    _pvcs="$(_cr_pvcs_by_prefix "$1" "$2")" || _rc=$?
    if [ "${_rc}" -eq 2 ]; then
        err "  [$3] 无法列出 PVC(查询失败), 跳过 placement(避免 Pending/误迁移)"; FAILED=1; return 1
    fi
    [ -n "${_pvcs}" ] || return 0
    _bound="$(placement_pvc_worker_bound "$1" ${_pvcs})" || _rc=$?
    case "${_rc}" in
        0) warn "  [$3] PVC ${_bound} 绑定在 worker(local-path), 跳过 placement(否则 Pending; 需共享存储或重建 PVC)"; return 1 ;;
        2) err "  [$3] 无法确认 PVC 绑定(查询失败), 跳过 placement(避免 Pending/误迁移)"; FAILED=1; return 1 ;;
    esac
    return 0
}

# CNPG Cluster 的 spec.affinity.nodeSelector 是否带 master: 0=带; 1=不带; 2=读取/解析失败。
_has_master_selector_cr_affinity() {   # <type> <ns> <name>
    local _out _rc=0
    _out="$(SSH "${K}" -n $2 get $1 $3 -o json 2>/dev/null)" || _rc=$?
    [ "${_rc}" -eq 0 ] || return 2
    printf '%s' "${_out}" | python3 -c '
import json, sys
try:
    aff = json.load(sys.stdin)["spec"].get("affinity") or {}
    sel = aff.get("nodeSelector") or {}
except Exception:
    sys.exit(2)
sys.exit(0 if "node-role.kubernetes.io/control-plane" in sel else 1)
'
}

_check_cr_affinity() {   # <type> <ns> <name>
    local _type="$1" _ns="$2" _name="$3" _json
    # 查询失败不能当成"不存在"静默通过(FAILED 已置位, 末尾非 0 退出)
    if ! _require_exists "check " "${_type}" "${_ns}" "${_name}"; then
        return 0
    fi
    _json="$(SSH "${K}" -n ${_ns} get ${_type} ${_name} -o json 2>/dev/null || true)"
    if ! printf '%s' "${_json}" | python3 -c '
import json, sys
try:
    aff = json.load(sys.stdin)["spec"].get("affinity") or {}
except Exception:
    sys.exit(1)
sel = aff.get("nodeSelector") or {}
tols = aff.get("tolerations") or []
ok = sel.get("node-role.kubernetes.io/control-plane") == "" and any(
    t.get("key") == "node-role.kubernetes.io/control-plane" and t.get("effect") == "NoSchedule"
    for t in tols
) and any(
    t.get("key") == "node.kubernetes.io/unschedulable" and t.get("effect") == "NoSchedule"
    for t in tols
)
sys.exit(0 if ok else 1)
'; then
        err "  [${_ns}/${_type}/${_name}] placement 不完整(需 spec.affinity.nodeSelector + control-plane/unschedulable tolerations)"; return 1
    fi
    ok "  [${_ns}/${_type}/${_name}] placement OK"
}

# RedisReplication sentinel 的 spec.sentinel.nodeSelector 是否带 master: 0=带; 1=不带; 2=读取/解析失败。
_has_master_selector_cr_sentinel() {   # <type> <ns> <name>
    local _out _rc=0
    _out="$(SSH "${K}" -n $2 get $1 $3 -o json 2>/dev/null)" || _rc=$?
    [ "${_rc}" -eq 0 ] || return 2
    printf '%s' "${_out}" | python3 -c '
import json, sys
try:
    sent = json.load(sys.stdin)["spec"].get("sentinel") or {}
    sel = sent.get("nodeSelector") or {}
except Exception:
    sys.exit(2)
sys.exit(0 if "node-role.kubernetes.io/control-plane" in sel else 1)
'
}

_check_cr_sentinel() {   # <type> <ns> <name>
    local _type="$1" _ns="$2" _name="$3" _json
    # 查询失败不能当成"不存在"静默通过(FAILED 已置位, 末尾非 0 退出)
    if ! _require_exists "check " "${_type}" "${_ns}" "${_name}"; then
        return 0
    fi
    _json="$(SSH "${K}" -n ${_ns} get ${_type} ${_name} -o json 2>/dev/null || true)"
    if ! printf '%s' "${_json}" | python3 -c '
import json, sys
try:
    sent = json.load(sys.stdin)["spec"].get("sentinel") or {}
except Exception:
    sys.exit(1)
sel = sent.get("nodeSelector") or {}
tols = sent.get("tolerations") or []
ok = sel.get("node-role.kubernetes.io/control-plane") == "" and any(
    t.get("key") == "node-role.kubernetes.io/control-plane" and t.get("effect") == "NoSchedule"
    for t in tols
) and any(
    t.get("key") == "node.kubernetes.io/unschedulable" and t.get("effect") == "NoSchedule"
    for t in tols
)
sys.exit(0 if ok else 1)
'; then
        err "  [${_ns}/${_type}/${_name}] sentinel placement 不完整(需 spec.sentinel.nodeSelector + control-plane/unschedulable tolerations)"; return 1
    fi
    ok "  [${_ns}/${_type}/${_name}] sentinel placement OK"
}

_check_one() {
    local _type="$1" _ns="$2" _name="$3" _json
    # 查询失败不能当成"不存在"静默通过(FAILED 已置位, 末尾非 0 退出)
    if ! _require_exists "check " "${_type}" "${_ns}" "${_name}"; then
        return 0
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

_check_cr() {   # <type> <ns> <name>
    local _type="$1" _ns="$2" _name="$3" _json
    # 查询失败不能当成"不存在"静默通过(FAILED 已置位, 末尾非 0 退出)
    if ! _require_exists "check " "${_type}" "${_ns}" "${_name}"; then
        return 0
    fi
    _json="$(SSH "${K}" -n ${_ns} get ${_type} ${_name} -o json 2>/dev/null || true)"
    if ! printf '%s' "${_json}" | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)["spec"]
except Exception:
    sys.exit(1)
sel = s.get("nodeSelector") or {}
tols = s.get("tolerations") or []
ok = sel.get("node-role.kubernetes.io/control-plane") == "" and any(
    t.get("key") == "node-role.kubernetes.io/control-plane" and t.get("effect") == "NoSchedule"
    for t in tols
) and any(
    t.get("key") == "node.kubernetes.io/unschedulable" and t.get("effect") == "NoSchedule"
    for t in tols
)
sys.exit(0 if ok else 1)
'; then
        err "  [${_ns}/${_type}/${_name}] placement 不完整(需 CR spec.nodeSelector + control-plane/unschedulable tolerations)"; return 1
    fi
    ok "  [${_ns}/${_type}/${_name}] placement OK"
}

# 清理 CubeStackCluster 内由 25_cubestack_operator.sh 持久化的组件 placement。
# 背景(2026-11-11 CodeRabbit): 只 patch 工作负载/CR 不够 —— components.<name>.values 里
#   仍存着 master nodeSelector, 后续组件调和/升级会把它重新带回。这里只删除 installer
#   写入的 control-plane key, 保留用户自定义 selector 与全部 tolerations(与 patch 回滚口径一致)。
_cb_clear_cr_component_placement() {
    local _ns="${CUBESTACK_OPERATOR_NAMESPACE:-cubestack-system}"
    local _json _rc=0 _msg _out _name _patch
    _json="$(SSH "${K}" -n "${_ns}" get csc -o json 2>/dev/null)" || _rc=$?
    if [ "${_rc}" -ne 0 ]; then
        _msg="$(SSH "${K}" -n "${_ns}" get csc -o json 2>&1 >/dev/null)" || true
        case "${_msg}" in
            *NotFound*|*"not found"*|*"doesn't have a resource type"*)
                say "  [${_ns}/csc] 不存在, 跳过 CR 组件 placement 回滚"; return 0 ;;
            *)
                err "  [${_ns}/csc] 查询失败, 未清理 CR 内组件 placement: $(printf '%s' "${_msg}" | tail -1)"
                FAILED=1; return 1 ;;
        esac
    fi
    _out="$(printf '%s' "${_json}" | python3 -c '
import json, sys

KEY = "node-role.kubernetes.io/control-plane"
PATHS = [
    ("cubepilot", "values", "operator", "nodeSelector"),
    ("cubepilot", "values", "api", "nodeSelector"),
    ("cubepilot", "values", "web", "nodeSelector"),
    ("cubestackControllerManager", "values", "nodeSelector"),
    ("cubestackPortal", "values", "nodeSelector"),
    ("envoyGateway", "values", "deployment", "pod", "nodeSelector"),
    ("aiGateway", "values", "controller", "nodeSelector"),
    ("prometheus", "values", "prometheusOperator", "nodeSelector"),
    ("prometheus", "values", "prometheus", "prometheusSpec", "nodeSelector"),
    ("prometheus", "values", "alertmanager", "alertmanagerSpec", "nodeSelector"),
    ("prometheus", "values", "grafana", "nodeSelector"),
    ("prometheus", "values", "kube-state-metrics", "nodeSelector"),
    ("perses", "values", "manager", "nodeSelector"),
]
try:
    items = json.load(sys.stdin).get("items") or []
except Exception:
    sys.exit(2)
if not items:
    sys.exit(0)
cr = items[0]
patch = {}
for path in PATHS:
    cur = cr.get("spec") or {}
    ok = True
    for k in ("components",) + path:
        if not isinstance(cur, dict) or k not in cur:
            ok = False
            break
        cur = cur[k]
    if not ok or not isinstance(cur, dict) or KEY not in cur:
        continue
    node = patch
    for k in ("spec", "components") + path:
        node = node.setdefault(k, {})
    node[KEY] = None
print(json.dumps({"name": (cr.get("metadata") or {}).get("name", ""), "patch": patch}))
' 2>/dev/null)" || {
        err "  [${_ns}/csc] 解析失败, 未清理 CR 内组件 placement"; FAILED=1; return 1; }
    [ -n "${_out}" ] || { say "  [${_ns}/csc] 不存在, 跳过 CR 组件 placement 回滚"; return 0; }
    _name="$(printf '%s' "${_out}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || true)"
    _patch="$(printf '%s' "${_out}" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("patch") or {}, separators=(",",":")))' 2>/dev/null || true)"
    [ -n "${_name}" ] || { say "  [${_ns}/csc] 不存在, 跳过 CR 组件 placement 回滚"; return 0; }
    if [ -z "${_patch}" ] || [ "${_patch}" = "{}" ]; then
        say "  [${_ns}/csc/${_name}] 无 master 组件 placement, 跳过"; return 0
    fi
    if printf '%s' "${_patch}" | SSH "${K} -n ${_ns} patch csc ${_name} --type=merge --patch-file=/dev/stdin" >/dev/null 2>&1; then
        ok "  [${_ns}/csc/${_name}] 已移除 CR 内组件 master nodeSelector(保留其他 key/tolerations)"
    else
        err "  [${_ns}/csc/${_name}] 清理 CR 组件 placement 失败"; FAILED=1
    fi
}

FAILED=0
case "${ACTION}" in
    apply)
        say "CubeStack operator/平台组件 master placement(Deployment) ..."
        # ★ 2026-10-27: 下面的 template patch 会触发 Deployment 滚动。若 Deployment 挂 RWO PVC
        #   且策略仍是 RollingUpdate, 旧 Pod 持卷、新 Pod Multi-Attach 卡死(实机 cuberouter)。
        #   先把这些 Deployment 改成 Recreate, 再 patch placement(来自 lib-common)。
        for _ns in cubestack-system cuberouter; do
            ensure_rwo_deployments_recreate "${_ns}" "cubestack.io/managed-by=cubestack-operator" 30 || true
        done
        unset _ns
        for _w in "${_CB_WORKLOADS[@]}"; do
            IFS='|' read -r _t _n _name <<< "${_w}"
            if ! _require_exists "apply " "${_t}" "${_n}" "${_name}"; then
                continue
            fi
            # local-path 等 nodeAffinity PV: PVC 已绑 worker 时钉 master 会 Pending。
            # 无法确认绑定时 guard 保守跳过并置 FAILED(不把"查不到"当成安全)。
            _obj_json="$( (SSH "${K}" -n "${_n}" get "${_t}" "${_name}" -o json 2>/dev/null) || true )"
            _pvc_guard_json "${_n}" "${_n}/${_t}/${_name}" "${_obj_json}" || continue
            if _patch_one "${_t}" "${_n}" "${_name}" "${_PATCH}"; then
                ok "  [${_n}/${_t}/${_name}] 已加 master nodeSelector + tolerations"
            else
                err "  [${_n}/${_t}/${_name}] patch 失败"; FAILED=1
            fi
        done
        say "CubeStack operator/平台组件 master placement(CR 调和的 StatefulSet) ..."
        for _w in "${_CB_CRS[@]}"; do
            IFS='|' read -r _t _n _name _pod _pvcp <<< "${_w}"
            if ! _require_exists "apply " "${_t}" "${_n}" "${_name}"; then
                continue
            fi
            if [ -n "${_pod}" ]; then
                _obj_json="$( (SSH "${K}" -n "${_n}" get pod "${_pod}" -o json 2>/dev/null) || true )"
                _pvc_guard_json "${_n}" "${_n}/${_t}/${_name}" "${_obj_json}" || continue
            elif [ -n "${_pvcp}" ]; then
                _pvc_guard_prefix "${_n}" "${_pvcp}" "${_n}/${_t}/${_name}" || continue
            fi
            _patch_cr_placement "${_t}" "${_n}" "${_name}" "spec" \
                "已加 master nodeSelector + tolerations(CR, 保留已有 tolerations)" || true
        done
        say "CubeStack operator/平台组件 master placement(CNPG Cluster spec.affinity) ..."
        for _w in "${_CB_CRS_AFFINITY[@]}"; do
            IFS='|' read -r _t _n _name _pvcp <<< "${_w}"
            if ! _require_exists "apply " "${_t}" "${_n}" "${_name}"; then
                continue
            fi
            if [ -n "${_pvcp}" ]; then
                _pvc_guard_prefix "${_n}" "${_pvcp}" "${_n}/${_t}/${_name}" || continue
            fi
            _patch_cr_placement "${_t}" "${_n}" "${_name}" "spec.affinity" \
                "已加 master affinity.nodeSelector + tolerations(CNPG, 保留已有 tolerations)" || true
        done
        say "CubeStack operator/平台组件 master placement(RedisReplication sentinel) ..."
        for _w in "${_CB_CRS_SENTINEL[@]}"; do
            IFS='|' read -r _t _n _name _pvcp <<< "${_w}"
            if ! _require_exists "apply " "${_t}" "${_n}" "${_name}"; then
                continue
            fi
            # Sentinel 和数据副本共用 local-path 卷前缀: Redis 侧被跳过时 sentinel 也必须跳过,
            # 否则 sentinel Pod 会迁到 master 而 PVC 仍绑在 worker → Pending(CodeRabbit 2026-11-11)。
            if [ -n "${_pvcp}" ]; then
                _pvc_guard_prefix "${_n}" "${_pvcp}" "${_n}/${_t}/${_name} sentinel" || continue
            fi
            _patch_cr_placement "${_t}" "${_n}" "${_name}" "spec.sentinel" \
                "已加 master sentinel.nodeSelector + tolerations(保留已有 tolerations)" || true
        done
        ;;
    check)
        say "校验 CubeStack operator/平台组件 master placement ..."
        for _w in "${_CB_WORKLOADS[@]}"; do
            IFS='|' read -r _t _n _name <<< "${_w}"
            _check_one "${_t}" "${_n}" "${_name}" || FAILED=1
        done
        for _w in "${_CB_CRS[@]}"; do
            IFS='|' read -r _t _n _name _pod _pvcp <<< "${_w}"
            _check_cr "${_t}" "${_n}" "${_name}" || FAILED=1
        done
        for _w in "${_CB_CRS_AFFINITY[@]}"; do
            IFS='|' read -r _t _n _name _pvcp <<< "${_w}"
            _check_cr_affinity "${_t}" "${_n}" "${_name}" || FAILED=1
        done
        for _w in "${_CB_CRS_SENTINEL[@]}"; do
            IFS='|' read -r _t _n _name _pvcp <<< "${_w}"
            _check_cr_sentinel "${_t}" "${_n}" "${_name}" || FAILED=1
        done
        ;;
    remove)
        say "移除 CubeStack 平台组件 master nodeSelector(tolerations 保留) ..."
        for _w in "${_CB_WORKLOADS[@]}"; do
            IFS='|' read -r _t _n _name <<< "${_w}"
            _ex=0; _exists "${_t}" "${_n}" "${_name}" || _ex=$?
            if [ "${_ex}" -eq 2 ]; then
                err "  [${_n}/${_t}/${_name}] remove 查询失败, 未清理(可能残留 master selector): ${_EXISTS_ERR:-未知错误}"; FAILED=1; continue
            fi
            if [ "${_ex}" -ne 0 ]; then
                say "  [${_n}/${_t}/${_name}] 不存在, 跳过"; continue
            fi
            if _patch_one "${_t}" "${_n}" "${_name}" "${_UNPATCH}"; then
                ok "  [${_n}/${_t}/${_name}] 已移除 master nodeSelector"
            else
                err "  [${_n}/${_t}/${_name}] remove patch 失败"; FAILED=1
            fi
        done
        for _w in "${_CB_CRS[@]}"; do
            IFS='|' read -r _t _n _name _pod _pvcp <<< "${_w}"
            _ex=0; _exists "${_t}" "${_n}" "${_name}" || _ex=$?
            if [ "${_ex}" -eq 2 ]; then
                err "  [${_n}/${_t}/${_name}] remove 查询失败, 未清理(可能残留 master selector): ${_EXISTS_ERR:-未知错误}"; FAILED=1; continue
            fi
            if [ "${_ex}" -ne 0 ]; then
                say "  [${_n}/${_t}/${_name}] 不存在, 跳过"; continue
            fi
            _sel_rc=0
            _has_master_selector_cr "${_t}" "${_n}" "${_name}" || _sel_rc=$?
            if [ "${_sel_rc}" -eq 2 ]; then
                err "  [${_n}/${_t}/${_name}] 读取 CR spec 失败, 无法确认 master nodeSelector"; FAILED=1; continue
            elif [ "${_sel_rc}" -eq 1 ]; then
                say "  [${_n}/${_t}/${_name}] 无 master nodeSelector, 跳过"; continue
            fi
            if _patch_cr_one "${_t}" "${_n}" "${_name}" "${_CR_UNPATCH}"; then
                ok "  [${_n}/${_t}/${_name}] 已移除 master nodeSelector(CR)"
            else
                err "  [${_n}/${_t}/${_name}] remove patch 失败"; FAILED=1
            fi
        done
        for _w in "${_CB_CRS_AFFINITY[@]}"; do
            IFS='|' read -r _t _n _name _pvcp <<< "${_w}"
            _ex=0; _exists "${_t}" "${_n}" "${_name}" || _ex=$?
            if [ "${_ex}" -eq 2 ]; then
                err "  [${_n}/${_t}/${_name}] remove 查询失败, 未清理(可能残留 master selector): ${_EXISTS_ERR:-未知错误}"; FAILED=1; continue
            fi
            if [ "${_ex}" -ne 0 ]; then
                say "  [${_n}/${_t}/${_name}] 不存在, 跳过"; continue
            fi
            _sel_rc=0
            _has_master_selector_cr_affinity "${_t}" "${_n}" "${_name}" || _sel_rc=$?
            if [ "${_sel_rc}" -eq 2 ]; then
                err "  [${_n}/${_t}/${_name}] 读取 CR spec.affinity 失败, 无法确认 master nodeSelector"; FAILED=1; continue
            elif [ "${_sel_rc}" -eq 1 ]; then
                say "  [${_n}/${_t}/${_name}] 无 master affinity.nodeSelector, 跳过"; continue
            fi
            if _patch_cr_one "${_t}" "${_n}" "${_name}" "${_CR_AFFINITY_UNPATCH}"; then
                ok "  [${_n}/${_t}/${_name}] 已移除 master affinity.nodeSelector(CNPG)"
            else
                err "  [${_n}/${_t}/${_name}] remove patch 失败"; FAILED=1
            fi
        done
        for _w in "${_CB_CRS_SENTINEL[@]}"; do
            IFS='|' read -r _t _n _name _pvcp <<< "${_w}"
            _ex=0; _exists "${_t}" "${_n}" "${_name}" || _ex=$?
            if [ "${_ex}" -eq 2 ]; then
                err "  [${_n}/${_t}/${_name}] remove 查询失败, 未清理(可能残留 master selector): ${_EXISTS_ERR:-未知错误}"; FAILED=1; continue
            fi
            if [ "${_ex}" -ne 0 ]; then
                say "  [${_n}/${_t}/${_name}] 不存在, 跳过"; continue
            fi
            _sel_rc=0
            _has_master_selector_cr_sentinel "${_t}" "${_n}" "${_name}" || _sel_rc=$?
            if [ "${_sel_rc}" -eq 2 ]; then
                err "  [${_n}/${_t}/${_name}] 读取 CR spec.sentinel 失败, 无法确认 master nodeSelector"; FAILED=1; continue
            elif [ "${_sel_rc}" -eq 1 ]; then
                say "  [${_n}/${_t}/${_name}] 无 master sentinel.nodeSelector, 跳过"; continue
            fi
            if _patch_cr_one "${_t}" "${_n}" "${_name}" "${_CR_SENTINEL_UNPATCH}"; then
                ok "  [${_n}/${_t}/${_name}] 已移除 master sentinel.nodeSelector"
            else
                err "  [${_n}/${_t}/${_name}] remove patch 失败"; FAILED=1
            fi
        done
        # 最后清 CR components.<name>.values 里持久化的 master selector, 防止后续调和/升级恢复。
        _cb_clear_cr_component_placement
        ;;
esac

if [ "${FAILED}" -ne 0 ]; then
    err "CubeStack 平台组件 placement ${ACTION} 存在失败项"; exit 1
fi
ok "CubeStack 平台组件 placement ${ACTION} 完成"
