#!/bin/bash
# ============================================================
# lws-save-images.sh — LWS(LeaderWorkerSet)controller 镜像: 离线下载 + 保存 tar
# 用途: 在联网/内网机器上把官方镜像 registry.k8s.io/lws/lws:<tag> 下载并保存为 tar,
#       供离线环境(集群安装机)使用: 部署模块 modules/03_addon/05_gpu_lws.sh 会自动
#       从 deployments/offline-files/lws 找到该 tar 并推送至集群内置 registry(本地源, 不联网)。
# 数据源: cluster.conf (LWS_IMAGE_TAG / LWS_IMAGE_SRC / LWS_SAVE_DIR / REPO_ROOT)
# 下载方式(按顺序尝试):
#   ① 本地 docker daemon 已有该镜像(任意前缀 /lws:tag) → docker save 直接导出
#   ② docker pull(默认, 5 次重试, 与 cubestack-offline.sh 一致)→ docker save
#   ③ skopeo copy docker:// → docker-archive(docker 不可用时兜底)
# 文件名: <repo>_<tag>.tar(与 cubestack-offline.sh 一致, 如 registry.k8s.io_lws_lws_v0.10.0.tar)
# 用法:   sudo ./lws-save-images.sh [镜像ref] [保存目录]
#         示例: sudo ./lws-save-images.sh                          # 全部走 cluster.conf(默认 v0.10.0)
#               sudo ./lws-save-images.sh registry.k8s.io/lws/lws:v0.10.0
#               sudo ./lws-save-images.sh my-registry/lws/lws:v0.10.0 /data/offline/images
# 加载:   tools/images/ 无独立 load 脚本 — 05_gpu_lws.sh 部署时自动识别并推送; 或直接
#         skopeo copy --src-tls-verify=false docker-archive:<tar> docker://<registry>/lws/manager:<tag>
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

[ "$(id -u)" -eq 0 ] || { err "需要 root(docker 访问), 请 sudo 执行"; exit 1; }

LWS_IMAGE_TAG="${LWS_IMAGE_TAG:-v0.10.0}"                                   # 目标 tag(对应官方 image.manager.tag)
SRC="${1:-${LWS_IMAGE_SRC:-registry.k8s.io/lws/lws:${LWS_IMAGE_TAG}}}"      # 源镜像(默认官方 registry)
SAVE_DIR="${2:-${LWS_SAVE_DIR:-${REPO_ROOT}/deployments/offline-files/lws}}"  # 默认 LWS 离线 tar 目录
mkdir -p "${SAVE_DIR}"

# 文件名与 cubestack-offline.sh 规则一致: repo 的 / 与 : → _
fname="$(echo "${SRC}" | sed 's#/#_#g; s#:#_#g').tar"
dest="${SAVE_DIR}/${fname}"

if [ -f "${dest}" ]; then
    ok "tar 已存在, 跳过: ${dest}"
    du -sh "${dest}" 2>/dev/null | awk '{print "  大小: "$1}'
    exit 0
fi

say "LWS controller 镜像: ${SRC}"
say "保存到: ${dest}"

SRC_TAG="${SRC##*:}"   # 源镜像 tag(自定义镜像源时可能 ≠ LWS_IMAGE_TAG)

# ① 本地 docker daemon 已有(任意 registry 前缀, 匹配 /lws:<tag> 或完整 ref)
_LOCAL="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -E "^(.*/)?lws:${SRC_TAG}$" | head -1 || true)"
[ -z "${_LOCAL}" ] \
    && _LOCAL="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -x "${SRC}" | head -1 || true)"

if [ -n "${_LOCAL}" ]; then
    say "  本地 docker 已有: ${_LOCAL}, 直接 save ..."
    if docker save "${_LOCAL}" -o "${dest}"; then
        ok "保存完成(本地 docker): ${dest}"
        du -sh "${dest}" 2>/dev/null | awk '{print "  大小: "$1}'
        exit 0
    fi
    rm -f "${dest}"
    warn "  本地 save 失败, 尝试 pull ..."
fi

# ② docker pull(5 次重试)→ save
if command -v docker >/dev/null 2>&1; then
    say "  docker pull ${SRC}(5 次重试)..."
    retry=0
    while ! docker pull "${SRC}" >/dev/null 2>&1; do
        retry=$((retry + 1))
        [ "${retry}" -ge 5 ] && { err "docker pull 失败(5 次重试): ${SRC}"; exit 1; }
        warn "    重试 ${retry}/5: ${SRC} ..."
        sleep 3
    done
    if docker save "${SRC}" -o "${dest}"; then
        ok "保存完成(docker pull + save): ${dest}"
        du -sh "${dest}" 2>/dev/null | awk '{print "  大小: "$1}'
        exit 0
    fi
    rm -f "${dest}"
fi

# ③ skopeo 兜底(docker 不可用/失败): docker:// → docker-archive
if command -v skopeo >/dev/null 2>&1; then
    say "  skopeo copy ${SRC} → docker-archive:${dest} ..."
    if skopeo copy --quiet --src-tls-verify=false "docker://${SRC}" "docker-archive:${dest}"; then
        ok "保存完成(skopeo): ${dest}"
        du -sh "${dest}" 2>/dev/null | awk '{print "  大小: "$1}'
        exit 0
    fi
    rm -f "${dest}"
fi

err "保存失败: ${SRC}(docker/skopeo 均不可用或拉取失败); 请检查网络/镜像源(LWS_IMAGE_SRC 可覆盖为内网镜像站)"
exit 1
