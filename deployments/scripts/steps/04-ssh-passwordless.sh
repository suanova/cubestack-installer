#!/bin/bash
# ============================================================
# 部署模块: 04-ssh-passwordless — 配置 VM 节点 SSH 免密
# 对 node_type=vm 的节点执行 setup-passwordless.sh(注入公钥)
# VM 密码: 节点行显式指定则用之, 否则用基础镜像预埋默认密码 SSH_DEFAULT_PASSWORD
# 支持 --only 过滤(ONLY_HOSTS 环境变量)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib-common.sh"
load_config

say "配置 VM 节点 SSH 免密 ..."
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    IFS=, read -r role hostname ip mac mem cpu disk user pw node_type <<<"${line}"
    node_is_vm "${role}" "${mac}" "${mem}" "${node_type:-}" || continue
    node_matches "${hostname}" || continue

    # VM 节点密码: 显式指定则用之, 否则用默认(基础镜像预埋)
    if [ -n "${pw}" ] && [ "${pw}" != "-" ]; then :; else pw="${SSH_DEFAULT_PASSWORD:-k8s@2026}"; fi
    say "  ${hostname}(${ip}) 注入公钥 ..."
    SSH_DEFAULT_PASSWORD="${pw}" bash "${SCRIPT_DIR}/setup-passwordless.sh" "${ip}" ${VM_SSH_USERS:-root ubuntu} \
        || warn "  ${hostname} 免密配置失败(检查密码/网络)"
done
ok "SSH 免密配置完成"
