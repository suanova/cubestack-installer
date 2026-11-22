#!/bin/bash
# ============================================================
# TOOL: install-os-packages (manual, NOT a deploy-cluster module)
# DESC: 手动下载/安装 offline-files/os/packages/ubuntu-<版本> 下的节点 OS deb。
#       默认排除 helm / nodejs 相关包（这些包由自动部署/其他模块负责）。
#
# 为什么是手动脚本:
#   · 不接入 deploy-cluster.sh，不会被模块发现或自动调度；
#   · 适合在部署前由运维按需执行，或用于离线包排障/补装。
#
# 目录布局（MinIO 与本地同构）:
#   MinIO: <alias>/<prefix>/ubuntu-<版本>/{*.deb,chrony/*.deb}
#   本地 : ${OFFLINE_FILES_ROOT}/os/packages/ubuntu-<版本>/{*.deb,chrony/*.deb}
#   旧布局兼容: ${OFFLINE_FILES_ROOT}/os/packages/{*.deb,chrony/*.deb}
#
# 用法:
#   ./install-os-packages.sh                 # 默认 = --install（本地缺包时提示下载）
#   ./install-os-packages.sh --layout [--os-version 24.04]
#   ./install-os-packages.sh --download [--os-version 24.04] [--mc-alias minio] [--mc-prefix ...]
#   ./install-os-packages.sh --install  [--os-version 24.04] [--ip 10.66.3.162] [--dry-run]
#   ./install-os-packages.sh --download --install ...
#
#   --exclude "helm* nodejs* libnode* node-*"   安装时排除的 deb basename glob（默认）
#   --skip-chrony                              不安装 chrony/ 专用集
#
# 数据源: 本地 offline-files/os/packages + MinIO（mc）；NODES/SSH 来自 cluster.conf。
# ============================================================
set -euo pipefail

MANUAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${MANUAL_DIR}/../../../.." && pwd)"
# shellcheck source=../lib-common.sh
source "${REPO_ROOT}/deployments/scripts/lib-common.sh"
load_config

MC_ALIAS="${MC_ALIAS:-minio}"
# 默认从 release-store/vendor/os 读取（发布存储的 vendor 区）；可用 --mc-prefix 覆盖。
MC_PREFIX="${MC_PREFIX:-cubestack-installer/release-store/vendor/os/packages}"
OFFLINE_ROOT="${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}"
OS_VER="${OS_PACKAGES_VERSION:-}"
EXCLUDE_PATTERNS="${NODE_PKGS_EXCLUDE_PATTERNS:-helm* nodejs* libnode* node-*}"
WITH_CHRONY=1
DRY_RUN=0
DO_DOWNLOAD=0
DO_INSTALL=0
DO_LAYOUT=0
ACTION_SET=0
IPS=()

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; }

# 默认 OS 版本（未显式指定时取 versions/base.yaml 的 os.version）
_base_os_version() {
    python3 - "${REPO_ROOT}/versions/base.yaml" <<'PY' 2>/dev/null || true
import sys
try:
    import yaml
    d = yaml.safe_load(open(sys.argv[1]))
    os_entries = d.get("os") or []
    if os_entries:
        print(os_entries[0].get("version", ""))
except Exception:
    pass
PY
}

while [ $# -gt 0 ]; do
    case "$1" in
        --layout|--print-layout) DO_LAYOUT=1; DO_DOWNLOAD=0; DO_INSTALL=0; ACTION_SET=1; shift ;;
        --download) DO_DOWNLOAD=1; ACTION_SET=1; shift ;;
        --install)  DO_INSTALL=1; ACTION_SET=1; shift ;;
        --os-version) OS_VER="${2:?--os-version 需要值}"; shift 2 ;;
        --offline-root) OFFLINE_ROOT="${2:?--offline-root 需要值}"; shift 2 ;;
        --mc-alias) MC_ALIAS="${2:?--mc-alias 需要值}"; shift 2 ;;
        --mc-prefix) MC_PREFIX="${2:?--mc-prefix 需要值}"; shift 2 ;;
        --exclude) EXCLUDE_PATTERNS="${2:?--exclude 需要值}"; shift 2 ;;
        --skip-chrony) WITH_CHRONY=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --ip) IPS+=("${2:?--ip 需要地址}"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) err "未知参数: $1（--help 查看用法）"; exit 1 ;;
    esac
done

# 默认动作 = 安装（--layout/--download 显式指定时不安装）
if [ "${ACTION_SET}" = "0" ]; then
    DO_INSTALL=1
fi

[ -n "${OS_VER}" ] || OS_VER="$(_base_os_version)"
[ -n "${OS_VER}" ] || { err "无法确定 OS 版本；请用 --os-version 22.04|24.04 指定"; exit 1; }

PKG_DIR="${OFFLINE_ROOT}/os/packages/ubuntu-${OS_VER}"
CHRONY_DIR="${PKG_DIR}/chrony"
MC_SRC="${MC_ALIAS}/${MC_PREFIX}/ubuntu-${OS_VER}"
# helm/nodejs 单独目录: 位于 os/ 下，由自动流程使用；本手动脚本不安装。
HELM_NODEJS_DIR="${OFFLINE_ROOT}/os/helm-nodejs"
HELM_NODEJS_MC="${MC_ALIAS}/$(dirname "${MC_PREFIX}")/helm-nodejs"

print_layout() {
    say "==== 手动 OS 包布局（不接入 deploy-cluster.sh） ===="
    echo "  MinIO 源:  ${MC_SRC}/"
    echo "  本地目标:  ${PKG_DIR}/"
    echo "             ├── *.deb        # 节点通用包（本脚本安装）"
    echo "             └── chrony/*.deb # chrony 专用安装集（含 timesyncd 回滚包）"
    echo "  自动流程目录 (本脚本不安装): ${HELM_NODEJS_DIR}/"
    echo "             ├── helm_*.deb                 # helm（静态、版本通用）"
    echo "             └── ubuntu-<版本>/nodejs_*.deb # 目标 OS 适配的 nodejs（自动流程安装）"
    echo "             （alternate-* 为备用包, 不自动安装）"
    echo "  旧布局兼容: ${OFFLINE_ROOT}/os/packages/{*.deb,chrony/*.deb}"
    echo
    echo "  下载（mc，含 helm/nodejs 自动流程目录）:"
    echo "    mc cp --recursive '${MC_SRC}/' '${PKG_DIR}/'"
    echo "    mc cp --recursive '${HELM_NODEJS_MC}/' '${HELM_NODEJS_DIR}/'"
    echo "  上传（如果 MinIO 尚无该版本目录）:"
    echo "    mc cp --recursive '${PKG_DIR}/' '${MC_ALIAS}/${MC_PREFIX}/ubuntu-${OS_VER}/'"
    echo "    mc cp --recursive '${HELM_NODEJS_DIR}/' '${HELM_NODEJS_MC}/'"
    echo "  手动安装（默认动作）:"
    echo "    $0 --os-version ${OS_VER} [--ip <节点IP> ...]"
    echo "    # 等价于 $0 --install --os-version ${OS_VER} ..."
    echo
    echo "  安装排除模式: ${EXCLUDE_PATTERNS}"
    echo "  （helm/nodejs 相关包保留给自动流程；如需全部安装请显式 --exclude ''）"
    echo "  提示: 手动模式请在 cluster.conf 关闭 NODE_PKGS_ENABLED / CHRONY_PKGS_ENABLED，"
    echo "        否则 deploy-cluster.sh 仍会自动装包。"
}

download_pkgs() {
    command -v mc >/dev/null 2>&1 || { err "未找到 mc；请先安装 MinIO Client，或手工按布局拷贝"; return 1; }
    if ! mc ls "${MC_SRC}/" >/dev/null 2>&1; then
        err "MinIO 未找到 ${MC_SRC}/"
        err "请先把本地 ${PKG_DIR}/ 上传到 MinIO："
        err "  mc cp --recursive '${PKG_DIR}/' '${MC_ALIAS}/${MC_PREFIX}/ubuntu-${OS_VER}/'"
        print_layout
        return 1
    fi
    say "从 MinIO 下载 ${MC_SRC}/ → ${PKG_DIR}/ ..."
    mkdir -p "${PKG_DIR}"
    mc cp --recursive "${MC_SRC}/" "${PKG_DIR}/" >/dev/null
    ok "已下载: $(find "${PKG_DIR}" -maxdepth 1 -name '*.deb' | wc -l) 个顶层 deb, $(find "${CHRONY_DIR}" -maxdepth 1 -name '*.deb' 2>/dev/null | wc -l) 个 chrony deb"
    # helm/nodejs 自动流程目录: 下载但不安装
    if mc ls "${HELM_NODEJS_MC}/" >/dev/null 2>&1; then
        mkdir -p "${HELM_NODEJS_DIR}"
        mc cp --recursive "${HELM_NODEJS_MC}/" "${HELM_NODEJS_DIR}/" >/dev/null
        say "已下载 helm/nodejs 自动流程目录: ${HELM_NODEJS_DIR}"
    else
        warn "MinIO 未找到 ${HELM_NODEJS_MC}/，跳过 helm/nodejs 目录"
    fi
}

# 检查本地是否具备可安装的 OS 包；缺失时打印包名/MinIO 路径/下载命令并返回 1。
check_local_pkgs() {
    local _f _base _pat _skip _miss=0 _have_top=0 _have_chrony=0
    if [ -d "${PKG_DIR}" ]; then
        for _f in "${PKG_DIR}"/*.deb; do
            [ -f "${_f}" ] || continue
            _base="$(basename "${_f}")"
            _skip=0
            for _pat in ${EXCLUDE_PATTERNS//,/ }; do
                case "${_base}" in ${_pat}) _skip=1; break ;; esac
            done
            if [ "${_skip}" = "0" ]; then _have_top=1; break; fi
        done
    fi
    [ "${_have_top}" = "1" ] || { _miss=1; err "本地缺少可安装的顶层 OS deb: ${PKG_DIR}/*.deb"; }
    if [ "${WITH_CHRONY}" = "1" ]; then
        if [ -d "${CHRONY_DIR}" ]; then
            for _f in "${CHRONY_DIR}"/*.deb; do
                [ -f "${_f}" ] && { _have_chrony=1; break; }
            done
        fi
        [ "${_have_chrony}" = "1" ] || { _miss=1; err "本地缺少 chrony 专用安装集: ${CHRONY_DIR}/*.deb"; }
    fi
    if [ "${_miss}" = "1" ]; then
        echo
        say "请从 MinIO 下载对应离线包："
        echo "  离线包名称: ubuntu-${OS_VER}（系统包） + chrony（专用安装集）"
        echo "  MinIO 路径: ${MC_ALIAS}:${MC_PREFIX}/ubuntu-${OS_VER}/"
        echo "  helm/nodejs: ${HELM_NODEJS_MC}/（自动流程用，本脚本不安装）"
        echo "  下载命令:"
        echo "    mc cp --recursive '${MC_SRC}/' '${PKG_DIR}/'"
        echo "    mc cp --recursive '${HELM_NODEJS_MC}/' '${HELM_NODEJS_DIR}/'"
        echo "  或直接执行:"
        echo "    $0 --download --os-version ${OS_VER}"
        return 1
    fi
    return 0
}

install_pkgs() {
    check_local_pkgs || return 1
    local -a ip_args=()
    local _ip
    for _ip in "${IPS[@]}"; do ip_args+=(--ip "${_ip}"); done
    say "手动安装 OS 包: 版本=${OS_VER}, 目录=${PKG_DIR}"
    say "  排除模式: ${EXCLUDE_PATTERNS}（helm/nodejs 相关包不安装）"
    say "  helm/nodejs 自动流程目录: ${HELM_NODEJS_DIR}（本脚本不安装）"

    # 1) chrony 专用集优先：安装 chrony 后再对账顶层，避免先装 systemd-timesyncd 再被 chrony 预卸。
    if [ "${WITH_CHRONY}" = "1" ]; then
        if [ "${DRY_RUN}" = "1" ]; then
            say "  --dry-run: 跳过 chrony 实际安装"
        elif [ -d "${CHRONY_DIR}" ]; then
            OS_PACKAGES_VERSION="${OS_VER}" bash "${MANUAL_DIR}/../node/install-chrony-packages.sh" "${ip_args[@]}"
        else
            warn "  未找到 ${CHRONY_DIR}，跳过 chrony 安装"
        fi
    else
        say "  --skip-chrony: 跳过 chrony/chrony 专用集"
    fi

    # 2) 顶层包对账安装（NODE_PKGS_EXCLUDE_PATTERNS 让 reconcile 跳过 helm/nodejs）。
    local -a rec_args=()
    if [ "${DRY_RUN}" = "1" ]; then rec_args+=(--dry-run); fi
    if [ "${#ip_args[@]}" -gt 0 ]; then rec_args+=("${ip_args[@]}"); fi
    NODE_PKGS_EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS}" OS_PACKAGES_VERSION="${OS_VER}" \
        bash "${MANUAL_DIR}/../node/reconcile-node-packages.sh" "${rec_args[@]}"

    ok "手动 OS 包安装完成（helm/nodejs 相关包未安装）"
}

if [ "${DO_LAYOUT}" = "1" ]; then
    print_layout
    exit 0
fi

if [ "${DO_DOWNLOAD}" = "1" ]; then download_pkgs; fi
if [ "${DO_INSTALL}" = "1" ]; then install_pkgs; fi
exit 0
