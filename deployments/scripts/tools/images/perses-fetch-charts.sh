#!/bin/bash
# ============================================================
# perses-fetch-charts.sh — Perses chart 下载/刷新(联网机)
# 用途: 把官方 chart 以 **tgz + digest 边车** 的形式放进仓库(随 git 分发):
#   deployments/cubestack-addon/perses/perses-<VERSION>.tgz
#   deployments/cubestack-addon/perses/perses-<VERSION>.tgz.digest
# 供 18_perses 模块离线安装(模块**恒用这份本地副本**, 在线只用于比对刷新 —— 见 helm_chart_ensure)。
#
# 独立运行: 本脚本**不依赖 lib-common.sh / cluster.conf / 其他脚本**, 自带最小日志与路径推导,
#   在无任何部署配置的联网准备机上可直接运行; 版本用环境变量覆盖, 默认与 cluster.conf 一致。
# 下载方式: ① helm pull(helm 可用时, 顺带取它报告的 Digest) ② curl 直下官方 release tgz(兜底,
#   digest 用 sha256sum —— 对经典 helm repo 而言两者等价, 已实测核对)。
# ⚠ 本 chart 走**经典 helm repo**(perses.github.io/helm-charts), 不是 OCI:
#   其 digest 就是 tgz 文件的 sha256。模块按此比对, 故**必须**把边车一起写出来。
# 用法:   ./perses-fetch-charts.sh                          # 不需要 sudo
#         PERSES_CHART_VERSION=0.22.0 ./perses-fetch-charts.sh
# 前置:   helm(可选, 推荐)或 curl; 能访问 perses.github.io / GitHub Releases
# ============================================================
set -euo pipefail

# ---- 独立运行: 自带最小日志与路径(不 source lib-common.sh / 不 load_config) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 定位仓库根: 从脚本所在目录向上找含本项目标识(deployments/scripts + cubestack-addon)的目录;
# 脚本被单独拷到别处时回退到当前工作目录(输出目录仍可用 PERSES_CHART_DIR 显式指定)。
REPO_ROOT=""
_d="${SCRIPT_DIR}"
while [ "${_d}" != "/" ] && [ -z "${REPO_ROOT}" ]; do
    if [ -d "${_d}/deployments/scripts" ] && [ -d "${_d}/deployments/cubestack-addon" ]; then
        REPO_ROOT="${_d}"
    fi
    _d="$(dirname "${_d}")"
done
REPO_ROOT="${REPO_ROOT:-${PWD}}"

say()  { echo -e "\033[36m→  $*\033[0m"; }
ok()   { echo -e "\033[32m✅ $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m"; }
err()  { echo -e "\033[31m【错误】$*\033[0m" >&2; }

CHART_NAME="${PERSES_CHART_REF:-perses}"
CHART_VERSION="${PERSES_CHART_VERSION:-0.23.2}"
CHART_REPO="${PERSES_CHART_REPO:-https://perses.github.io/helm-charts}"
# 官方 release tgz 的固定 URL 规律(与 index.yaml 里的 urls 字段一致)
CHART_URL="https://github.com/perses/helm-charts/releases/download/${CHART_NAME}-${CHART_VERSION}/${CHART_NAME}-${CHART_VERSION}.tgz"
CHART_DIR="${PERSES_CHART_DIR:-${REPO_ROOT}/deployments/cubestack-addon/perses}"
TGZ="${CHART_DIR}/${CHART_NAME}-${CHART_VERSION}.tgz"

mkdir -p "${CHART_DIR}"
say "配置: chart=${CHART_NAME} 版本=${CHART_VERSION} 仓库=${CHART_REPO}"
say "输出: ${TGZ}"

_TMPD="$(mktemp -d)"
trap 'rm -rf "${_TMPD}"' EXIT
_DIGEST=""

if command -v helm >/dev/null 2>&1; then
    say "方式: helm pull"
    # helm 落盘名 = <chart>-<version>.tgz, 与目标名一致
    if helm pull "${CHART_NAME}" --repo "${CHART_REPO}" --version "${CHART_VERSION}" \
            --destination "${_TMPD}" 2>&1 | tee "${_TMPD}/pull.log"; then
        # helm 各版本把 "Digest:" 写 stdout 还是 stderr 不一致 → 上面已合并捕获
        _DIGEST="$(sed -n 's/^Digest:[[:space:]]*//p' "${_TMPD}/pull.log" | head -1 || true)"
    fi
fi

if [ ! -f "${_TMPD}/${CHART_NAME}-${CHART_VERSION}.tgz" ]; then
    warn "helm 不可用或拉取失败, 回退 curl 直下官方 release tgz ..."
    if ! curl -sL --http1.1 --max-time 120 -o "${_TMPD}/${CHART_NAME}-${CHART_VERSION}.tgz" "${CHART_URL}"; then
        err "下载失败: ${CHART_URL}"
        err "  常见原因: ① 版本号不存在(核对 https://perses.github.io/helm-charts/index.yaml)"
        err "            ② 网络不可达(GitHub Releases)"
        exit 1
    fi
fi

[ -s "${_TMPD}/${CHART_NAME}-${CHART_VERSION}.tgz" ] || { err "下载结果为空: ${CHART_URL}"; exit 1; }
# 校验是真的 chart 包(而不是被重定向到的 HTML 错误页)
tar tzf "${_TMPD}/${CHART_NAME}-${CHART_VERSION}.tgz" >/dev/null 2>&1 \
    || { err "下载到的不是有效 tgz(可能被重定向到错误页): ${CHART_URL}"; exit 1; }
# digest 兜底: helm 没给就用文件 sha256(经典 helm repo 两者等价, 已实测核对)
if [ -z "${_DIGEST}" ]; then
    _DIGEST="sha256:$(sha256sum "${_TMPD}/${CHART_NAME}-${CHART_VERSION}.tgz" | awk '{print $1}')"
    say "  helm 未报告 digest, 用文件 sha256 作边车值"
fi

mv -f "${_TMPD}/${CHART_NAME}-${CHART_VERSION}.tgz" "${TGZ}"
printf '%s' "${_DIGEST}" > "${TGZ}.digest"
chmod 644 "${TGZ}" "${TGZ}.digest" 2>/dev/null || true
ok "已落盘: ${TGZ}"
ok "   digest: ${_DIGEST}"

echo "---------------------------------------------"
ok "Perses chart 下载完成"
echo "  chart tgz:  ${TGZ}"
echo "  下一步:     ① 镜像另用统一工具备料: tools/images/harbor-save-images.sh --group perses"
echo "              ② 提交 chart 与 .digest 到 git(离线副本**必须随仓库分发**)"
echo "              ③ 部署机 cluster.conf 置 PERSES_MODE=offline 后 --steps perses"
echo "  ⚠ 部署机若可访问私服, PERSES_MODE=online(默认) 会在部署时自动比对并刷新这份副本;"
echo "    但**无论哪种模式, 安装用的都是这份本地副本** —— 缺了它模块会直接报错。"
