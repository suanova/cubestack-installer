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

say "更新 /etc/hosts(API/registry 域名 + 节点主机名解析收敛) ..."
# 先删旧行再写当前行(ensure_hosts_entry), 多套集群/换 IP 不再残留同一域名的旧 IP 行
# API_DOMAIN 的解析地址用 api_entry_ip(): kube-vip 已绑 → VIP(高可用入口), 未绑 → 首个 master。
# ⚠ 不能用 API_IP —— 它是"能通 NodePort 的节点 IP"语义(registry mirror/DNAT 判定用), 见其说明。
API_ENTRY_IP="$(api_entry_ip)" || exit 1
say "  ${API_DOMAIN} → ${API_ENTRY_IP}"
ensure_hosts_entry "${API_ENTRY_IP}" "${API_DOMAIN}"
ensure_hosts_entry "${REGISTRY_IP}" "${REGISTRY_DOMAIN}"
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    ensure_hosts_entry "${NODE_IP}" "${NODE_HOSTNAME}"
    ok "已收敛 /etc/hosts: ${NODE_IP} ${NODE_HOSTNAME}"
done
ok "/etc/hosts 更新完成(${API_DOMAIN}/${REGISTRY_DOMAIN} + ${#NODES[@]} 节点)"
