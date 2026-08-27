#!/bin/bash
# Kubespray专用 Ubuntu22.04 Minimal 虚拟机创建脚本（v8-配置驱动）
# 前置条件: 基础镜像(配置 BASE_IMG)已预埋 root/ubuntu 用户及SSH配置; 网络已按配置文件就绪
# 数据源:   config/cluster.conf(网络/镜像/密码/节点统一配置), 环境变量同名可覆盖
# 网络模式: 由配置 NET_MODE 决定
#           bridge=方案A(privbr0+精准SNAT,跨二层互通) | net=方案B(libvirt NAT)
# 用法: $0 [VM主机名] [内存G] [CPU核数] [磁盘G] [MAC地址] [静态IP]
# 示例: $0 cubestack-k8s-master01 16 8 50 52:54:00:1a:ad:11 10.244.1.11
# 可选: AUTO_SETUP_NET=1 时,网络不存在会自动创建(方案A建桥/方案B建NAT,需root/sudo)

set -euo pipefail

# ==================== 加载统一配置 ====================
# 配置来源: config/cluster.conf; 兼容映射: NET_MODE→VM_NET_MODE, BRIDGE→VM_BRIDGE, BRIDGE_IP→VM_GATEWAY
# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

VM_NET_MODE="${VM_NET_MODE:-${NET_MODE:-bridge}}"
LIBVIRT_NET_NAME="${LIBVIRT_NET_NAME:-${NAT_NET_NAME:-default}}"
VM_BRIDGE="${VM_BRIDGE:-${BRIDGE:-privbr0}}"
VM_SUBNET="${VM_SUBNET:-10.244.0.0/16}"
VM_GATEWAY="${VM_GATEWAY:-${BRIDGE_IP:-10.244.0.1}}"
AUTO_SETUP_NET="${AUTO_SETUP_NET:-0}"               # 网络不存在时自动创建(方案A建桥/方案B建NAT,需root/sudo)

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
BASE_IMG="${BASE_IMG:-/k8s/cloud-images/ubuntu2204-k8s-base.qcow2}"   # 取自配置(内置兜底)
VM_DISK="${VM_DISK_DIR:-/k8s/vm-disks}/${VM_NAME}.qcow2"
WORK_DIR="$(mktemp -d)"

virsh list --all | grep -qw "${VM_NAME}" && { echo -e "\033[31m【错误】VM ${VM_NAME} 已存在\033[0m"; exit 1; }
[ -f "${VM_DISK}" ] && { echo -e "\033[31m【错误】磁盘 ${VM_DISK} 已存在\033[0m"; exit 1; }
[ -f "${BASE_IMG}" ] || { echo -e "\033[31m【错误】基础镜像不存在：${BASE_IMG}\033[0m"; exit 1; }

trap 'rm -rf "${WORK_DIR}"' EXIT

# ==================== 网络参数解析 ====================
# 网络模式(二选一):
#   方案A bridge(显式指定 VM_NET_MODE=bridge): 私有 Linux 网桥 privbr0(10.244.0.0/16) + 精准SNAT,
#                       由 scripts/setup-vm-network.sh 初始化, 或 AUTO_SETUP_NET=1 自动建桥
#   方案B net(默认):   libvirt NAT 网络(默认 default), 自动探测网关/掩码,
#                       由 scripts/setup-libvirt-nat.sh 创建, 或 AUTO_SETUP_NET=1 自动创建
# (ip2int/int2ip/mask2int/cidr_contains 等工具函数来自 lib-common.sh)

if [ "${VM_NET_MODE}" = "bridge" ]; then
    # ---- 私有网桥模式: 静态网段,无需探测 ----
    if [ ! -d "/sys/class/net/${VM_BRIDGE}" ]; then
        if [ "${AUTO_SETUP_NET:-0}" = "1" ]; then
            # 自动调用同目录 setup-vm-network.sh 初始化宿主网络(建桥/回程路由/SNAT/开机自启)
            SETUP_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setup-vm-network.sh"
            [ -f "${SETUP_SCRIPT}" ] || {
                echo -e "\033[31m【错误】未找到 ${SETUP_SCRIPT},无法自动建桥\033[0m"; exit 1; }
            echo -e "\033[36m→ 网桥 ${VM_BRIDGE} 不存在,AUTO_SETUP_NET=1 自动调用: ${SETUP_SCRIPT}\033[0m"
            # 透传与本次 VM 一致的网络配置(避免 sudo 清空环境变量导致建错网桥/网段)
            SETUP_ENV=(BRIDGE="${VM_BRIDGE}" VM_SUBNET="${VM_SUBNET}" BRIDGE_IP="${VM_GATEWAY}")
            if [ "$(id -u)" -eq 0 ]; then
                env "${SETUP_ENV[@]}" "${SETUP_SCRIPT}"
            else
                sudo env "${SETUP_ENV[@]}" "${SETUP_SCRIPT}"
            fi || {
                echo -e "\033[31m【错误】自动建桥失败,请检查 setup-vm-network.sh 输出后重试\033[0m"; exit 1; }
            [ -d "/sys/class/net/${VM_BRIDGE}" ] || {
                echo -e "\033[31m【错误】setup-vm-network.sh 执行后网桥 ${VM_BRIDGE} 仍不存在\033[0m"; exit 1; }
        else
            echo -e "\033[31m【错误】网桥 ${VM_BRIDGE} 不存在,请先执行 scripts/setup-vm-network.sh\033[0m"
            echo -e "\033[33m提示: 设置 AUTO_SETUP_NET=1 可自动建桥(需 root/sudo)\033[0m"
            exit 1
        fi
    fi
    cidr_contains "${VM_IP}" "${VM_SUBNET}" || {
        echo -e "\033[31m【错误】IP ${VM_IP} 不在虚拟机网段 ${VM_SUBNET} 内\033[0m"; exit 1; }
    GATEWAY="${VM_GATEWAY}"
    PREFIX="${VM_SUBNET#*/}"
else
    # ---- 方案B: libvirt NAT 网络模式,自动探测网关/掩码 ----
    mask2cidr() {
        case "$1" in
            255.255.255.0) echo 24;; 255.255.255.128) echo 25;; 255.255.255.192) echo 26;;
            255.255.255.224) echo 27;; 255.255.255.240) echo 28;; 255.255.255.248) echo 29;;
            255.255.255.252) echo 30;; 255.255.254.0) echo 23;; 255.255.252.0) echo 22;;
            255.255.0.0) echo 16;; *) echo 24;;
        esac
    }
    NET_XML="$(virsh net-dumpxml "${LIBVIRT_NET_NAME}" 2>/dev/null || true)"
    if [ -z "${NET_XML}" ] && [ "${AUTO_SETUP_NET:-0}" = "1" ]; then
        # 自动创建 libvirt NAT 网络(方案B)
        SETUP_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setup-libvirt-nat.sh"
        [ -f "${SETUP_SCRIPT}" ] || {
            echo -e "\033[31m【错误】未找到 ${SETUP_SCRIPT},无法自动创建 NAT 网络\033[0m"; exit 1; }
        echo -e "\033[36m→ libvirt 网络 ${LIBVIRT_NET_NAME} 不存在,AUTO_SETUP_NET=1 自动调用: ${SETUP_SCRIPT}\033[0m"
        SETUP_ENV=(NET_NAME="${LIBVIRT_NET_NAME}")
        if [ "$(id -u)" -eq 0 ]; then
            env "${SETUP_ENV[@]}" "${SETUP_SCRIPT}"
        else
            sudo env "${SETUP_ENV[@]}" "${SETUP_SCRIPT}"
        fi || {
            echo -e "\033[31m【错误】自动创建 NAT 网络失败,请检查 setup-libvirt-nat.sh 输出后重试\033[0m"; exit 1; }
        NET_XML="$(virsh net-dumpxml "${LIBVIRT_NET_NAME}" 2>/dev/null || true)"
    fi
    NET_GW="$(echo "${NET_XML}" | sed -n "s/.*<ip address=['\"]\([^'\"]*\)['\"].* netmask=['\"]\([^'\"]*\)['\"].*/\1/p" | head -1)"
    NET_MASK="$(echo "${NET_XML}" | sed -n "s/.*<ip address=['\"]\([^'\"]*\)['\"].* netmask=['\"]\([^'\"]*\)['\"].*/\2/p" | head -1)"
    [ -z "${NET_GW}" ] || [ -z "${NET_MASK}" ] && {
        echo -e "\033[31m【错误】无法从 ${LIBVIRT_NET_NAME} 读取网关/掩码\033[0m"
        echo -e "\033[33m提示: 设置 AUTO_SETUP_NET=1 可自动创建 NAT 网络(需 root/sudo)\033[0m"
        exit 1; }
    GATEWAY="${GATEWAY:-${NET_GW}}"
    PREFIX="${PREFIX:-$(mask2cidr "${NET_MASK}")}"
    # 校验 VM_IP 属于该 libvirt 网络(由网关&掩码推算网络地址)
    NET_NETADDR="$(int2ip $(( $(ip2int "${NET_GW}") & $(mask2int "${NET_MASK}") )) )"
    cidr_contains "${VM_IP}" "${NET_NETADDR}/${PREFIX}" || {
        echo -e "\033[31m【错误】IP ${VM_IP} 不在 libvirt 网络 ${LIBVIRT_NET_NAME} 网段 ${NET_NETADDR}/${PREFIX} 内\033[0m"; exit 1; }
fi

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

# 1. 校验基础镜像已内置 kubespray 所需常用包（只读校验, 不安装任何组件）
#    这些包由 create-vm-template.sh 制作黄金镜像时固化, 创建 VM 无需再装;
#    离线环境 apt 无法联网, 故此处只校验缺包并告警(不中断), 避免静默缺 rsync/curl 导致后续同步失败
echo -e "\033[36m→ 校验基础镜像已含常用包 (iputils-ping rsync iptables curl ca-certificates) ...\033[0m"
if virt-customize -a "${VM_DISK}" --quiet \
    --run-command 'for c in ping rsync iptables curl update-ca-certificates; do command -v "$c" >/dev/null 2>&1 || exit 1; done' \
    >/dev/null 2>&1; then
    echo -e "\033[32m✓ 所需包已内置\033[0m"
else
    echo -e "\033[33m⚠ 基础镜像缺少 kubespray 所需包(rsync/iptables/curl/iputils-ping/ca-certificates)\033[0m"
    echo -e "\033[33m  请确认基础镜像由 create-vm-template.sh 制作; 离线环境无法自动安装, 可继续但后续 rsync/curl 相关步骤可能失败\033[0m"
fi

# 1b. 磁盘扩容到 ${DISK_G}G(不依赖 cloud-init runcmd, 在 virt-customize 阶段直接扩展分区+文件系统)
echo -e "\033[36m→ 磁盘扩容分区+文件系统到 ${DISK_G}G ...\033[0m"
virt-customize -a "${VM_DISK}" --quiet --run-command 'growpart /dev/sda 1 2>/dev/null || growpart /dev/vda 1 2>/dev/null || true' 2>&1
virt-customize -a "${VM_DISK}" --quiet --run-command 'resize2fs /dev/sda1 2>/dev/null || resize2fs /dev/vda1 2>/dev/null || true' 2>&1

# 2. 禁用 IPv6
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
# 网络挂载参数: bridge 模式挂 Linux 网桥 / net 模式挂 libvirt 网络
if [ "${VM_NET_MODE}" = "bridge" ]; then
    NET_ARG="bridge=${VM_BRIDGE}"
else
    NET_ARG="network=${LIBVIRT_NET_NAME}"
fi

# ==================== Auto-register VM in cluster.conf ====================
# 当 AUTO_REGISTER_CLUSTER=1 时,将 VM 信息写入 config/cluster.conf 的 NODES 数组
# (新5字段格式: role,hostname,ip,ssh_user,ssh_password; 密码 "-"=用默认; 复用 register_node_to_conf, 幂等)
auto_register_vm() {
    [ "${AUTO_REGISTER_CLUSTER:-0}" != "1" ] && return 0
    register_node_to_conf master "${VM_NAME}" "${VM_IP}" ubuntu -
}

virt-install \
  --name "${VM_NAME}" \
  --memory "${MEM_MB}" \
  --vcpus "${VCPU}" \
  --cpu host-passthrough \
  --disk path="${VM_DISK}",format=qcow2,bus=virtio \
  --network "${NET_ARG}",mac="${VM_MAC}",model=virtio \
  --os-variant ubuntu22.04 \
  --cloud-init user-data="${WORK_DIR}/user-data",meta-data="${WORK_DIR}/meta-data" \
  --import \
  --noautoconsole

# ==================== 创建后立即启动虚拟机(running) ====================
# 显式通过 virsh start 启动, 不依赖 virt-install 是否自动启动; 启动失败重试(创建刚结束时域可能处于瞬时状态)
virsh list --all | grep -qw "${VM_NAME}" || {
    echo -e "\033[31m【错误】VM ${VM_NAME} 创建后未找到,请检查 virt-install 输出\033[0m"; exit 1; }
echo -e "\033[36m→ 启动 VM ${VM_NAME} ...\033[0m"
STARTED=0
for attempt in 1 2 3 4 5; do
    if virsh domstate "${VM_NAME}" 2>/dev/null | grep -qi "running"; then
        STARTED=1; break
    fi
    virsh start "${VM_NAME}" >/dev/null 2>&1 && { STARTED=1; break; }
    echo -e "\033[33m⚠ 启动尝试 ${attempt}/5 失败,2s 后重试...\033[0m"
    sleep 2
done
[ "${STARTED}" = "1" ] || {
    echo -e "\033[31m【错误】VM ${VM_NAME} 启动失败,请检查磁盘/日志(virsh list --all / virsh start ${VM_NAME})\033[0m"; exit 1; }
# 确认状态: Ubuntu cloud image 首次启动时 cloud-init 会在完成后自动关机,
# 属于正常行为, 此时只需再次启动即可; 后续"最终确保运行"会兜底重试
sleep 2
if virsh domstate "${VM_NAME}" 2>/dev/null | grep -qi "running"; then
    echo -e "\033[32m✓ VM ${VM_NAME} 已启动(running)\033[0m"
else
    echo -e "\033[33m⚠ VM ${VM_NAME} 未运行(cloud-init 首次关机是正常行为), 重新启动...\033[0m"
    virsh start "${VM_NAME}" >/dev/null 2>&1 || true
fi

# ==================== 设置宿主机重启自动启动(autostart) ====================
# 宿主机重启后 VM 自动启动, 避免每次重启后手动 virsh start
if virsh autostart "${VM_NAME}" >/dev/null 2>&1; then
    echo -e "\033[32m✓ VM ${VM_NAME} 已设置开机自启(宿主机重启后自动启动)\033[0m"
else
    echo -e "\033[33m⚠ 设置 VM ${VM_NAME} 开机自启失败(可手动: virsh autostart ${VM_NAME})\033[0m"
fi

# ==================== 最终确保运行(收尾) ====================
# virt-install 创建后 VM 可能在短暂启动后被关闭(创建流程/libvirt 状态抖动),
# 脚本退出前再确认一次, 未运行则重新 virsh start, 保证结束时 VM 一定是 running
echo -e "\033[36m→ 最终确认 VM ${VM_NAME} 运行状态 ...\033[0m"
sleep 5
RUNNING=0
for attempt in 1 2 3 4 5; do
    if virsh domstate "${VM_NAME}" 2>/dev/null | grep -qi "running"; then
        RUNNING=1; break
    fi
    echo -e "\033[33m⚠ VM ${VM_NAME} 未在运行,重新启动(尝试 ${attempt}/5) ...\033[0m"
    virsh start "${VM_NAME}" >/dev/null 2>&1 || true
    sleep 5
done
if [ "${RUNNING}" = "1" ]; then
    echo -e "\033[32m✓ 最终确认: VM ${VM_NAME} running\033[0m"
else
    echo -e "\033[31m【错误】VM ${VM_NAME} 最终未能启动,请检查磁盘/日志(virsh list --all)\033[0m"; exit 1
fi

echo "============================================="
echo -e "\033[32m✅ VM ${VM_NAME} 创建成功(running)\033[0m"

# 自动注册到 cluster.conf (AUTO_REGISTER_CLUSTER=1 时生效)
auto_register_vm

echo "✅ 登录: root/${SSH_DEFAULT_PASSWORD:-k8s@2026} 或 ubuntu/${SSH_DEFAULT_PASSWORD:-k8s@2026} (镜像预埋)"
echo "  静态IP: ${VM_IP}/${PREFIX}  网关: ${GATEWAY}"
echo "  规格: ${MEM_G}G/${VCPU}C/${DISK_G}G"
if [ "${VM_NET_MODE}" = "bridge" ]; then
    echo "  网络: bridge 方案(${NET_ARG}), 跨二层互通由宿主 SNAT+回程路由保证"
else
    echo "  网络: net 方案(${NET_ARG}), 出网由 libvirt NAT 伪装"
fi
echo "============================================="
