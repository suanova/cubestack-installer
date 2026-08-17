#!/bin/bash
# 生成集群 SSH 密钥对(幂等,已存在则跳过)
# 用法: ./gen-ssh-key.sh
# 数据源: config/cluster.conf (SSH_KEY_DIR / SSH_KEY_NAME)
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"
load_config

SSH_KEY_DIR="${SSH_KEY_DIR:-${HOME}/.ssh}"
SSH_KEY_NAME="${SSH_KEY_NAME:-cubestack_k8s}"
SSH_KEY="${SSH_KEY_DIR}/${SSH_KEY_NAME}"

mkdir -p "${SSH_KEY_DIR}" && chmod 700 "${SSH_KEY_DIR}"

if [ -f "${SSH_KEY}" ]; then
    ok "密钥已存在: ${SSH_KEY} (跳过生成)"
else
    say "生成 SSH 密钥对(ed25519, 无口令) ..."
    ssh-keygen -t ed25519 -N "" -C "cubestack-cluster" -f "${SSH_KEY}" >/dev/null
    chmod 600 "${SSH_KEY}"
    ok "已生成: ${SSH_KEY}"
fi

echo "  私钥: ${SSH_KEY}"
echo "  公钥: ${SSH_KEY}.pub"
echo "  公钥内容:"
cat "${SSH_KEY}.pub"
