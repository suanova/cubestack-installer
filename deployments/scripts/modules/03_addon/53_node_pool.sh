#!/bin/bash
# ============================================================
# MODULE: node_pool
# DESC: 节点池调度隔离(默认启用: master 默认 cordon, 平台组件仍可调度到 master)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: NODE_POOL_ENABLED
# REQUIRES: k8s_deploy
# 说明:
#   · 默认口径(2026-10-27): master 默认 **cordon(Unschedulable=true)**；CubeStack operator/
#     平台组件通过 nodeSelector + toleration 仍能调度/重建到 master。设
#     NODE_POOL_MASTER_CORDON=false 可保持 master 可调度；Pod 侧已带
#     node.kubernetes.io/unschedulable:NoSchedule + control-plane toleration。
#   · 本模块 = 平台 placement(先) + master 标签/cordon(后)：
#       - NODE_POOL_CUBESTACK_PLACEMENT=true(默认): cubestack-placement.sh 兜底 patch 平台 Deployment
#         (patch 前先给 RWO PVC 的 Deployment 设 Recreate，避免 Multi-Attach)；
#         25_cubestack_operator.sh 还会通过 CubeStackCluster components.<name>.values 在创建
#         cubepilot-api/operator、controller-manager、portal 时直接下发 master placement。
#       - NODE_POOL_PLATFORM_PLACEMENT=false(默认): 不动 CoreDNS/metrics/registry/MetalLB 等系统组件。
#   · 无可用 worker 安全护栏(2026-10-28): 没有 **Ready 且未 cordon** 的 worker(单节点
#     all-in-one / 纯 master 集群, 或配置的 worker 全部 NotReady/已 cordon)时,
#     node-pool.sh 自动**跳过 cordon**, master 保持可调度 ——
#     否则 CoreDNS/dns-autoscaler(不带 node.kubernetes.io/unschedulable 容忍)滚动/重启
#     后会永久 Pending, 单节点集群将失去 DNS; 单节点 play 的 uncordon 也不会被撤销。
#     有 worker 时才按 NODE_POOL_MASTER_CORDON 执行。
#   · NODE_POOL_ENABLED 默认 true ⇒ 随全量部署在 addon 末尾(本文件 53)执行；也可手动:
#       sudo ./deploy-cluster.sh --steps node_pool
#       sudo env NODE_POOL_ACTION=remove ./deploy-cluster.sh --steps node_pool   # 回滚
#       (变量必须经 env 传给 root: sudo 默认 env_reset 会清掉 "VAR=... sudo" 前置赋值)
#   · remove 不看当前 NODE_POOL_MASTER_CORDON / NODE_POOL_CUBESTACK_PLACEMENT /
#     NODE_POOL_PLATFORM_PLACEMENT：应用后把开关改成 false 再回滚, 同样会清掉本工具
#     施加的 cordon 与 master nodeSelector(幂等; 不存在的对象/未施加的 selector 跳过)。
#     placement 移除失败会使回滚**非 0 退出**(不再降级为告警), 由调用方如实看到残留。
#   · cordon 由本工具创建时会打 ownership annotation; remove 只回滚自己创建的 cordon,
#     不会误删用户/其他工具预先设置的 cordon。
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

case "${_ACTION}" in
    apply)
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
