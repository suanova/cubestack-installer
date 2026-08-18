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

# 定位离线包目录(REPO_ROOT 由 lib-common.sh 计算,为仓库根目录)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_ROOT}/deployments/kubespray/repository/${CLUSTER_NAME}"
# 离线 .deb 包来源: 优先仓库根目录(与 kubeadm/etcd 等二进制同层),兼容 packages/ 子目录
PKG_DIRS=("${REPO_DIR}" "${REPO_DIR}/packages")

# SSH 密钥配置: 优先 root 默认 id_rsa(物理 worker 已预配 root 免密), 回退 cubestack_k8s
SSH_KEY_DIR="${SSH_KEY_DIR:-${REAL_HOME}/.ssh}"
SSH_KEY_NAME="${SSH_KEY_NAME:-cubestack_k8s}"
if [ -f /root/.ssh/id_rsa ] && [ "${ROOT_SSH:-0}" = "1" ]; then
    SSH_KEY="/root/.ssh/id_rsa"
    SSH_SUDO="sudo"
else
    SSH_KEY="${SSH_KEY_DIR}/${SSH_KEY_NAME}"
    SSH_SUDO=""
fi
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# 收集所有存在的 .deb 包完整路径(按 basename 去重,优先仓库根目录)
DEBS=()
declare -A DEB_SEEN
for d in "${PKG_DIRS[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.deb; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        if [ -z "${DEB_SEEN[$base]:-}" ]; then
            DEB_SEEN["$base"]=1
            DEBS+=("$f")
        fi
    done
done
[ "${#DEBS[@]}" -gt 0 ] || { err "未找到离线 .deb 包: ${REPO_DIR} 或 ${REPO_DIR}/packages"; exit 1; }

[ -f "${SSH_KEY}" ] || { err "SSH 密钥不存在: ${SSH_KEY}"; exit 1; }

say "安装 worker 节点 ${USER}@${IP} 所需离线包(${#DEBS[@]} 个)..."

# 1. 复制离线包到目标节点(先建目录,再从所有来源逐个复制)
${SSH_SUDO} ssh ${SSH_OPTS} "${USER}@${IP}" "mkdir -p /tmp/packages" 2>/dev/null || true
say "复制离线包到 ${IP}:/tmp/packages/ ..."
for f in "${DEBS[@]}"; do
    [ -f "$f" ] || continue
    vlog "  复制: $(basename "$f")"
    ${SSH_SUDO} rsync -e "ssh ${SSH_OPTS}" "$f" "${USER}@${IP}:/tmp/packages/" 2>/dev/null || \
      ${SSH_SUDO} scp ${SSH_OPTS} "$f" "${USER}@${IP}:/tmp/packages/" 2>/dev/null || true
done

# 2. 安装包
say "安装中 (dpkg -i) ..."
${SSH_SUDO} ssh ${SSH_OPTS} "${USER}@${IP}" \
  "sudo dpkg -i /tmp/packages/*.deb 2>&1 | tail -5 && sudo rm -rf /tmp/packages"

ok "✅ ${IP} 离线包安装完成: iputils-ping rsync iptables curl ca-certificates"