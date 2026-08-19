#!/bin/bash
# CubeStack 私有网桥(privbr0)网络连通性验证脚本
# ============================================================
# 验证: 内核参数 / 网桥 / 回程路由 / SNAT 规则 / 宿主机自测
# 用法: sudo ./verify-vm-network.sh [VM1_IP ...]   # 附带上创建的虚拟机IP可顺带自测
# ============================================================

set -uo pipefail

# ==================== 加载统一配置 ====================
# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"
load_config
# 兜底默认(仅在配置文件缺失时生效)
BRIDGE="${BRIDGE:-privbr0}"
BRIDGE_IP="${BRIDGE_IP:-10.244.0.1}"
VM_SUBNET="${VM_SUBNET:-10.244.0.0/16}"
# HOST_PHYS_IP 由 lib-common load_config 统一提供(留空自动检测), 不再本地设置
PHYS_WORKER_NET="${PHYS_WORKER_NET:-10.66.1.0/24}"

PASS=0; FAIL=0
check() { # check <描述> <命令...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo -e "  \033[32m✅ ${desc}\033[0m"; PASS=$((PASS+1))
    else
        echo -e "  \033[31m❌ ${desc}\033[0m"; FAIL=$((FAIL+1))
    fi
}

echo "============== 1. 内核参数 =============="
check "net.ipv4.ip_forward = 1"        sh -c '[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]'
check "br_netfilter 模块已加载"        sh -c 'lsmod | grep -qw br_netfilter'
check "net.bridge.bridge-nf-call-iptables = 1" sh -c '[ "$(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null)" = "1" ]'

echo "============== 2. 网桥 =============="
check "网桥 ${BRIDGE} 存在"            sh -c "[ -d '/sys/class/net/${BRIDGE}' ]"
check "网桥已配置 IP ${BRIDGE_IP}/16"  sh -c "ip -4 addr show dev ${BRIDGE} 2>/dev/null | grep -q '${BRIDGE_IP}/'"

echo "============== 3. 回程路由 =============="
check "回程路由 ${VM_SUBNET} → dev ${BRIDGE}"  sh -c "ip route get 10.244.1.1 2>/dev/null | grep -q 'dev ${BRIDGE}'"

echo "============== 4. SNAT 规则 =============="
check "SNAT: ${VM_SUBNET}→${PHYS_WORKER_NET} 伪装 ${HOST_PHYS_IP}" \
    iptables -t nat -C POSTROUTING -s "${VM_SUBNET}" -d "${PHYS_WORKER_NET}" -j SNAT --to-source "${HOST_PHYS_IP}"
check "FORWARD 放行 ${BRIDGE}" sh -c "iptables -C FORWARD -i ${BRIDGE} -j ACCEPT 2>/dev/null || iptables -C FORWARD -o ${BRIDGE} -j ACCEPT 2>/dev/null"

echo "============== 5. 宿主机自测 =============="
check "宿主机 → 网关 ${BRIDGE_IP} ping" ping -c 1 -W 1 "${BRIDGE_IP}"
for vm_ip in "$@"; do
    check "宿主机 → VM ${vm_ip} ping" ping -c 1 -W 1 "${vm_ip}"
done

echo "============== 6. 互通验证指引 =============="
echo "  ① 虚拟机访问物理Worker(正向SNAT): 在VM内执行:"
echo "     ping -c2 ${PHYS_WORKER_NET%.*}.232"
echo "  ② 物理Worker访问虚拟机(回程路由回溯): 在Worker上执行:"
echo "     ping -c2 10.244.1.11"
echo "  ③ 查看 NAT 规则:"
echo "     iptables -t nat -L POSTROUTING -n --line-numbers"
echo "  ④ 查看回程路由:"
echo "     ip route | grep ${VM_SUBNET%%/*}"

echo "============================================="
if [ "${FAIL}" -eq 0 ]; then
    echo -e "\033[32m✅ 全部 ${PASS} 项检查通过\033[0m"
else
    echo -e "\033[31m❌ ${FAIL} 项检查失败(共 ${PASS} 通过),请重新执行 scripts/setup-vm-network.sh\033[0m"
    exit 1
fi
