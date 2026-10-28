#!/bin/bash
# ============================================================
# master-placement.sh — 系统/平台组件 master placement(节点池 cordon 前置)
# ------------------------------------------------------------
# 目标(2026-10-27): master 保持 Unschedulable=True 时, CoreDNS/metrics-server/
#   dns-autoscaler/calico-kube-controllers/registry/MetalLB controller 仍能调度到 master。
#   做法: 给这些 Deployment/ReplicaSet 的 PodTemplate 加
#     nodeSelector: node-role.kubernetes.io/control-plane: ""
#     tolerations:  control-plane:NoSchedule + node.kubernetes.io/unschedulable:NoSchedule
#   MetalLB speaker 是 DaemonSet, 只补 toleration(全节点), 不加 master nodeSelector。
#
# 注意:
#   · kubespray 下次 k8s_deploy 会按 addons.yml 重新渲染这些 Deployment; 本工具需在
#     k8s_deploy 之后执行(node_pool 模块在 addon 末尾调用), 或重跑 --steps node_pool。
#   · registry 是裸 ReplicaSet: 模板变更不会自动替换现有 Pod, apply/remove 都会删旧 Pod
#     让其按新模板重建; **删除失败会报错并非 0 退出**(否则"已删除"是假成功)。
#   · --remove 只移除本工具加的 master nodeSelector; tolerations 保留(无害, 避免
#     master 仍有 control-plane taint 时把组件卡 Pending)。组件会留到当前 master 上,
#     下次滚动才会重新调度。未带 master selector 的对象**跳过**(不 patch、不为 registry
#     重建 Pod) —— 从未应用过 placement 时回滚不会扰动任何组件。
#
# 用法:
#   sudo ./master-placement.sh --apply
#   sudo ./master-placement.sh --check
#   sudo ./master-placement.sh --remove
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
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1(可用 --apply/--check/--remove)" >&2; exit 2 ;;
    esac
done
[ -n "${ACTION}" ] || { echo "需要 --apply/--check/--remove" >&2; exit 2; }

init_remote_kubectl || exit 1

# <type>|<namespace>|<name>
_MASTER_WORKLOADS=(
    "deploy|kube-system|coredns"
    "deploy|kube-system|metrics-server"
    "deploy|kube-system|dns-autoscaler"
    "deploy|kube-system|calico-kube-controllers"
    "rs|kube-system|registry"
    "deploy|metallb-system|controller"
)
_MASTER_DS=(
    "ds|metallb-system|speaker"
)

_PATCH='{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node.kubernetes.io/unschedulable","operator":"Exists","effect":"NoSchedule"}]}}}}'
_DS_PATCH='{"spec":{"template":{"spec":{"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node.kubernetes.io/unschedulable","operator":"Exists","effect":"NoSchedule"}]}}}}'
_UNPATCH='{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":null}}}}}'

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
    esac
    _EXISTS_ERR="$(printf '%s' "${out}" | tail -1 || true)"
    return 2
}

_patch_one() {   # <type> <ns> <name> <patch>
    SSH "${K} -n $2 patch $1 $3 --type=strategic -p '$4'" >/dev/null 2>&1
}

# 当前 PodTemplate 是否带 master nodeSelector: 0=带; 1=不带; 2=读取/解析失败。
# ★ 必须先把 SSH 输出捕获下来(2026-10-28 CodeRabbit): 否则 pipefail 下"SSH 非零但输出
#   完整 JSON"会让管道返回 SSH 状态, 被误判成"无 selector"; JSON 非法也与"无 selector"
#   混为一谈。remove 对 2 必须报错而非跳过。
_has_master_selector() {   # <type> <ns> <name>
    local _out _rc=0
    _out="$(SSH "${K} -n $2 get $1 $3 -o json" 2>/dev/null)" || _rc=$?
    [ "${_rc}" -eq 0 ] || return 2
    printf '%s' "${_out}" | python3 -c '
import json, sys
try:
    sel = json.load(sys.stdin)["spec"]["template"]["spec"].get("nodeSelector") or {}
except Exception:
    sys.exit(2)
sys.exit(0 if "node-role.kubernetes.io/control-plane" in sel else 1)
'
}

# 仍带 master nodeSelector 的 Pod 名(每行一个): 0=有; 1=确认没有; 2=查询/解析失败。
# ★ partial remove 的重试(2026-10-28 CodeRabbit): 上一次 patch 已生效、删 Pod 失败时,
#   RS 模板已无 selector —— 只看模板会跳过, 旧 Pod 会一直留在 master 上。重试时按 Pod
#   实际 spec 补删, 且只删**确实仍带** selector 的 Pod(从未应用过 placement 的健康 Pod
#   不会被白重启)。
_pods_with_master_selector() {   # <ns> <label-selector>
    local _out _rc=0
    _out="$(SSH "${K} -n $1 get pods -l $2 -o json" 2>/dev/null)" || _rc=$?
    [ "${_rc}" -eq 0 ] || return 2
    printf '%s' "${_out}" | python3 -c '
import json, sys
try:
    items = json.load(sys.stdin).get("items", [])
except Exception:
    sys.exit(2)
sel = "node-role.kubernetes.io/control-plane"
names = [i["metadata"]["name"] for i in items
         if sel in ((i.get("spec") or {}).get("nodeSelector") or {})]
if names:
    print("\n".join(names))
    sys.exit(0)
sys.exit(1)
'
}

_check_one() {   # <type> <ns> <name> <require_selector:0|1>
    local _type="$1" _ns="$2" _name="$3" _need_sel="$4" _json
    if ! _exists "${_type}" "${_ns}" "${_name}"; then
        say "  [${_ns}/${_type}/${_name}] 不存在, 跳过"
        return 0
    fi
    _json="$(SSH "${K}" -n ${_ns} get ${_type} ${_name} -o json 2>/dev/null || true)"
    # ★ 2026-10-27: 必须**只检查 nodeSelector/tolerations 字段** —— tolerations 里也含
    #   control-plane/unschedulable 字符串, 旧实现 grep 整个 JSON 会对"只有 tolerations、
    #   没有 nodeSelector"的对象误报 OK(容器 c 实测: Pod 实际全在 worker)。
    # ★ 2026-10-28: control-plane 与 unschedulable 两个 toleration 都必须校验 —— 只有
    #   unschedulable 时, master 的 control-plane taint 仍会把 Pod 挡在 master 外。
    if ! printf '%s' "${_json}" | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)["spec"]["template"]["spec"]
except Exception:
    sys.exit(1)
sel = s.get("nodeSelector") or {}
tols = s.get("tolerations") or []
need_sel = sys.argv[1] == "1"
ok = (not need_sel or sel.get("node-role.kubernetes.io/control-plane") == "") and any(
    t.get("key") == "node-role.kubernetes.io/control-plane" and t.get("effect") == "NoSchedule"
    for t in tols
) and any(
    t.get("key") == "node.kubernetes.io/unschedulable" and t.get("effect") == "NoSchedule"
    for t in tols
)
sys.exit(0 if ok else 1)
' "${_need_sel}"; then
        err "  [${_ns}/${_type}/${_name}] placement 不完整(selector=${_need_sel}, 需 master nodeSelector + control-plane/unschedulable tolerations)"; return 1
    fi
    ok "  [${_ns}/${_type}/${_name}] placement OK"
    return 0
}

FAILED=0
case "${ACTION}" in
    apply)
        say "系统组件 master placement(Deployment/ReplicaSet ...)"
        for _w in "${_MASTER_WORKLOADS[@]}"; do
            IFS='|' read -r _t _n _name <<< "${_w}"
            if ! _exists "${_t}" "${_n}" "${_name}"; then
                say "  [${_n}/${_t}/${_name}] 不存在, 跳过"
                continue
            fi
            if _patch_one "${_t}" "${_n}" "${_name}" "${_PATCH}"; then
                ok "  [${_n}/${_t}/${_name}] 已加 master nodeSelector + tolerations"
                # ReplicaSet 不会因模板变更自动替换现有 Pod; registry 是 kubespray 的裸 RS,
                # 必须删旧 Pod 让 RS 按新模板在 master 重建。
                # delete 失败不能报成功: 模板已改但运行中的 Pod 仍是旧调度(旧模板),
                # 必须让调用方看到 FAILED(2026-10-28 CodeRabbit)。
                if [ "${_t}" = "rs" ]; then
                    if SSH "${K} -n ${_n} delete pod -l k8s-app=registry --wait=false >/dev/null 2>&1"; then
                        say "  [${_n}/${_t}/${_name}] 已删除旧 Pod, 由 ReplicaSet 按新模板重建"
                    else
                        err "  [${_n}/${_t}/${_name}] 删除旧 Pod 失败, registry Pod 仍使用旧调度模板"; FAILED=1
                    fi
                fi
            else
                err "  [${_n}/${_t}/${_name}] patch 失败"; FAILED=1
            fi
        done
        for _w in "${_MASTER_DS[@]}"; do
            IFS='|' read -r _t _n _name <<< "${_w}"
            if ! _exists "${_t}" "${_n}" "${_name}"; then
                say "  [${_n}/${_t}/${_name}] 不存在, 跳过"
                continue
            fi
            if _patch_one "${_t}" "${_n}" "${_name}" "${_DS_PATCH}"; then
                ok "  [${_n}/${_t}/${_name}] 已加 tolerations(DaemonSet 全节点)"
            else
                err "  [${_n}/${_t}/${_name}] patch 失败"; FAILED=1
            fi
        done
        ;;
    check)
        say "校验系统组件 master placement ..."
        for _w in "${_MASTER_WORKLOADS[@]}"; do
            IFS='|' read -r _t _n _name <<< "${_w}"
            _check_one "${_t}" "${_n}" "${_name}" 1 || FAILED=1
        done
        for _w in "${_MASTER_DS[@]}"; do
            IFS='|' read -r _t _n _name <<< "${_w}"
            _check_one "${_t}" "${_n}" "${_name}" 0 || FAILED=1
        done
        ;;
    remove)
        say "移除系统组件 master nodeSelector(tolerations 保留) ..."
        for _w in "${_MASTER_WORKLOADS[@]}"; do
            IFS='|' read -r _t _n _name <<< "${_w}"
            _ex=0; _exists "${_t}" "${_n}" "${_name}" || _ex=$?
            if [ "${_ex}" -eq 2 ]; then
                err "  [${_n}/${_t}/${_name}] remove 查询失败, 未清理(可能残留 master selector): ${_EXISTS_ERR:-未知错误}"; FAILED=1; continue
            fi
            if [ "${_ex}" -ne 0 ]; then
                say "  [${_n}/${_t}/${_name}] 不存在, 跳过"; continue
            fi
            # ★ 2026-10-28: 只有确实带 master nodeSelector 才 patch —— 未应用过 placement
            #   时跳过(含 registry RS 的 Pod 删除), 避免回滚动作重启无关组件。
            _sel_rc=0
            _has_master_selector "${_t}" "${_n}" "${_name}" || _sel_rc=$?
            if [ "${_sel_rc}" -eq 2 ]; then
                err "  [${_n}/${_t}/${_name}] 读取 PodTemplate 失败, 无法确认 master nodeSelector"; FAILED=1; continue
            elif [ "${_sel_rc}" -eq 1 ]; then
                # ★ partial remove 重试(2026-10-28 CodeRabbit): 上一次 patch 已生效但删 Pod
                #   失败时, 模板已无 selector; 只看模板会跳过, 旧 Pod 仍以 master selector
                #   留在 master 上。只补删**确实仍带** selector 的 Pod —— 从未应用过
                #   placement 的 registry Pod 没有该 selector, 不会被白重启。
                if [ "${_t}" = "rs" ]; then
                    _pod_rc=0
                    _stale_pods="$(_pods_with_master_selector "${_n}" "k8s-app=registry")" || _pod_rc=$?
                    if [ "${_pod_rc}" -eq 2 ]; then
                        err "  [${_n}/${_t}/${_name}] 读取 Pod 失败, 无法确认是否有残留 registry Pod"; FAILED=1; continue
                    fi
                    if [ "${_pod_rc}" -eq 0 ] && [ -n "${_stale_pods}" ]; then
                        while IFS= read -r _p; do
                            [ -n "${_p}" ] || continue
                            if SSH "${K} -n ${_n} delete pod ${_p} --wait=false >/dev/null 2>&1"; then
                                say "  [${_n}/${_t}/${_name}] 已删除残留 Pod ${_p}(仍带 master nodeSelector)"
                            else
                                err "  [${_n}/${_t}/${_name}] 删除残留 Pod ${_p} 失败, 仍使用旧调度模板"; FAILED=1
                            fi
                        done <<< "${_stale_pods}"
                    fi
                    unset _stale_pods _pod_rc
                fi
                say "  [${_n}/${_t}/${_name}] 无 master nodeSelector, 跳过"; continue
            fi
            if _patch_one "${_t}" "${_n}" "${_name}" "${_UNPATCH}"; then
                ok "  [${_n}/${_t}/${_name}] 已移除 master nodeSelector"
                if [ "${_t}" = "rs" ]; then
                    if SSH "${K} -n ${_n} delete pod -l k8s-app=registry --wait=false >/dev/null 2>&1"; then
                        say "  [${_n}/${_t}/${_name}] 已删除旧 Pod, 由 ReplicaSet 按新模板重建"
                    else
                        err "  [${_n}/${_t}/${_name}] 删除旧 Pod 失败, registry Pod 仍使用旧调度模板"; FAILED=1
                    fi
                fi
            else
                err "  [${_n}/${_t}/${_name}] remove patch 失败"; FAILED=1
            fi
        done
        ;;
esac

if [ "${FAILED}" -ne 0 ]; then
    err "系统组件 placement ${ACTION} 存在失败项"
    exit 1
fi
ok "系统组件 placement ${ACTION} 完成"
