#!/bin/bash
# ============================================================
# 部署模块: 10-lws — 安装 LeaderWorkerSet (LWS)
# 【占位模块】默认关闭; 由 deploy-cluster.sh --enable lws 或 --steps 启用
# 接入方法: 在此实现 LWS 安装(kubectl apply 官方 manifest / 离线 yaml)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib-common.sh"
load_config

say "安装 LeaderWorkerSet (LWS) ..."

FIRST_MASTER_IP=""
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    IFS=, read -r role hostname ip mac mem cpu disk user pw node_type <<<"${line}"
    if [ "${role}" = "master" ]; then FIRST_MASTER_IP="${ip}"; break; fi
done
[ -n "${FIRST_MASTER_IP}" ] || { err "未找到 master 节点"; exit 1; }

# TODO(LWS): 填入实际安装步骤, 示例:
#   K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"
#   SSH="ssh -i ${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s} -o StrictHostKeyChecking=no ubuntu@${FIRST_MASTER_IP}"
#   $SSH "$K apply -f https://github.com/kubernetes-sigs/lws/releases/download/<ver>/lws.yaml" 2>/dev/null
warn "模块 [lws] 尚未实现具体逻辑, 请编辑 steps/10-lws.sh 接入 LeaderWorkerSet 安装"
