#!/bin/bash
# 向目标主机注入公钥,实现免密登录
# 用法: ./setup-passwordless.sh <IP> [user ...]      # user 缺省用配置 VM_SSH_USERS
# 前置: 已执行 gen-ssh-key.sh 生成密钥; 目标主机允许密码登录
# 密码: 默认取配置 SSH_DEFAULT_PASSWORD(虚拟机镜像预埋密码), 可用环境变量覆盖
# 退出码: 0=全部用户免密可用; 1=任一用户免密不可用(逐条打印具体原因)
#
# 2026-10-22 修订(用户实机: 密码错误却一路跑到 node_pkgs, 最后报"Ceph/RBD 残留"):
#   ① 先验证密钥是否**已经可用** —— 密钥已注入时不应再尝试密码(密码可能早已轮换),
#      避免把幂等重跑误报成失败;
#   ② 密码/网络失败必须给出可执行的诊断(密码错? 禁止密码登录? 网络不通?),
#      并让脚本**非零退出**, 由模块中止部署 —— 不再 warn 后谎报"免密配置完成"。
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

IP="${1:?用法: $0 <IP> [user ...]}"
shift || true

SSH_KEY_DIR="${SSH_KEY_DIR:-${HOME}/.ssh}"
SSH_KEY_NAME="${SSH_KEY_NAME:-cubestack_k8s}"
SSH_KEY="${SSH_KEY_DIR}/${SSH_KEY_NAME}"
KEY_PUB="${SSH_KEY}.pub"
PASSWORD="${SSH_DEFAULT_PASSWORD:-}"

[ -f "${KEY_PUB}" ] || { err "公钥不存在: ${KEY_PUB},请先执行 ./gen-ssh-key.sh"; exit 1; }

USERS=("$@")
[ "${#USERS[@]}" -gt 0 ] || USERS=(${VM_SSH_USERS:-root ubuntu})

PUBKEY="$(cat "${KEY_PUB}")"
FAILED=0

# 密钥认证是否已可用(幂等判断; 失败时不打印噪声)
# ⚠ 只验证**部署密钥本身**:
#   · -F /dev/null 忽略 ~/.ssh/config(其中可能有其它 IdentityFile);
#   · -i "${SSH_KEY}" 取代 OpenSSH 默认身份列表(~/.ssh/id_*), 实际只会尝试这一把;
#   · IdentitiesOnly=yes 禁止 ssh-agent 用**其它**身份代答。
#   · **不禁用 agent**: 口令保护的部署密钥若已加载进 ssh-agent, 需要由 agent 用同一把密钥
#     签名(BatchMode 无法交互输入口令); IdentitiesOnly 保证 agent 只能用它, 不会放行别的
#     身份。IdentityAgent=none 会让这种密钥在无节点密码时被误判为不可用(2026-10-23 CodeRabbit)。
_key_ok() {
    ssh -i "${SSH_KEY}" -F /dev/null -o IdentitiesOnly=yes \
        -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$1@${IP}" true 2>/dev/null
}

for user in "${USERS[@]}"; do
    if _key_ok "${user}"; then
        ok "免密登录已就绪: ${user}@${IP} (key: ${SSH_KEY})"
        continue
    fi

    if [ -z "${PASSWORD}" ]; then
        err "${user}@${IP} 免密登录不可用, 且未配置密码(SSH_DEFAULT_PASSWORD 或该节点 NODES 密码) —— 无法注入公钥"
        FAILED=1
        continue
    fi
    command -v sshpass >/dev/null 2>&1 \
        || { err "缺少 sshpass(密码注入依赖它), 请先安装 sshpass"; FAILED=1; continue; }

    say "注入公钥 → ${user}@${IP} ..."
    _err="$(mktemp)"
    # 强制密码认证注入公钥(幂等: 已存在则跳过); 只尝试一次密码, 避免错误密码反复重试
    if SSHPASS="${PASSWORD}" sshpass -e ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o NumberOfPasswordPrompts=1 \
        "${user}@${IP}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qF '${PUBKEY}' ~/.ssh/authorized_keys 2>/dev/null || echo '${PUBKEY}' >> ~/.ssh/authorized_keys" 2>"${_err}"; then
        rm -f "${_err}"
    else
        _msg="$(grep -v '^Warning: Permanently added ' "${_err}" | grep -v '^[[:space:]]*$' | tail -2 | tr '\n' ' ' || true)"
        rm -f "${_err}"
        if printf '%s' "${_msg}" | grep -qiE 'permission denied|no supported authentication methods'; then
            err "${user}@${IP} 密码认证失败 —— 密码错误, 或目标禁止密码登录(检查 SSH_DEFAULT_PASSWORD / 该节点 NODES 密码、sshd PasswordAuthentication)"
        elif printf '%s' "${_msg}" | grep -qiE 'connection refused|connection timed out|connection closed|no route to host|network is unreachable'; then
            err "${user}@${IP} SSH 网络不可达 —— ${_msg:-连接失败}"
        else
            err "${user}@${IP} 公钥注入失败 —— ${_msg:-SSH 密码认证失败}"
        fi
        FAILED=1
        continue
    fi

    # 免密验证
    if _key_ok "${user}"; then
        ok "免密登录成功: ${user}@${IP} (key: ${SSH_KEY})"
    else
        err "${user}@${IP} 公钥已写入但免密验证失败 —— 检查目标 sshd 的 PubkeyAuthentication, 以及 ~/.ssh 与 authorized_keys 权限(700/600)"
        FAILED=1
    fi
done

[ "${FAILED}" = "0" ] || exit 1
