#!/bin/bash
# Kubespray专用 Ubuntu22.04 Minimal 虚拟机创建脚本（静态IP版 v5-简化）
# 前置条件: 基础镜像 /k8s/cloud-images/ubuntu2204-k8s-base.qcow2 已预埋 root/ubuntu 用户及SSH配置
# 用法: $0 [VM主机名] [内存G] [CPU核数] [磁盘G] [MAC地址] [静态IP]
# 示例: $0 cubestack-k8s-master01 16 8 50 52:54:00:1a:ad:11 192.168.122.11

set -euo pipefail

# ==================== 可配置项 ====================
LIBVIRT_NET_NAME="${LIBVIRT_NET_NAME:-default}"

# ==================== 参数校验 ====================
if [ $# -ne 6 ]; then
    echo -e "\033[31m【错误】必须传入完整6个参数\033[0m"
    echo "用法: $0 [VM主机名] [内存G] [CPU核数] [磁盘G] [MAC地址] [静态IP]"
    exit 1
fi

VM_NAME="$1"; MEM_G="$2"; VCPU="$3"; DISK_G="$4"; VM_MAC="$5"; VM_IP="$6"
MEM_MB=$((MEM_G * 1024))
VM_MAC_LC="$(echo "${VM_MAC}" | tr 'A-F' 'a-f')"

# ==================== 合法性校验 ====================
[[ ${VM_NAME} =~ ^cubestack-k8s- ]] || { echo -e "\033[31m【错误】虚拟机名称必须以 cubestack-k8s- 开头\033[0m"; exit 1; }
[[ ${MEM_G} =~ ^[0-9]+$ && ${VCPU} =~ ^[0-9]+$ && ${DISK_G} =~ ^[0-9]+$ ]] || { echo -e "\033[31m【错误】内存/CPU/磁盘必须为纯数字\033[0m"; exit 1; }
[ ${MEM_G} -ge 4 ] && [ ${VCPU} -ge 2 ] && [ ${DISK_G} -ge 20 ] || { echo -e "\033[31m【错误】最小规格：4G/2核/20G\033[0m"; exit 1; }
[[ ${VM_MAC} =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || { echo -e "\033[31m【错误】MAC地址格式非法\033[0m"; exit 1; }
[[ ${VM_IP} =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo -e "\033[31m【错误】IP格式非法\033[0m"; exit 1; }

# ==================== 防重复 & 文件检查 ====================
BASE_IMG="/k8s/cloud-images/ubuntu2204-k8s-base.qcow2"
VM_DISK="/k8s/vm-disks/${VM_NAME}.qcow2"
WORK_DIR="$(mktemp -d)"

virsh list --all | grep -qw "${VM_NAME}" && { echo -e "\033[31m【错误】VM ${VM_NAME} 已存在\033[0m"; exit 1; }
[ -f "${VM_DISK}" ] && { echo -e "\033[31m【错误】磁盘 ${VM_DISK} 已存在\033[0m"; exit 1; }
[ -f "${BASE_IMG}" ] || { echo -e "\033[31m【错误】基础镜像不存在：${BASE_IMG}\033[0m"; exit 1; }

trap 'rm -rf "${WORK_DIR}"' EXIT

# ==================== 网络参数自动探测 ====================
mask2cidr() {
    case "$1" in
        255.255.255.0) echo 24;; 255.255.255.128) echo 25;; 255.255.255.192) echo 26;;
        255.255.255.224) echo 27;; 255.255.255.240) echo 28;; 255.255.255.248) echo 29;;
        255.255.255.252) echo 30;; 255.255.254.0) echo 23;; 255.255.252.0) echo 22;;
        255.255.0.0) echo 16;; *) echo 24;;
    esac
}

NET_XML="$(virsh net-dumpxml "${LIBVIRT_NET_NAME}" 2>/dev/null || true)"
NET_GW="$(echo "${NET_XML}" | sed -n "s/.*<ip address=['\"]\([^'\"]*\)['\"].* netmask=['\"]\([^'\"]*\)['\"].*/\1/p" | head -1)"
NET_MASK="$(echo "${NET_XML}" | sed -n "s/.*<ip address=['\"]\([^'\"]*\)['\"].* netmask=['\"]\([^'\"]*\)['\"].*/\2/p" | head -1)"
[ -z "${NET_GW}" ] || [ -z "${NET_MASK}" ] && { echo -e "\033[31m【错误】无法从 ${LIBVIRT_NET_NAME} 读取网关/掩码\033[0m"; exit 1; }

GATEWAY="${GATEWAY:-${NET_GW}}"
PREFIX="${PREFIX:-$(mask2cidr "${NET_MASK}")}"

if [ -z "${DNS_SERVERS:-}" ]; then
    DNS_SERVERS="$(awk '/^nameserver/ && !s[$2]++ {print $2}' /etc/resolv.conf 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/ *$//')"
    [ -z "${DNS_SERVERS}" ] && DNS_SERVERS="${GATEWAY} 8.8.8.8"
fi

echo -e "\033[36m→ 网关=${GATEWAY}  掩码=/${PREFIX}  DNS=${DNS_SERVERS}\033[0m"

# ==================== IP 冲突预检 ====================
ping -c 1 -W 1 "${VM_IP}" >/dev/null 2>&1 && { echo -e "\033[31m【错误】IP ${VM_IP} 已被占用\033[0m"; exit 1; }

# ==================== 磁盘初始化 ====================
cp "${BASE_IMG}" "${VM_DISK}"
qemu-img resize "${VM_DISK}" "${DISK_G}G"

# ==================== virt-customize 系统调优（不含用户/SSH）====================
VC="virt-customize -a ${VM_DISK} --quiet --no-network"

# 1. 禁用 IPv6
${VC} --run-command 'sed -i -E "s#^(GRUB_CMDLINE_LINUX_DEFAULT=.*)\"#\1 ipv6.disable=1\"#" /etc/default/grub'
${VC} --run-command 'update-grub'

# 2. 关闭 swap + 开启 IP 转发
${VC} --run-command 'sed -i -E "/[[:space:]]swap[[:space:]]/d" /etc/fstab'
${VC} --run-command 'grep -qE "^net.ipv4.ip_forward" /etc/sysctl.conf && sed -i -E "s/^net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf'

# 3. 屏蔽网络等待服务
${VC} --run-command 'systemctl mask systemd-networkd-wait-online.service NetworkManager-wait-online.service 2>/dev/null || true'

# 4. 固化主机名
${VC} --run-command "echo '${VM_NAME}' > /etc/hostname"
${VC} --run-command "sed -i -E 's/^127.0.1.1.*/127.0.1.1 ${VM_NAME}/' /etc/hosts; grep -q '^127.0.1.1' /etc/hosts || echo '127.0.1.1 ${VM_NAME}' >> /etc/hosts"

# 5. 禁用 cloud-init 网络管理（防双IP）
cat > "${WORK_DIR}/99-disable-network-config.cfg" <<'EOF'
network: {config: disabled}
EOF
${VC} --upload "${WORK_DIR}/99-disable-network-config.cfg":/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
${VC} --run-command 'rm -f /etc/netplan/50-cloud-init.yaml /etc/netplan/01-netcfg.yaml /etc/netplan/00-installer-config.yaml 2>/dev/null || true'

# 6. 预置 netplan 静态 IP
cat > "${WORK_DIR}/99-static.yaml" <<EOF
network:
  version: 2
  ethernets:
    nic0:
      match:
        macaddress: ${VM_MAC_LC}
      set-name: nic0
      addresses:
        - ${VM_IP}/${PREFIX}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS_SERVERS// /, }]
EOF
${VC} --upload "${WORK_DIR}/99-static.yaml":/etc/netplan/99-static.yaml
${VC} --run-command 'chmod 600 /etc/netplan/99-static.yaml'

# ==================== cloud-init 元数据（仅主机名+磁盘扩容）====================
cat > "${WORK_DIR}/user-data" <<EOF
#cloud-config
hostname: ${VM_NAME}
runcmd:
  - (growpart /dev/vda 1 || growpart /dev/sda 1) && (resize2fs /dev/vda1 || resize2fs /dev/sda1) || true
  - netplan apply || true
EOF

cat > "${WORK_DIR}/meta-data" <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

# ==================== 创建虚拟机 ====================
virt-install \
  --name "${VM_NAME}" \
  --memory "${MEM_MB}" \
  --vcpus "${VCPU}" \
  --cpu host-passthrough \
  --disk path="${VM_DISK}",format=qcow2,bus=virtio \
  --network network="${LIBVIRT_NET_NAME}",mac="${VM_MAC}",model=virtio \
  --os-variant ubuntu22.04 \
  --cloud-init user-data="${WORK_DIR}/user-data",meta-data="${WORK_DIR}/meta-data" \
  --import \
  --noautoconsole

echo "============================================="
echo -e "\033[32m✅ VM ${VM_NAME} 创建成功\033[0m"
echo "✅ 登录: root/k8s@2026 或 ubuntu/k8s@2026 (镜像预埋)"
echo "  静态IP: ${VM_IP}/${PREFIX}  网关: ${GATEWAY}"
echo "  规格: ${MEM_G}G/${VCPU}C/${DISK_G}G"
echo "============================================="
