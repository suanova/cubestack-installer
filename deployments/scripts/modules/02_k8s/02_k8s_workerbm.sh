#!/bin/bash
# ============================================================
# MODULE: k8s_workerbm
# DESC: worker 节点离线包安装(对所有 worker, 不区分虚拟机/裸金属)
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# 说明: 主程序不判断虚拟机/裸金属 — 对 cluster.conf NODES 中全部 worker 执行:
#       免密连通检测(已在 k8s_passwordless 注入公钥)→ 离线系统包安装(幂等)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

say "worker 节点连通性检查 + 离线包安装(全部 worker, 不区分虚拟机/裸金属) ..."
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    [ "${NODE_ROLE}" = "worker" ] || continue
    node_matches "${NODE_HOSTNAME}" || continue

    # 免密连通检测(公钥已在 k8s_passwordless 注入; 失败则提示)
    SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
    if ! ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes -o ConnectTimeout=8 "${NODE_USER}@${NODE_IP}" 'true' >/dev/null 2>&1; then
        if [ -z "${NODE_PW}" ]; then
            warn "worker ${NODE_HOSTNAME}(${NODE_IP}) 免密不可达且未配置密码, 跳过(检查 k8s_passwordless 与 SSH_DEFAULT_PASSWORD/节点独立密码)"
            continue
        fi
        if ! SSHPASS="${NODE_PW}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=8 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            "${NODE_USER}@${NODE_IP}" 'hostname' >/dev/null 2>&1; then
            warn "worker ${NODE_HOSTNAME}(${NODE_IP}) 免密/密码均不可达, 跳过(检查网络与密码)"
            continue
        fi
        warn "worker ${NODE_HOSTNAME}(${NODE_IP}) 免密不可达但密码连通(公钥未注入?), 继续尝试装包"
    fi
    ok "worker ${NODE_HOSTNAME}(${NODE_IP}) 连通(user=${NODE_USER})"

    # 安装离线包
    say "安装离线包到 worker ${NODE_HOSTNAME}(${NODE_IP}) ..."
    bash "${SCRIPT_DIR}/tools/node/install-worker-packages.sh" "${NODE_IP}" "${NODE_USER}" || warn "离线包安装失败,可稍后手动执行"
done
ok "worker 节点处理完成"
