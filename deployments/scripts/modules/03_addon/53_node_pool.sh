#!/bin/bash
# ============================================================
# MODULE: node_pool
# DESC: 节点池调度隔离(默认启用: 平台组件钉 master, master 默认不 cordon; 可选 cordon)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: NODE_POOL_ENABLED
# REQUIRES: k8s_deploy
# 说明:
#   · 默认口径(2026-10-27): master 保持**可调度**(Unschedulable=false)，CubeStack operator/
#     平台组件通过 nodeSelector + toleration 钉到 master。需要维护窗口时显式
#     NODE_POOL_MASTER_CORDON=true；Pod 侧已有 node.kubernetes.io/unschedulable:NoSchedule
#     toleration，仍能调度到 cordon master。
#   · 本模块 = 平台 placement(先) + master 标签/按需 cordon(后)：
#       - NODE_POOL_CUBESTACK_PLACEMENT=true(默认): cubestack-placement.sh 兜底 patch 平台 Deployment；
#         25_cubestack_operator.sh 还会通过 CubeStackCluster components.<name>.values 在创建
#         cubepilot-api/operator、controller-manager、portal 时直接下发 master placement。
#       - NODE_POOL_PLATFORM_PLACEMENT=false(默认): 不动 CoreDNS/metrics/registry/MetalLB 等系统组件。
#   · NODE_POOL_ENABLED 默认 true ⇒ 随全量部署在 addon 末尾(本文件 53)执行；也可手动:
#       sudo ./deploy-cluster.sh --steps node_pool
#       NODE_POOL_ACTION=remove sudo ./deploy-cluster.sh --steps node_pool   # 回滚
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
    say "节点池回滚(master 标签/cordon)..."
    bash "${SCRIPT_DIR}/tools/node/node-pool.sh" --remove
    if [ "${NODE_POOL_CUBESTACK_PLACEMENT:-true}" = "true" ]; then
        bash "${SCRIPT_DIR}/tools/k8s/cubestack-placement.sh" --remove || warn "  CubeStack 平台组件 placement 回滚失败(不阻断)"
    fi
    if [ "${NODE_POOL_PLATFORM_PLACEMENT:-true}" = "true" ]; then
        bash "${SCRIPT_DIR}/tools/k8s/master-placement.sh" --remove || warn "  系统组件 placement 回滚失败(不阻断)"
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
        say "节点池隔离: master 打标签$( [ "${NODE_POOL_MASTER_CORDON:-true}" = "true" ] && echo ' + cordon' || echo '' )..."
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
