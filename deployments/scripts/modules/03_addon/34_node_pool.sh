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
#     push)之前完成 placement; 组件 Deployment 由 operator 异步创建, 因此 apply 前会做
#     有界等待(NODE_POOL_PLACEMENT_WAIT_SECONDS, 默认 180s), 避免"组件还没出现 → 跳过 →
#     留在 worker"。
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

# operator 异步创建平台组件: placement 前先有界等待目标 Deployment 出现。
# 只等待 CR 中 enabled 的组件, 禁用的组件不会拖满超时; 等待失败不阻断(后续可重跑收敛)。
_wait_for_platform_deployments() {
    local _ns="${CUBESTACK_OPERATOR_NAMESPACE:-cubestack-system}"
    local _cr_json _expected _deadline _missing _item _dns _dname _wait_s
    _wait_s="${NODE_POOL_PLACEMENT_WAIT_SECONDS:-180}"
    case "${_wait_s}" in ''|*[!0-9]*) _wait_s=180 ;; esac
    _cr_json="$(SSH "${K}" -n "${_ns}" get csc -o json 2>/dev/null || true)"
    case "${_cr_json}" in
        ""|*"NotFound"*|*"not found"*|*"Unable to connect"*) return 0 ;;
    esac
    _expected="$(printf '%s' "${_cr_json}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
items = d.get("items") if isinstance(d, dict) and isinstance(d.get("items"), list) else [d]
if not items:
    sys.exit(0)
c = (items[0].get("spec") or {}).get("components") or {}
m = {
    "cubepilot": ["cubestack-system/cubepilot-operator", "cubestack-system/cubepilot-api"],
    "cubestackControllerManager": ["cubestack-system/cubestack-controller-manager"],
    "cubestackPortal": ["cubestack-system/cubestack-portal"],
    "cubestackDocs": ["cubestack-system/cubestack-docs"],
    "lws": ["lws-system/lws-controller-manager"],
    "envoyGateway": ["envoy-gateway-system/envoy-gateway"],
    "aiGateway": ["ai-gateway-system/ai-gateway-controller"],
    "cuberouter": ["cuberouter/cuberouter"],
    "prometheus": ["monitoring/kube-prometheus-kube-prome-operator",
                   "monitoring/kube-prometheus-grafana",
                   "monitoring/kube-prometheus-kube-state-metrics"],
    "perses": ["monitoring/perses-operator-controller-manager"],
}
for k, v in m.items():
    if (c.get(k) or {}).get("enabled"):
        for x in v:
            print(x)
')" || return 0
    [ -n "${_expected}" ] || return 0
    say "等待平台组件 Deployment 出现(最多 ${_wait_s}s)..."
    _deadline=$(( $(date +%s) + _wait_s ))
    _n_expected=0
    for _item in ${_expected}; do _n_expected=$(( _n_expected + 1 )); done
    [ "${_n_expected}" -ge 1 ] || _n_expected=1
    while :; do
        # 单次查询预算 = 剩余时间 / 待查对象数(至少 1s)。远端 kubectl 没有默认请求超时,
        # 必须同时用 --request-timeout 和远端 timeout 兜底 —— SSH ConnectTimeout 只约束
        # 连接建立, 不约束远端命令; 否则一次 API 卡死会拖过整个 NODE_POOL_PLACEMENT_WAIT_SECONDS。
        _remain=$(( _deadline - $(date +%s) ))
        _q=$(( _remain / _n_expected ))
        [ "${_q}" -ge 1 ] || _q=1
        _missing=""
        for _item in ${_expected}; do
            _dns="${_item%%/*}"; _dname="${_item##*/}"
            SSH "timeout ${_q} ${K}" --request-timeout="${_q}s" -n "${_dns}" get deploy "${_dname}" \
                >/dev/null 2>&1 </dev/null \
                || _missing="${_missing} ${_item}"
        done
        if [ -z "${_missing}" ]; then
            say "平台组件 Deployment 已出现, 开始 placement"
            return 0
        fi
        if [ "$(date +%s)" -ge "${_deadline}" ]; then
            warn "等待超时(仍缺失:${_missing}); 继续 placement, 缺失项可重跑 --steps node_pool 收敛"
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
