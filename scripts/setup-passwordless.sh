#!/bin/bash
# 向目标主机注入公钥,实现免密登录
# 用法: ./setup-passwordless.sh <IP> [user ...]      # user 缺省用配置 VM_SSH_USERS
# 前置: 已执行 gen-ssh-key.sh 生成密钥; 目标主机允许密码登录
# 密码: 默认取配置 SSH_DEFAULT_PASSWORD(虚拟机镜像预埋密码), 可用环境变量覆盖
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"
load_config

IP="${1:?用法: $0 <IP> [user ...]}"
shift || true

SSH_KEY_DIR="${SSH_KEY_DIR:-${HOME}/.ssh}"
SSH_KEY_NAME="${SSH_KEY_NAME:-cubestack_k8s}"
SSH_KEY="${SSH_KEY_DIR}/${SSH_KEY_NAME}"
KEY_PUB="${SSH_KEY}.pub"
PASSWORD="${SSH_DEFAULT_PASSWORD:-}"

[ -f "${KEY_PUB}" ] || { err "公钥不存在: ${KEY_PUB},请先执行 ./gen-ssh-key.sh"; exit 1; }
[ -n "${PASSWORD}" ] || { err "未配置密码,请设置 SSH_DEFAULT_PASSWORD(配置文件或环境变量)"; exit 1; }

USERS=("$@")
[ "${#USERS[@]}" -gt 0 ] || USERS=(${VM_SSH_USERS:-root ubuntu})

PUBKEY="$(cat "${KEY_PUB}")"
for user in "${USERS[@]}"; do
    say "注入公钥 → ${user}@${IP} ..."
    # 强制密码认证注入公钥(幂等: 已存在则跳过)
    if SSHPASS="${PASSWORD}" sshpass -e ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        "${user}@${IP}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qF '${PUBKEY}' ~/.ssh/authorized_keys 2>/dev/null || echo '${PUBKEY}' >> ~/.ssh/authorized_keys"; then
        :
    else
        warn "${user}@${IP} 密码注入失败(检查 SSH_DEFAULT_PASSWORD 是否正确 / 目标是否开启SSH密码登录)"
        continue
    fi
    # 免密验证
    if ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "${user}@${IP}" true 2>/dev/null; then
        ok "免密登录成功: ${user}@${IP} (key: ${SSH_KEY})"
    else
        warn "公钥已写入但免密验证失败: ${user}@${IP}"
    fi
done
