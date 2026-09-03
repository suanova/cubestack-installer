#!/bin/bash
# ============================================================
# ceph-save-images.sh — Rook/Ceph/ceph-csi 离线镜像: 下载 + 保存独立 tar
# 用途: 在联网/内网机器上把 Rook + Ceph + ceph-csi 全部镜像拉取并保存为 tar,
#       供离线环境使用: ceph 模块部署前由 ceph-sync-images.sh 同步到节点 ctr import。
# ⚠ 独立脚本: 不依赖 lib-common.sh / cluster.conf / 仓库目录结构 —— 可单独拷到
#   联网机任意目录直接运行(如拷到 /opt 后 ./ceph-save-images.sh)。
# 默认输出目录: 仓库内运行 → ${REPO_ROOT}/deployments/offline-files/ceph
#   (即 ~/cubestack-installer/deployments/offline-files/ceph); 独立运行 → $(pwd)/offline-files/ceph;
#   均可 CEPH_IMAGE_DIR 显式覆盖。
# ⚠ tar 完整性: 保存后校验 <10MB 视为残缺(拉取中断/多架构 index-only)删除重下 ——
#   曾出现 quay.io/ceph/ceph:v20.2.2 仅 7.6KB 的损坏 tar, 同步到节点 ctr import 缺层必失败。
# 镜像清单(默认, 版本可经 CEPH_VERSION/ROOK_VERSION/CEPHCSI_VERSION/CEPH_CSI_OPERATOR_VERSION 覆盖):
#   docker.io/rook/ceph:v1.20.2                     Rook operator
#   quay.io/cephcsi/ceph-csi-operator:v1.0.4        CSI operator(rook v1.20 必须)
#   quay.io/ceph/ceph:v20.2.2                       全部 Ceph 守护进程
#   quay.io/cephcsi/cephcsi:v3.17.0                 CSI 驱动
#   registry.k8s.io/sig-storage/csi-*               CSI sidecar(provisioner/attacher/resizer/snapshotter/registrar)
#   quay.io/csiaddons/k8s-sidecar:v0.14.0           csiaddons sidecar
#   registry.k8s.io/sig-storage/snapshot-controller:v8.0.1
#   ubuntu:22.04                                    (通用工具/验证镜像)
#   nginx:1.27                                      (通用工具/验证镜像)
# 下载方式: ① 本地 docker 已有 → save; ② docker pull → save; ③ skopeo 兜底。
#   每镜像独立 tar(多镜像 tar 会致 ctr import "content digest not found"); --platform linux/amd64 拉单架构。
# 用法: sudo ./ceph-save-images.sh [镜像ref ...]
#        sudo CEPH_IMAGE_DIR=/data/offline-files/ceph ./ceph-save-images.sh     # 指定输出目录
#        sudo CEPH_IMAGE_LIST="img1 img2" ./ceph-save-images.sh                # 整体覆盖默认清单
# 同步到节点(部署机, 仓库内): sudo ./deployments/scripts/tools/images/ceph-sync-images.sh
# ============================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "【错误】需要 root(docker 访问), 请 sudo 执行" >&2; exit 1; }

# ---------------- 独立日志助手(不依赖 lib-common) ----------------
say()  { echo -e "\033[36m→  $*\033[0m"; }
ok()   { echo -e "\033[32m✅ $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m"; }
err()  { echo -e "\033[31m【错误】$*\033[0m" >&2; }

# ---------------- 输出目录 ----------------
# 默认 = 仓库内 deployments/offline-files/ceph(脚本位于 cubestack-installer 仓库内时自动检测,
#   即 ~/cubestack-installer/deployments/offline-files/ceph); 独立拷到联网机任意目录运行时
#   回退 $(pwd)/offline-files/ceph; 均可 CEPH_IMAGE_DIR 显式覆盖。
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CEPH_IMAGE_DIR_DEFAULT="$(pwd)/offline-files/ceph"
case "${_SELF_DIR}" in
    *cubestack-installer/deployments/scripts/tools/images)
        _REPO_ROOT="$(cd "${_SELF_DIR}/../../../.." && pwd)"
        [ -d "${_REPO_ROOT}/deployments" ] && _CEPH_IMAGE_DIR_DEFAULT="${_REPO_ROOT}/deployments/offline-files/ceph"
        ;;
esac
CEPH_IMAGE_DIR="${CEPH_IMAGE_DIR:-${_CEPH_IMAGE_DIR_DEFAULT}}"
mkdir -p "${CEPH_IMAGE_DIR}"

# ---------------- 版本(可经环境变量覆盖) ----------------
CEPH_VERSION="${CEPH_VERSION:-v20.2.2}"
ROOK_VERSION="${ROOK_VERSION:-v1.20.2}"
CEPHCSI_VERSION="${CEPHCSI_VERSION:-v3.17.0}"
CEPH_CSI_OPERATOR_VERSION="${CEPH_CSI_OPERATOR_VERSION:-v1.0.4}"

# ---------------- 默认镜像清单(每行一个; CEPH_IMAGE_LIST 环境变量可整体覆盖; 命令行参数追加) ----------------
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
registry.k8s.io/sig-storage/snapshot-controller:v8.0.1
ubuntu:22.04
nginx:1.27"
fi
[ $# -gt 0 ] && CEPH_IMAGE_LIST="$(printf '%s\n' ${CEPH_IMAGE_LIST} $*)"

# tar 完整性快速校验: 正常镜像 tar ≥ 数十 MB; <10MB 多为残缺产物
# (拉取中断 / 多架构 index-only), 删除重下, 避免"看似下载完实则 ctr import 缺层失败"。
validate_tar() {   # <tar文件> → 退出码 0=正常
    local f="$1" sz
    [ -f "${f}" ] || return 1
    sz="$(stat -c%s "${f}" 2>/dev/null || echo 0)"
    [ "${sz:-0}" -ge 10485760 ]
}

save_one() {
    local src="$1" fname dest retry=0
    fname="$(echo "${src}" | sed 's#/#_#g; s#:#_#g').tar"
    dest="${CEPH_IMAGE_DIR}/${fname}"
    # 已存在: 完整则跳过; 残缺(<10MB)则删除重下
    if [ -f "${dest}" ]; then
        if validate_tar "${dest}"; then
            ok "tar 已存在, 跳过: ${fname}"
            du -sh "${dest}" 2>/dev/null | awk '{print "  大小: "$1}'
            return 0
        fi
        warn "tar 残缺(<10MB, 拉取中断或 index-only 产物), 删除重下: ${fname}"
        rm -f "${dest}"
    fi
    say "镜像: ${src} → ${dest}"
    # ① 本地 docker 已有
    if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -qx "${src}"; then
        say "  本地 docker 已有, 直接 save ..."
        if docker save "${src}" -o "${dest}"; then
            if validate_tar "${dest}"; then ok "保存完成(本地 docker): ${fname}"; return 0; fi
            rm -f "${dest}"; warn "  本地 save 产物残缺, 尝试 pull ..."
        else
            rm -f "${dest}"; warn "  本地 save 失败, 尝试 pull ..."
        fi
    fi
    # ② docker pull(--platform linux/amd64 拉单架构, 规避 ctr import 多架构 digest 问题; 5 次重试)→ save
    retry=0
    while ! docker pull --platform linux/amd64 "${src}" >/dev/null 2>&1; do
        retry=$((retry + 1))
        [ "${retry}" -ge 5 ] && break
        warn "    重试 ${retry}/5: ${src} ..."; sleep 3
    done
    if docker image inspect "${src}" >/dev/null 2>&1 && docker save "${src}" -o "${dest}"; then
        if validate_tar "${dest}"; then ok "保存完成(docker pull + save): ${fname}"; return 0; fi
        rm -f "${dest}"; warn "  docker save 产物残缺, 尝试 skopeo ..."
    fi
    rm -f "${dest}"
    # ③ skopeo 兜底(docker 不可用/失败); --platform 单架构: 不指定会拷整份多架构
    #    index(大且部分镜像 ctr import 失败), 与 docker pull 行为对齐
    if command -v skopeo >/dev/null 2>&1; then
        if skopeo copy --quiet --src-tls-verify=false --platform linux/amd64 "docker://${src}" "docker-archive:${dest}"; then
            if validate_tar "${dest}"; then ok "保存完成(skopeo): ${fname}"; return 0; fi
            rm -f "${dest}"; warn "  skopeo 产物残缺, 判定失败"
        else
            rm -f "${dest}"
        fi
    fi
    err "保存失败: ${src}(docker/skopeo 均不可用或拉取失败); 检查网络/镜像源"
    return 1
}

say "Rook/Ceph 离线镜像清单(输出目录: ${CEPH_IMAGE_DIR}):"
echo "${CEPH_IMAGE_LIST}" | sed 's/^/  - /'
count=0
while IFS= read -r img; do
    [ -z "${img}" ] && continue
    save_one "${img}" && count=$((count + 1))
done <<< "${CEPH_IMAGE_LIST}"

echo "---------------------------------------------"
ok "保存完成: ${count} 个镜像 → ${CEPH_IMAGE_DIR}"
du -sh "${CEPH_IMAGE_DIR}" 2>/dev/null | awk '{print "  总大小: "$1}'
echo "  同步到节点(部署机, 仓库内): sudo ./deployments/scripts/tools/images/ceph-sync-images.sh"
echo "  或部署时(CEPH_ENABLED=true)由 ceph 模块自动同步"
