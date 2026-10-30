#!/bin/bash
# ============================================================
# lib-offline-gate.sh — 离线文件安装前门禁/release.env 预校验(被 source)
# 依赖: lib-offline-verify.sh(ensure_offline_verify_tool) + 调用方的 warn/err.
# 全局契约: OFFLINE_FILES_ROOT/OFFLINE_VERIFY_*/CUBESTACK_RELEASE*/
#           CUBESTACK_RELEASE_LAYOUT/CUBESTACK_RELEASE_ROOT.
# ============================================================

# ---------------- 离线文件完整性校验(2026-10-28) ----------------
# release.env 被 root source 之前的最小校验: 存在 SHA256SUMS 时强制(防损坏文件被执行)。
# 无清单(旧树/开发树)只警告, 不阻断 —— 完整校验由 verify_offline_gate 负责。
verify_release_env_precheck() {   # <offline-files-root>
    local base="$1" sums="${1}/SHA256SUMS" envf="${1}/release.env" want got ssum asum
    [ -f "${envf}" ] || return 0
    if [ ! -f "${sums}" ]; then
        # ⚠ 必须走 stderr: load_config 常被 "$(...)" 捕获, stdout 只能有值
        echo -e "\033[33m⚠  未找到 ${sums}, 跳过 release.env 预校验(建议 verify-offline-files.sh --seal)\033[0m" >&2
        return 0
    fi
    want="$(awk -v p="./release.env" '$2==p {print $1}' "${sums}" 2>/dev/null | head -1)"
    [ -n "${want}" ] || want="$(awk -v p="release.env" '$2==p {print $1}' "${sums}" 2>/dev/null | head -1)"
    [ -n "${want}" ] || want="$(awk -v p="*./release.env" '$2==p {print $1}' "${sums}" 2>/dev/null | head -1)"
    [ -n "${want}" ] || want="$(awk -v p="*release.env" '$2==p {print $1}' "${sums}" 2>/dev/null | head -1)"
    if [ -z "${want}" ]; then
        err "release.env 未登记在 ${sums}; 拒绝 source(发布树不完整或已被修改)"
        return 1
    fi
    got="$(sha256sum "${envf}" | awk '{print $1}')"
    if [ "${want,,}" != "${got,,}" ]; then
        err "release.env 校验失败: 期望 ${want} 实际 ${got}; 拒绝 source(文件损坏或被修改)"
        return 1
    fi
    if [ -f "${base}/_SUCCESS" ]; then
        ssum="$(awk -F= '$1=="sha256sums"{print $2}' "${base}/_SUCCESS" 2>/dev/null | tr -d '[:space:]')"
        ssum="${ssum#sha256:}"
        if [ -n "${ssum}" ]; then
            asum="$(sha256sum "${sums}" | awk '{print $1}')"
            if [ "${ssum,,}" != "${asum,,}" ]; then
                err "_SUCCESS.sha256sums 与 SHA256SUMS 不符(期望 ${ssum} 实际 ${asum})"
                return 1
            fi
        fi
    fi
    return 0
}

# 解析本次部署的有效离线校验级别(纯函数, 便于单测).
# 规则(2026-10-30):
#   ① --no-verify-offline → off
#   ② --verify-offline=<auto|quick|full|off> → 该值(显式优先)
#   ③ 部分部署(--steps 非空)且配置为 auto → quick(不做整树 full+deep)
#   ④ 其余 → 配置值(全量部署 auto 仍走 full/校验戳)
# 输出: 第一行=有效级别; 若因 --steps 降级, 追加第二行 "downgraded".
offline_verify_effective_mode() {  # <mode> <steps_arg> <no_verify> <verify_arg>
    local mode="${1:-auto}" steps_arg="${2:-}" no_verify="${3:-0}" verify_arg="${4:-}"
    if [ "${no_verify}" = "1" ]; then
        printf 'off\n'
        return 0
    fi
    if [ -n "${verify_arg}" ]; then
        case "${verify_arg}" in
            auto|quick|full|off) printf '%s\n' "${verify_arg}"; return 0 ;;
            *) printf 'invalid\n'; return 1 ;;
        esac
    fi
    if [ -n "${steps_arg}" ] && [ "${mode}" = "auto" ]; then
        printf 'quick\ndowngraded\n'
        return 0
    fi
    printf '%s\n' "${mode}"
    return 0
}

# 安装前完整性门禁: 调用独立校验器(唯一实现)。失败返回 1; 未 seal 的开发树按
# OFFLINE_VERIFY_STRICT_DEV 决定"检出损坏是否阻断"(默认 true)。
verify_offline_gate() {
    local mode="${OFFLINE_VERIFY_MODE:-auto}" root="${OFFLINE_FILES_ROOT:-}"
    local tool rc level="${OFFLINE_VERIFY_MODE:-auto}"
    local -a args
    case "${mode}" in
        off|Off|OFF) warn "已跳过离线文件完整性校验(OFFLINE_VERIFY_MODE=off)"; return 0 ;;
        auto|quick|full) ;;
        *) err "OFFLINE_VERIFY_MODE 非法: ${mode}(可用 auto|off|quick|full)"; return 1 ;;
    esac
    [ -n "${root}" ] && [ -d "${root}" ] || { err "离线目录不存在: ${root:-<未配置>}"; return 1; }
    if ! tool="$(ensure_offline_verify_tool)"; then
        if [ -n "${CUBESTACK_RELEASE:-}" ] || [ -f "${root}/SHA256SUMS" ]; then
            err "校验器不可用(镜像/发布树/在线安装均失败); 请用 cubestack-cli 镜像或手工拷贝 verify-offline-files.sh"
            return 1
        fi
        warn "校验器不可用; 未 seal 的开发树跳过完整性校验"
        return 0
    fi
    # 未 seal 的树没有清单, full 无意义 → 降级 quick
    if [ ! -f "${root}/SHA256SUMS" ] && [ "${level}" = "full" ]; then
        level="quick"
        warn "未 seal 的离线树没有清单; full 降级为 quick(${root})"
    fi
    args=(--root "${root}" --level "${level}" --jobs "${OFFLINE_VERIFY_JOBS:-4}" --fail-missing)
    if [ -n "${CUBESTACK_RELEASE:-}" ]; then
        args+=(--release "${CUBESTACK_RELEASE}")
        if [ "${CUBESTACK_RELEASE_LAYOUT:-}" = "flat" ]; then
            args+=(--layout flat)
        else
            args+=(--layout release)
            local _cli="${CUBESTACK_RELEASE_ROOT:-}/${CUBESTACK_RELEASE}/cubestack-installer-cli-v${CUBESTACK_RELEASE}.tar"
            [ -f "${_cli}" ] && args+=(--cli-tar "${_cli}")
        fi
    elif [ ! -f "${root}/SHA256SUMS" ]; then
        args+=(--allow-unsealed)
    fi
    [ "${OFFLINE_VERIFY_STAMP:-true}" = "true" ] || args+=(--no-stamp)
    bash "${tool}" ${args[@]+"${args[@]}"}
    rc=$?
    if [ "${rc}" = "0" ]; then return 0; fi
    if [ "${rc}" = "2" ]; then
        err "校验器环境错误(退出码 2); 详见上方输出"
        return 1
    fi
    if [ ! -f "${root}/SHA256SUMS" ] && [ "${OFFLINE_VERIFY_STRICT_DEV:-true}" != "true" ]; then
        warn "未 seal 的开发树检出损坏, 但 OFFLINE_VERIFY_STRICT_DEV=false → 仅警告"
        return 0
    fi
    return 1
}

