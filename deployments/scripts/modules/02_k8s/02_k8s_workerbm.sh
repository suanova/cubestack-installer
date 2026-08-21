#!/bin/bash
# ============================================================
# MODULE: k8s_workerbm
# DESC: 裸金属 worker 连通性 + 离线包安装
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# 说明: 仅处理 node_type=bm 的 worker: 密码连通检查 → 注入公钥 → install-worker-packages.sh
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

say "裸金属 worker(bm) 连通性检查 + 离线包安装 ..."
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    IFS=, read -r role hostname ip mac mem cpu disk user pw node_type <<<"${line}"
    [ "${role}" = "worker" ] || continue
    node_is_vm "${role}" "${mac}" "${mem}" "${node_type:-}" && { vlog "worker ${hostname} 为 VM, 已由 04-ssh-passwordless 处理, 跳过"; continue; }
    node_matches "${hostname}" || continue

    pw="$(node_password worker "${pw}")"
    if [ -z "${pw}" ]; then
        warn "worker ${hostname}(${ip}) 未配置密码,跳过连通性检查(可稍后补 config 后重跑)"
        continue
    fi
    if ! SSHPASS="${pw}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=8 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        "${user}@${ip}" 'hostname' >/dev/null 2>&1; then
        warn "worker ${hostname}(${ip}) 密码连接失败(检查 WORKER_SSH_PASSWORD 或节点第9字段)"
        continue
    fi
    ok "worker ${hostname}(${ip}) 连通(user=${user}, 密码认证OK)"

    # 注入 SSH 公钥(免密)
    say "注入 SSH 公钥到 worker ${hostname}(${ip}) ..."
    KEY_PUB="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}.pub"
    if [ -f "${KEY_PUB}" ]; then
        PUBKEY="$(cat "${KEY_PUB}")"
        SSHPASS="${pw}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            "${user}@${ip}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qF '${PUBKEY}' ~/.ssh/authorized_keys 2>/dev/null || echo '${PUBKEY}' >> ~/.ssh/authorized_keys" 2>/dev/null || true
        ok "SSH 公钥已注入 ${hostname}"
    fi
    # 安装离线包
    say "安装离线包到 worker ${hostname}(${ip}) ..."
    bash "${SCRIPT_DIR}/tools/node/install-worker-packages.sh" "${ip}" "${user}" || warn "离线包安装失败,可稍后手动执行"
done
ok "裸金属 worker 处理完成"
