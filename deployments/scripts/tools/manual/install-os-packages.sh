#!/bin/bash
# ============================================================
# TOOL: install-os-packages (manual, NOT a deploy-cluster module)
# DESC: 手动下载/安装 offline-files/os/packages/ubuntu-<版本> 下的节点 OS deb。
#       默认安装通用 OS 包 + chrony 专用集；--with-helm 额外安装**可选节点 helm**。
#       nodejs 不再由 installer 安装（已移除）。
#       通用 OS 包默认假设操作系统镜像已存在；pre_install_check 缺失时提示运行本脚本。
#       lock 文件(versions/os/*.lock)只用于安装前体检，本脚本不读它。
#
# 为什么是手动脚本:
#   · 不接入 deploy-cluster.sh，不会被模块发现或自动调度；
#   · 适合在部署前由运维按需执行，或用于离线包排障/补装。
#
# 目录布局（MinIO 与本地同构）:
#   MinIO: <alias>/<prefix>/ubuntu-<版本>/{*.deb,chrony/*.deb}
#   本地 : ${OFFLINE_FILES_ROOT}/os/packages/ubuntu-<版本>/{*.deb,chrony/*.deb}
#   旧布局兼容: ${OFFLINE_FILES_ROOT}/os/packages/{*.deb,chrony/*.deb}
#   可选 helm: ${OFFLINE_FILES_ROOT}/os/helm/helm_*.deb（旧布局 os/helm-nodejs/ 兼容）
#
# OS 版本选择:
#   · 未显式指定 --os-version / OS_PACKAGES_VERSION 时，**逐目标节点**读取 VERSION_ID，
#     按 22.04 / 24.04 分组安装；只有探测失败的目标才回退 versions/base.yaml 的基线版本。
#   · 显式值强制所有目标使用同一个 ubuntu-<版本> 目录。
#   · 版本目录不存在时回退旧布局 os/packages（仅本地安装路径）。
#
# 用法:
#   ./install-os-packages.sh                 # 默认 = --install（本地缺包时提示下载）
#   ./install-os-packages.sh --layout [--os-version 24.04]
#   ./install-os-packages.sh --download [--os-version 24.04] [--mc-alias minio] [--mc-prefix ...]
#   ./install-os-packages.sh --install  [--os-version 24.04] [--ip 10.66.3.162] [--dry-run]
#   ./install-os-packages.sh --install --with-helm ...   # 额外安装可选节点 helm
#   ./install-os-packages.sh --download --install ...
#
#   --with-helm                                额外安装可选节点 helm（os/helm/helm_*.deb）
#   --exclude "pattern ..."                    安装时排除的 deb basename glob（可选）
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
OS_VER_EXPLICIT=0
[ -n "${OS_VER}" ] && OS_VER_EXPLICIT=1
EXCLUDE_PATTERNS="${NODE_PKGS_EXCLUDE_PATTERNS:-}"
WITH_HELM=0
WITH_CHRONY=1
DRY_RUN=0
DO_DOWNLOAD=0
DO_INSTALL=0
DO_LAYOUT=0
ACTION_SET=0
IPS=()

usage() { sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; }

# 默认 OS 版本（仅用于“目标版本探测失败”的兜底；未显式指定时不强制所有目标）。
_base_os_version() {
    python3 - "${REPO_ROOT}/versions/base.yaml" <<'PY' 2>/dev/null || true
import re, sys
try:
    import yaml
    d = yaml.safe_load(open(sys.argv[1]))
    os_entries = d.get("os") or []
    if os_entries:
        print(os_entries[0].get("version", ""))
    sys.exit(0)
except Exception:
    pass
# 部署机 python 可能没有 PyYAML: 只解析 os: 块里的 version 字段。
try:
    in_os = False
    for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
        if re.match(r"^os:\s*$", line):
            in_os = True
            continue
        if in_os and re.match(r"^[A-Za-z_]", line):
            break
        if in_os:
            m = re.match(r"\s*version:\s*[\"']?([^\"'\s#]+)", line)
            if m:
                print(m.group(1))
                break
except Exception:
    pass
PY
}
BASELINE_OS_VER="$(_base_os_version)"

while [ $# -gt 0 ]; do
    case "$1" in
        --layout|--print-layout) DO_LAYOUT=1; DO_DOWNLOAD=0; DO_INSTALL=0; ACTION_SET=1; shift ;;
        --download) DO_DOWNLOAD=1; ACTION_SET=1; shift ;;
        --install)  DO_INSTALL=1; ACTION_SET=1; shift ;;
        --os-version) OS_VER="${2:?--os-version 需要值}"; OS_VER_EXPLICIT=1; shift 2 ;;
        --offline-root) OFFLINE_ROOT="${2:?--offline-root 需要值}"; shift 2 ;;
        --mc-alias) MC_ALIAS="${2:?--mc-alias 需要值}"; shift 2 ;;
        --mc-prefix) MC_PREFIX="${2:?--mc-prefix 需要值}"; shift 2 ;;
        --exclude) EXCLUDE_PATTERNS="${2:?--exclude 需要值}"; shift 2 ;;
        --with-helm) WITH_HELM=1; shift ;;
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

# 目标节点（ip|user|pw|hostname）；--ip 只保留显式地址，否则 NODES 全部。
TARGET_ENTRIES=()
for _line in "${NODES[@]:-}"; do
    [ -z "${_line}" ] && continue
    node_parse "${_line}"
    [ -n "${NODE_IP}" ] && [ -n "${NODE_USER}" ] || continue
    if [ "${#IPS[@]}" -gt 0 ]; then
        _hit=0
        for _ip in "${IPS[@]}"; do [ "${_ip}" = "${NODE_IP}" ] && { _hit=1; break; }; done
        [ "${_hit}" = "1" ] || continue
    fi
    TARGET_ENTRIES+=("${NODE_IP}|${NODE_USER}|${NODE_PW}|${NODE_HOSTNAME}")
done
unset _line _ip _hit

# 设置某个版本的包路径（install=允许旧布局回退；download=始终写版本目录）。
_set_dirs_for_version() {
    local _ver="$1" _mode="${2:-install}" _vdir
    OS_VER="${_ver}"
    _vdir="${OFFLINE_ROOT}/os/packages/ubuntu-${_ver}"
    if [ "${_mode}" = "download" ]; then
        PKG_DIR="${_vdir}"
    elif [ -d "${_vdir}" ]; then
        PKG_DIR="${_vdir}"
    else
        # 旧布局兼容: 版本目录不存在时才回退 os/packages 根目录
        PKG_DIR="${OFFLINE_ROOT}/os/packages"
    fi
    CHRONY_DIR="${PKG_DIR}/chrony"
    MC_SRC="${MC_ALIAS}/${MC_PREFIX}/ubuntu-${_ver}"
}

# 从目标节点读取 /etc/os-release 的 VERSION_ID；失败输出空（调用方回退基线）。
_detect_target_os() {  # <ip> <user> <pw>
    local _ip="$1" _u="$2" _pw="$3" _key _out
    _key="${SSH_KEY_DIR:-${REAL_HOME:-${HOME}}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
    _out="$(ssh -i "${_key}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${_u}@${_ip}" \
        "bash -c '. /etc/os-release; echo \"\$VERSION_ID\"'" 2>/dev/null | tr -d '\r' | head -1 || true)"
    if [ -z "${_out}" ] && [ -n "${_pw}" ] && command -v sshpass >/dev/null 2>&1; then
        _out="$(SSHPASS="${_pw}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8 \
            "${_u}@${_ip}" "bash -c '. /etc/os-release; echo \"\$VERSION_ID\"'" 2>/dev/null | tr -d '\r' | head -1 || true)"
    fi
    case "${_out}" in ''|*[!0-9.]*) _out="" ;; esac
    printf '%s' "${_out}"
}

# 版本 → 目标 IP 分组（保持首次出现顺序）
_VERS=()
_VER_IPS=()
_add_version_group() {  # <ver> <ip>
    local _ver="$1" _ip="$2" _i
    for _i in "${!_VERS[@]}"; do
        if [ "${_VERS[$_i]}" = "${_ver}" ]; then
            case " ${_VER_IPS[$_i]} " in
                *" ${_ip} "*) ;;
                *) _VER_IPS[$_i]="${_VER_IPS[$_i]}${_VER_IPS[$_i]:+ }${_ip}" ;;
            esac
            return 0
        fi
    done
    _VERS+=("${_ver}")
    _VER_IPS+=("${_ip}")
}

# 计算本次动作的版本计划:
#   · 显式 --os-version / OS_PACKAGES_VERSION → 单版本，强制所有目标；
#   · 否则逐目标探测 VERSION_ID 并分组；探测失败的目标回退基线版本。
_plan_versions() {
    _VERS=(); _VER_IPS=()
    if [ "${OS_VER_EXPLICIT}" = "1" ]; then
        [ -n "${OS_VER}" ] || { err "--os-version/OS_PACKAGES_VERSION 为空"; return 1; }
        local _ips="" _e _ip
        for _e in ${TARGET_ENTRIES[@]+"${TARGET_ENTRIES[@]}"}; do
            _ip="${_e%%|*}"
            [ -n "${_ip}" ] || continue
            case " ${_ips} " in *" ${_ip} "*) ;; *) _ips="${_ips}${_ips:+ }${_ip}" ;; esac
        done
        _VERS=("${OS_VER}")
        _VER_IPS=("${_ips}")
        return 0
    fi
    if [ "${#TARGET_ENTRIES[@]}" -eq 0 ]; then
        # 没有目标节点（--layout/--download 场景）: 用基线做展示/下载兜底。
        [ -n "${BASELINE_OS_VER}" ] || { err "无法确定 OS 版本；请用 --os-version 22.04|24.04 指定"; return 1; }
        _VERS=("${BASELINE_OS_VER}")
        _VER_IPS=("")
        return 0
    fi
    local _e _ip _u _pw _hn _ver
    for _e in "${TARGET_ENTRIES[@]}"; do
        IFS='|' read -r _ip _u _pw _hn <<< "${_e}"
        _ver="$(_detect_target_os "${_ip}" "${_u}" "${_pw}")"
        if [ -z "${_ver}" ]; then
            [ -n "${BASELINE_OS_VER}" ] || { err "无法探测 ${_hn}(${_ip}) 的 VERSION_ID，且基线版本为空"; return 1; }
            warn "  ${_hn}(${_ip}) 无法读取 VERSION_ID, 回退基线 ${BASELINE_OS_VER}"
            _ver="${BASELINE_OS_VER}"
        fi
        _add_version_group "${_ver}" "${_ip}"
    done
    return 0
}

print_layout() {
    local _mode_note="(基线兜底)"
    [ "${#TARGET_ENTRIES[@]}" -gt 0 ] && _mode_note="(目标自动探测)"
    [ "${OS_VER_EXPLICIT}" = "1" ] && _mode_note="(显式指定)"
    say "==== 手动 OS 包布局（不接入 deploy-cluster.sh） ===="
    echo "  OS 版本:   ${OS_VER} ${_mode_note}"
    echo "  MinIO 源:  ${MC_SRC}/"
    echo "  本地目标:  ${PKG_DIR}/"
    echo "             ├── *.deb        # 节点通用包（本脚本安装）"
    echo "             └── chrony/*.deb # chrony 专用安装集（含 timesyncd 回滚包）"
    echo "  可选 helm: ${HELM_DIR}/helm_*.deb（--with-helm 安装）"
    echo "  旧布局兼容: ${OFFLINE_ROOT}/os/packages/{*.deb,chrony/*.deb}（版本目录不存在时自动回退）"
    echo "             helm 旧目录 os/helm-nodejs/"
    echo
    echo "  下载（mc）:"
    echo "    mc cp --recursive '${MC_SRC}/' '${OFFLINE_ROOT}/os/packages/ubuntu-${OS_VER}/'"
    echo "    mc cp --recursive '${HELM_MC_BASE}/helm/' '${HELM_DIR}/'    # 旧布局用 helm-nodejs/"
    echo "  上传（如果 MinIO 尚无该版本目录）:"
    echo "    mc cp --recursive '${OFFLINE_ROOT}/os/packages/ubuntu-${OS_VER}/' '${MC_ALIAS}/${MC_PREFIX}/ubuntu-${OS_VER}/'"
    echo "    mc cp --recursive '${HELM_DIR}/' '${HELM_MC_BASE}/helm/'"
    echo "  手动安装（默认动作，不含 helm）:"
    echo "    $0 --os-version ${OS_VER} [--ip <节点IP> ...]"
    echo "  额外安装可选节点 helm:"
    echo "    $0 --install --with-helm --os-version ${OS_VER} [--ip <节点IP> ...]"
    echo
    echo "  安装排除模式: ${EXCLUDE_PATTERNS:-<无>}"
    echo "  提示: 手动模式请在 cluster.conf 关闭 CHRONY_PKGS_ENABLED，"
    echo "        否则 deploy-cluster.sh 仍会自动装 chrony 包。"
}

# 可选 helm 目录/源（与 OS 版本无关）
HELM_DIR="${OFFLINE_ROOT}/os/helm"
if [ ! -d "${HELM_DIR}" ] && [ -d "${OFFLINE_ROOT}/os/helm-nodejs" ]; then
    HELM_DIR="${OFFLINE_ROOT}/os/helm-nodejs"
fi
HELM_MC_BASE="${MC_ALIAS}/$(dirname "${MC_PREFIX}")"
_HELM_DL_DONE=0

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
    # ★ 2026-11-23(CodeRabbit): download_pkgs 被 `|| exit 1` 调用时 bash 会关闭函数内
    #   errexit; 必须对目录创建/传输显式 return 1, 否则 mc cp 失败仍会打印"已下载"并 exit 0。
    mkdir -p "${PKG_DIR}" || { err "创建目录失败: ${PKG_DIR}"; return 1; }
    mc cp --recursive "${MC_SRC}/" "${PKG_DIR}/" >/dev/null \
        || { err "下载失败: ${MC_SRC}/ → ${PKG_DIR}/"; return 1; }
    ok "已下载: $(find "${PKG_DIR}" -maxdepth 1 -name '*.deb' | wc -l) 个顶层 deb, $(find "${CHRONY_DIR}" -maxdepth 1 -name '*.deb' 2>/dev/null | wc -l) 个 chrony deb"
    # 可选节点 helm 只需下载一次（旧布局 os/helm-nodejs 兼容; nodejs 已移除）
    if [ "${_HELM_DL_DONE}" = "0" ]; then
        local _helm_mc=""
        if mc ls "${HELM_MC_BASE}/helm/" >/dev/null 2>&1; then
            _helm_mc="${HELM_MC_BASE}/helm"
        elif mc ls "${HELM_MC_BASE}/helm-nodejs/" >/dev/null 2>&1; then
            _helm_mc="${HELM_MC_BASE}/helm-nodejs"
        fi
        if [ -n "${_helm_mc}" ]; then
            mkdir -p "${HELM_DIR}" || { err "创建目录失败: ${HELM_DIR}"; return 1; }
            mc cp --recursive "${_helm_mc}/" "${HELM_DIR}/" >/dev/null \
                || { err "helm 下载失败: ${_helm_mc}/ → ${HELM_DIR}/"; return 1; }
            say "已下载可选节点 helm: ${HELM_DIR}(root helm_*.deb: $(find "${HELM_DIR}" -maxdepth 1 -name 'helm_*.deb' | wc -l) 个)"
        else
            warn "MinIO 未找到 ${HELM_MC_BASE}/{helm,helm-nodejs}/，跳过 helm"
        fi
        _HELM_DL_DONE=1
        unset _helm_mc
    fi
}

# 检查本地是否具备可安装的 OS 包；缺失时打印包名/MinIO 路径/下载命令并返回 1。
check_local_pkgs() {  # <pkg_dir> <chrony_dir> <ver>
    local _pkg_dir="$1" _chrony_dir="$2" _ver="$3"
    local _f _base _pat _skip _miss=0 _have_top=0 _have_chrony=0 _have_helm=0
    if [ -d "${_pkg_dir}" ]; then
        for _f in "${_pkg_dir}"/*.deb; do
            [ -f "${_f}" ] || continue
            _base="$(basename "${_f}")"
            _skip=0
            for _pat in ${EXCLUDE_PATTERNS//,/ }; do
                case "${_base}" in ${_pat}) _skip=1; break ;; esac
            done
            if [ "${_skip}" = "0" ]; then _have_top=1; break; fi
        done
    fi
    [ "${_have_top}" = "1" ] || { _miss=1; err "本地缺少可安装的顶层 OS deb: ${_pkg_dir}/*.deb"; }
    if [ "${WITH_CHRONY}" = "1" ]; then
        if [ -d "${_chrony_dir}" ]; then
            for _f in "${_chrony_dir}"/*.deb; do
                [ -f "${_f}" ] && { _have_chrony=1; break; }
            done
        fi
        [ "${_have_chrony}" = "1" ] || { _miss=1; err "本地缺少 chrony 专用安装集: ${_chrony_dir}/*.deb"; }
    fi
    if [ "${WITH_HELM}" = "1" ]; then
        for _f in "${HELM_DIR}"/helm_*.deb; do
            [ -f "${_f}" ] && { _have_helm=1; break; }
        done
        [ "${_have_helm}" = "1" ] || { _miss=1; err "本地缺少可选节点 helm: ${HELM_DIR}/helm_*.deb"; }
    fi
    if [ "${_miss}" = "1" ]; then
        echo
        say "请从 MinIO 下载对应离线包："
        echo "  离线包名称: ubuntu-${_ver}（系统包） + chrony（专用安装集）"
        echo "  MinIO 路径: ${MC_ALIAS}:${MC_PREFIX}/ubuntu-${_ver}/"
        echo "  可选 helm: ${HELM_MC_BASE}/{helm,helm-nodejs}/（仅 --with-helm 时安装）"
        echo "  下载命令:"
        echo "    mc cp --recursive '${MC_ALIAS}/${MC_PREFIX}/ubuntu-${_ver}/' '${OFFLINE_ROOT}/os/packages/ubuntu-${_ver}/'"
        echo "    mc cp --recursive '${HELM_MC_BASE}/helm/' '${HELM_DIR}/'"
        echo "  或直接执行:"
        echo "    $0 --download --os-version ${_ver}"
        return 1
    fi
    return 0
}

install_pkgs() {
    [ "${#TARGET_ENTRIES[@]}" -gt 0 ] || { err "没有目标节点(cluster.conf NODES 为空或 --ip 不在 NODES 中)"; return 1; }
    _plan_versions || return 1
    local -a rec_args=()
    [ "${DRY_RUN}" = "1" ] && rec_args+=(--dry-run)

    # 先校验所有版本分组的本地包，避免装到一半才发现某个版本缺包。
    local _vi
    for _vi in "${!_VERS[@]}"; do
        _set_dirs_for_version "${_VERS[$_vi]}" install
        check_local_pkgs "${PKG_DIR}" "${CHRONY_DIR}" "${_VERS[$_vi]}" || return 1
    done

    # 可选节点 helm 与 OS 版本无关，先装一次（--with-helm 时）。
    if [ "${WITH_HELM}" = "1" ]; then
        # 尊重 --ip: 只对本次选中的目标安装(否则 reconcile 会回退到 inventory 全量)。
        local -a _helm_ip_args=()
        local _he
        for _he in ${TARGET_ENTRIES[@]+"${TARGET_ENTRIES[@]}"}; do
            _helm_ip_args+=(--ip "${_he%%|*}")
        done
        say "安装可选节点 helm ..."
        OFFLINE_FILES_ROOT="${OFFLINE_ROOT}" \
            bash "${MANUAL_DIR}/../node/reconcile-node-packages.sh" --scope helm \
            --offline-root "${OFFLINE_ROOT}" \
            ${_helm_ip_args[@]+"${_helm_ip_args[@]}"} ${rec_args[@]+"${rec_args[@]}"} || return 1
    fi

    local _i _ver _ips _ip
    for _i in "${!_VERS[@]}"; do
        _ver="${_VERS[$_i]}"
        _ips="${_VER_IPS[$_i]}"
        _set_dirs_for_version "${_ver}" install
        check_local_pkgs "${PKG_DIR}" "${CHRONY_DIR}" "${_ver}" || return 1

        local -a group_ip_args=()
        for _ip in ${_ips}; do group_ip_args+=(--ip "${_ip}"); done

        say "手动安装 OS 包: 版本=${_ver}, 目录=${PKG_DIR}${_ips:+, 目标=${_ips}}"
        if [ -n "${EXCLUDE_PATTERNS}" ]; then
            say "  排除模式: ${EXCLUDE_PATTERNS}"
        fi
        if [ "${WITH_HELM}" = "1" ]; then
            say "  可选节点 helm: ${HELM_DIR}(--with-helm)"
        fi

        # 1) chrony 专用集优先：安装 chrony 后再对账顶层，避免先装 systemd-timesyncd 再被 chrony 预卸。
        if [ "${WITH_CHRONY}" = "1" ]; then
            if [ "${DRY_RUN}" = "1" ]; then
                say "  --dry-run: 跳过 chrony 实际安装"
            elif [ -d "${CHRONY_DIR}" ]; then
                OFFLINE_FILES_ROOT="${OFFLINE_ROOT}" OS_PACKAGES_VERSION="${_ver}" \
                    bash "${MANUAL_DIR}/../node/install-chrony-packages.sh" \
                    ${group_ip_args[@]+"${group_ip_args[@]}"} --offline-root "${OFFLINE_ROOT}" || return 1
            else
                warn "  未找到 ${CHRONY_DIR}，跳过 chrony 安装"
            fi
        else
            say "  --skip-chrony: 跳过 chrony/chrony 专用集"
        fi

        # 2) 顶层包对账安装（--scope general 只装该版本目录的通用 OS 包）。
        NODE_PKGS_EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS}" OFFLINE_FILES_ROOT="${OFFLINE_ROOT}" \
            OS_PACKAGES_VERSION="${_ver}" \
            bash "${MANUAL_DIR}/../node/reconcile-node-packages.sh" --scope general \
            --offline-root "${OFFLINE_ROOT}" ${group_ip_args[@]+"${group_ip_args[@]}"} \
            ${rec_args[@]+"${rec_args[@]}"} || return 1
    done

    if [ "${WITH_HELM}" = "1" ]; then
        ok "手动 OS 包安装完成（含可选节点 helm）"
    else
        ok "手动 OS 包安装完成（节点 helm 未安装；需要时加 --with-helm）"
    fi
}

if [ "${DO_LAYOUT}" = "1" ]; then
    _plan_versions || exit 1
    for _i in "${!_VERS[@]}"; do
        _set_dirs_for_version "${_VERS[$_i]}" install
        print_layout
        echo
    done
    exit 0
fi

if [ "${DO_DOWNLOAD}" = "1" ]; then
    _plan_versions || exit 1
    for _i in "${!_VERS[@]}"; do
        _set_dirs_for_version "${_VERS[$_i]}" download
        download_pkgs || exit 1
    done
fi
if [ "${DO_INSTALL}" = "1" ]; then install_pkgs; fi
exit 0
