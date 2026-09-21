#!/bin/bash
# ============================================================
# bmc-fetch-charts.sh — CubeStack BMC Exporter chart 下载/刷新(联网机)
# 用途: 把私服上的 chart 以 **tgz + digest 边车** 的形式放进仓库(随 git 分发):
#   deployments/cubestack-addon/bmc-exporter/cubestack-bmc-exporter-<VERSION>.tgz
#   deployments/cubestack-addon/bmc-exporter/cubestack-bmc-exporter-<VERSION>.tgz.digest
# 供 33_bmc_exporter 模块离线安装(模块**恒用这份本地副本**, 在线只用于比对刷新)。
#
# 独立运行: 本脚本**不依赖 lib-common.sh / cluster.conf / 其他脚本**, 自带最小日志与路径推导,
#   在无任何部署配置的联网准备机上可直接运行; 版本用环境变量覆盖, 默认与 cluster.conf 一致。
# ⚠ chart 托管在**私服 Harbor 的 OCI**:
#   oci://harbor.isuanova.com/suanova/**cubestack-bmc-exporter-chart**
#   —— 仓库名带 -chart 后缀, 但落盘文件名**不带**(模块 BMC_EXPORTER_CHART_TGZ 按去后缀派生)。
#   该项目公开只读, 通常免凭据即可拉; 私有化后用 BMC_EXPORTER_HARBOR_USER/PASSWORD。
# ⚠ OCI chart 的 Digest 是 **manifest 摘要**, 不是文件 sha256 → **不能**用 sha256sum 重算,
#   必须从 helm pull 输出里取。模块的 helm_chart_ensure 就是拿它跟 .digest 边车比对的。
# 用法:   ./bmc-fetch-charts.sh                          # 不需要 sudo
#         BMC_EXPORTER_CHART_VERSION=1.1.0 ./bmc-fetch-charts.sh
#         BMC_EXPORTER_HARBOR_USER=<bot> BMC_EXPORTER_HARBOR_PASSWORD=<pw> ./bmc-fetch-charts.sh
# 前置:   helm 3.8+(OCI 支持); 私服凭据(或已 helm registry login 过)
# ============================================================
set -euo pipefail

# ---- 独立运行: 自带最小日志与路径(不 source lib-common.sh / 不 load_config) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 定位仓库根: 从脚本所在目录向上找含本项目标识(deployments/scripts + cubestack-addon)的目录;
# 脚本被单独拷到别处时回退到当前工作目录(输出目录仍可用 BMC_EXPORTER_CHART_DIR 显式指定)。
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

command -v helm >/dev/null 2>&1 || { err "未找到 helm(需 3.8+, OCI 支持); 请在联网机安装 Helm 后重试"; exit 1; }

BMC_EXPORTER_HARBOR="${BMC_EXPORTER_HARBOR:-harbor.isuanova.com}"
BMC_EXPORTER_PROJECT="${BMC_EXPORTER_PROJECT:-suanova}"
BMC_EXPORTER_CHART_VERSION="${BMC_EXPORTER_CHART_VERSION:-1.0.0}"
BMC_EXPORTER_CHART_DIR="${BMC_EXPORTER_CHART_DIR:-${REPO_ROOT}/deployments/cubestack-addon/bmc-exporter}"
# ⚠ chart 仓库名带 -chart 后缀(cubestack-bmc-exporter-chart), 不是 cubestack-bmc-exporter
BMC_EXPORTER_CHART_REF="oci://${BMC_EXPORTER_HARBOR}/${BMC_EXPORTER_PROJECT}/cubestack-bmc-exporter-chart"

mkdir -p "${BMC_EXPORTER_CHART_DIR}"
say "配置: chart=${BMC_EXPORTER_CHART_REF} 版本=${BMC_EXPORTER_CHART_VERSION} 输出=${BMC_EXPORTER_CHART_DIR}"

# ---- 登录私服(提供凭据时; 否则复用已有登录态/匿名) ----
if [ -n "${BMC_EXPORTER_HARBOR_USER:-}" ] && [ -n "${BMC_EXPORTER_HARBOR_PASSWORD:-}" ]; then
    say "helm registry login ${BMC_EXPORTER_HARBOR}(用户 ${BMC_EXPORTER_HARBOR_USER})..."
    # --password-stdin: 不把密码放进 argv(ps 可见)
    printf '%s' "${BMC_EXPORTER_HARBOR_PASSWORD}" | helm registry login "${BMC_EXPORTER_HARBOR}" \
        -u "${BMC_EXPORTER_HARBOR_USER}" --password-stdin >/dev/null \
        || { err "helm registry login 失败(检查 BMC_EXPORTER_HARBOR_USER/PASSWORD 与网络)"; exit 1; }
    ok "  登录成功"
else
    say "未提供凭据, 复用本机已有 helm 登录态(该 Harbor 公开只读, 通常匿名即可)"
fi

# ---- 下载 chart tgz ----
# 先拉到临时目录再改名落盘: 保证**一定用刚拉下来的文件覆盖**旧的规范名文件。
_TMPD="$(mktemp -d)"
trap 'rm -rf "${_TMPD}"' EXIT
say "helm pull ${BMC_EXPORTER_CHART_REF} --version ${BMC_EXPORTER_CHART_VERSION} → ${BMC_EXPORTER_CHART_DIR}/ ..."
# helm 的 "Digest:" 行要留下来写边车; 各版本把它写 stdout 还是 stderr 不一致 → 合并捕获再回显
if ! helm pull "${BMC_EXPORTER_CHART_REF}" --version "${BMC_EXPORTER_CHART_VERSION}" \
        --destination "${_TMPD}" 2>&1 | tee "${_TMPD}/pull.log"; then
    err "chart 下载失败: ${BMC_EXPORTER_CHART_REF} --version ${BMC_EXPORTER_CHART_VERSION}"
    err "  常见原因: ① 私服不可达/未登录(该项目公开只读, 通常无需凭据);"
    err "            ② chart 仓库名写错(**是 cubestack-bmc-exporter-chart**, 带 -chart 后缀);"
    err "            ③ 版本号不存在(核对发布流水线的 tag)"
    exit 1
fi
_DIGEST="$(sed -n 's/^Digest:[[:space:]]*//p' "${_TMPD}/pull.log" | head -1 || true)"

# helm 落盘名 = <chart>-<version>.tgz = cubestack-bmc-exporter-chart-<ver>.tgz;
# 统一改名为模块派生路径 cubestack-bmc-exporter-<ver>.tgz(**去掉 -chart**)
_TGZ="${BMC_EXPORTER_CHART_DIR}/cubestack-bmc-exporter-${BMC_EXPORTER_CHART_VERSION}.tgz"
_FOUND="$(ls -1t "${_TMPD}"/*.tgz 2>/dev/null | head -1 || true)"
if [ -z "${_FOUND}" ]; then
    err "helm pull 未产出 tgz(${_TMPD}/ 为空); 检查 helm 版本(需 3.8+ 的 OCI 支持)与输出"
    exit 1
fi
mv -f "${_FOUND}" "${_TGZ}"
ok "已下载: ${_TGZ}"
# 边车一并写出 —— 缺了它 helm_chart_ensure 只能判定"无法比对, 按已变更处理",
# 每次在线部署都会白白覆盖一遍这份副本。
if [ -n "${_DIGEST}" ]; then
    printf '%s' "${_DIGEST}" > "${_TGZ}.digest"
    chmod 644 "${_TGZ}" "${_TGZ}.digest" 2>/dev/null || true
    ok "   digest 边车: ${_TGZ}.digest(${_DIGEST})"
else
    warn "helm 未报告 Digest, **边车未写出** —— 请手工把 helm pull 的 Digest: 值写进 ${_TGZ}.digest"
fi

echo "---------------------------------------------"
ok "BMC Exporter chart 下载完成"
echo "  chart tgz:   ${_TGZ}"
echo "  digest 边车: ${_TGZ}.digest"
echo "  下一步:      ① 下载镜像: ./deployments/scripts/tools/images/bmc-save-images.sh"
echo "               ② **把 chart 与 .digest 提交进 git** —— 模块安装时恒用仓库内这份离线副本,"
echo "                  只在部署时落到盘上不算数(私服抖动时回退会空转)"
echo "  提示:        部署机若可访问私服, BMC_EXPORTER_MODE=online(默认) 会拿私服 digest 与边车比对,"
echo "               有更新才覆盖这份副本; 本脚本是**在没有部署机可访问私服时**的替代刷新路径"
