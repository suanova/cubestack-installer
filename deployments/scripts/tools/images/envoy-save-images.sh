#!/bin/bash
# ============================================================
# envoy-save-images.sh — Envoy Gateway + Envoy AI Gateway 镜像: 离线下载 + 保存 tar
# 用途: 在联网/内网机器上把官方镜像下载并保存为 tar, 供离线环境(集群安装机)使用:
#       部署模块 modules/03_addon/09_envoy_gateway.sh / 10_envoy_ai_gateway.sh 会自动
#       从 deployments/offline-files/envoy 找到这些 tar 并推送至集群内置 registry(本地源, 不联网)。
# 数据源: cluster.conf (ENVOY_EG_VERSION / ENVOY_AI_VERSION / ENVOY_SAVE_DIR / REPO_ROOT)
# 镜像清单(随版本变化):
#   Envoy Gateway   : envoyproxy/gateway:<EG_VERSION>(控制面) + envoyproxy/envoy:<EG_VERSION>(数据面)
#                     可选限流组件: envoyproxy/ratelimit:<tag> + envoyproxy/envoy-ratelimit:<tag>(默认不下载)
#   Envoy AI Gateway: ghcr.io/envoyproxy/ai-gateway/ai-gateway-controller:<AI_VERSION>(控制器)
#                     数据面复用 Envoy Gateway 的 envoyproxy/envoy 镜像
# 下载方式(按顺序尝试, 与 lws-save-images.sh 一致):
#   ① 本地 docker daemon 已有 → docker save 直接导出
#   ② docker pull(5 次重试)→ docker save
#   ③ skopeo copy docker:// → docker-archive(docker 不可用时兜底)
# 文件名: <repo>_<tag>.tar(与 cubestack-offline.sh 一致, 如 docker.io_envoyproxy_gateway_v1.2.3.tar)
# 用法:   sudo ./envoy-save-images.sh [镜像ref ...]
#         示例: sudo ./envoy-save-images.sh                    # 全部走 cluster.conf 默认(EG + AI 全部)
#               sudo ./envoy-save-images.sh docker.io/envoyproxy/gateway:v1.2.3   # 只下载指定镜像
# 加载:   tools/images/ 无独立 load 脚本 — 09/10 模块部署时自动识别并推送; 或直接
#         skopeo copy --src-tls-verify=false docker-archive:<tar> docker://<registry>/envoyproxy/gateway:<tag>
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

[ "$(id -u)" -eq 0 ] || { err "需要 root(docker 访问), 请 sudo 执行"; exit 1; }

ENVOY_EG_VERSION="${ENVOY_EG_VERSION:-v1.9.0}"        # Envoy Gateway 版本(控制面 + 数据面 tag)
ENVOY_AI_VERSION="${ENVOY_AI_VERSION:-v1.0.0}"        # Envoy AI Gateway 控制器版本(1.0 = GA)
ENVOY_SAVE_DIR="${ENVOY_SAVE_DIR:-${REPO_ROOT}/deployments/offline-files/envoy}"
mkdir -p "${ENVOY_SAVE_DIR}"

# 默认镜像清单(cluster.conf 可覆盖; 每行: 源镜像 ref)
ENVOY_IMAGE_LIST="${ENVOY_IMAGE_LIST:-}"
if [ -z "${ENVOY_IMAGE_LIST}" ]; then
    ENVOY_IMAGE_LIST="docker.io/envoyproxy/gateway:${ENVOY_EG_VERSION}
docker.io/envoyproxy/envoy:${ENVOY_EG_VERSION}
ghcr.io/envoyproxy/ai-gateway/ai-gateway-controller:${ENVOY_AI_VERSION}"
fi

# 命令行指定镜像则覆盖清单
[ $# -gt 0 ] && ENVOY_IMAGE_LIST="$*"

save_one() {
    local src="$1" fname dest SRC_TAG _LOCAL retry=0
    fname="$(echo "${src}" | sed 's#/#_#g; s#:#_#g').tar"
    dest="${ENVOY_SAVE_DIR}/${fname}"
    if [ -f "${dest}" ]; then
        ok "tar 已存在, 跳过: ${fname}"
        du -sh "${dest}" 2>/dev/null | awk '{print "  大小: "$1}'
        return 0
    fi
    say "镜像: ${src}"
    say "保存到: ${dest}"
    SRC_TAG="${src##*:}"

    # ① 本地 docker daemon 已有
    _LOCAL="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -x "${src}" | head -1 || true)"
    [ -z "${_LOCAL}" ] \
        && _LOCAL="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E "/${src##*/}$|^${src}$" | head -1 || true)"
    if [ -n "${_LOCAL}" ]; then
        say "  本地 docker 已有: ${_LOCAL}, 直接 save ..."
        if docker save "${_LOCAL}" -o "${dest}"; then
            ok "保存完成(本地 docker): ${fname}"; return 0
        fi
        rm -f "${dest}"
        warn "  本地 save 失败, 尝试 pull ..."
    fi

    # ② docker pull(5 次重试)→ save
    if command -v docker >/dev/null 2>&1; then
        say "  docker pull ${src}(5 次重试)..."
        retry=0
        while ! docker pull "${src}" >/dev/null 2>&1; do
            retry=$((retry + 1))
            [ "${retry}" -ge 5 ] && { err "docker pull 失败(5 次重试): ${src}"; return 1; }
            warn "    重试 ${retry}/5: ${src} ..."
            sleep 3
        done
        if docker save "${src}" -o "${dest}"; then
            ok "保存完成(docker pull + save): ${fname}"; return 0
        fi
        rm -f "${dest}"
    fi

    # ③ skopeo 兜底
    if command -v skopeo >/dev/null 2>&1; then
        say "  skopeo copy ${src} → docker-archive:${dest} ..."
        if skopeo copy --quiet --src-tls-verify=false "docker://${src}" "docker-archive:${dest}"; then
            ok "保存完成(skopeo): ${fname}"; return 0
        fi
        rm -f "${dest}"
    fi

    err "保存失败: ${src}(docker/skopeo 均不可用或拉取失败); 检查网络/镜像源"
    return 1
}

say "Envoy Gateway / Envoy AI Gateway 镜像清单:"
echo "${ENVOY_IMAGE_LIST}" | sed 's/^/  - /'
count=0
while IFS= read -r img; do
    [ -z "${img}" ] && continue
    if save_one "${img}"; then
        count=$((count + 1))
    fi
done <<< "${ENVOY_IMAGE_LIST}"

echo "---------------------------------------------"
ok "保存完成: ${count} 个镜像 → ${ENVOY_SAVE_DIR}"
du -sh "${ENVOY_SAVE_DIR}" 2>/dev/null | awk '{print "  总大小: "$1}'
echo "  部署时由 09_envoy_gateway.sh / 10_envoy_ai_gateway.sh 自动推送至集群内置 registry"
echo "  也可手动: skopeo copy --src-tls-verify=false docker-archive:<tar> docker://<registry>/<repo>:<tag>"
