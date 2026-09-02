#!/bin/bash
# ============================================================
# ceph-sync-images.sh — 同步 Ceph 离线镜像 tar 到全部部署节点并 ctr import
# 用途: 把 CEPH_IMAGE_DIR(默认 deployments/offline-files/ceph)下的全部 *.tar
#       复制到所有 NODES 节点(或 --only 指定), 逐个 `ctr -n k8s.io images import --no-unpack`,
#       让 kubelet/containerd 以原始镜像 ref 直接命中(无需改写 Rook manifest 镜像地址)。
# 用法: sudo ./ceph-sync-images.sh [--node <hostname|ip> ...]
# 数据源: cluster.conf (NODES / SSH_KEY_NAME / CEPH_IMAGE_DIR)
# 说明: 需目标节点 SSH 免密(部署前 k8s_passwordless 已注入公钥)。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

CEPH_IMAGE_DIR="${CEPH_IMAGE_DIR:-${REPO_ROOT}/deployments/offline-files/ceph}"
[ -d "${CEPH_IMAGE_DIR}" ] || { err "Ceph 离线镜像目录不存在: ${CEPH_IMAGE_DIR}(先联网跑 tools/images/ceph-save-images.sh 生成)"; exit 1; }
TARS=("${CEPH_IMAGE_DIR}"/*.tar)
[ -f "${TARS[0]:-}" ] || { err "${CEPH_IMAGE_DIR} 下无 *.tar(先跑 ceph-save-images.sh)"; exit 1; }

ONLY_ARG=""
[ "${1:-}" = "--node" ] && ONLY_ARG="${2:-}"

SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
[ -f "${SSH_KEY}" ] || { err "SSH 密钥不存在: ${SSH_KEY}"; exit 1; }

say "同步 ${#TARS[@]} 个 ceph 镜像 tar → 部署节点并 ctr import ..."
COUNT_NODE=0
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    [ -z "${ONLY_ARG}" ] || { [ "${NODE_HOSTNAME}" = "${ONLY_ARG}" ] || [ "${NODE_IP}" = "${ONLY_ARG}" ] || continue; }
    node_matches "${NODE_HOSTNAME}" || continue

    COUNT_NODE=$((COUNT_NODE + 1))
    say "── [${NODE_HOSTNAME}](${NODE_IP}) 同步镜像 tar + ctr import ──"
    # 1. 复制 tar(rsync 优先, scp 兜底; 目标目录先建)
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "${NODE_USER}@${NODE_IP}" "sudo mkdir -p /tmp/ceph-images && sudo chown ${NODE_USER} /tmp/ceph-images" 2>/dev/null || true
    for t in "${TARS[@]}"; do
        [ -f "${t}" ] || continue
        vlog "  复制: $(basename "${t}")"
        rsync -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" -q "${t}" "${NODE_USER}@${NODE_IP}:/tmp/ceph-images/" 2>/dev/null \
            || scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q "${t}" "${NODE_USER}@${NODE_IP}:/tmp/ceph-images/" 2>/dev/null || true
    done
    # 2. ctr import(每个 tar 单独; --no-unpack 让 containerd 按需解包)
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "${NODE_USER}@${NODE_IP}" \
        "for t in /tmp/ceph-images/*.tar; do [ -f \"\$t\" ] || continue; sudo ctr -n k8s.io images import --no-unpack \"\$t\" >/dev/null 2>&1 || echo \"import 失败: \$t\"; done; sudo rm -rf /tmp/ceph-images; sudo ctr -n k8s.io images ls -q 2>/dev/null | grep -E 'rook|ceph' | sort -u | head -30" \
        | sed 's/^/    /'
    ok "  ${NODE_HOSTNAME} 镜像导入完成"
done
[ "${COUNT_NODE}" -gt 0 ] || { err "未匹配到任何节点(检查 NODES / --node)"; exit 1; }
ok "ceph 镜像已同步到 ${COUNT_NODE} 台节点"
