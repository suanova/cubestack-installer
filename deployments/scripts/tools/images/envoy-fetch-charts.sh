#!/bin/bash
# ============================================================
# envoy-fetch-charts.sh — Envoy Gateway + Envoy AI Gateway 离线 helm chart 下载
# 用途: 在联网机上把两个网关的官方 helm chart **以 tgz 形式**下载到本地仓库,
#   部署模块在部署时临时解压(仓库只存小体积 tgz, 不膨胀):
#   deployments/cubestack-addon/envoy-gateway/eg/gateway-helm-<V>.tgz          ← Envoy Gateway(gateway-helm)
#   deployments/cubestack-addon/envoy-gateway/ai/ai-gateway-crds-helm-<V>.tgz  ← AI CRD chart
#   deployments/cubestack-addon/envoy-gateway/ai/ai-gateway-helm-<V>.tgz       ← AI 控制器 chart
# 独立运行: 本脚本**不依赖 lib-common.sh / cluster.conf / 其他脚本**, 自带最小日志与路径推导,
#   在无任何部署配置的联网准备机上可直接运行; 版本/目录用环境变量覆盖, 默认与 cluster.conf 一致。
# 注意:
#   · 官方 gateway-helm chart 托管在 **DockerHub OCI**(oci://docker.io/envoyproxy/gateway-helm),
#     旧 helm repo(charts.gateway.envoyproxy.io)仅作兜底; 版本带 v / 不带 v 都会自动尝试。
#   · AI chart 同样是 docker.io OCI, 名字是 ai-gateway-crds-helm / ai-gateway-helm
#     (不是 ghcr, 也不是 ai-gateway-controller-helm)。
#   · **只下载 tgz, 不 --untar 解包**: 部署模块(09/10)在部署时把 tgz 解到临时目录再 helm 安装,
#     仓库只保留小体积 tgz, 避免代码库体积膨胀。tgz 文件名统一为 <chart>-<ENVOY_*_VERSION>.tgz
#     (版本带 v, 与 cluster.conf 的 ENVOY_EG_VERSION / ENVOY_AI_VERSION 一致)。
#   · 幂等: 重复运行会覆盖同版本 tgz; 若存在旧版脚本留下的解包目录(eg/gateway-helm 等)会自动清掉。
# 用法:   ./envoy-fetch-charts.sh                       # 不需要 sudo(无 root 依赖)
#         或指定版本: ENVOY_EG_VERSION=v1.9.1 ENVOY_AI_VERSION=v1.1.0 ./envoy-fetch-charts.sh
#         或指定输出目录: ENVOY_CHART_DIR=/opt/cubestack-installer/deployments/cubestack-addon/envoy-gateway ./envoy-fetch-charts.sh
# 前置:   需要 helm 3.0+(联网机器上)
# ============================================================
set -euo pipefail

# ---- 独立运行: 自带最小日志与路径(不 source lib-common.sh / 不 load_config) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 定位仓库根: 从脚本所在目录向上找含本项目标识(deployments/scripts + cubestack-addon)的目录;
# 脚本被单独拷到别处时回退到当前工作目录(输出目录仍可用 ENVOY_CHART_DIR 显式指定)。
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

command -v helm >/dev/null 2>&1 || { err "未找到 helm(需 3.0+); 请在联网机安装 Helm 后重试"; exit 1; }

ENVOY_EG_VERSION="${ENVOY_EG_VERSION:-v1.9.1}"       # 对应 gateway-helm 的 chart/appVersion(带 v)
ENVOY_AI_VERSION="${ENVOY_AI_VERSION:-v1.1.0}"       # 对应 ai-gateway-crds-helm / ai-gateway-helm 的 chart 版本(带 v)
ENVOY_CHART_DIR="${ENVOY_CHART_DIR:-${REPO_ROOT}/deployments/cubestack-addon/envoy-gateway}"
mkdir -p "${ENVOY_CHART_DIR}/eg" "${ENVOY_CHART_DIR}/ai"
say "配置: EG=${ENVOY_EG_VERSION} AI=${ENVOY_AI_VERSION} 输出=${ENVOY_CHART_DIR}"

# 清理旧版脚本可能留下的解包目录(仓库只保留 tgz; 避免体积膨胀 + 与 tgz 源混淆)
rm -rf "${ENVOY_CHART_DIR}/eg/gateway-helm"
rm -rf "${ENVOY_CHART_DIR}/ai/ai-gateway-crds-helm" "${ENVOY_CHART_DIR}/ai/ai-gateway-helm"

# ① Envoy Gateway: gateway-helm(官方托管在 DockerHub OCI; 旧 helm repo 仅兜底; 带 v/不带 v 都试)
say "下载 Envoy Gateway gateway-helm ${ENVOY_EG_VERSION} tgz → ${ENVOY_CHART_DIR}/eg/ ..."
CHART_VER="${ENVOY_EG_VERSION#v}"
_TMP="$(mktemp -d)"
_ok=0
for _try in \
    "oci://docker.io/envoyproxy/gateway-helm|${ENVOY_EG_VERSION}" \
    "oci://docker.io/envoyproxy/gateway-helm|${CHART_VER}" \
    "envoy-gateway/gateway-helm|${CHART_VER}"; do
    _src="${_try%%|*}"; _ver="${_try##*|}"
    if [ "${_src}" = "envoy-gateway/gateway-helm" ]; then
        helm repo add envoy-gateway https://charts.gateway.envoyproxy.io >/dev/null 2>&1 || true
        helm repo update envoy-gateway >/dev/null 2>&1 || true
    fi
    say "  helm pull ${_src} --version ${_ver} ..."
    rm -f "${_TMP}"/*.tgz 2>/dev/null || true
    ( cd "${_TMP}" && helm pull "${_src}" --version "${_ver}" )
    if [ -n "$(ls "${_TMP}"/*.tgz 2>/dev/null | head -1)" ]; then _ok=1; break; fi
done
if [ "${_ok}" != "1" ]; then
    rm -rf "${_TMP}"
    err "gateway-helm ${ENVOY_EG_VERSION} 下载失败(需可达 docker.io 或 charts.gateway.envoyproxy.io); 官方命令: helm pull oci://docker.io/envoyproxy/gateway-helm --version v1.9.1"
    exit 1
fi
# 规整为规范文件名 <chart>-<ENVOY_EG_VERSION>.tgz(带 v, 与 cluster.conf / 模块默认一致)
mv -f "${_TMP}"/*.tgz "${ENVOY_CHART_DIR}/eg/gateway-helm-${ENVOY_EG_VERSION}.tgz"
rm -rf "${_TMP}"
[ -f "${ENVOY_CHART_DIR}/eg/gateway-helm-${ENVOY_EG_VERSION}.tgz" ] \
    || { err "Envoy Gateway chart 保存失败: ${ENVOY_CHART_DIR}/eg/gateway-helm-${ENVOY_EG_VERSION}.tgz"; exit 1; }
ok "Envoy Gateway chart tgz 就绪: ${ENVOY_CHART_DIR}/eg/gateway-helm-${ENVOY_EG_VERSION}.tgz"

# ② Envoy AI Gateway: 官方 OCI chart(docker.io, 与 EG 同一 registry; 版本带 v, 如 --version v1.1.0)
#   官方安装: helm upgrade -i aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm --version v1.1.0
#             helm upgrade -i aieg    oci://docker.io/envoyproxy/ai-gateway-helm    --version v1.1.0
#   (注: 这两个 chart **不是** ghcr OCI, 也不叫 ai-gateway-controller-helm; ghcr 对应路径会 403)
say "下载 Envoy AI Gateway charts ${ENVOY_AI_VERSION} tgz → ${ENVOY_CHART_DIR}/ai/ ..."
_TMP="$(mktemp -d)"
for _c in ai-gateway-crds-helm ai-gateway-helm; do
    _ok=0
    for _ver in "${ENVOY_AI_VERSION}" "${ENVOY_AI_VERSION#v}"; do
        say "  helm pull oci://docker.io/envoyproxy/${_c} --version ${_ver} ..."
        rm -f "${_TMP}"/*.tgz 2>/dev/null || true
        ( cd "${_TMP}" && helm pull "oci://docker.io/envoyproxy/${_c}" --version "${_ver}" )
        if [ -n "$(ls "${_TMP}"/*.tgz 2>/dev/null | head -1)" ]; then _ok=1; break; fi
    done
    if [ "${_ok}" != "1" ]; then
        rm -rf "${_TMP}"
        err "  ${_c} 下载失败(检查 ENVOY_AI_VERSION=${ENVOY_AI_VERSION} 与网络可达 docker.io; 官方命令: helm pull oci://docker.io/envoyproxy/${_c} --version v1.1.0; 备选: 从 github.com/envoyproxy/ai-gateway/releases 下载 ${_c}-v<版本>.tgz 后改名放到 ai/ 目录)"
        exit 1
    fi
    mv -f "${_TMP}"/*.tgz "${ENVOY_CHART_DIR}/ai/${_c}-${ENVOY_AI_VERSION}.tgz"
done
rm -rf "${_TMP}"
[ -f "${ENVOY_CHART_DIR}/ai/ai-gateway-crds-helm-${ENVOY_AI_VERSION}.tgz" ] \
    && [ -f "${ENVOY_CHART_DIR}/ai/ai-gateway-helm-${ENVOY_AI_VERSION}.tgz" ] \
    || { err "AI Gateway charts 保存失败(ai/ 下应有两个 tgz)"; exit 1; }
ok "Envoy AI Gateway charts tgz 就绪: ${ENVOY_CHART_DIR}/ai/(ai-gateway-crds-helm + ai-gateway-helm ${ENVOY_AI_VERSION})"

echo "---------------------------------------------"
ok "离线 chart tgz 全部就绪(部署机无需联网; 部署时临时解压):"
echo "  EG : ${ENVOY_CHART_DIR}/eg/gateway-helm-${ENVOY_EG_VERSION}.tgz"
echo "  AI : ${ENVOY_CHART_DIR}/ai/ai-gateway-crds-helm-${ENVOY_AI_VERSION}.tgz"
echo "       ${ENVOY_CHART_DIR}/ai/ai-gateway-helm-${ENVOY_AI_VERSION}.tgz"
echo "  下一步(部署机): sudo ./deploy-cluster.sh --enable envoy_gateway,envoy_ai_gateway"
echo "  离线镜像:        sudo ENVOY_EG_VERSION=${ENVOY_EG_VERSION} ./envoy-save-images.sh(本目录 tools/images/)"
