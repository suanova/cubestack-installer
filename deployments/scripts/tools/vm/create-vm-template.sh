#!/bin/bash
set -euo pipefail

BASE_IMG="/k8s/cloud-images/ubuntu2204-k8s-base.qcow2"
PASS='k8s@2026'

echo "📦 复制原始镜像作为基底..."
cp /k8s/cloud-images/ubuntu-22.04-server-cloudimg-amd64.img "$BASE_IMG"

echo "📐 扩容根分区 +5G..."
qemu-img resize "$BASE_IMG" +5G

echo "🔧 开始定制镜像（安装内核、创建用户、配置SSH）..."
export LIBGUESTFS_TMPDIR=/var/tmp

virt-customize -a "$BASE_IMG" --memsize 4096 \
  \
  `# ===== 1. 系统基础：扩容 + 更新 =====` \
  --run-command 'export DEBIAN_FRONTEND=noninteractive' \
  --run-command 'growpart /dev/sda 1 || true' \
  --run-command 'resize2fs /dev/sda1 || true' \
  --run-command 'apt-get update -qq' \
  \
  `# ===== 2. 替换 KVM 内核为通用内核 =====` \
  --run-command 'apt-get remove -y -qq --purge "linux-image-*-kvm" "linux-modules-*-kvm" || true' \
  --run-command 'apt-get autoremove -y -qq && apt-get clean' \
  --run-command 'rm -rf /var/cache/apt/archives/*.deb /tmp/*' \
  --run-command 'mkdir -p /var/cache/apt/archives/partial' \
  --run-command 'apt-get install -y -qq --no-install-recommends linux-image-generic' \
  --run-command 'update-grub' \
  \
  `# ===== 🆕 3. 安装 kubespray 离线部署所需包(唯一固化点) =====` \
  `# 这些包只在制作黄金镜像时安装一次, 固化进基础镜像; 之后 create-libvirt-vm.sh 创建` \
  `# 虚拟机不再安装任何组件(离线环境无法 apt), 仅校验已内置。新增依赖请在此处添加。` \
  --run-command 'apt-get install -y -qq --no-install-recommends iputils-ping rsync iptables curl ca-certificates' \
  \
  `# ===== 🆕 4. 时区 + NTP 时间同步 =====` \
  --run-command 'ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime' \
  --run-command 'echo "Asia/Shanghai" > /etc/timezone' \
  --run-command 'dpkg-reconfigure -f noninteractive tzdata' \
  --run-command 'apt-get install -y -qq --no-install-recommends chrony' \
  --run-command 'systemctl enable chrony' \
  --run-command 'cat > /etc/chrony/chrony.conf <<EOF
pool ntp.aliyun.com iburst
pool time1.cloud.tencent.com iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF' \
  \
  `# ===== 4. 系统清理 =====` \
  --run-command 'truncate -s 0 /etc/machine-id' \
  --run-command 'sync' \
  \
  `# ===== 5. SSH 服务初始化 =====` \
  --run-command 'ssh-keygen -A' \
  --run-command 'mkdir -p /run/sshd && chmod 755 /run/sshd' \
  --run-command 'systemctl enable ssh' \
  \
  `# ===== 6. 预埋 root 密码 =====` \
  --root-password "password:${PASS}" \
  \
  `# ===== 7. 预埋 ubuntu 用户（创建 + 密码 + sudo免密） =====` \
  --run-command "id ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash ubuntu" \
  --run-command "echo 'ubuntu:${PASS}' | chpasswd" \
  --run-command 'usermod -aG sudo ubuntu' \
  --run-command 'echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-ubuntu && chmod 440 /etc/sudoers.d/90-ubuntu' \
  \
  `# ===== 8. SSH 配置：主文件 =====` \
  --run-command 'sed -i -E "s/^#?PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config' \
  --run-command 'sed -i -E "s/^#?PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config' \
  --run-command 'grep -q "^PermitRootLogin" /etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config' \
  --run-command 'grep -q "^PasswordAuthentication" /etc/ssh/sshd_config || echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config' \
  \
  `# ===== 9. SSH 配置：修复 drop-in 目录（防止 cloud-init 覆盖） =====` \
  --run-command 'mkdir -p /etc/ssh/sshd_config.d' \
  --run-command 'find /etc/ssh/sshd_config.d/ -name "*.conf" -exec sed -i -E "s/^#?PasswordAuthentication.*/PasswordAuthentication yes/" {} \;' \
  --run-command 'find /etc/ssh/sshd_config.d/ -name "*.conf" -exec sed -i -E "s/^#?PermitRootLogin.*/PermitRootLogin yes/" {} \;' \
  --run-command 'echo "PasswordAuthentication yes" > /etc/ssh/sshd_config.d/99-custom.conf' \
  --run-command 'echo "PermitRootLogin yes" >> /etc/ssh/sshd_config.d/99-custom.conf' \
  --run-command 'chmod 644 /etc/ssh/sshd_config.d/99-custom.conf'

unset LIBGUESTFS_TMPDIR

echo "============================================="
echo "✅ 黄金基础镜像制作完成: $BASE_IMG"
echo "   预埋用户: root / ${PASS}"
echo "   预埋用户: ubuntu / ${PASS} (sudo免密)"
echo "   SSH: 密码登录已开启, root登录已开启"
echo "   🕐 时区: Asia/Shanghai (chrony NTP已启用)"
echo "============================================="
