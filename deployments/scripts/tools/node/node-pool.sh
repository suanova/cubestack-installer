#!/bin/bash
# ============================================================
# node-pool.sh — 节点池基础操作(master 标签 + 可选 cordon; 幂等可回滚)
# ------------------------------------------------------------
# 目标(2026-10-27): master 保持 Unschedulable=True(SchedulingDisabled), 但 Ceph/
#   operator 等平台 Pod 通过 nodeSelector + special toleration
#   (node.kubernetes.io/unschedulable:NoSchedule)仍可调度到 master。
#   本工具只做**节点侧**标签/cordon:
#     · --apply  : master 打 NODE_POOL_MASTER_LABEL(默认 node-pool=control-plane);
#                  NODE_POOL_MASTER_CORDON=true 时 cordon, 并打 ownership annotation
#                  cubestack.io/node-pool-cordoned-by-installer=true;
#     · --check  : 只读校验期望态(标签 + cordon); 漂移非 0;
#     · --remove : 移除本工具打的标签; 仅当 ownership annotation 存在时 uncordon
#                  (不会误删用户/其他工具创建的 cordon)。
#   DaemonSet 会由控制器自动容忍 node.kubernetes.io/unschedulable:NoSchedule;
#   Deployment/StatefulSet 需要在其 PodTemplate 里显式加该 toleration(见 docs/node-pool.md)。
#
# 用法:
#   sudo ./node-pool.sh --apply [--only <hostname>]
#   sudo ./node-pool.sh --check
#   sudo ./node-pool.sh --remove
# 数据源: cluster.conf NODES / NODE_POOL_* (见 cluster.defaults.conf §2.8)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/../../lib-common.sh"
load_config

ACTION=""; ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)  ACTION="apply"; shift ;;
        --check)  ACTION="check"; shift ;;
        --remove) ACTION="remove"; shift ;;
        --only)   ONLY="${2:?--only 需要 hostname}"; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1(可用 --apply/--check/--remove/--only)" >&2; exit 2 ;;
    esac
done

ACTION="${ACTION:-${NODE_POOL_ACTION:-apply}}"
case "${ACTION}" in apply|check|remove) : ;; *) err "NODE_POOL_ACTION=${ACTION} 非法(apply|check|remove)"; exit 1 ;; esac

MASTER_LABEL="${NODE_POOL_MASTER_LABEL:-node-pool=control-plane}"
MASTER_CORDON="${NODE_POOL_MASTER_CORDON:-true}"
case "${MASTER_CORDON,,}" in
    true|1|yes|on)  MASTER_CORDON="true" ;;
    false|0|no|off|"") MASTER_CORDON="false" ;;
    *) err "NODE_POOL_MASTER_CORDON 非法: '${MASTER_CORDON}'(true/false)"; exit 1 ;;
esac
MASTER_KEY="${MASTER_LABEL%%=*}"
MASTER_VAL="${MASTER_LABEL#*=}"
if [ "${MASTER_KEY}" = "${MASTER_LABEL}" ] || [ -z "${MASTER_KEY}" ]; then
    err "NODE_POOL_MASTER_LABEL 需要 key=value: '${MASTER_LABEL}'"; exit 1
fi
if ! printf '%s' "${MASTER_KEY}" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._/-]*$'; then
    err "NODE_POOL_MASTER_LABEL key 非法: '${MASTER_KEY}'"; exit 1
fi
if ! printf '%s' "${MASTER_VAL}" | grep -qE '^[A-Za-z0-9._-]*$'; then
    err "NODE_POOL_MASTER_LABEL value 非法: '${MASTER_VAL}'"; exit 1
fi

init_remote_kubectl || exit 1

_np_get_labels() { SSH "${K} get node "$1" --show-labels --no-headers" 2>/dev/null | awk '{print $NF}'; }
_np_get_unsched() { SSH "${K} get node "$1" -o jsonpath='{.spec.unschedulable}'" 2>/dev/null || true; }
_np_get_annotations() { SSH "${K} get node "$1" -o jsonpath='{.metadata.annotations}'" 2>/dev/null || true; }
_np_label_present() { local labels="$1"; case ",${labels}," in *",${MASTER_KEY}=${MASTER_VAL},"*) return 0 ;; *) return 1 ;; esac; }
_np_owned() {
    # 真实 kubectl -o jsonpath='{.metadata.annotations}' 返回 JSON 对象:
    #   {"cubestack.io/node-pool-cordoned-by-installer":"true",...}
    # 测试/旧版本可能给 map[key:value]; 两种都认。
    case "$1" in
        *cubestack.io/node-pool-cordoned-by-installer:true*) return 0 ;;
        *'cubestack.io/node-pool-cordoned-by-installer":"true'*) return 0 ;;
        *) return 1 ;;
    esac
}

# 收集 master(可选 --only)
MASTER_HOSTS=()
for _line in "${NODES[@]:-}"; do
    [ -z "${_line}" ] && continue
    node_parse "${_line}"
    [ "${NODE_ROLE}" = "master" ] || continue
    [ -n "${NODE_HOSTNAME}" ] || continue
    [ -n "${ONLY}" ] && [ "${NODE_HOSTNAME}" != "${ONLY}" ] && continue
    MASTER_HOSTS+=("${NODE_HOSTNAME}")
done
if [ "${#MASTER_HOSTS[@]}" -eq 0 ]; then
    err "未找到 master 节点(NODES 无 role=master 或 --only 未命中)"
    exit 1
fi

say "节点池(master)动作=${ACTION}: ${#MASTER_HOSTS[@]} 台; label=${MASTER_KEY}=${MASTER_VAL}; cordon=${MASTER_CORDON}"
FAILED=0
for host in "${MASTER_HOSTS[@]}"; do
    labels="$(_np_get_labels "${host}")"
    unsched="$(_np_get_unsched "${host}")"
    ann="$(_np_get_annotations "${host}")"

    case "${ACTION}" in
        apply)
            if _np_label_present "${labels}"; then
                ok "  [${host}] 标签已就绪"
            else
                if SSH "${K} label node ${host} ${MASTER_LABEL} --overwrite" >/dev/null 2>&1; then
                    ok "  [${host}] 已打标签 ${MASTER_LABEL}"
                else
                    err "  [${host}] 打标签失败"; FAILED=1
                fi
            fi
            if [ "${MASTER_CORDON}" = "true" ]; then
                if [ "${unsched}" = "true" ]; then
                    if _np_owned "${ann}"; then
                        ok "  [${host}] 已 cordon(本工具标记)"
                    else
                        warn "  [${host}] 已 cordon(非本工具创建; remove 不会 uncordon)"
                    fi
                else
                    if SSH "${K} cordon ${host}" >/dev/null 2>&1; then
                        SSH "${K} annotate node ${host} cubestack.io/node-pool-cordoned-by-installer=true --overwrite" >/dev/null 2>&1 || true
                        ok "  [${host}] 已 cordon + ownership 标记"
                    else
                        err "  [${host}] cordon 失败"; FAILED=1
                    fi
                fi
            fi
            ;;
        check)
            if _np_label_present "${labels}"; then
                ok "  [${host}] 标签 OK(${MASTER_KEY}=${MASTER_VAL})"
            else
                err "  [${host}] 标签缺失/不匹配: 实际 labels=${labels:-<none>}, 期望 ${MASTER_KEY}=${MASTER_VAL}"; FAILED=1
            fi
            if [ "${MASTER_CORDON}" = "true" ]; then
                if [ "${unsched}" = "true" ]; then
                    ok "  [${host}] cordon OK"
                else
                    err "  [${host}] 未 cordon(spec.unschedulable 非 true)"; FAILED=1
                fi
            fi
            ;;
        remove)
            if _np_label_present "${labels}"; then
                if SSH "${K} label node ${host} ${MASTER_KEY}-" >/dev/null 2>&1; then
                    ok "  [${host}] 已移除标签 ${MASTER_KEY}"
                else
                    err "  [${host}] 移除标签失败"; FAILED=1
                fi
            else
                say "  [${host}] 标签不存在或值不同, 跳过移除"
            fi
            if [ "${MASTER_CORDON}" = "true" ]; then
                if _np_owned "${ann}"; then
                    if SSH "${K} uncordon ${host}" >/dev/null 2>&1; then
                        SSH "${K} annotate node ${host} cubestack.io/node-pool-cordoned-by-installer-" >/dev/null 2>&1 || true
                        ok "  [${host}] 已 uncordon(本工具创建)"
                    else
                        err "  [${host}] uncordon 失败"; FAILED=1
                    fi
                elif [ "${unsched}" = "true" ]; then
                    warn "  [${host}] 节点 cordon 非本工具创建(无 ownership annotation), 不 uncordon"
                else
                    say "  [${host}] 节点未 cordon, 无需 uncordon"
                fi
            fi
            ;;
    esac
done

if [ "${FAILED}" -ne 0 ]; then
    err "节点池动作 ${ACTION} 存在失败项"
    exit 1
fi
ok "节点池动作 ${ACTION} 完成(${#MASTER_HOSTS[@]} 台 master)"
