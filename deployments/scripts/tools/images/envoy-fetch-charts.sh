#!/bin/bash
# ============================================================
# envoy-fetch-charts.sh — Envoy Gateway + Envoy AI Gateway 离线 helm chart 下载
# 用途: 在联网机上把两个网关的官方 helm chart 下载并解包到本地, 供离线环境(部署机)使用:
#   deployments/cubestack-addon/envoy-gateway/eg/   ← Envoy Gateway(gateway-helm)
#   deployments/cubestack-addon/envoy-gateway/ai/   ← Envoy AI Gateway(CRD chart + 控制器 chart)
# 数据源: cluster.conf (ENVOY_EG_VERSION / ENVOY_AI_VERSION / ENVOY_CHART_DIR)
# 用法:   sudo ./envoy-fetch-charts.sh
#         或指定版本: ENVOY_EG_VERSION=v1.2.3 ENVOY_AI_VERSION=v0.7.0 ./envoy-fetch-charts.sh
# 前置:   需要 helm 3.0+(联网机器上)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

command -v helm >/dev/null 2>&1 || { err "未找到 helm(需 3.0+); 请在联网机安装 Helm 后重试"; exit 1; }

ENVOY_EG_VERSION="${ENVOY_EG_VERSION:-v1.9.0}"       # 对应 gateway-helm 的 chart/appVersion
ENVOY_AI_VERSION="${ENVOY_AI_VERSION:-v1.0.0}"       # 对应 ai-gateway-* helm 的版本(1.0 = GA)
ENVOY_CHART_DIR="${ENVOY_CHART_DIR:-${REPO_ROOT}/deployments/cubestack-addon/envoy-gateway}"
mkdir -p "${ENVOY_CHART_DIR}/eg" "${ENVOY_CHART_DIR}/ai"

# ① Envoy Gateway: gateway-helm(官方 helm repo; 也可 OCI oci://docker.io/envoyproxy/gateway-helm)
say "下载 Envoy Gateway gateway-helm ${ENVOY_EG_VERSION} → ${ENVOY_CHART_DIR}/eg/ ..."
helm repo add envoy-gateway https://charts.gateway.envoyproxy.io >/dev/null 2>&1 || true
helm repo update envoy-gateway >/dev/null 2>&1 || true
CHART_VER="${ENVOY_EG_VERSION#v}"
helm pull envoy-gateway/gateway-helm --version "${CHART_VER}" --untar --untardir "${ENVOY_CHART_DIR}/eg" \
    || helm pull envoy-gateway/gateway-helm --untar --untardir "${ENVOY_CHART_DIR}/eg"
# 解包结果可能在 eg/gateway-helm/ 或 eg/<chart-name>/ 下, 规整到 eg/ 顶层
if [ -d "${ENVOY_CHART_DIR}/eg/gateway-helm" ]; then
    mv -f "${ENVOY_CHART_DIR}/eg/gateway-helm/"* "${ENVOY_CHART_DIR}/eg/" 2>/dev/null || true
    rmdir "${ENVOY_CHART_DIR}/eg/gateway-helm" 2>/dev/null || true
fi
[ -f "${ENVOY_CHART_DIR}/eg/Chart.yaml" ] || { err "Envoy Gateway chart 下载/解包失败: ${ENVOY_CHART_DIR}/eg/Chart.yaml 不存在"; exit 1; }
ok "Envoy Gateway chart 就绪: ${ENVOY_CHART_DIR}/eg/Chart.yaml"

# ② Envoy AI Gateway: 官方 OCI chart(ghcr.io/envoyproxy/ai-gateway/charts/), 含 CRD 与控制器两个 chart
say "下载 Envoy AI Gateway charts ${ENVOY_AI_VERSION} → ${ENVOY_CHART_DIR}/ai/ ..."
AI_CHART_VER="${ENVOY_AI_VERSION#v}"
for _c in ai-gateway-crds-helm ai-gateway-controller-helm; do
    say "  helm pull oci://ghcr.io/envoyproxy/ai-gateway/charts/${_c} --version ${AI_CHART_VER} ..."
    helm pull "oci://ghcr.io/envoyproxy/ai-gateway/charts/${_c}" --version "${AI_CHART_VER}" \
        --untar --untardir "${ENVOY_CHART_DIR}/ai" || {
            err "  ${_c} 下载失败(检查 ENVOY_AI_VERSION=${ENVOY_AI_VERSION} 与网络; 可手工 helm pull 后解包到 ${ENVOY_CHART_DIR}/ai/${_c})";
            exit 1;
        }
done
[ -f "${ENVOY_CHART_DIR}/ai/ai-gateway-crds-helm/Chart.yaml" ] \
    && [ -f "${ENVOY_CHART_DIR}/ai/ai-gateway-controller-helm/Chart.yaml" ] \
    || { err "AI Gateway charts 下载/解包失败"; exit 1; }
ok "Envoy AI Gateway charts 就绪: ${ENVOY_CHART_DIR}/ai/(ai-gateway-crds-helm + ai-gateway-controller-helm)"

echo "---------------------------------------------"
ok "离线 chart 全部就绪(部署机无需联网):"
echo "  EG : ${ENVOY_CHART_DIR}/eg/    (gateway-helm ${ENVOY_EG_VERSION})"
echo "  AI : ${ENVOY_CHART_DIR}/ai/    (ai-gateway-crds-helm + ai-gateway-controller-helm ${ENVOY_AI_VERSION})"
echo "  下一步(部署机): sudo ./deploy-cluster.sh --enable envoy_gateway,envoy_ai_gateway"
echo "  离线镜像:        sudo ./envoy-save-images.sh(本目录 tools/images/)"
