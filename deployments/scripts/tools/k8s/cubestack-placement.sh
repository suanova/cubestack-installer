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
_CB_CRS_SENTINEL=(
    "redisreplications.redis.redis.opstreelabs.in|cuberouter|cuberouter-redis"
)

_PATCH='{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node.kubernetes.io/unschedulable","operator":"Exists","effect":"NoSchedule"}]}}}}'
_UNPATCH='{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":null}}}}}'
# CRD 的 merge patch 只能走 --type=merge(strategic 不适用于自定义资源)。
_CR_PATCH='{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node.kubernetes.io/unschedulable","operator":"Exists","effect":"NoSchedule"}]}}'
_CR_UNPATCH='{"spec":{"nodeSelector":null}}'
_CR_AFFINITY_PATCH='{"spec":{"affinity":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node.kubernetes.io/unschedulable","operator":"Exists","effect":"NoSchedule"}]}}}'
# 只清 nodeSelector; CNPG 的 affinity 还含 podAntiAffinityType, merge patch 保留它。
_CR_AFFINITY_UNPATCH='{"spec":{"affinity":{"nodeSelector":null}}}'
_CR_SENTINEL_PATCH='{"spec":{"sentinel":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node.kubernetes.io/unschedulable","operator":"Exists","effect":"NoSchedule"}]}}}'
_CR_SENTINEL_UNPATCH='{"spec":{"sentinel":{"nodeSelector":null}}}'

# 三态存在性探测: 0=存在; 1=不存在; 2=查询失败(API/RBAC/SSH)。
# ★ remove 必须区分"不存在"与"查不到"(2026-10-28 CodeRabbit): 查询失败时跳过循环会让
#   残留的 master selector 被报成回滚成功。apply/check 仍按"非 0 即跳过"处理(行为不变)。
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
_cr_pvcs_by_prefix() {   # <ns> <prefix>
    (SSH "${K}" -n "$1" get pvc -o json 2>/dev/null) | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
p = sys.argv[1]
for i in d.get("items", []):
    n = (i.get("metadata") or {}).get("name", "")
    if n.startswith(p):
        print(n)
' "$2"
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
    if ! _exists "${_type}" "${_ns}" "${_name}"; then
        say "  [${_ns}/${_type}/${_name}] 不存在, 跳过"; return 0
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
    if ! _exists "${_type}" "${_ns}" "${_name}"; then
        say "  [${_ns}/${_type}/${_name}] 不存在, 跳过"; return 0
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

_check_cr() {   # <type> <ns> <name>
    local _type="$1" _ns="$2" _name="$3" _json
    if ! _exists "${_type}" "${_ns}" "${_name}"; then
        say "  [${_ns}/${_type}/${_name}] 不存在, 跳过"; return 0
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
            if ! _exists "${_t}" "${_n}" "${_name}"; then
                say "  [${_n}/${_t}/${_name}] 不存在, 跳过"; continue
            fi
            # local-path 等 nodeAffinity PV: PVC 已绑 worker 时钉 master 会 Pending。
            _pvcs="$( (SSH "${K}" -n "${_n}" get "${_t}" "${_name}" -o json 2>/dev/null) | placement_pod_pvcs || true )"
            if [ -n "${_pvcs}" ]; then
                if _bound="$(placement_pvc_worker_bound "${_n}" ${_pvcs})"; then
                    warn "  [${_n}/${_t}/${_name}] PVC ${_bound} 绑定在 worker(local-path), 跳过 placement(否则 Pending; 需共享存储或重建 PVC)"
                    continue
                fi
            fi
            if _patch_one "${_t}" "${_n}" "${_name}" "${_PATCH}"; then
                ok "  [${_n}/${_t}/${_name}] 已加 master nodeSelector + tolerations"
            else
                err "  [${_n}/${_t}/${_name}] patch 失败"; FAILED=1
            fi
        done
        say "CubeStack operator/平台组件 master placement(CR 调和的 StatefulSet) ..."
        for _w in "${_CB_CRS[@]}"; do
            IFS='|' read -r _t _n _name _pod _pvcp <<< "${_w}"
            if ! _exists "${_t}" "${_n}" "${_name}"; then
                say "  [${_n}/${_t}/${_name}] 不存在, 跳过"; continue
            fi
            if [ -n "${_pod}" ]; then
                _pvcs="$( (SSH "${K}" -n "${_n}" get pod "${_pod}" -o json 2>/dev/null) | placement_pod_pvcs || true )"
                if [ -n "${_pvcs}" ]; then
                    if _bound="$(placement_pvc_worker_bound "${_n}" ${_pvcs})"; then
                        warn "  [${_n}/${_t}/${_name}] PVC ${_bound} 绑定在 worker(local-path), 跳过 placement(否则 Pending; 需共享存储或重建 PVC)"
                        continue
                    fi
                fi
            elif [ -n "${_pvcp}" ]; then
                _pvcs="$(_cr_pvcs_by_prefix "${_n}" "${_pvcp}")"
                if [ -n "${_pvcs}" ]; then
                    if _bound="$(placement_pvc_worker_bound "${_n}" ${_pvcs})"; then
                        warn "  [${_n}/${_t}/${_name}] PVC ${_bound} 绑定在 worker(local-path), 跳过 placement(否则 Pending; 需共享存储或重建 PVC)"
                        continue
                    fi
                fi
            fi
            if _patch_cr_one "${_t}" "${_n}" "${_name}" "${_CR_PATCH}"; then
                ok "  [${_n}/${_t}/${_name}] 已加 master nodeSelector + tolerations(CR)"
            else
                err "  [${_n}/${_t}/${_name}] patch 失败"; FAILED=1
            fi
        done
        say "CubeStack operator/平台组件 master placement(CNPG Cluster spec.affinity) ..."
        for _w in "${_CB_CRS_AFFINITY[@]}"; do
            IFS='|' read -r _t _n _name _pvcp <<< "${_w}"
            if ! _exists "${_t}" "${_n}" "${_name}"; then
                say "  [${_n}/${_t}/${_name}] 不存在, 跳过"; continue
            fi
            if [ -n "${_pvcp}" ]; then
                _pvcs="$(_cr_pvcs_by_prefix "${_n}" "${_pvcp}")"
                if [ -n "${_pvcs}" ]; then
                    if _bound="$(placement_pvc_worker_bound "${_n}" ${_pvcs})"; then
                        warn "  [${_n}/${_t}/${_name}] PVC ${_bound} 绑定在 worker(local-path), 跳过 placement(否则 Pending; 需共享存储或重建 PVC)"
                        continue
                    fi
                fi
            fi
            if _patch_cr_one "${_t}" "${_n}" "${_name}" "${_CR_AFFINITY_PATCH}"; then
                ok "  [${_n}/${_t}/${_name}] 已加 master affinity.nodeSelector + tolerations(CNPG)"
            else
                err "  [${_n}/${_t}/${_name}] patch 失败"; FAILED=1
            fi
        done
        say "CubeStack operator/平台组件 master placement(RedisReplication sentinel) ..."
        for _w in "${_CB_CRS_SENTINEL[@]}"; do
            IFS='|' read -r _t _n _name <<< "${_w}"
            if ! _exists "${_t}" "${_n}" "${_name}"; then
                say "  [${_n}/${_t}/${_name}] 不存在, 跳过"; continue
            fi
            if _patch_cr_one "${_t}" "${_n}" "${_name}" "${_CR_SENTINEL_PATCH}"; then
                ok "  [${_n}/${_t}/${_name}] 已加 master sentinel.nodeSelector + tolerations"
            else
                err "  [${_n}/${_t}/${_name}] sentinel patch 失败"; FAILED=1
            fi
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
            IFS='|' read -r _t _n _name <<< "${_w}"
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
            IFS='|' read -r _t _n _name <<< "${_w}"
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
        ;;
esac

if [ "${FAILED}" -ne 0 ]; then
    err "CubeStack 平台组件 placement ${ACTION} 存在失败项"; exit 1
fi
ok "CubeStack 平台组件 placement ${ACTION} 完成"
