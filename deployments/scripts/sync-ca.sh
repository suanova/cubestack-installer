#!/bin/bash
# ============================================================
# 同步集群 CA 证书到所有节点并重启 kubelet
# 修复物理 worker 旧集群残留 CA 导致 kubelet TLS 验证失败
#   (worker kubelet 报 "certificate signed by unknown authority")
# 用法: ./sync-ca.sh [--only <hostname>]
# 数据源: 第一个 master 节点的 /etc/kubernetes/ssl/ca.crt
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"
load_config

ONLY=""
[ "${1:-}" = "--only" ] && ONLY="${2:-}"

SSH_KEY_DIR="${SSH_KEY_DIR:-${REAL_HOME}/.ssh}"
SSH_KEY_NAME="${SSH_KEY_NAME:-cubestack_k8s}"
SSH_KEY="${SSH_KEY_DIR}/${SSH_KEY_NAME}"
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# 确定第一个 master(取配置第一个 master)
FIRST_MASTER=""
FIRST_MASTER_IP=""
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    IFS=, read -r role hostname ip mac mem cpu disk user pw <<<"${line}"
    if [ "${role}" = "master" ] && [ -z "${FIRST_MASTER}" ]; then
        FIRST_MASTER="${hostname}"
        FIRST_MASTER_IP="${ip}"
        break
    fi
done
[ -n "${FIRST_MASTER}" ] || { err "cluster.conf 中无 master 节点"; exit 1; }

say "从 ${FIRST_MASTER}(${FIRST_MASTER_IP}) 获取集群 CA ..."
CA_FILE="/tmp/cubestack-ca-${CLUSTER_NAME}.crt"
ssh ${SSH_OPTS} "${user:-ubuntu}@${FIRST_MASTER_IP}" "sudo cat /etc/kubernetes/ssl/ca.crt" > "${CA_FILE}" 2>/dev/null
[ -s "${CA_FILE}" ] || { err "获取 CA 失败"; exit 1; }
ok "CA 已获取 ($(wc -c < "${CA_FILE}") 字节)"

# 远端修复脚本(复制到节点后 root 执行)
REMOTE_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/sync-ca-remote.sh"
[ -f "${REMOTE_SCRIPT}" ] || { err "缺少远端脚本: ${REMOTE_SCRIPT}"; exit 1; }

# 分发到所有节点(主要修复物理 worker 旧残留)
COUNT=0
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    IFS=, read -r role hostname ip mac mem cpu disk user pw <<<"${line}"
    [ -z "${ONLY}" ] || [ "${hostname}" = "${ONLY}" ] || continue

    COUNT=$((COUNT + 1))
    say "── [${hostname}](${ip}) 同步 CA + 更新 kubelet.conf + 重启 kubelet ..."
    # 1. scp CA 和远端脚本
    scp ${SSH_OPTS} -o BatchMode=yes "${CA_FILE}" "${user}@${ip}:/tmp/cubestack-ca.crt" >/dev/null 2>&1 || { warn "  scp CA 失败,跳过"; continue; }
    scp ${SSH_OPTS} -o BatchMode=yes "${REMOTE_SCRIPT}" "${user}@${ip}:/tmp/sync-ca-remote.sh" >/dev/null 2>&1 || { warn "  scp 脚本失败,跳过"; continue; }
    # 2. root 执行远端修复脚本
    if ssh ${SSH_OPTS} -o BatchMode=yes "${user}@${ip}" "sudo bash /tmp/sync-ca-remote.sh; rm -f /tmp/sync-ca-remote.sh" >/dev/null 2>&1; then
        ok "  ${hostname} CA + kubelet.conf 已同步, kubelet 已重启"
    else
        warn "  ${hostname} 同步失败"
    fi
done

rm -f "${CA_FILE}"
[ "${COUNT}" -gt 0 ] || { warn "未处理任何节点"; exit 1; }
ok "CA 同步完成: ${COUNT} 台节点"