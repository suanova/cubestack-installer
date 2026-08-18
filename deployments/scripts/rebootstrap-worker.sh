#!/bin/bash
# ============================================================
# 重新 bootstrap worker 节点客户端证书(修复 kubelet Unauthorized)
# 物理 worker 旧集群残留的 kubelet 客户端证书(旧 CA 签发)导致 apiserver 认证失败
# 方案: 用 kubeadm join 重新加入, 生成新 CA 签发的客户端证书
# 用法: ./rebootstrap-worker.sh [--only <hostname>]
# 数据源: 第一个 master 节点(生成 join token)
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

# 确定第一个 master
FIRST_MASTER=""; FIRST_MASTER_IP=""
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    IFS=, read -r role hostname ip mac mem cpu disk user pw <<<"${line}"
    if [ "${role}" = "master" ] && [ -z "${FIRST_MASTER}" ]; then
        FIRST_MASTER="${hostname}"; FIRST_MASTER_IP="${ip}"; break
    fi
done
[ -n "${FIRST_MASTER}" ] || { err "cluster.conf 中无 master 节点"; exit 1; }

say "从 ${FIRST_MASTER}(${FIRST_MASTER_IP}) 获取 kubeadm join 命令 ..."
JOIN_CMD=""
ssh ${SSH_OPTS} -o BatchMode=yes "ubuntu@${FIRST_MASTER_IP}" \
    "sudo kubeadm token create --print-join-command 2>/dev/null" > /tmp/cubestack-join-cmd.txt 2>/dev/null || { err "生成 join token 失败"; exit 1; }
JOIN_CMD="$(cat /tmp/cubestack-join-cmd.txt)"
rm -f /tmp/cubestack-join-cmd.txt
[ -n "${JOIN_CMD}" ] || { err "join 命令为空"; exit 1; }
# 追加 ignore-preflight-errors(容忍已存在资源/端口, 兼容幂等)
JOIN_CMD="${JOIN_CMD} --ignore-preflight-errors=FileAvailable--etc-kubernetes-pki-ca.crt,FileAvailable--etc-kubernetes-kubelet.conf,Port-10250"
ok "join 命令: ${JOIN_CMD}"

# 远端重建脚本
REMOTE_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/rebootstrap-remote.sh"
[ -f "${REMOTE_SCRIPT}" ] || { err "缺少远端脚本: ${REMOTE_SCRIPT}"; exit 1; }

# 对每个 worker 重新 bootstrap
COUNT=0
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    IFS=, read -r role hostname ip mac mem cpu disk user pw <<<"${line}"
    [ "${role}" = "worker" ] || continue
    [ -z "${ONLY}" ] || [ "${hostname}" = "${ONLY}" ] || continue

    COUNT=$((COUNT + 1))
    say "── [${hostname}](${ip}) 清理旧状态 + kubeadm join ..."

    # scp 远端脚本
    scp ${SSH_OPTS} -o BatchMode=yes "${REMOTE_SCRIPT}" "${user}@${ip}:/tmp/rebootstrap-remote.sh" >/dev/null 2>&1 || { warn "  scp 脚本失败,跳过"; continue; }

    # 用 JOIN_CMD 环境变量传递, root 执行远端脚本(避免 ssh 字符串转义问题)
    if ssh ${SSH_OPTS} -o BatchMode=yes "${user}@${ip}" \
        "JOIN_CMD='${JOIN_CMD}' sudo bash /tmp/rebootstrap-remote.sh; rm -f /tmp/rebootstrap-remote.sh" >/dev/null 2>&1; then
        ok "  ${hostname} 重新加入集群"
    else
        warn "  ${hostname} join 失败"
    fi
done

[ "${COUNT}" -eq 0 ] && { warn "未处理任何 worker 节点"; exit 1; }
ok "worker 重新 bootstrap 完成: ${COUNT} 台"