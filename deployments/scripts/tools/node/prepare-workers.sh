#!/bin/bash
# ============================================================
# 批量准备物理 GPU worker 节点(master VM 外的裸金属)
# 对每台 worker:
#   1. 用节点密码(NODES 第5字段显式密码或默认 SSH_DEFAULT_PASSWORD)注入 SSH 公钥(免密)
#   2. 安装离线 .deb 包(iputils-ping/rsync/iptables/curl/ca-certificates)
#   3. 推送 /etc/hosts 节点解析(k8s-api.cubestack.io + 全节点)
# 用法: sudo ./prepare-workers.sh [--only <hostname>]
# 数据源: deployments/config/cluster.conf
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

ONLY=""
[ "${1:-}" = "--only" ] && ONLY="${2:-}"

# SSH 密钥: 优先 root 默认 id_rsa(物理 worker 已预配 root 免密), 回退 cubestack_k8s
SSH_KEY_DIR="${SSH_KEY_DIR:-${REAL_HOME}/.ssh}"
SSH_KEY_NAME="${SSH_KEY_NAME:-cubestack_k8s}"
if [ -f /root/.ssh/id_rsa ]; then
    SSH_KEY="/root/.ssh/id_rsa"
    SSH_SUDO="sudo"    # 读 root 密钥需 sudo
    vlog "worker 登录密钥: /root/.ssh/id_rsa (root)"
else
    SSH_KEY="${SSH_KEY_DIR}/${SSH_KEY_NAME}"
    SSH_SUDO=""
fi
KEY_PUB="${SSH_KEY}.pub"
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

[ -f "${SSH_KEY}" ] || { err "SSH 密钥不存在: ${SSH_KEY}, 先运行 gen-ssh-key.sh"; exit 1; }

# 宿主机解析块(与 sync-hosts.sh 一致)
# API_IP / API_DOMAIN 由 lib-common load_config 统一提供(从 cluster.conf 派生), 不再本地设置
HOSTS_BLOCK="# >>> cubestack-cluster
${API_IP}          ${API_DOMAIN}"
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    HOSTS_BLOCK="${HOSTS_BLOCK}
${NODE_IP}     ${NODE_HOSTNAME}"
done
HOSTS_BLOCK="${HOSTS_BLOCK}
# <<< cubestack-cluster"

say "准备物理 GPU worker 节点(登录密钥: ${SSH_KEY}) ..."
COUNT=0
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    [ "${NODE_ROLE}" = "worker" ] || continue
    [ -z "${ONLY}" ] || [ "${NODE_HOSTNAME}" = "${ONLY}" ] || continue

    COUNT=$((COUNT + 1))
    say "── [${NODE_HOSTNAME}](${NODE_IP}) ──"

    # 1. 免密检测(root id_rsa) → 并确保 cubestack_k8s 公钥已在 authorized_keys
    if ${SSH_SUDO} timeout 5 ssh ${SSH_OPTS} -o BatchMode=yes "${NODE_USER}@${NODE_IP}" 'true' >/dev/null 2>&1; then
        ok "root id_rsa 免密登录 OK"
    else
        # root id_rsa 免密失败: 尝试密码注入 root id_rsa 公钥
        PWD="${NODE_PW:-}"
        [ -n "${PWD}" ] || { warn "免密失败且无密码,跳过 ${NODE_HOSTNAME}"; continue; }
        say "注入公钥(密码认证 ${NODE_USER}@${NODE_IP})..."
        PUBKEY="$(sudo cat /root/.ssh/id_rsa.pub 2>/dev/null)"
        SSHPASS="${PWD}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            "${NODE_USER}@${NODE_IP}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '${PUBKEY}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" 2>/dev/null \
            && ok "root 公钥已注入" || { warn "公钥注入失败,跳过 ${NODE_HOSTNAME}"; continue; }
    fi

    # 1b. 确保 cubestack_k8s 公钥在 authorized_keys(kubespray 统一用此密钥连接)
    #     先删除旧的 cubestack-cluster 行(grep -F 会因注释误判存在), 再追加正确公钥
    say "注入 cubestack_k8s 公钥(幂等)..."
    CSPUBKEY="$(cat "${SSH_KEY_DIR}/${SSH_KEY_NAME}.pub" 2>/dev/null)"
    ${SSH_SUDO} ssh ${SSH_OPTS} -o BatchMode=yes "${NODE_USER}@${NODE_IP}" \
        "sed -i '/cubestack-cluster/d' ~/.ssh/authorized_keys 2>/dev/null; echo '${CSPUBKEY}' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys" 2>/dev/null \
        && ok "cubestack_k8s 公钥已就绪" || warn "cubestack_k8s 公钥注入失败"

    # 2. 安装离线包(用 root id_rsa)
    say "安装离线包..."
    ROOT_SSH=1 bash "${SCRIPT_DIR}/tools/node/install-worker-packages.sh" "${NODE_IP}" "${NODE_USER}" || warn "离线包安装失败"

    # 3. 推送 /etc/hosts
    say "更新 /etc/hosts ..."
    # 先删旧块 + 旧裸条目(nova-k8s-*/mxgpu-*/k8s-api.nova.local / k8s-api.cubestack.io), 再追加新块 → 主机名不重复
    ${SSH_SUDO} timeout 30 ssh ${SSH_OPTS} "${NODE_USER}@${NODE_IP}" "sudo bash -c '
        sed -i \"/# >>> cubestack-cluster/,/# <<< cubestack-cluster/d\" /etc/hosts
        sed -i -E \"/nova-k8s-(master|node)/d; /mxgpu-[0-9]/d; /k8s-api\\\\.(nova\\\\.local|cubestack\\\\.io)/d\" /etc/hosts
        echo \"${HOSTS_BLOCK}\" >> /etc/hosts
    '" 2>&1 && ok "hosts 已更新" || warn "hosts 更新失败"
    vlog "  校验: ${NODE_USER}@${NODE_IP} hostname = $(${SSH_SUDO} ssh ${SSH_OPTS} -o BatchMode=yes "${NODE_USER}@${NODE_IP}" 'hostname' 2>/dev/null)"
done

[ "${COUNT}" -eq 0 ] && { warn "未处理任何 worker 节点"; exit 1; }
ok "物理 worker 准备完成: ${COUNT} 台"