#!/bin/bash
# ============================================================
# MODULE: vm_network
# DESC: 初始化宿主网络(bridge/nat)
# PHASE: env
# DEFAULT: 0
# REPEAT: 0
# 说明: 宿主网络初始化(网桥/NAT)已移出默认部署序列, 改由创建虚拟机的
#       tools/vm/create-vms.sh 在创建 VM 前自动执行; 本模块保留用于
#       --steps vm_network / --enable vm_network 手动独立执行。
# 数据源: cluster.conf (NET_MODE / BRIDGE / NAT_NET_NAME ...)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# 网络初始化前, 校验关键命令已装(ip/modprobe/systemctl), 缺失时给出安装指引:
# CLI 镜像已内置 iproute2/kmod/systemd/procps/bridge-utils, 宿主机裸跑需自行安装。
for _bin in ip modprobe systemctl sysctl; do
    command -v "${_bin}" >/dev/null 2>&1 || { err "缺少命令 ${_bin}; 请先安装对应包(如 iproute2/kmod/systemd/procps), CLI 容器已内置"; exit 1; }
done

# 未定义任何虚拟机 → 无需宿主网络, 幂等跳过(与 create-vms.sh 逻辑一致)
if ! vm_conf_has_nodes; then
    say "未定义任何虚拟机(tools/vm/vm-nodes.conf 无节点), 跳过宿主网络初始化(纯裸金属集群)"
    exit 0
fi

say "初始化宿主网络 (NET_MODE=${NET_MODE:-bridge}) ..."
case "${NET_MODE:-bridge}" in
    bridge)
        bash "${SCRIPT_DIR}/tools/net/setup-vm-network.sh"
        bash "${SCRIPT_DIR}/tools/net/verify-vm-network.sh" || true
        ;;
    nat)
        bash "${SCRIPT_DIR}/tools/net/setup-libvirt-nat.sh" "${NAT_NET_NAME:-cubestack-nat}"
        ;;
    *) err "未知 NET_MODE: ${NET_MODE}"; exit 1 ;;
esac
ok "宿主网络就绪"
