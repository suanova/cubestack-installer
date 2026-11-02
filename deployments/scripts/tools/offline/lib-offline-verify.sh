#!/bin/bash
# ============================================================
# lib-offline-verify.sh — offline-files 校验器定位/自举(被 source, 不直接执行)
#
# ensure_offline_verify_tool:
#   按顺序查找校验器, 成功时把**绝对路径**打印到 stdout; 日志走 stderr。
#   1) CUBESTACK_VERIFY_TOOL
#   2) 仓库副本 deployments/scripts/tools/offline/verify-offline-files.sh(+ .pyz)
#   3) 发布树副本 <OFFLINE_FILES_ROOT>/tools/verify-offline-files.sh + .pyz(按 SHA256SUMS 引导校验)
#   4) PATH 里的 cubestack-verify-offline(CLI 镜像内置)
#   5) 在线安装(最多 3 次, 固定 sha256, fail-closed)
#
# 说明: 本库**不 source lib-common.sh**, 供 deploy-cluster/fetch/cubestack-offline 共用。
# ============================================================
_OV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# deployments/scripts/tools/offline → 仓库根
_OV_REPO_ROOT="$(cd "${_OV_LIB_DIR}/../../../.." && pwd)"
_OV_TOOL_NAME="verify-offline-files.sh"
_OV_PYZ_NAME="verify-offline-files.pyz"
_OV_PIN_FILE="${_OV_REPO_ROOT}/deployments/config/verify-tool.sha256"
_OV_CACHE_DIR="${XDG_CACHE_HOME:-${HOME:-/root}/.cache}/cubestack/verify"

_ov_log() { echo "$*" >&2; }
_ov_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# 发布树副本引导校验: 在树的 SHA256SUMS 中校验 wrapper(以及存在时的 pyz)
_ov_bootstrap_one() {   # <tree-root> <relative-path>
    local root="$1" rel="$2" want got
    want="$(awk -v p="./${rel}" '$2==p {print $1}' "${root}/SHA256SUMS" 2>/dev/null | head -1)"
    [ -n "${want}" ] || want="$(awk -v p="${rel}" '$2==p {print $1}' "${root}/SHA256SUMS" 2>/dev/null | head -1)"
    [ -n "${want}" ] || return 1
    got="$(_ov_sha "${root}/${rel}")"
    [ -n "${got}" ] && [ "${want,,}" = "${got,,}" ]
}
_ov_bootstrap_ok() {   # <tree-root>
    local root="$1"
    [ -f "${root}/SHA256SUMS" ] || return 1
    _ov_bootstrap_one "${root}" "tools/${_OV_TOOL_NAME}" || return 1
    if [ -f "${root}/tools/${_OV_PYZ_NAME}" ]; then
        _ov_bootstrap_one "${root}" "tools/${_OV_PYZ_NAME}" || return 1
    fi
    return 0
}

_ov_try_online() {
    local url="${OFFLINE_VERIFY_TOOL_URL:-https://raw.githubusercontent.com/suanova/cubestack-installer/main/deployments/scripts/tools/offline/verify-offline-files.pyz}"
    local pin="${OFFLINE_VERIFY_TOOL_SHA256:-}"
    local pyz="${_OV_CACHE_DIR}/${_OV_PYZ_NAME}"
    local wrapper="${_OV_CACHE_DIR}/${_OV_TOOL_NAME}"
    local tmp n
    if [ -z "${pin}" ] && [ -f "${_OV_PIN_FILE}" ]; then
        pin="$(tr -d '[:space:]' < "${_OV_PIN_FILE}")"
    fi
    if [ -z "${pin}" ]; then
        _ov_log "⚠ 未配置校验器 pin(OFFLINE_VERIFY_TOOL_SHA256 / ${_OV_PIN_FILE}), 拒绝在线安装"
        return 1
    fi
    mkdir -p "${_OV_CACHE_DIR}" || return 1
    tmp="${pyz}.part.$$"
    for n in 1 2 3; do
        rm -f "${tmp}"
        if command -v curl >/dev/null 2>&1 \
           && curl -fsSL --connect-timeout 5 --max-time 30 -o "${tmp}" "${url}"; then
            local got; got="$(_ov_sha "${tmp}")"
            if [ -n "${got}" ] && [ "${got,,}" = "${pin,,}" ]; then
                if python3 "${tmp}" --version >/dev/null 2>&1; then
                    mv -f "${tmp}" "${pyz}" || { rm -f "${tmp}"; return 1; }
                    printf '#!/bin/sh\nexec python3 "%s" "$@"\n' "${pyz}" > "${wrapper}" \
                        || { rm -f "${pyz}"; return 1; }
                    chmod 0755 "${wrapper}" || return 1
                    _ov_log "✅ 已在线安装校验器: ${pyz}(wrapper: ${wrapper})"
                    printf '%s\n' "${wrapper}"
                    return 0
                fi
                _ov_log "⚠ 第 ${n}/3 次安装: pyz 无法执行(--version 失败), 丢弃"
            else
                _ov_log "⚠ 第 ${n}/3 次安装: sha256 不符(期望 ${pin}, 实际 ${got:-空}), 丢弃"
            fi
        else
            _ov_log "⚠ 第 ${n}/3 次安装失败: ${url}"
        fi
        rm -f "${tmp}"
        [ "${n}" -lt 3 ] && sleep $((n * 3))
    done
    return 1
}

ensure_offline_verify_tool() {
    local tool tree
    # 0) 运行依赖
    if ! command -v python3 >/dev/null 2>&1; then
        _ov_log "❌ 校验器需要 python3(>=3.8); 未找到 python3"
        return 1
    fi
    # 1) 显式指定
    if [ -n "${CUBESTACK_VERIFY_TOOL:-}" ]; then
        if [ -x "${CUBESTACK_VERIFY_TOOL}" ]; then
            printf '%s\n' "${CUBESTACK_VERIFY_TOOL}"; return 0
        fi
        _ov_log "⚠ CUBESTACK_VERIFY_TOOL 不可执行: ${CUBESTACK_VERIFY_TOOL}"
    fi
    # 2) 仓库副本
    tool="${_OV_LIB_DIR}/${_OV_TOOL_NAME}"
    if [ -x "${tool}" ]; then
        printf '%s\n' "${tool}"; return 0
    fi
    # 3) 发布树副本(引导校验; 新树同时带 wrapper + pyz)
    tree="${OFFLINE_FILES_ROOT:-}"
    if [ -n "${tree}" ] && [ -x "${tree}/tools/${_OV_TOOL_NAME}" ]; then
        if _ov_bootstrap_ok "${tree}"; then
            printf '%s\n' "${tree}/tools/${_OV_TOOL_NAME}"; return 0
        fi
        _ov_log "⚠ 发布树校验器引导校验失败, 拒绝执行: ${tree}/tools/${_OV_TOOL_NAME}"
    fi
    # 4) PATH
    if command -v cubestack-verify-offline >/dev/null 2>&1; then
        command -v cubestack-verify-offline; return 0
    fi
    # 5) 在线安装
    case "${OFFLINE_VERIFY_ONLINE_INSTALL:-auto}" in
        never)
            _ov_log "⚠ 校验器不存在, 且 OFFLINE_VERIFY_ONLINE_INSTALL=never"
            return 1
            ;;
        *)
            _ov_try_online
            ;;
    esac
}
