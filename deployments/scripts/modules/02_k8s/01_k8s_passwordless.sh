#!/bin/bash
# ============================================================
# MODULE: k8s_passwordless
# DESC: 配置节点 SSH 免密(对所有节点注入公钥, 幂等; 不区分虚拟机/裸金属)
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# 说明: 主程序不判断虚拟机/裸金属 — 对 cluster.conf NODES 中全部节点执行公钥注入
#       (密码 = 节点独立密码或默认 SSH_DEFAULT_PASSWORD); 支持 --only 过滤
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

say "配置节点 SSH 免密(全部节点, 不区分虚拟机/裸金属) ..."
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    node_matches "${NODE_HOSTNAME}" || continue
    [ -n "${NODE_PW}" ] || { warn "  ${NODE_HOSTNAME}(${NODE_IP}) 未配置密码(SSH_DEFAULT_PASSWORD 或节点独立密码), 跳过免密"; continue; }

    say "  ${NODE_HOSTNAME}(${NODE_IP}, user=${NODE_USER}) 注入公钥 ..."
    SSH_DEFAULT_PASSWORD="${NODE_PW}" \
        bash "${SCRIPT_DIR}/tools/node/setup-passwordless.sh" "${NODE_IP}" "${NODE_USER}" \
        || warn "  ${NODE_HOSTNAME} 免密配置失败(检查密码/网络)"
done
ok "SSH 免密配置完成"
