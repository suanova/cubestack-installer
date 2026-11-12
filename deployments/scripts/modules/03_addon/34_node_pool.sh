#!/bin/bash
# ============================================================
# MODULE: node_pool
# DESC: 节点池调度隔离(默认启用: master 默认可调度, 平台组件仍钉 master)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: NODE_POOL_ENABLED
# REQUIRES: k8s_deploy
# 说明:
#   · 默认口径(2026-11-02): master 默认 **可调度** —— 不 cordon, 且移除 kubespray 默认
#     给 control-plane 打的 node-role.kubernetes.io/control-plane:NoSchedule 污点;
#     CubeStack operator/平台组件仍通过 nodeSelector + toleration 钉到 master。
#     设 NODE_POOL_MASTER_CORDON=true 可改为 cordon 隔离;
#     设 NODE_POOL_MASTER_SCHEDULABLE=false 可保留 kubespray 默认污点。
#     Pod 侧仍带 node.kubernetes.io/unschedulable:NoSchedule + control-plane toleration。
#   · 本模块 = 平台 placement(先) + master 标签/污点/cordon(后)：
#       - NODE_POOL_CUBESTACK_PLACEMENT=true(默认): cubestack-placement.sh 兜底 patch 平台 Deployment
#         (patch 前先给 RWO PVC 的 Deployment 设 Recreate，避免 Multi-Attach)；
#         25_cubestack_operator.sh 还会通过 CubeStackCluster components.<name>.values 在创建
#         cubepilot-api/operator、controller-manager、portal 时直接下发 master placement。
#       - NODE_POOL_PLATFORM_PLACEMENT=true(默认): 给 CoreDNS/metrics-server/dns-autoscaler/
#         calico-kube-controllers/registry/MetalLB/local-path-provisioner/MetaX operator
#         等系统组件加 master placement。
#         设 false 可只钉 CubeStack 平台组件、不动系统组件。
#       - 由 CR 调和的 StatefulSet(Prometheus/Alertmanager/Perses)通过 patch CR spec 下发。
#   · 执行时机(2026-11-10): 本模块排在 **34**, 在 dev_lab/model_images(vllm/sglang 大镜像
#     push)之前完成 placement; 组件由 operator 异步安装, 因此 apply 前按
#     NODE_POOL_PLACEMENT_WAIT_SECONDS(默认 180s)等待 CubeStackCluster.status 中的组件状态收敛,
#     避免"组件还没出现 → 跳过 → 留在 worker"。
#   · 无可用 worker 安全护栏(2026-10-28): 没有 **Ready 且未 cordon** 的 worker(单节点
#     all-in-one / 纯 master 集群, 或配置的 worker 全部 NotReady/已 cordon)时,
#     node-pool.sh 自动**跳过 cordon**, master 保持可调度 ——
#     否则 CoreDNS/dns-autoscaler(不带 node.kubernetes.io/unschedulable 容忍)滚动/重启
#     后会永久 Pending, 单节点集群将失去 DNS; 单节点 play 的 uncordon 也不会被撤销。
#     有 worker 时才按 NODE_POOL_MASTER_CORDON 执行。
#   · NODE_POOL_ENABLED 默认 true ⇒ 随全量部署在 dev_lab/model_images 之前(本文件 34)执行；也可手动:
#       sudo ./deploy-cluster.sh --steps node_pool
#       sudo env NODE_POOL_ACTION=remove ./deploy-cluster.sh --steps node_pool   # 回滚
#       (变量必须经 env 传给 root: sudo 默认 env_reset 会清掉 "VAR=... sudo" 前置赋值)
#   · remove 不看当前 NODE_POOL_MASTER_CORDON / NODE_POOL_CUBESTACK_PLACEMENT /
#     NODE_POOL_PLATFORM_PLACEMENT：应用后把开关改成 false 再回滚, 同样会清掉本工具
#     施加的 cordon 与 master nodeSelector(幂等; 不存在的对象/未施加的 selector 跳过)。
#     placement 移除失败会使回滚**非 0 退出**(不再降级为告警), 由调用方如实看到残留。
#   · cordon 由本工具创建时会打 ownership annotation; remove 只回滚自己创建的 cordon,
#     不会误删用户/其他工具预先设置的 cordon。remove **不还原**已移除的 master 污点
#     (可调度是默认策略; 需要恢复污点请手工 kubectl taint)。
#   · 详见 docs/node-pool.md。
# 数据源: cluster.conf NODES / NODE_POOL_* (cluster.defaults.conf §2.8)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

_ACTION="$(echo "${NODE_POOL_ACTION:-apply}" | tr '[:upper:]' '[:lower:]')"
case "${_ACTION}" in
    apply|check|remove) : ;;
    *) err "NODE_POOL_ACTION=${_ACTION} 非法(apply|check|remove)"; exit 1 ;;
esac

# remove 分支必须在 TOGGLE 检查之前: 即使开关已关, 也要能回滚节点标签/cordon。
if [ "${_ACTION}" = "remove" ]; then
    say "节点池回滚(master 标签/cordon + placement)..."
    bash "${SCRIPT_DIR}/tools/node/node-pool.sh" --remove
    # ★ 2026-10-28: placement 回滚**不看当前 placement 开关** —— 应用时开关可能是 true,
    #   之后被改成 false; 只回滚"当前仍为 true"的项会留下 nodeSelector 残留(与 cordon 的
    #   ownership 口径一致: remove 尽力回滚本工具曾做过的 placement)。
    #   master-placement.sh --remove 只在 workload 确实带 master selector 时才 patch /
    #   删 registry Pod, 从未应用过 placement 时不会扰动 registry。
    #   ★ 失败必须向上传播(2026-10-28): 回滚没清干净时不能报成功, 否则调度器拒绝重跑。
    _rm_failed=0
    bash "${SCRIPT_DIR}/tools/k8s/cubestack-placement.sh" --remove || _rm_failed=1
    bash "${SCRIPT_DIR}/tools/k8s/master-placement.sh" --remove || _rm_failed=1
    if [ "${_rm_failed}" -ne 0 ]; then
        err "节点池回滚: placement 移除存在失败项, 请人工核对残留 nodeSelector"
        exit 1
    fi
    exit 0
fi

if [ "${NODE_POOL_ENABLED:-false}" != "true" ]; then
    say "NODE_POOL_ENABLED=false, 跳过节点池隔离(平台 placement 配置完成后再启用)"
    exit 0
fi

# operator 异步创建平台组件: placement 前有界等待 CubeStackCluster.status 收敛。
# 直接读 CR 的 status.components/conditions(组件状态由 operator 维护), 不再硬编码
# Deployment 名单 —— 新组件自动覆盖, 也不会漏掉 DaemonSet/多工作负载组件。
# 超时/查询失败不阻断(后续可重跑收敛)。
_wait_for_platform_deployments() {
    local _ns="${CUBESTACK_OPERATOR_NAMESPACE:-cubestack-system}"
    local _wait_s _deadline _remain _q _rc _json _msg _state
    _wait_s="${NODE_POOL_PLACEMENT_WAIT_SECONDS:-180}"
    case "${_wait_s}" in ''|*[!0-9]*) _wait_s=180 ;; esac
    say "等待平台组件状态收敛(以 CubeStackCluster.status 为准, 最多 ${_wait_s}s)..."
    _deadline=$(( $(date +%s) + _wait_s ))
    while :; do
        _remain=$(( _deadline - $(date +%s) ))
        _q="${_remain}"; [ "${_q}" -ge 1 ] || _q=1
        # 单次查询也受预算约束: 远端 kubectl 无默认请求超时, 同时用 timeout + --request-timeout。
        _rc=0
        _json="$(SSH "timeout ${_q} ${K}" --request-timeout="${_q}s" -n "${_ns}" get csc -o json 2>/dev/null)" || _rc=$?
        if [ "${_rc}" -ne 0 ]; then
            _msg="$(SSH "timeout ${_q} ${K}" --request-timeout="${_q}s" -n "${_ns}" get csc -o json 2>&1 >/dev/null)" || true
            case "${_msg}" in
                *NotFound*|*"not found"*|*"doesn't have a resource type"*)
                    return 0 ;;   # 无 CR / CRD 未装 → 无平台组件可等
                *)
                    warn "  读取 CubeStackCluster.status 失败(rc=${_rc}), 继续 placement: $(printf '%s' "${_msg}" | tail -1)"
                    return 0 ;;
            esac
        fi
        _state="$(printf '%s' "${_json}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
items = d.get("items") if isinstance(d, dict) and isinstance(d.get("items"), list) else [d]
if not items:
    print("READY"); sys.exit(0)
cr = items[0]
st = cr.get("status") or {}
def _int(v):
    try:
        return int(v)
    except Exception:
        return None
gen = _int((cr.get("metadata") or {}).get("generation"))
obs = _int(st.get("observedGeneration"))
# 只有 status 对应当前 generation 才可信: 升级/改 spec 后旧 status 仍可能是上一次调和的
# Ready=True / 全部终态, 直接放行会让新组件尚未创建就被跳过(留在 worker)。
if gen is not None and (obs is None or obs < gen):
    print("PENDING:status 尚未对应当前 generation(observed=%s < %s)" % (obs, gen))
    sys.exit(0)
ready = ""
for c in st.get("conditions") or []:
    if c.get("type") == "Ready":
        ready = c.get("status", ""); break
comps = st.get("components") or []
TERMINAL = ("ready", "degraded", "failed")
pending = ["%s=%s" % (c.get("name", "?"), c.get("phase", "<无>"))
           for c in comps if str(c.get("phase", "")).lower() not in TERMINAL]
if ready == "True":
    print("READY"); sys.exit(0)
if comps and not pending:
    # 所有已上报组件都已到终态(Degraded/Failed 也算安装结束; 继续 placement 由后续步骤暴露问题)
    print("READY"); sys.exit(0)
if not comps:
    print("PENDING:status.components 尚未生成"); sys.exit(0)
print("PENDING:" + " ".join(pending))
' 2>/dev/null)" || { warn "  解析 CubeStackCluster.status 失败, 继续 placement"; return 0; }
        case "${_state}" in
            READY) say "平台组件状态已收敛, 开始 placement"; return 0 ;;
        esac
        if [ "$(date +%s)" -ge "${_deadline}" ]; then
            warn "等待超时(${_wait_s}s, ${_state#PENDING:}); 继续 placement, 可重跑 --steps node_pool 收敛"
            return 0
        fi
        sleep 5
    done
}

case "${_ACTION}" in
    apply)
        init_remote_kubectl || exit 1
        _wait_for_platform_deployments
        if [ "${NODE_POOL_PLATFORM_PLACEMENT:-true}" = "true" ]; then
            say "系统组件 master placement(CoreDNS/metrics/registry/MetalLB 等)..."
            bash "${SCRIPT_DIR}/tools/k8s/master-placement.sh" --apply
        fi
        if [ "${NODE_POOL_CUBESTACK_PLACEMENT:-true}" = "true" ]; then
            say "CubeStack operator/平台组件 master placement ..."
            bash "${SCRIPT_DIR}/tools/k8s/cubestack-placement.sh" --apply
        fi
        say "节点池隔离: master 打标签/按配置 cordon(无 worker 集群自动保持可调度)..."
        bash "${SCRIPT_DIR}/tools/node/node-pool.sh" --apply
        ;;
    check)
        if [ "${NODE_POOL_PLATFORM_PLACEMENT:-true}" = "true" ]; then
            say "校验系统组件 master placement..."
            bash "${SCRIPT_DIR}/tools/k8s/master-placement.sh" --check
        fi
        if [ "${NODE_POOL_CUBESTACK_PLACEMENT:-true}" = "true" ]; then
            say "校验 CubeStack operator/平台组件 master placement..."
            bash "${SCRIPT_DIR}/tools/k8s/cubestack-placement.sh" --check
        fi
        say "节点池隔离: 校验 master 标签/cordon..."
        bash "${SCRIPT_DIR}/tools/node/node-pool.sh" --check
        ;;
esac
ok "节点池隔离完成(NODE_POOL_ACTION=${_ACTION})"
