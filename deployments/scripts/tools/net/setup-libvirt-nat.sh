#!/bin/bash
# CubeStack 方案B: libvirt NAT 网络创建/删除脚本
# ============================================================
# 双方案二选一:
#   方案A(bridge):  sudo ./scripts/setup-vm-network.sh   → create 脚本 VM_NET_MODE=bridge(显式指定)
#                    私有网桥 privbr0 + 精准SNAT + 回程路由, 用于跨二层互通
#   方案B(net,默认): sudo ./scripts/setup-libvirt-nat.sh → create 脚本 VM_NET_MODE=net(默认)
#                    libvirt 自动建桥 + 全局MASQUERADE + dnsmasq DHCP, 零手工 iptables/路由
#                    缺点: 出网全部伪装为宿主IP(非精准), 复杂多网段不如方案A精细
#
# 用法:
#   sudo ./scripts/setup-libvirt-nat.sh [网络名]        # 创建(幂等)
#   sudo ./scripts/setup-libvirt-nat.sh --delete [网络名]  # 删除回滚
# 数据源: config/cluster.conf(NAT_NET_NAME/NAT_SUBNET/NAT_GATEWAY)
# 环境变量: NET_NAME NET_SUBNET NET_GATEWAY DHCP_START DHCP_END
# 说明: 默认网段 10.245.0.0/16 避开方案A的 10.244.0.0/16, 两方案可并存不冲突
# ============================================================

set -euo pipefail

# ==================== 加载统一配置 ====================
# say/ok/warn/err 等函数来自 lib-common.sh
# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ==================== 参数解析 ====================
ACTION="create"; NET_NAME=""
if [ "${1:-}" = "--delete" ]; then
    ACTION="delete"; NET_NAME="${2:-}"
else
    NET_NAME="${1:-}"
fi
NET_NAME="${NET_NAME:-${NAT_NET_NAME:-cubestack-nat}}"
NET_SUBNET="${NET_SUBNET:-${NAT_SUBNET:-10.245.0.0/16}}"
NET_GATEWAY="${NET_GATEWAY:-${NAT_GATEWAY:-10.245.0.1}}"
NET_PREFIX="${NET_PREFIX:-${NET_SUBNET#*/}}"

# ==================== 前置检查 ====================
[ "$(id -u)" -eq 0 ] || { err "需要 root 权限,请执行: sudo $0"; exit 1; }

# virsh 依赖
command -v virsh >/dev/null 2>&1 || {
    err "缺少 virsh。安装: sudo apt-get install -y libvirt-clients"; exit 1; }
systemctl is-active --quiet libvirtd 2>/dev/null || {
    say "libvirtd 未运行,尝试启动 ..."
    systemctl start libvirtd 2>/dev/null || { err "libvirtd 启动失败"; exit 1; }
}

# ==================== 删除模式 ====================
if [ "${ACTION}" = "delete" ]; then
    if virsh net-info "${NET_NAME}" >/dev/null 2>&1; then
        virsh net-destroy "${NET_NAME}" 2>/dev/null || true
        virsh net-undefine "${NET_NAME}"
        ok "已删除 libvirt NAT 网络 ${NET_NAME}"
    else
        echo -e "→ NAT 网络 ${NET_NAME} 不存在,跳过"
    fi
    exit 0
fi

# ==================== 创建模式 ====================
cidr2mask() {
    local m=$(( (0xFFFFFFFF << (32 - $1)) & 0xFFFFFFFF ))
    echo "$(( (m>>24)&255 )).$(( (m>>16)&255 )).$(( (m>>8)&255 )).$(( m&255 ))"
}
NET_MASK="$(cidr2mask "${NET_PREFIX}")"
NETWORK_ADDR="${NET_SUBNET%%/*}"

# 幂等: 已存在则确保启动并返回
if virsh net-info "${NET_NAME}" >/dev/null 2>&1; then
    say "NAT 网络 ${NET_NAME} 已存在,确保启动中 ..."
    virsh net-start "${NET_NAME}" 2>/dev/null || true
    virsh net-autostart "${NET_NAME}" >/dev/null 2>&1 || true
    virsh net-info "${NET_NAME}" | sed -n '1,12p'
    ok "网络就绪(幂等,未重复创建)"
    exit 0
fi

# DHCP 范围(默认 .100~.200,避开网关 .1)
DHCP_START="${DHCP_START:-${NETWORK_ADDR%.*}.$(( ${NETWORK_ADDR##*.} + 100 ))}"
DHCP_END="${DHCP_END:-${NETWORK_ADDR%.*}.$(( ${NETWORK_ADDR##*.} + 200 ))}"

XML="/tmp/${NET_NAME}.xml"
cat > "${XML}" <<EOF
<network>
  <name>${NET_NAME}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge stp='on' delay='0'/>
  <ip address='${NET_GATEWAY}' netmask='${NET_MASK}'>
    <dhcp>
      <range start='${DHCP_START}' end='${DHCP_END}'/>
    </dhcp>
  </ip>
</network>
EOF

virsh net-define "${XML}"
virsh net-start "${NET_NAME}"
virsh net-autostart "${NET_NAME}"
rm -f "${XML}"

# NAT 依赖 IP 转发
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || warn "设置 ip_forward 失败(手动: sysctl -w net.ipv4.ip_forward=1)"

echo "============================================="
echo -e "\033[32m✅ libvirt NAT 网络 ${NET_NAME} 创建成功\033[0m"
echo "  网段: ${NET_SUBNET}  网关: ${NET_GATEWAY}  掩码: ${NET_MASK}"
echo "  DHCP: ${DHCP_START} - ${DHCP_END} (create 脚本用静态IP,不受影响)"
echo "  使用: VM_NET_MODE=net LIBVIRT_NET_NAME=${NET_NAME} ./scripts/create-libvirt-vm.sh ... <VM_IP>"
echo "       (VM_IP 需在 ${NET_SUBNET} 内, 例如 10.245.1.11)"
echo "  回滚: sudo ./scripts/setup-libvirt-nat.sh --delete ${NET_NAME}"
echo "============================================="
