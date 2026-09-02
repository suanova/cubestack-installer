#!/bin/bash
# ============================================================
# ceph-save-images.sh — Rook/Ceph 离线镜像: 下载 + 保存独立 tar
# 用途: 在联网/内网机器上把 Rook + Ceph + ceph-csi 全部镜像拉取并保存为 tar,
#       供离线环境使用: ceph 模块(modules/03_addon/07_ceph.sh)部署前由
#       ceph-sync-images.sh 把这些 tar 同步到全部部署节点并 ctr import。
# 默认目录: ${REPO_ROOT}/deployments/offline-files/ceph
#           (即 ~/cubestack-installer/deployments/offline-files/ceph)
# 镜像清单(默认, 版本可经 CEPH_VERSION/ROOK_VERSION/CEPHCSI_VERSION 覆盖, 见 docs/ceph-rook.md):
#   docker.io/rook/ceph:v<ROOK_VERSION>            Rook operator
#   quay.io/cephcsi/ceph-csi-operator:v<CSI_OP>    CSI operator(rook v1.20 必须)
#   quay.io/ceph/ceph:v<CEPH_VERSION>              全部 Ceph 守护进程
#   quay.io/cephcsi/cephcsi:v<CEPHCSI_VERSION>     CSI 驱动
#   + CSI sidecar 等(见下方 CEPH_IMAGE_LIST)
# 下载方式(与 lws/envoy save 工具一致): ① 本地 docker 已有 → save; ② docker pull → save; ③ skopeo 兜底。
#   每镜像独立 tar(多镜像 tar 会致 ctr import "content digest not found"); --platform linux/amd64 拉单架构。
# 用法: sudo ./ceph-save-images.sh [镜像ref ...]
# 同步到节点: sudo ./ceph-sync-images.sh(本目录; 或部署时 ceph 模块自动执行)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

[ "$(id -u)" -eq 0 ] || { err "需要 root(docker 访问), 请 sudo 执行"; exit 1; }

CEPH_VERSION="${CEPH_VERSION:-v20.2.2}"
ROOK_VERSION="${ROOK_VERSION:-v1.20.2}"
CEPHCSI_VERSION="${CEPHCSI_VERSION:-v3.17.0}"
CEPH_CSI_OPERATOR_VERSION="${CEPH_CSI_OPERATOR_VERSION:-v1.0.4}"
CEPH_IMAGE_DIR="${CEPH_IMAGE_DIR:-${REPO_ROOT}/deployments/offline-files/ceph}"
mkdir -p "${CEPH_IMAGE_DIR}"

# 默认镜像清单(每行一个; CEPH_IMAGE_LIST 环境变量可整体覆盖; 命令行参数追加)
CEPH_IMAGE_LIST="${CEPH_IMAGE_LIST:-}"
if [ -z "${CEPH_IMAGE_LIST}" ]; then
    CEPH_IMAGE_LIST="docker.io/rook/ceph:${ROOK_VERSION}
quay.io/cephcsi/ceph-csi-operator:${CEPH_CSI_OPERATOR_VERSION}
quay.io/ceph/ceph:${CEPH_VERSION}
quay.io/cephcsi/cephcsi:${CEPHCSI_VERSION}
registry.k8s.io/sig-storage/csi-provisioner:v6.2.0
registry.k8s.io/sig-storage/csi-attacher:v4.12.0
registry.k8s.io/sig-storage/csi-resizer:v2.1.0
registry.k8s.io/sig-storage/csi-snapshotter:v8.5.0
registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.17.0
quay.io/csiaddons/k8s-sidecar:v0.14.0
registry.k8s.io/sig-storage/snapshot-controller:v8.0.1"
fi
[ $# -gt 0 ] && CEPH_IMAGE_LIST="$(printf '%s\n' ${CEPH_IMAGE_LIST} $*)"

save_one() {
    local src="$1" fname dest retry=0
    fname="$(echo "${src}" | sed 's#/#_#g; s#:#_#g').tar"
    dest="${CEPH_IMAGE_DIR}/${fname}"
    if [ -f "${dest}" ]; then
        ok "tar 已存在, 跳过: ${fname}"
        du -sh "${dest}" 2>/dev/null | awk '{print "  大小: "$1}'
        return 0
    fi
    say "镜像: ${src} → ${dest}"
    # ① 本地 docker 已有
    if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -qx "${src}"; then
        say "  本地 docker 已有, 直接 save ..."
        if docker save "${src}" -o "${dest}"; then ok "保存完成(本地 docker): ${fname}"; return 0; fi
        rm -f "${dest}"; warn "  本地 save 失败, 尝试 pull ..."
    fi
    # ② docker pull(--platform linux/amd64 拉单架构, 规避 ctr import 多架构 digest 问题; 5 次重试)→ save
    retry=0
    while ! docker pull --platform linux/amd64 "${src}" >/dev/null 2>&1; do
        retry=$((retry + 1))
        [ "${retry}" -ge 5 ] && break
        warn "    重试 ${retry}/5: ${src} ..."; sleep 3
    done
    if docker image inspect "${src}" >/dev/null 2>&1 && docker save "${src}" -o "${dest}"; then
        ok "保存完成(docker pull + save): ${fname}"; return 0
    fi
    rm -f "${dest}"
    # ③ skopeo 兜底(docker 不可用/失败)
    if command -v skopeo >/dev/null 2>&1; then
        if skopeo copy --quiet --src-tls-verify=false "docker://${src}" "docker-archive:${dest}"; then
            ok "保存完成(skopeo): ${fname}"; return 0
        fi
        rm -f "${dest}"
    fi
    err "保存失败: ${src}(docker/skopeo 均不可用或拉取失败); 检查网络/镜像源"
    return 1
}

say "Rook/Ceph 离线镜像清单:"
echo "${CEPH_IMAGE_LIST}" | sed 's/^/  - /'
count=0
while IFS= read -r img; do
    [ -z "${img}" ] && continue
    save_one "${img}" && count=$((count + 1))
done <<< "${CEPH_IMAGE_LIST}"

echo "---------------------------------------------"
ok "保存完成: ${count} 个镜像 → ${CEPH_IMAGE_DIR}"
du -sh "${CEPH_IMAGE_DIR}" 2>/dev/null | awk '{print "  总大小: "$1}'
echo "  同步到节点: sudo ./deployments/scripts/tools/images/ceph-sync-images.sh"
echo "  或部署时(CEPH_ENABLED=true)由 ceph 模块自动同步"
