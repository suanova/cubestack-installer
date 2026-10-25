#!/bin/bash
# ============================================================
# MODULE: k8s_hosts
# DESC: 同步节点侧 /etc/hosts(NODES hostname → IP, 供 hostNetwork Pod 解析对端) + 可选部署机 /etc/hosts
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# REQUIRES: k8s_passwordless
# 说明:
#   · **节点侧**(所有 NODES): 无条件执行 —— 把每个 NODES hostname→IP 写入每台节点的 /etc/hosts,
#     幂等(先删旧行再追加), 不碰 /etc/hostname; 失败即非 0(列出节点)。
#     背景(2026-10-23): NODES hostname 是 K8s 节点名, 但节点上没有解析; hostNetwork Pod 的
#     MCCL/RoCE 多机通信按 hostname 找对端失败 → 回退 127.0.0.1 → 通信失败。
#   · **部署机** /etc/hosts: 由 UPDATE_ETC_HOSTS=1 控制(默认关闭; API/registry 域名 + 节点名)。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ★ 节点侧 hostname 解析必须先于/独立于部署机 hosts 开关: hostNetwork Pod 在节点上运行,
#   部署机 /etc/hosts 对它们没有意义(2026-10-23 MCCL 实机根因)。
say "同步节点侧 /etc/hosts(NODES hostname → IP, 供 hostNetwork Pod 解析对端)..."
sync_nodes_hosts_remote || exit 1

if [ "${UPDATE_ETC_HOSTS:-0}" != "1" ]; then
    say "跳过部署机 /etc/hosts 更新(配置 UPDATE_ETC_HOSTS=1 可启用)"
    exit 0
fi

say "更新部署机 /etc/hosts(API/registry 域名 + 节点主机名解析收敛) ..."
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
