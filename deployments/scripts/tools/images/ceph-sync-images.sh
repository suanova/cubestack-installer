#!/bin/bash
# ============================================================
# ceph-sync-images.sh — 同步 Ceph 离线镜像 tar 到部署节点并 ctr import(手工补同步用)
# 用途: 把 CEPH_IMAGE_DIR(默认 offline-files/kubespray/images)下的 ceph tar(rook/ceph/csi-)
#       复制到所有 NODES 节点(或 --node 指定), 逐个 `ctr -n k8s.io images import --no-unpack`,
#       让 kubelet/containerd 以原始镜像 ref 直接命中(无需改写 Rook manifest 镜像地址)。
# ⚠ 正常部署无需本脚本: ceph 镜像已并入 kubespray images/, k8s 阶段由 cluster.yml 内置
#   预加载 play 统一同步。本脚本仅供手工补同步/扩容补镜像。
# 幂等: 节点上同名同大小 tar 且已导入成功(/.tar.done 标记) → 跳过复制与导入;
#       tar 变化(重新下载)或导入失败 → 自动重传重导。
# 用法: sudo ./ceph-sync-images.sh [--node <hostname|ip> ...]
# 数据源: cluster.conf (NODES / SSH_KEY_NAME / CEPH_IMAGE_DIR)
# 说明: 需目标节点 SSH 免密(部署前 k8s_passwordless 已注入公钥)。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

CEPH_IMAGE_DIR="${CEPH_IMAGE_DIR:-${OFFLINE_FILES_DIR}/images}"
# ★ ceph 镜像已并入 kubespray images/(k8s 阶段统一预加载), 不再使用独立 offline-files/ceph:
#   从 images/ 挑选 ceph 相关 tar(rook/ceph/csi-)。源目录(CEPH_IMAGE_DIR 默认即 images/)存在且
#   含 ceph tar 则直接用; 否则回退 kubespray images/(兼容旧 CEPH_IMAGE_DIR 指向 offline-files/ceph)。
if [ -n "${CEPH_IMAGE_DIR}" ] && [ -d "${CEPH_IMAGE_DIR}" ] && ls "${CEPH_IMAGE_DIR}"/docker.io_rook_*.tar "${CEPH_IMAGE_DIR}"/quay.io_ceph_*.tar >/dev/null 2>&1; then
    TARS=()
    for _t in "${CEPH_IMAGE_DIR}"/docker.io_rook_*.tar "${CEPH_IMAGE_DIR}"/quay.io_ceph_*.tar \
             "${CEPH_IMAGE_DIR}"/quay.io_cephcsi_*.tar "${CEPH_IMAGE_DIR}"/quay.io_csiaddons_*.tar \
             "${CEPH_IMAGE_DIR}"/registry.k8s.io_sig-storage_csi-*.tar "${CEPH_IMAGE_DIR}"/ubuntu_*.tar "${CEPH_IMAGE_DIR}"/nginx_*.tar; do
        [ -f "${_t}" ] && TARS+=("${_t}")
    done
else
    CEPH_IMAGE_DIR="${LOCAL_REPO_DIR:-${REPO_ROOT}/deployments/offline-files/kubespray}/images"
    say "源目录 ${CEPH_IMAGE_DIR:-<未设置>} 无 ceph tar, 从 kubespray images/ 挑选 ceph 镜像 tar"
    TARS=()
    for _t in "${CEPH_IMAGE_DIR}"/docker.io_rook_*.tar "${CEPH_IMAGE_DIR}"/quay.io_ceph_*.tar \
             "${CEPH_IMAGE_DIR}"/quay.io_cephcsi_*.tar "${CEPH_IMAGE_DIR}"/quay.io_csiaddons_*.tar \
             "${CEPH_IMAGE_DIR}"/registry.k8s.io_sig-storage_csi-*.tar "${CEPH_IMAGE_DIR}"/ubuntu_*.tar "${CEPH_IMAGE_DIR}"/nginx_*.tar; do
        [ -f "${_t}" ] && TARS+=("${_t}")
    done
fi
TARS=("${TARS[@]}")   # 空 glob 保护
[ -f "${TARS[0]:-}" ] || { err "未找到 ceph 镜像 tar(${CEPH_IMAGE_DIR} 下无匹配; 先跑 ceph-save-images.sh)"; exit 1; }

# 多个 --node 参数(hostname/ip 均可); 不指定 = 全部 NODES
NODE_FILTER=()
while [ $# -gt 0 ]; do
    case "$1" in
        --node) NODE_FILTER+=("${2:?--node 需要节点名}"); shift 2 ;;
        *) err "未知参数: $1(用法: [--node <hostname|ip> ...])"; exit 1 ;;
    esac
done

SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
[ -f "${SSH_KEY}" ] || { err "SSH 密钥不存在: ${SSH_KEY}"; exit 1; }
SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8)

say "同步 ${#TARS[@]} 个 ceph 镜像 tar → 部署节点并 ctr import ..."
COUNT_NODE=0
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    if [ "${#NODE_FILTER[@]}" -gt 0 ]; then
        _hit=0
        for _f in "${NODE_FILTER[@]}"; do
            { [ "${NODE_HOSTNAME}" = "${_f}" ] || [ "${NODE_IP}" = "${_f}" ]; } && _hit=1
        done
        [ "${_hit}" = "1" ] || continue
    fi
    node_matches "${NODE_HOSTNAME}" || continue

    COUNT_NODE=$((COUNT_NODE + 1))
    say "── [${NODE_HOSTNAME}](${NODE_IP}) 同步镜像 tar + ctr import ──"
    # 1. 目标目录就绪(节点用户可写, 用于写 .done 标记)
    ssh "${SSH_OPTS[@]}" "${NODE_USER}@${NODE_IP}" \
        "sudo mkdir -p /tmp/ceph-images && sudo chown ${NODE_USER} /tmp/ceph-images" 2>/dev/null || true
    # 2. 逐 tar: 已同步+已导入(同名同大小 + .done) → 跳过; 否则复制
    _COPY_FAIL=0
    for t in "${TARS[@]}"; do
        [ -f "${t}" ] || continue
        name="$(basename "${t}")"; sz="$(stat -c%s "${t}")"
        if ssh "${SSH_OPTS[@]}" "${NODE_USER}@${NODE_IP}" \
            "test -f /tmp/ceph-images/.${name}.done && [ \"\$(stat -c%s /tmp/ceph-images/${name} 2>/dev/null || echo 0)\" = \"${sz}\" ]" 2>/dev/null; then
            vlog "  已同步并导入(大小一致), 跳过: ${name}"
            continue
        fi
        vlog "  复制: ${name}"
        rsync -e "ssh ${SSH_OPTS[*]}" -q "${t}" "${NODE_USER}@${NODE_IP}:/tmp/ceph-images/" 2>/dev/null \
            || scp "${SSH_OPTS[@]}" -q "${t}" "${NODE_USER}@${NODE_IP}:/tmp/ceph-images/" 2>/dev/null \
            || { warn "  ${name} 复制失败(检查 SSH/磁盘空间)"; _COPY_FAIL=1; }
    done
    # 3. ctr import(每个 tar 单独; --no-unpack 让 containerd 按需解包); 成功写 .done 标记
    ssh "${SSH_OPTS[@]}" "${NODE_USER}@${NODE_IP}" \
        "for t in /tmp/ceph-images/*.tar; do [ -f \"\$t\" ] || continue; if sudo ctr -n k8s.io images import --no-unpack \"\$t\" >/dev/null 2>&1; then touch /tmp/ceph-images/.\$(basename \"\$t\").done; else echo \"import 失败: \$t\"; fi; done; sudo ctr -n k8s.io images ls -q 2>/dev/null | grep -E 'rook|ceph' | sort -u | head -30" \
        | sed 's/^/    /'
    [ "${_COPY_FAIL}" = "0" ] || warn "  ${NODE_HOSTNAME} 部分 tar 复制失败(导入阶段已跳过缺失文件; 可重跑本脚本续传)"
    ok "  ${NODE_HOSTNAME} 镜像导入完成"
done
[ "${COUNT_NODE}" -gt 0 ] || { err "未匹配到任何节点(检查 NODES / --node)"; exit 1; }
ok "ceph 镜像已同步到 ${COUNT_NODE} 台节点"
