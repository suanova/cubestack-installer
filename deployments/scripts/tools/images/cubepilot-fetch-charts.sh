#!/bin/bash
# ============================================================
# cubepilot-fetch-charts.sh — CubePilot 离线 helm chart(OCI)下载
# 用途: 在**联网机**上把 CubePilot 的 helm chart 以 tgz 形式拉到本地仓库, 供离线部署用:
#   deployments/cubestack-addon/cubepilot/cubepilot-<VERSION>.tgz
#   (文件名 = helm pull 默认的 <chart>-<version>.tgz, 与模块派生路径一致)
# 独立运行: 本脚本**不依赖 lib-common.sh / cluster.conf / 其他脚本**, 自带最小日志与路径推导,
#   在无任何部署配置的联网准备机上可直接运行; 版本/目录用环境变量覆盖, 默认与 cluster.conf 一致。
# 注意:
#   · chart 托管在**私服 Harbor 的 OCI**(oci://harbor.isuanova.com/suanova/**cubepilot-chart**;
#     ⚠ 仓库名带 -chart 后缀, 不是 cubepilot —— 曾经写错, 那个仓库根本不存在)。
#     该项目**公开只读**, 通常免凭据即可拉; 私有化后用 CUBEPILOT_HARBOR_USER/PASSWORD。
#   · **只下载 tgz, 不 --untar 解包**: 部署模块在部署时直接 helm install <tgz>,
#     仓库只保留小体积 tgz, 避免代码库体积膨胀(与 envoy/lws 的 tgz-only 约定一致)。
#   · 版本联动: main 分支 → 0.1.0-latest(镜像 tag 为 latest);
#     正式 tag vX.Y.Z → X.Y.Z(镜像 tag 同为 X.Y.Z)。本脚本只负责 chart, 镜像另用
#     cubepilot-save-images.sh(其 CUBEPILOT_IMAGE_TAG 派生规则与模块一致)。
# 用法:   ./cubepilot-fetch-charts.sh                          # 不需要 sudo
#         CUBEPILOT_VERSION=0.1.0 ./cubepilot-fetch-charts.sh  # 指定版本(正式发布 tag)
#         CUBEPILOT_HARBOR_USER=<bot> CUBEPILOT_HARBOR_PASSWORD=<pw> ./cubepilot-fetch-charts.sh
# 前置:   helm 3.8+(OCI 支持); 私服凭据(或已 helm registry login 过)
# ============================================================
set -euo pipefail

# ---- 独立运行: 自带最小日志与路径(不 source lib-common.sh / 不 load_config) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 定位仓库根: 从脚本所在目录向上找含本项目标识(deployments/scripts + cubestack-addon)的目录;
# 脚本被单独拷到别处时回退到当前工作目录(输出目录仍可用 CUBEPILOT_CHART_DIR 显式指定)。
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

command -v helm >/dev/null 2>&1 || { err "未找到 helm(需 3.8+, OCI 支持); 请在联网机安装 Helm 后重试"; exit 1; }

CUBEPILOT_HARBOR="${CUBEPILOT_HARBOR:-harbor.isuanova.com}"
CUBEPILOT_PROJECT="${CUBEPILOT_PROJECT:-suanova}"
CUBEPILOT_VERSION="${CUBEPILOT_VERSION:-0.1.0-latest}"
CUBEPILOT_CHART_DIR="${CUBEPILOT_CHART_DIR:-${REPO_ROOT}/deployments/cubestack-addon/cubepilot}"
CUBEPILOT_CHART_REF="oci://${CUBEPILOT_HARBOR}/${CUBEPILOT_PROJECT}/cubepilot-chart"
mkdir -p "${CUBEPILOT_CHART_DIR}"
say "配置: chart=${CUBEPILOT_CHART_REF} 版本=${CUBEPILOT_VERSION} 输出=${CUBEPILOT_CHART_DIR}"

# ---- 登录私服(提供凭据时; 否则复用已有登录态) ----
if [ -n "${CUBEPILOT_HARBOR_USER:-}" ] && [ -n "${CUBEPILOT_HARBOR_PASSWORD:-}" ]; then
    say "helm registry login ${CUBEPILOT_HARBOR}(用户 ${CUBEPILOT_HARBOR_USER})..."
    # --password-stdin: 不把密码放进 argv(ps 可见)
    printf '%s' "${CUBEPILOT_HARBOR_PASSWORD}" | helm registry login "${CUBEPILOT_HARBOR}" \
        -u "${CUBEPILOT_HARBOR_USER}" --password-stdin >/dev/null \
        || { err "helm registry login 失败(检查 CUBEPILOT_HARBOR_USER/PASSWORD 与网络)"; exit 1; }
    ok "  登录成功"
else
    say "未提供 CUBEPILOT_HARBOR_USER/PASSWORD, 复用本机已有 helm 登录态"
fi

# ---- 下载 chart tgz ----
# 先拉到临时目录再改名落盘: 保证**一定用刚拉下来的文件覆盖**旧的规范名文件。
# (若直接 --destination 到目标目录, 当 cubepilot-<ver>.tgz 已存在时, 新拉的
#  cubepilot-chart-<ver>.tgz 会被留在原地, 旧的反而被当成"已下载" —— 结果拿到陈旧 chart)
_TMPD="$(mktemp -d)"
trap 'rm -rf "${_TMPD}"' EXIT
say "helm pull ${CUBEPILOT_CHART_REF} --version ${CUBEPILOT_VERSION} → ${CUBEPILOT_CHART_DIR}/ ..."
if ! helm pull "${CUBEPILOT_CHART_REF}" --version "${CUBEPILOT_VERSION}" --destination "${_TMPD}"; then
    err "chart 下载失败: ${CUBEPILOT_CHART_REF} --version ${CUBEPILOT_VERSION}"
    err "  常见原因: ① 私服不可达/未登录(该项目公开只读, 通常无需凭据; 私有化后设 CUBEPILOT_HARBOR_USER/PASSWORD);"
    err "            ② chart 仓库名写错(**是 cubepilot-chart**, 不是 cubepilot);"
    err "            ③ 版本号不存在(核对发布流水线的 tag: main→0.1.0-latest, tag vX.Y.Z→X.Y.Z)"
    exit 1
fi

# helm 落盘名 = <chart>-<version>.tgz, 即 **cubepilot-chart-<version>.tgz**;
# 统一改名为模块派生路径 cubepilot-<version>.tgz(模块 CUBEPILOT_CHART_TGZ 按此派生)。
_TGZ="${CUBEPILOT_CHART_DIR}/cubepilot-${CUBEPILOT_VERSION}.tgz"
_FOUND="$(ls -1t "${_TMPD}"/*.tgz 2>/dev/null | head -1 || true)"
if [ -z "${_FOUND}" ]; then
    err "helm pull 未产出 tgz(${_TMPD}/ 为空); 检查 helm 版本(需 3.8+ 的 OCI 支持)与输出"
    exit 1
fi
mv -f "${_FOUND}" "${_TGZ}"
ok "已下载: ${_TGZ}"

echo "---------------------------------------------"
ok "CubePilot chart 下载完成"
echo "  chart tgz:  ${_TGZ}"
echo "  下一步:     下载镜像(cubepilot-save-images.sh), 把两处产物拷到部署机,"
echo "              cluster.conf 置 CUBEPILOT_MODE=offline 后 --steps cubepilot"
echo "  ⚠ 仅在\"离线机没有私服访问\"时才需要本脚本; 部署机若可访问私服,"
echo "    CUBEPILOT_MODE=online(默认) 会在部署时自动完成同样的同步(见模块 31_cubepilot.sh)"
