#!/bin/bash
# ============================================================
# MODULE: k8s_hosts
# DESC: 更新宿主机 /etc/hosts 节点解析
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# 说明: 由 UPDATE_ETC_HOSTS=1 控制(默认关闭)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if [ "${UPDATE_ETC_HOSTS:-0}" != "1" ]; then
    say "跳过 /etc/hosts 更新(配置 UPDATE_ETC_HOSTS=1 可启用)"
    exit 0
fi

say "更新 /etc/hosts(节点主机名解析) ..."
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    if ! grep -qE "[[:space:]]${NODE_HOSTNAME}([[:space:]]|\$)" /etc/hosts; then
        echo "${NODE_IP} ${NODE_HOSTNAME}" >> /etc/hosts
        ok "已添加 /etc/hosts: ${NODE_IP} ${NODE_HOSTNAME}"
    fi
done
ok "/etc/hosts 更新完成"
