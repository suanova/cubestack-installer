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
#                  CORDON=false 时反向收敛: 本工具创建过的 cordon(annotation 判定)会被
#                  uncordon 并清 annotation; 用户/其他工具创建的 cordon 保持不动;
#                  ownership 标记写/删失败不会静默忽略: 写失败回滚 cordon;
#                  删失败先**确认性重读** annotation: 已清则视为完成, 仍在才重新 cordon,
#                  读取失败则不擅自动作并报错(避免留下无标记、永不回滚的 cordon);
#     · --check  : 只读校验期望态(标签 + cordon); 漂移非 0;
#     · --remove : 移除本工具打的标签; 仅当 ownership annotation 存在时 uncordon
#                  (不会误删用户/其他工具创建的 cordon)。
#   DaemonSet 会由控制器自动容忍 node.kubernetes.io/unschedulable:NoSchedule;
#   Deployment/StatefulSet 需要在其 PodTemplate 里显式加该 toleration(见 docs/node-pool.md)。
#
#   ★ 无可用 worker 安全护栏(2026-10-28): 没有 **Ready 且未 cordon** 的 worker 时(单节点
#     all-in-one、纯 master 集群, 或配置的 worker 全部 NotReady/已 cordon), 即使
#     NODE_POOL_MASTER_CORDON=true 也**跳过 cordon**:
#       - CoreDNS/dns-autoscaler 的 kubespray 模板只容忍 control-plane:NoSchedule,
#         没有 node.kubernetes.io/unschedulable 容忍; NODE_POOL_PLATFORM_PLACEMENT=false
#         (默认)也不会补 ⇒ 全部节点 cordon 后, DNS 组件滚动/重启会永久 Pending;
#       - 单节点 play(cubestack-single-node.yml)特意 uncordon 的唯一 master 不会被再次 cordon;
#       - --apply 会回滚**本工具此前创建**的 cordon(ownership annotation 判定);
#       - --check 在该拓扑下期望 master 可调度, 被 cordon 即报漂移。
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
_np_get_annotations() { SSH "${K} get node "${1}" -o jsonpath='{.metadata.annotations}'" 2>/dev/null || true; }
# 读取 annotations 并**保留退出码**: 用于区分"读取失败"与"标记确实不存在"。
_np_read_annotations() { SSH "${K} get node "${1}" -o jsonpath='{.metadata.annotations}'" 2>/dev/null; }
_np_label_present() { local labels="$1"; case ",${labels}," in *",${MASTER_KEY}=${MASTER_VAL},"*) return 0 ;; *) return 1 ;; esac; }
_np_owned() {
    # 真实 kubectl -o jsonpath='{.metadata.annotations}' 返回 JSON 对象:
    #   {"cubestack.io/node-pool-cordoned-by-installer":"true",...}
    # 测试/旧版本可能给 map[key:value]; 两种都认。
    # ★ 必须锚定 key 的左边界(2026-10-28): 否则 example.cubestack.io/node-pool-cordoned-by-installer
    #   这类相似 key 会被误判为本工具标记(--remove 会误 uncordon)。
    case "$1" in
        *'[cubestack.io/node-pool-cordoned-by-installer:true'*) return 0 ;;
        *' cubestack.io/node-pool-cordoned-by-installer:true'*) return 0 ;;
        *'"cubestack.io/node-pool-cordoned-by-installer":"true'*) return 0 ;;
        *) return 1 ;;
    esac
}

# 回滚本工具创建的 cordon: 先 uncordon, 成功后再删 ownership 标记。
# ⚠ 顺序不能反: 先删标记时若 uncordon 失败, 所有权丢失 → 无法重试。
# ⚠ 标记删除失败不能静默忽略(2026-10-28): stale marker 会让后续 --remove 把管理员
#   后来创建的 cordon 当成本工具的而误 uncordon。删不掉时把节点重新 cordon 回去,
#   保持"marker ⇒ 本工具创建"的契约; 本轮失败(非 0), 下一轮幂等重试。
_np_uncordon_owned() {   # <host> <success-suffix> → 0=成功; 1=失败(已 err)
    local host="$1" suf="${2:-}"
    if ! SSH "${K} uncordon ${host}" >/dev/null 2>&1; then
        err "  [${host}] uncordon 失败${suf:+(${suf})}"
        return 1
    fi
    if SSH "${K} annotate node ${host} cubestack.io/node-pool-cordoned-by-installer-" >/dev/null 2>&1; then
        ok "  [${host}] 已 uncordon(本工具创建${suf})"
        return 0
    fi
    # annotate 返回非 0 也可能已在远端删除成功(仅 SSH 返回失败) —— 必须**确认性重读**:
    #   读取失败(空输出) ≠ 标记不存在; 只有读取成功且确认无标记才视为完成。
    #   确认标记仍在时才补偿 cordon; 无法确认时不擅自 cordon(否则会留下无标记的 cordon,
    #   后续 apply/remove 会当外部 cordon 永不回滚)。
    local _ann2=""
    if _ann2="$(_np_read_annotations "${host}")"; then
        if _np_owned "${_ann2}"; then
            if SSH "${K} cordon ${host}" >/dev/null 2>&1; then
                err "  [${host}] uncordon 成功但 ownership 标记仍在; 已重新 cordon 保持状态一致, 请修复后重跑${suf:+(${suf})}"
            else
                err "  [${host}] ownership 标记仍在且无法重新 cordon: 节点可调度但 marker 仍在, 请手工处理${suf:+(${suf})}"
                err "           修复后先删标记: kubectl annotate node ${host} cubestack.io/node-pool-cordoned-by-installer-"
            fi
            return 1
        fi
        ok "  [${host}] 已 uncordon; ownership 标记已清除(annotate 返回非 0, 复核确认生效${suf})"
        return 0
    fi
    err "  [${host}] ownership 标记删除返回失败且无法复核(读取 annotations 失败); 未重新 cordon(避免创建无标记 cordon)${suf:+(${suf})}"
    err "           请检查: kubectl get node ${host} -o jsonpath='{.metadata.annotations}' ; 然后重跑 --apply/--remove 收敛"
    return 1
}

# 收集 master(可选 --only) + 统计 worker(--only 不影响 worker 计数: 护栏看的是集群拓扑)
MASTER_HOSTS=()
WORKER_HOSTS=()
WORKER_COUNT=0
for _line in "${NODES[@]:-}"; do
    [ -z "${_line}" ] && continue
    node_parse "${_line}"
    [ -n "${NODE_HOSTNAME}" ] || continue
    case "${NODE_ROLE}" in
        worker) WORKER_COUNT=$((WORKER_COUNT + 1)); WORKER_HOSTS+=("${NODE_HOSTNAME}"); continue ;;
        master) : ;;
        *) continue ;;
    esac
    [ -n "${ONLY}" ] && [ "${NODE_HOSTNAME}" != "${ONLY}" ] && continue
    MASTER_HOSTS+=("${NODE_HOSTNAME}")
done
if [ "${#MASTER_HOSTS[@]}" -eq 0 ]; then
    err "未找到 master 节点(NODES 无 role=master 或 --only 未命中)"
    exit 1
fi

# ★ 无**可用** worker 安全护栏(2026-10-28): 仅按 NODES 配置数量不够 —— worker 全部 NotReady
#   或已被 cordon 时，cordon master 同样会让集群没有可调度节点:
#   CoreDNS/dns-autoscaler(kubespray 模板只容忍 control-plane:NoSchedule, 无
#   node.kubernetes.io/unschedulable 容忍; 默认也不跑 master-placement.sh)滚动/重启后
#   永久 Pending ⇒ 单节点 all-in-one 集群整集群 DNS 失效; 单节点 play 的 uncordon 也会被撤销。
#   ⇒ 只有存在 Ready 且未 cordon 的 worker 才 cordon; 否则等同 NODE_POOL_MASTER_CORDON=false
#   (apply 不新增 cordon, 并回滚本工具此前创建的 cordon)。--remove 不探测(不需要该判定)。
NO_WORKER_CORDON_GUARD=0
USABLE_WORKERS=0
if [ "${MASTER_CORDON}" = "true" ] && [ "${ACTION}" != "remove" ]; then
    if [ "${WORKER_COUNT}" -eq 0 ]; then
        NO_WORKER_CORDON_GUARD=1
        MASTER_CORDON="false"
        warn "NODES 无 role=worker 节点(${#MASTER_HOSTS[@]} 台 master): 跳过 cordon, master 保持可调度"
        warn "  原因: 无 worker 时 cordon 会让 CoreDNS/dns-autoscaler 等系统组件滚动/重启后永久 Pending"
        warn "  (--check 在本拓扑下同样期望 master 可调度)"
    else
        for _wh in "${WORKER_HOSTS[@]}"; do
            _wst="$(SSH "${K} get node "${_wh}" --no-headers" 2>/dev/null | awk '{print $2}')" || true
            _wun="$(_np_get_unsched "${_wh}")"
            _why=""
            case "${_wst}" in
                Ready|Ready,*) : ;;
                *) _why="状态='${_wst:-未知}'" ;;
            esac
            if [ "${_wun}" = "true" ]; then
                _why="${_why:+${_why}, }已 cordon"
            fi
            if [ -z "${_why}" ]; then
                USABLE_WORKERS=$((USABLE_WORKERS + 1))
            else
                warn "  worker ${_wh} 不可用(${_why})"
            fi
        done
        if [ "${USABLE_WORKERS}" -eq 0 ]; then
            NO_WORKER_CORDON_GUARD=1
            MASTER_CORDON="false"
            warn "NODES 有 ${WORKER_COUNT} 台 worker 但无可用(Ready 且未 cordon)worker: 跳过 cordon, master 保持可调度"
            warn "  原因: 无可用 worker 时 cordon 会让 CoreDNS/dns-autoscaler 等系统组件滚动/重启后永久 Pending"
            warn "  (--check 在本拓扑下同样期望 master 可调度)"
        fi
    fi
fi

say "节点池(master)动作=${ACTION}: ${#MASTER_HOSTS[@]} 台 master, ${WORKER_COUNT} 台 worker; label=${MASTER_KEY}=${MASTER_VAL}; cordon=${MASTER_CORDON}"
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
                        if SSH "${K} annotate node ${host} cubestack.io/node-pool-cordoned-by-installer=true --overwrite" >/dev/null 2>&1; then
                            ok "  [${host}] 已 cordon + ownership 标记"
                        else
                            # 标记写不上 → 回滚 cordon: 否则留下"本工具 cordon 但无所有权"的
                            # 不可回滚状态(remove 永远不敢动它), 且上面的成功文案会说谎。
                            if SSH "${K} uncordon ${host}" >/dev/null 2>&1; then
                                err "  [${host}] cordon 成功但 ownership 标记写入失败; 已回滚 uncordon(未施加隔离, 请修复后重跑)"
                            else
                                err "  [${host}] ownership 标记写入失败且无法回滚 uncordon: 节点已 cordon 但无标记, 请手工处理"
                                err "           kubectl uncordon ${host}"
                            fi
                            FAILED=1
                        fi
                    else
                        err "  [${host}] cordon 失败"; FAILED=1
                    fi
                fi
            elif [ "${NO_WORKER_CORDON_GUARD}" = "1" ] && [ "${unsched}" = "true" ]; then
                # 护栏只阻止"新增" cordon 不够: 此前有 worker 时本工具 cordon 过、
                # 之后 worker 被移除的集群, 遗留 cordon 同样会让系统组件 Pending ⇒ 回滚自己的。
                if _np_owned "${ann}"; then
                    _np_uncordon_owned "${host}" "; 无 worker 拓扑: 回滚本工具此前创建的 cordon" || FAILED=1
                else
                    warn "  [${host}] 已 cordon(非本工具创建); 无 worker 拓扑下建议 uncordon, 否则系统组件重启会 Pending"
                fi
            elif [ "${NO_WORKER_CORDON_GUARD}" = "1" ]; then
                ok "  [${host}] 无 worker 拓扑: 保持可调度(跳过 cordon)"
            elif [ "${unsched}" = "true" ]; then
                # ★ NODE_POOL_MASTER_CORDON=false(有 worker 的普通集群): 本工具此前 cordon 过
                #   的节点要恢复可调度(幂等收敛; 模块不会先跑 --remove)。非本工具创建的 cordon
                #   保持不动(只告警), 与 --remove 的 ownership 口径一致。
                if _np_owned "${ann}"; then
                    _np_uncordon_owned "${host}" "; CORDON=false" || FAILED=1
                else
                    warn "  [${host}] 已 cordon(非本工具创建; CORDON=false 也不会 uncordon)"
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
            elif [ "${NO_WORKER_CORDON_GUARD}" = "1" ]; then
                if [ "${unsched}" = "true" ]; then
                    err "  [${host}] 无 worker 拓扑但节点被 cordon: 系统组件滚动/重启会永久 Pending(--apply 可回滚本工具创建的 cordon)"; FAILED=1
                else
                    ok "  [${host}] 可调度 OK(无 worker 拓扑跳过 cordon)"
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
            # ★ remove 不看当前 NODE_POOL_MASTER_CORDON: 只要 ownership annotation 在,
            #   就回滚 cordon(创建时可能是 true, 之后配置改回 false 也要能清理)。
            if _np_owned "${ann}"; then
                _np_uncordon_owned "${host}" "" || FAILED=1
            elif [ "${unsched}" = "true" ]; then
                warn "  [${host}] 节点 cordon 非本工具创建(无 ownership annotation), 不 uncordon"
            else
                say "  [${host}] 节点未 cordon, 无需 uncordon"
            fi
            ;;
    esac
done

if [ "${FAILED}" -ne 0 ]; then
    err "节点池动作 ${ACTION} 存在失败项"
    exit 1
fi
ok "节点池动作 ${ACTION} 完成(${#MASTER_HOSTS[@]} 台 master)"
