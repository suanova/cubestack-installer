#!/bin/bash
# ============================================================
# MODULE: node_net_guard
# DESC: 节点源策略路由/Calico rpfilter 冲突预检(IB/多网卡节点; 默认只检查不阻断)
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# REQUIRES: k8s_passwordless
# 说明:
#   · 背景(2026-10-27 worker05/08 实机): 主机镜像 netplan 自带
#     `routing-policy: from <IB> lookup <table>`; Calico 给本地 Pod 的设备路由没有
#     preferred source, 内核按接口枚举顺序选到 IB 地址作源; Pod 回包到达宿主机 cali
#     网卡后, Calico raw 表 rpfilter 反向校验命中 IB 表 → 出接口(IB)≠入接口(cali)
#     → DROP; kubelet 探针超时 → coredns/metallb/metrics-server 0/1 无限重启。
#   · 根治(默认): k8s_deploy 的 sync-kubespray-config.sh 写
#     calico_use_default_route_src_ipaddr=true → FELIX_DEVICEROUTESOURCEADDRESS=status.hostIP
#     → Felix 给每 Pod 设备路由写 src=<节点 IP>。k8s_deploy 会断言该值真的进了 inventory。
#   · 本模块只做“部署前发现 + 明确指引”: 逻辑在 tools/node/node-net-guard.sh。
#     动作由 NODE_NET_GUARD_ACTION 控制:
#       check = 只检测(默认; 原生修复开启 → 告警不阻断; 关闭 → 硬失败)
#       rule  = 存量集群/无法改 Calico 时, 幂等加 ip rule + systemd 持久化兜底
#       off   = 跳过
#   · 定序: k8s_deploy 的 REQUIRES 显式声明本模块, 保证在 kubespray 之前跑。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

_ACTION="$(echo "${NODE_NET_GUARD_ACTION:-check}" | tr '[:upper:]' '[:lower:]')"
case "${_ACTION}" in
    check)
        say "节点源策略路由/Calico rpfilter 冲突预检(只检查; 原生修复 CALICO_USE_DEFAULT_ROUTE_SRC_IPADDR=${CALICO_USE_DEFAULT_ROUTE_SRC_IPADDR:-true}) ..."
        bash "${SCRIPT_DIR}/tools/node/node-net-guard.sh" --check
        ;;
    rule|fix)
        warn "NODE_NET_GUARD_ACTION=${_ACTION}: 将在命中节点写 ip rule + systemd 持久化兜底(原生修复仍是首选)"
        bash "${SCRIPT_DIR}/tools/node/node-net-guard.sh" --apply-rule
        ;;
    remove)
        say "清理节点侧兜底规则 ..."
        bash "${SCRIPT_DIR}/tools/node/node-net-guard.sh" --remove
        ;;
    off)
        say "NODE_NET_GUARD_ACTION=off, 跳过节点源策略路由预检"
        exit 0
        ;;
    *)
        err "NODE_NET_GUARD_ACTION=${_ACTION} 非法(可用 check|rule|remove|off)"
        exit 1
        ;;
esac

ok "节点源策略路由预检完成"
