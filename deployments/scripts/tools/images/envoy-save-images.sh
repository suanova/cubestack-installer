#!/bin/bash
# ============================================================
# envoy-save-images.sh — Envoy Gateway + Envoy AI Gateway 镜像: 离线下载 + 保存 tar
# 用途: 在联网/内网机器上把官方镜像下载并保存为 tar, 供离线环境(集群安装机)使用:
#       部署模块 modules/03_addon/09_envoy_gateway.sh / 10_envoy_ai_gateway.sh 会自动
#       从 deployments/offline-files/envoy 找到这些 tar 并推送至集群内置 registry(本地源, 不联网)。
#
# ── 需要下载的镜像清单(随版本变化; 版本取 ENVOY_EG_VERSION / ENVOY_AI_VERSION, 可用环境变量覆盖)──
#   [Envoy Gateway]    docker.io/envoyproxy/gateway:<EG_VERSION>     控制面
#                      docker.io/envoyproxy/envoy:<EG_VERSION>       数据面(用户 Gateway 动态创建 Envoy Proxy)
#   [Envoy AI Gateway] docker.io/envoyproxy/ai-gateway-controller:<AI_VERSION>   控制器(独立 Deployment; 官方源 docker.io, 非 ghcr)
#   (可选限流, 默认不下载): envoyproxy/ratelimit:<tag> + envoyproxy/envoy-ratelimit:<tag>
#
# 下载方式(按顺序尝试, 与 lws-save-images.sh 一致):
#   ① 本地 docker daemon 已有 → docker save 直接导出
#   ② docker pull(5 次重试)→ docker save
#   ③ skopeo copy docker:// → docker-archive(docker 不可用时兜底)
# 文件名: <repo>_<tag>.tar(与 cubestack-offline.sh / 09/10 模块一致, 如 docker.io_envoyproxy_gateway_v1.9.1.tar)
#
# 「保持」语义(幂等): 默认**已有 tar 则跳过**(只补缺/补新版本), 保持离线镜像集合完整;
#   加 --force 可强制重新下载覆盖。
#
# 独立运行: 本脚本**不依赖 lib-common.sh / cluster.conf / 其他脚本**, 自带最小日志/路径/skopeo
#   trust policy, 在无任何部署配置的联网准备机上可直接运行; 镜像清单用环境变量 ENVOY_IMAGE_LIST 覆盖。
# 数据源: 环境变量(优先) / 内置默认
#
# 用法:   sudo ./envoy-save-images.sh                      # 下载并保存全部镜像(已有 tar 跳过, 幂等保持)
#         sudo ./envoy-save-images.sh --list               # 只列出要下载的镜像清单(不下载)
#         sudo ./envoy-save-images.sh --force              # 强制重新下载(覆盖已有 tar)
#         sudo ./envoy-save-images.sh <镜像ref ...>        # 只下载指定镜像(如 docker.io/envoyproxy/gateway:v1.9.1)
# 注意: sudo 会清空环境变量, 指定版本时**必须把 VAR= 写在 sudo 之后**(否则被丢弃用默认值):
#         sudo ENVOY_EG_VERSION=v1.9.1 ./envoy-save-images.sh
# 加载:   tools/images/ 无独立 load 脚本 — 09/10 模块部署时自动识别并推送; 或直接
#         skopeo copy --src-tls-verify=false docker-archive:<tar> docker://<registry>/envoyproxy/gateway:<tag>
# ============================================================
set -euo pipefail

# ---- 独立运行: 自带最小日志与路径(不 source lib-common.sh / 不 load_config) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../deployments/scripts/tools/images
# 定位仓库根: 从脚本所在目录向上找含本项目标识(deployments/scripts + cubestack-addon)的目录;
# 脚本被单独拷到别处时回退到当前工作目录(输出目录仍可用 ENVOY_SAVE_DIR 显式指定)。
REPO_ROOT=""
_d="${SCRIPT_DIR}"
while [ "${_d}" != "/" ] && [ -z "${REPO_ROOT}" ]; do
    if [ -d "${_d}/deployments/scripts" ] && [ -d "${_d}/deployments/cubestack-addon" ]; then
        REPO_ROOT="${_d}"
    fi
    _d="$(dirname "${_d}")"
done
REPO_ROOT="${REPO_ROOT:-${PWD}}"
_log_file() { [ -n "${LOG_FILE:-}" ] && echo -e "$*" >> "${LOG_FILE}" 2>/dev/null || true; }
say()  { local m="→  $*"; echo -e "\033[36m${m}\033[0m"; _log_file "${m}"; }
ok()   { local m="✅ $*"; echo -e "\033[32m${m}\033[0m"; _log_file "${m}"; }
warn() { local m="⚠  $*"; echo -e "\033[33m${m}\033[0m"; _log_file "${m}"; }
err()  { local m="【错误】$*"; echo -e "\033[31m${m}\033[0m" >&2; _log_file "${m}"; }

# skopeo 兜底所需最小 trust policy(独立自带, 与 lib-common 一致): 仅当本机有 skopeo 且缺 policy 时生成
ensure_skopeo_policy() {
    command -v skopeo >/dev/null 2>&1 || return 0
    [ -f "/etc/containers/policy.json" ] && return 0
    mkdir -p /etc/containers 2>/dev/null || { warn "无法创建 /etc/containers: skopeo 兜底可能失败(需 root)"; return 1; }
    cat > /etc/containers/policy.json <<'POLICY_EOF'
{
    "default": [
        {
            "type": "insecureAcceptAnything"
        }
    ]
}
POLICY_EOF
}

[ "$(id -u)" -eq 0 ] || { err "需要 root(docker 访问), 请 sudo 执行"; exit 1; }
ensure_skopeo_policy

ENVOY_EG_VERSION="${ENVOY_EG_VERSION:-v1.9.1}"        # Envoy Gateway 版本(控制面 + 数据面 tag)
ENVOY_AI_VERSION="${ENVOY_AI_VERSION:-v1.1.0}"        # Envoy AI Gateway 控制器版本(镜像 tag + chart 版本)
ENVOY_SAVE_DIR="${ENVOY_SAVE_DIR:-${REPO_ROOT}/deployments/offline-files/envoy}"
mkdir -p "${ENVOY_SAVE_DIR}"
say "配置: EG=${ENVOY_EG_VERSION} AI=${ENVOY_AI_VERSION} 保存目录=${ENVOY_SAVE_DIR}"

# ---- 参数解析: --list / --force / 镜像 ref ----
MODE="save"; FORCE=0
for a in "$@"; do
    case "${a}" in
        --list|-l)  MODE="list" ;;
        --force|-f) FORCE=1 ;;
        *)          EXTRA_IMGS="${EXTRA_IMGS:-} ${a}" ;;
    esac
done

# 默认镜像清单(可用环境变量 ENVOY_IMAGE_LIST 覆盖; 每行: 源镜像 ref)
ENVOY_IMAGE_LIST="${ENVOY_IMAGE_LIST:-}"
if [ -z "${ENVOY_IMAGE_LIST}" ]; then
    ENVOY_IMAGE_LIST="docker.io/envoyproxy/gateway:${ENVOY_EG_VERSION}
docker.io/envoyproxy/envoy:${ENVOY_EG_VERSION}
docker.io/envoyproxy/ai-gateway-controller:${ENVOY_AI_VERSION}"
fi

# 命令行指定镜像则覆盖清单
[ -n "${EXTRA_IMGS:-}" ] && ENVOY_IMAGE_LIST="${EXTRA_IMGS# }"

# --list: 只打印清单(不下载), 供确认需离线准备的镜像
if [ "${MODE}" = "list" ]; then
    echo "Envoy Gateway / Envoy AI Gateway 需下载的镜像清单(保存目录: ${ENVOY_SAVE_DIR}):"
    while IFS= read -r img; do
        [ -z "${img}" ] && continue
        fname="$(echo "${img}" | sed 's#/#_#g; s#:#_#g').tar"
        if [ -f "${ENVOY_SAVE_DIR}/${fname}" ]; then
            echo "  ✓ [已存在] ${img}  →  ${fname}"
        else
            echo "  ☐ [待下载] ${img}  →  ${fname}"
        fi
    done <<< "${ENVOY_IMAGE_LIST}"
    exit 0
fi

save_one() {
    local src="$1" fname dest SRC_TAG _LOCAL retry=0
    fname="$(echo "${src}" | sed 's#/#_#g; s#:#_#g').tar"
    dest="${ENVOY_SAVE_DIR}/${fname}"
    if [ -f "${dest}" ] && [ "${FORCE}" != "1" ]; then
        ok "tar 已存在, 跳过(保持幂等): ${fname}"
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
