#!/bin/bash
# ============================================================
# 离线安装 bare-metal worker 节点所需系统包
# 将 repository 中的离线 .deb 包复制到目标节点并安装
# 自动从 cluster.conf 读取 SSH 密钥配置
# 用法:
#   ./install-worker-packages.sh <IP> [user]         # 直接 SSH 安装
#   ansible-playbook -i <hosts> install-packages.yml  # Ansible 安装
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"
load_config

IP="${1:?用法: $0 <IP> [user]}"
USER="${2:-ubuntu}"

# 定位离线包目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PKG_DIR="${REPO_ROOT}/deployments/kubespray/repository/cubestack-cluster/packages"

# SSH 密钥配置
SSH_KEY_DIR="${SSH_KEY_DIR:-${HOME}/.ssh}"
SSH_KEY_NAME="${SSH_KEY_NAME:-cubestack_k8s}"
SSH_KEY="${SSH_KEY_DIR}/${SSH_KEY_NAME}"
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

[ -d "${PKG_DIR}" ] || { err "包目录不存在: ${PKG_DIR}"; exit 1; }
[ -f "${SSH_KEY}" ] || { err "SSH 密钥不存在: ${SSH_KEY}"; exit 1; }

say "安装 worker 节点 ${USER}@${IP} 所需离线包..."

# 1. 复制离线包到目标节点
say "复制离线包到 ${IP}:/tmp/packages/ ..."
rsync -e "ssh ${SSH_OPTS}" \
  "${PKG_DIR}/"*.deb "${USER}@${IP}:/tmp/packages/" 2>/dev/null || {
  warn "rsync 失败,尝试 scp 逐个复制..."
  ssh ${SSH_OPTS} "${USER}@${IP}" "mkdir -p /tmp/packages"
  for f in "${PKG_DIR}"/*.deb; do
    scp ${SSH_OPTS} "$f" "${USER}@${IP}:/tmp/packages/" 2>/dev/null || true
  done
}

# 2. 安装包
say "安装中 (dpkg -i) ..."
ssh ${SSH_OPTS} "${USER}@${IP}" \
  "sudo dpkg -i /tmp/packages/*.deb 2>&1 | tail -5 && sudo rm -rf /tmp/packages"

ok "✅ ${IP} 离线包安装完成: iputils-ping rsync iptables curl ca-certificates"