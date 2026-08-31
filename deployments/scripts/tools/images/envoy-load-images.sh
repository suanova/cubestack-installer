#!/bin/bash
# ============================================================
# envoy-load-images.sh — 把离线 envoy 镜像 tar 加载推送到集群内置 registry
# 用途: 独立预加载入口(无需跑 09/10 部署模块)。把 envoy-save-images.sh 生成的
#       offline-files/envoy 下 tar 批量推送到集群内置 registry(幂等, 已存在则跳过)。
#       09/10 模块部署时也会自动推送; 本脚本用于**先预加载**(如先推镜像再装 chart)。
# 目标镜像(与 09/10 模块 helm --set 完全一致):
#   envoyproxy/gateway:${ENVOY_EG_VERSION}              ← *gateway_${ENVOY_EG_VERSION}.tar(EG 控制面)
#   envoyproxy/envoy:${ENVOY_PROXY_VERSION}             ← *envoy_${ENVOY_PROXY_VERSION}.tar(EG 数据面; ⚠ tag=ENVOY_PROXY_VERSION, 默认 distroless-v1.39.1, 勿用 EG 版本号)
#   ai-gateway/ai-gateway-controller:${ENVOY_AI_IMAGE_TAG} ← *ai-gateway-controller*.tar(AI 控制器)
#   ai-gateway/ai-gateway-extproc:${ENVOY_AI_IMAGE_TAG}    ← *ai-gateway-extproc*.tar(⚠ extProc sidecar: AI 控制器
#       把它注入数据面 pod, 漏推则数据面 2/3 ImagePullBackOff, AI 路由 404)
# 纯离线: 不联网(在线拉取由 09/10 模块 ENVOY_*_IMAGE_ONLINE 控制)。
# tar 识别: 文件名 glob 快路径 + tar_first_image_tag 内容校验(兼容改名/异常命名)。
# nodeport 模式(无 MetalLB, REGISTRY_IP 为空): 用 ENVOY_PUSH_ENDPOINT 覆盖推送入口,
#   如 <首节点IP>:${REGISTRY_NODEPORT:-31148}(参见 tools/lb/gateway-nodeport.sh / 22_verify_registry_storage.sh)。
# 数据源: cluster.conf (REGISTRY_* / ENVOY_EG_VERSION / ENVOY_AI_VERSION / ENVOY_AI_IMAGE_TAG / ENVOY_SAVE_DIR)
# 用法:   sudo ./envoy-load-images.sh [tar 目录]   (缺省 = ENVOY_SAVE_DIR)
# 注意:   sudo 会清空环境变量, 指定版本时**必须把 VAR= 写在 sudo 之后**:
#         sudo ENVOY_EG_VERSION=v1.9.1 ENVOY_AI_VERSION=v1.1.0 ./envoy-load-images.sh
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

need_root() { [ "$(id -u)" -eq 0 ] || { err "需要 root, 请 sudo 执行"; exit 1; }; }
need_root

REGISTRY_BASE="${REGISTRY_DOMAIN}:${REGISTRY_PORT}"   # 集群内置 registry 域名(registry.local:5000)
# 推送直连入口: 默认 MetalLB VIP(REGISTRY_IP:REGISTRY_PORT); nodeport 模式无 VIP 时用 ENVOY_PUSH_ENDPOINT 覆盖
PUSH_HOST="${ENVOY_PUSH_ENDPOINT:-${REGISTRY_IP}:${REGISTRY_PORT}}"
PUSH_REGISTRY_EG="${PUSH_HOST}/envoyproxy"   # 与 09 模块一致
PUSH_REGISTRY_AI="${PUSH_HOST}/ai-gateway"   # 与 10 模块一致
ENVOY_EG_VERSION="${ENVOY_EG_VERSION:-v1.9.1}"        # EG 控制面版本
# ⚠ 数据面 Envoy tag 与 EG 版本不同(EG 1.9.x 配套 Envoy 1.39.x), 勿用 EG 版本号
ENVOY_PROXY_VERSION="${ENVOY_PROXY_VERSION:-distroless-v1.39.1}"   # 数据面 Envoy 镜像 tag
ENVOY_AI_VERSION="${ENVOY_AI_VERSION:-v1.1.0}"
ENVOY_AI_IMAGE_TAG="${ENVOY_AI_IMAGE_TAG:-${ENVOY_AI_VERSION}}"
ENVOY_SAVE_DIR="${ENVOY_SAVE_DIR:-${REPO_ROOT}/deployments/offline-files/envoy}"

# skopeo 前置检查(缺失时给明确指引, 而非 3 次重试后误报"未找到镜像")
skopeo_require "envoy-load-images"

TAR_DIR="${1:-${ENVOY_SAVE_DIR}}"   # argv1 = tar 目录(缺省 ENVOY_SAVE_DIR)
# 宿主机把 registry.local 解析到集群 registry VIP(不留过期 IP; 复用 lib-common)
ensure_hosts_entry "${REGISTRY_IP}" "${REGISTRY_DOMAIN}"
wait_registry_ready "http://${REGISTRY_BASE}/v2/" \
    || { err "集群内置 registry ${REGISTRY_BASE}/v2/ 不可达(检查 hosts 与 MetalLB VIP / nodeport 入口)"; exit 1; }

say "加载 envoy 离线镜像 tar → 集群内置 registry(目录=${TAR_DIR})..."
# load_one <内容后缀> <文件名glob> <push_registry> <repo短名> <tag>
#   注意: repo 传**短名**(gateway/envoy/ai-gateway-controller), 完整仓库前缀由 push_registry
#   携带(如 PUSH_REGISTRY_EG=.../envoyproxy), 与 09/10 模块 docker://${PUSH_REGISTRY}/${short} 完全一致。
load_one() {
    local suffix="$1" glob="$2" pr="$3" repo="$4" tag="$5" t
    local display="${pr#*/}/${repo}:${tag}"   # 显示完整仓库路径(envoyproxy/gateway:v1.9.1)
    if reg_has_tag "${pr}" "${repo}" "${tag}"; then
        ok "  ${display} 已在 registry, 跳过"
        return 0
    fi
    t="$(find_offline_tar "${suffix}" "${glob}" "${TAR_DIR}" \
            "${LOCAL_REPO_DIR}/images" \
            "${OFFLINE_FILES_DIR:-${REPO_ROOT}/deployments/offline-files/kubespray}/${CLUSTER_NAME}/images")" || t=""
    if [ -z "${t}" ]; then
        err "离线安装: 未找到 ${display} 的 tar(目录 ${TAR_DIR} 无匹配)。请: ① 在联网机跑 tools/images/envoy-save-images.sh 生成 tar, 或 ② 把 tar 放到 ${ENVOY_SAVE_DIR}/ 或 ${LOCAL_REPO_DIR}/images/"
        return 1
    fi
    say "  推送 ${display} ← $(basename "${t}")"
    push_image_skopeo "docker-archive:${t}" "docker://${pr}/${repo}:${tag}" \
        || { err "推送失败(3 次重试后): ${t}"; return 1; }
    ok "  ${display} 已推送"
}
_OK=0; _FAIL=0
load_one "/gateway:${ENVOY_EG_VERSION}"  "*gateway_${ENVOY_EG_VERSION}.tar"  "${PUSH_REGISTRY_EG}" "gateway" "${ENVOY_EG_VERSION}" && _OK=$((_OK+1)) || _FAIL=$((_FAIL+1))
load_one "/envoy:${ENVOY_PROXY_VERSION}" "*envoy_${ENVOY_PROXY_VERSION}.tar" "${PUSH_REGISTRY_EG}" "envoy"   "${ENVOY_PROXY_VERSION}" && _OK=$((_OK+1)) || _FAIL=$((_FAIL+1))
load_one "/ai-gateway-controller:${ENVOY_AI_IMAGE_TAG}" "*ai-gateway-controller*.tar" "${PUSH_REGISTRY_AI}" "ai-gateway-controller" "${ENVOY_AI_IMAGE_TAG}" && _OK=$((_OK+1)) || _FAIL=$((_FAIL+1))
load_one "/ai-gateway-extproc:${ENVOY_AI_IMAGE_TAG}" "*ai-gateway-extproc*.tar" "${PUSH_REGISTRY_AI}" "ai-gateway-extproc" "${ENVOY_AI_IMAGE_TAG}" && _OK=$((_OK+1)) || _FAIL=$((_FAIL+1))
[ "${_FAIL}" -eq 0 ] || { err "加载未完全成功: 成功/已在 ${_OK}, 失败 ${_FAIL}; 见上方错误指引"; exit 1; }
ok "加载完成: ${_OK} 个镜像已就绪(推送或已在 registry)"
