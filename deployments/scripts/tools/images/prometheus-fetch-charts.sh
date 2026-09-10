#!/bin/bash
# ============================================================
# prometheus-fetch-charts.sh — kube-prometheus-stack chart 下载/刷新(联网机)
# 用途: 把 prometheus-community 官方 chart 下载解包到
#   deployments/cubestack-addon/observability/prometheus/kube-prometheus-stack/
#   (vendored 进 git), 供 08_prometheus 模块离线 helm 安装。
# 下载方式: ① helm pull(helm 可用时) ② curl 直下官方 release tgz(无 helm 兜底)
# 独立运行: 不依赖 lib-common.sh / cluster.conf。
# 用法:   sudo bash deployments/scripts/tools/images/prometheus-fetch-charts.sh
#         sudo PROMETHEUS_CHART_VERSION=90.0.0 bash .../prometheus-fetch-charts.sh   # 指定版本
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 定位仓库根(与 save 脚本同款向上查找)
REPO_ROOT=""
_d="${SCRIPT_DIR}"
while [ "${_d}" != "/" ] && [ -z "${REPO_ROOT}" ]; do
    if [ -d "${_d}/deployments/scripts" ] && [ -d "${_d}/deployments/cubestack-addon" ]; then
        REPO_ROOT="${_d}"
    fi
    _d="$(dirname "${_d}")"
done
REPO_ROOT="${REPO_ROOT:-${PWD}}"

CHART_VERSION="${PROMETHEUS_CHART_VERSION:-90.0.0}"
CHART_NAME="kube-prometheus-stack"
CHART_REPO="https://prometheus-community.github.io/helm-charts"
CHART_URL="https://github.com/prometheus-community/helm-charts/releases/download/${CHART_NAME}-${CHART_VERSION}/${CHART_NAME}-${CHART_VERSION}.tgz"
DEST_DIR="${REPO_ROOT}/deployments/cubestack-addon/observability/prometheus"

say()  { echo -e "\033[36m→  $*\033[0m"; }
ok()   { echo -e "\033[32m✅ $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m"; }
err()  { echo -e "\033[31m【错误】$*\033[0m" >&2; }

[ "$(id -u)" -eq 0 ] || { err "需要 root(写 ${DEST_DIR}); 请 sudo 执行"; exit 1; }
mkdir -p "${DEST_DIR}"
TMP_TGZ="$(mktemp -d)/${CHART_NAME}-${CHART_VERSION}.tgz"

say "下载 ${CHART_NAME} ${CHART_VERSION}(源: ${CHART_REPO})..."
if command -v helm >/dev/null 2>&1; then
    say "  方式: helm pull"
    helm pull "${CHART_NAME}" --repo "${CHART_REPO}" --version "${CHART_VERSION}" --untar=false -d "$(dirname "${TMP_TGZ}")" \
        || { warn "  helm pull 失败, 回退 curl 直下..."; TMP_TGZ=$(mktemp -d)/${CHART_NAME}-${CHART_VERSION}.tgz
             curl -sL --http1.1 -o "${TMP_TGZ}" "${CHART_URL}" || { err "curl 下载失败: ${CHART_URL}"; exit 1; } }
else
    say "  方式: curl 直下官方 release tgz(无 helm)"
    curl -sL --http1.1 -o "${TMP_TGZ}" "${CHART_URL}" || { err "curl 下载失败: ${CHART_URL}"; exit 1; }
fi

[ -s "${TMP_TGZ}" ] || { err "下载结果为空: ${CHART_URL}"; exit 1; }
say "解包 → ${DEST_DIR}/${CHART_NAME}/ ..."
TMP_X="$(mktemp -d)"
tar xzf "${TMP_TGZ}" -C "${TMP_X}" || { err "tgz 解包失败(文件可能损坏)"; exit 1; }
[ -d "${TMP_X}/${CHART_NAME}" ] || { err "tgz 内无 ${CHART_NAME}/ 目录, 结构异常"; exit 1; }
rm -rf "${DEST_DIR}/${CHART_NAME}"
mv "${TMP_X}/${CHART_NAME}" "${DEST_DIR}/"
rm -rf "${TMP_X}" "$(dirname "${TMP_TGZ}")"

ok "chart 就绪: ${DEST_DIR}/${CHART_NAME}(版本见 Chart.yaml):"
grep -E '^(version|appVersion):' "${DEST_DIR}/${CHART_NAME}/Chart.yaml" | sed 's/^/  /'
echo "  下一步(联网机备镜像): sudo bash ${SCRIPT_DIR}/prometheus-save-images.sh"
