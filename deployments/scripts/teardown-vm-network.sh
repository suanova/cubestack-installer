#!/bin/bash
# CubeStack 私有网桥(privbr0)网络配置回滚脚本（故障快速恢复）
# ============================================================
# 默认动作: 删除 SNAT 规则 + 回程路由 + 网桥转发放行 + 卸载开机自启服务
# 可选:     REMOVE_BRIDGE=1 删除网桥 / RESTORE_SYSCTL=1 恢复内核参数(移除固化文件)
# 用法:     sudo ./teardown-vm-network.sh
# ============================================================

set -euo pipefail

# ==================== 加载统一配置 ====================
# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"
load_config
# 兜底默认(仅在配置文件缺失时生效)
BRIDGE="${BRIDGE:-privbr0}"
BRIDGE_IP="${BRIDGE_IP:-10.244.0.1}"
VM_SUBNET="${VM_SUBNET:-10.244.0.0/16}"
HOST_PHYS_IP="${HOST_PHYS_IP:-10.66.3.37}"
PHYS_WORKER_NET="${PHYS_WORKER_NET:-10.66.1.0/24}"

SYSCTL_CONF="/etc/sysctl.d/99-k8s-forward.conf"
SVC_NAME="privbr0-net.service"
BOOTSTRAP="/usr/local/sbin/privbr0-net-bootstrap.sh"

[ "$(id -u)" -eq 0 ] || { err "需要 root 权限,请执行: sudo $0"; exit 1; }

echo "============= 1. 删除 SNAT 规则 ============="
if iptables -t nat -C POSTROUTING -s "${VM_SUBNET}" -d "${PHYS_WORKER_NET}" -j SNAT --to-source "${HOST_PHYS_IP}" 2>/dev/null; then
    iptables -t nat -D POSTROUTING -s "${VM_SUBNET}" -d "${PHYS_WORKER_NET}" -j SNAT --to-source "${HOST_PHYS_IP}"
    echo -e "\033[32m✅ SNAT 规则已删除\033[0m"
else
    echo -e "→ SNAT 规则不存在,跳过"
fi

echo "============= 2. 删除回程路由 ============="
if ip route del "${VM_SUBNET}" dev "${BRIDGE}" 2>/dev/null; then
    echo -e "\033[32m✅ 回程路由已删除: ${VM_SUBNET} dev ${BRIDGE}\033[0m"
else
    echo -e "→ 回程路由不存在,跳过"
fi

echo "============= 3. 删除网桥转发放行 ============="
iptables -D FORWARD -i "${BRIDGE}" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -o "${BRIDGE}" -j ACCEPT 2>/dev/null || true
echo -e "→ FORWARD 放行规则已清理"

echo "============= 4. 卸载开机自启 ============="
if [ -f "/etc/systemd/system/${SVC_NAME}" ]; then
    systemctl disable --now "${SVC_NAME}" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${SVC_NAME}" "${BOOTSTRAP}"
    systemctl daemon-reload
    echo -e "\033[32m✅ 已移除开机自启服务 ${SVC_NAME} 与 ${BOOTSTRAP}\033[0m"
else
    echo -e "→ 自启服务未安装,跳过"
fi

# ============= 5.（可选）删除网桥 =============
if [ "${REMOVE_BRIDGE:-0}" = "1" ] && [ -d "/sys/class/net/${BRIDGE}" ]; then
    echo "============= 5. 删除网桥 ${BRIDGE} ============="
    ip link del "${BRIDGE}" 2>/dev/null && echo -e "\033[32m✅ 网桥 ${BRIDGE} 已删除\033[0m" \
        || echo -e "\033[33m⚠ 网桥删除失败(可能有虚拟机仍在使用,先停用相关VM)\033[0m"
fi

# ============= 6.（可选）恢复内核参数 =============
if [ "${RESTORE_SYSCTL:-0}" = "1" ]; then
    echo "============= 6. 恢复内核参数 ============="
    rm -f "${SYSCTL_CONF}" && sysctl -p >/dev/null 2>&1 || true
    echo -e "\033[32m✅ 已移除内核参数固化文件 ${SYSCTL_CONF}\033[0m"
fi

echo "============================================="
echo -e "\033[32m✅ 回滚完成\033[0m"
echo "  提示: 若需恢复,重新执行 sudo ./scripts/setup-vm-network.sh 即可"
echo "============================================="
