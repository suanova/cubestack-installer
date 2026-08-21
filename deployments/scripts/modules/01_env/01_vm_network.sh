#!/bin/bash
# ============================================================
# MODULE: vm_network
# DESC: 初始化宿主网络(bridge/nat)
# PHASE: env
# DEFAULT: 1
# REPEAT: 0
# 说明: 由 deploy-cluster.sh 按框架调度; 也可独立执行
# 数据源: cluster.conf (NET_MODE / BRIDGE / NAT_NET_NAME ...)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

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
