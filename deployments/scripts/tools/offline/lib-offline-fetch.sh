#!/bin/bash
# ============================================================
# lib-offline-fetch.sh — fetch-offline-from-minio.sh 的辅助函数(被 source)
#
# 模块边界:
#   · mc 重试/远端大小/期望 sha/清理 stash/传输
#   · 校验失败展示/断点续传修复/发布树校验
#
# 全局契约(调用方在调用前必须设置):
#   DST_ROOT, FLAT, RELEASE_ARG, SRC_ROOT, TARGET, REPAIR, REPAIR_DONE,
#   NO_VERIFY, CLEAN, CLEAN_COUNTDOWN, YES, FETCH_RETRY, FETCH_RETRY_DELAY,
#   _CLEAN_STASH, _CLEAN_DST
# 日志函数 say/ok/warn/err 由调用方提供。
# ============================================================

_print_verify_failures() {   # <json>
    python3 - "$1" <<'PY' >&2 || true
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("❌ 校验失败(无法解析校验器输出)")
    raise SystemExit
fails = d.get("failures") or []
print(f"❌ 校验失败: {len(fails)} 个文件")
for f in fails[:20]:
    print(f"  {f.get('path')}: {f.get('message', '')}")
if len(fails) > 20:
    print(f"  ... 其余 {len(fails) - 20} 条见 --json")
print("修复: 加 --repair 只重下坏文件, 或从发布源重新拷贝")
PY
}

_repair_from_json() {   # <json>
    local json="$1" qbase ts rel src dst
    local -a bad=()
    mapfile -t bad < <(python3 - "$json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit
seen = set()
for f in d.get("failures") or []:
    p = f.get("path")
    if p and p not in seen:
        seen.add(p)
        print(p)
PY
)
    [ "${#bad[@]}" -gt 0 ] || return 1
    ts="$(date +%Y%m%d-%H%M%S)"
    qbase="$(dirname "${DST_ROOT}")/.repair-quarantine/${RELEASE_ARG}/${ts}"
    mkdir -p "${qbase}" 2>/dev/null \
        || qbase="${TMPDIR:-/var/tmp}/cubestack-repair/${RELEASE_ARG}/${ts}"
    mkdir -p "${qbase}" || return 1
    local rc=0 n_fixed=0
    for rel in "${bad[@]}"; do
        rel="${rel#./}"
        # 元数据项由校验器 --seal --update-success 重建, 不在 SHA256SUMS 内, 不能用 mc cp 修复;
        # 截断文件会让 _SUCCESS.bytes 校验失败, 若不跳过会先撞上它而放弃后续文件(2026-10-29 实测)。
        case "${rel}" in
            _SUCCESS|SHA256SUMS|SIZES)
                warn "  跳过元数据项: ${rel}(由 verify --seal --update-success 重建)"
                continue ;;
        esac
        case "${rel}" in
            cubestack-installer-cli-*.tar|cubestack-installer-cli.tar)
                src="${SRC_ROOT}/${rel}"; dst="${DST_ROOT}/${rel}" ;;
            *)
                # 两种布局的远端都在 <release>/offline-files/ 下; flat 只改本地落点。
                # (旧实现 flat 用 ${SRC_ROOT}/${rel}, 少了 offline-files/, 续传/重下必失败)
                src="${SRC_ROOT}/offline-files/${rel}"
                if [ "${FLAT}" = "1" ]; then dst="${DST_ROOT}/${rel}"; else dst="${DST_ROOT}/offline-files/${rel}"; fi ;;
        esac
        local expected="" lsize="" rsize=""
        case "${rel}" in
            cubestack-installer-cli-*.tar|cubestack-installer-cli.tar)
                if [ "${FLAT}" = "1" ]; then
                    expected="$(_cli_expected_sha "${DST_ROOT}/release.json")"
                else
                    expected="$(_cli_expected_sha "${DST_ROOT}/offline-files/release.json")"
                fi ;;
            *)
                if [ "${FLAT}" = "1" ]; then
                    expected="$(_expected_sha "${DST_ROOT}/SHA256SUMS" "${rel}")"
                else
                    expected="$(_expected_sha "${DST_ROOT}/offline-files/SHA256SUMS" "${rel}")"
                fi ;;
        esac
        # 断点续传: 本地是远端的前缀时, 只追加剩余字节, 再按清单 sha 验证
        if [ -n "${expected}" ] && [ -f "${dst}" ]; then
            lsize="$(stat -c %s "${dst}" 2>/dev/null || echo 0)"
            rsize="$(_remote_size "${src}")"
            case "${rsize}" in ''|*[!0-9]*) rsize="" ;; esac
            if [ -n "${rsize}" ] && [ "${lsize}" -gt 0 ] && [ "${lsize}" -lt "${rsize}" ]; then
                say "断点续传 ${rel} (${lsize}/${rsize} 字节)..."
                if mc cat --offset "${lsize}" "${src}" >> "${dst}" 2>/dev/null \
                   && [ "$(sha256sum "${dst}" | awk '{print $1}')" = "${expected,,}" ]; then
                    ok "断点续传完成: ${rel}"
                    n_fixed=$((n_fixed + 1))
                    continue
                fi
                warn "续传后校验失败, 改为完整重下: ${rel}"
            fi
        fi
        if [ -f "${dst}" ]; then
            mkdir -p "${qbase}/$(dirname "${rel}")"
            mv -f "${dst}" "${qbase}/${rel}" || true
        fi
        say "重新下载 ${rel} ..."
        # 2026-10-29: mc RELEASE.2026-09 起 `mc cp` 已移除 --overwrite(默认即覆盖);
        #   带该 flag 会 "flag provided but not defined" 导致 repair 全部失败。
        _mc_retry mc cp "${src}" "${dst}" \
            || { err "重新下载失败: ${rel}(检查网络/mc 配置)"; rc=1; continue; }
        if [ -n "${expected}" ] && [ "$(sha256sum "${dst}" | awk '{print $1}')" != "${expected,,}" ]; then
            err "重下后 sha 仍不符(远端可能已变化/损坏): ${rel}"
            rc=1; continue
        fi
        n_fixed=$((n_fixed + 1))
    done
    [ "${rc}" = "0" ] || return 1
    ok "已修复 ${n_fixed} 个文件; 重新校验..."
    return 0
}

_verify_release() {
    local root="${DST_ROOT}" base="${DST_ROOT}/offline-files" _vt _json _rc
    [ "${FLAT}" = "1" ] && base="${DST_ROOT}"
    if [ "${NO_VERIFY}" = "1" ]; then
        warn "已跳过发布树完整性校验(--no-verify; 仅调试用)"
        return 0
    fi
    _vt="$(ensure_offline_verify_tool)" || { err "校验器不可用; 无法校验发布树"; return 1; }
    _json="$(mktemp)"
    local -a _args=(--root "${base}" --release "${RELEASE_ARG}" --level full --json --fail-missing)
    if [ "${FLAT}" = "1" ]; then
        _args+=(--layout flat)
    else
        _args+=(--layout release)
        local _cli="${root}/cubestack-installer-cli-v${RELEASE_ARG}.tar"
        [ -f "${_cli}" ] && _args+=(--cli-tar "${_cli}")
        _args+=(--require-cli-tar)
    fi
    say "校验发布树(完整 sha256 + CLI tar): ${base}"
    _rc=0
    bash "${_vt}" ${_args[@]+"${_args[@]}"} > "${_json}" || _rc=$?
    if [ "${_rc}" = "0" ]; then
        rm -f "${_json}"
        ok "发布版本 ${RELEASE_ARG} 校验通过"
        return 0
    fi
    _print_verify_failures "${_json}"
    if [ "${REPAIR}" = "1" ] && [ "${REPAIR_DONE}" = "0" ]; then
        REPAIR_DONE=1
        if _repair_from_json "${_json}"; then
            rm -f "${_json}"
            _verify_release
            return $?
        fi
    fi
    rm -f "${_json}"
    return 1
}

# ---------------- 8a. mc 重试 / 断点续传辅助 ----------------
_mc_retry() {
    local n=1 rc=0
    while [ "${n}" -le "${FETCH_RETRY}" ]; do
        "$@" && return 0
        rc=$?
        if [ "${n}" -lt "${FETCH_RETRY}" ]; then
            warn "mc 命令失败(第 ${n}/${FETCH_RETRY} 次), ${FETCH_RETRY_DELAY}s 后重试..."
            sleep "${FETCH_RETRY_DELAY}"
        fi
        n=$((n + 1))
    done
    return "${rc}"
}

_remote_size() {   # <remote>
    mc stat --json "$1" 2>/dev/null | python3 -c \
        'import json,sys; print(json.load(sys.stdin).get("size",""))' 2>/dev/null || true
}

_expected_sha() {   # <SHA256SUMS> <rel>
    local sums="$1" rel="$2" p out
    for p in "./${rel}" "${rel}" "*./${rel}" "*${rel}"; do
        out="$(awk -v p="$p" '$2==p {print $1; exit}' "${sums}" 2>/dev/null || true)"
        if [ -n "${out}" ]; then
            printf '%s\n' "${out}"
            return 0
        fi
    done
    return 0
}

_cli_expected_sha() {   # <release.json>
    python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("cli_tar_sha256") or "").replace("sha256:","").strip())' \
        "$1" 2>/dev/null || true
}

# ---------------- 8b. 精确清理(release/flat 默认) ----------------
# 保留 .cubestack-* (校验戳/清单备份): 先移出目标目录, 镜像完成后再移回。
_clean_begin() {   # <dst>
    local dst="$1"
    _CLEAN_DST="$dst"
    _CLEAN_STASH="$(dirname "$dst")/.cubestack-fetch-stash.$$.$RANDOM"
    mkdir -p "$_CLEAN_STASH" || { err "无法创建清理保留目录: $_CLEAN_STASH"; return 1; }
    if [ -d "$dst" ]; then
        find "$dst" -mindepth 1 -maxdepth 1 -name '.cubestack-*' \
            -exec mv -t "$_CLEAN_STASH" {} + 2>/dev/null || true
    fi
    return 0
}
_clean_end() {
    if [ -n "${_CLEAN_STASH}" ] && [ -d "${_CLEAN_STASH}" ]; then
        find "${_CLEAN_STASH}" -mindepth 1 -maxdepth 1 \
            -exec mv -t "${_CLEAN_DST}" {} + 2>/dev/null || true
        rmdir "${_CLEAN_STASH}" 2>/dev/null || true
    fi
    _CLEAN_STASH=""
    _CLEAN_DST=""
}
_clean_warning() {   # <desc>
    local desc="$1" i="${CLEAN_COUNTDOWN}"
    echo -e "\033[41m\033[97m================================================================\033[0m"
    echo -e "\033[41m\033[97m ⚠ 精确同步: 将覆盖本地文件, 并删除 MinIO 中不存在的多余文件\033[0m"
    echo -e "\033[41m\033[97m   目标: ${desc}\033[0m"
    echo -e "\033[41m\033[97m   .cubestack-* (校验戳/清单备份) 会保留; 其他清理不可恢复\033[0m"
    echo -e "\033[41m\033[97m================================================================\033[0m"
    if [ "${YES}" = "1" ]; then
        echo "  --yes: 跳过倒计时"
        return 0
    fi
    if [ "${i}" -le 0 ]; then
        echo "  倒计时 0: 立即执行"
        return 0
    fi
    while [ "${i}" -gt 0 ]; do
        printf "\r  %2d 秒后开始( Ctrl-C 中止 )" "${i}"
        sleep 1
        i=$((i - 1))
    done
    printf "\r  开始执行...                    \n"
}
_transfer() {   # <src> <dst> <exact_copy 0|1>
    local src="$1" dst="$2" exact="$3"
    if [ "${CLEAN}" = "1" ]; then
        _clean_begin "$dst" || return 1
        # 中断/失败也要把 .cubestack-* 移回, 避免留在 stash 里
        trap '_clean_end' EXIT INT TERM
        if _mc_retry mc mirror --overwrite --remove --retry "$src" "$dst"; then
            _clean_end
            trap - EXIT INT TERM
            return 0
        fi
        _clean_end
        trap - EXIT INT TERM
        return 1
    fi
    if [ "${exact}" = "1" ]; then
        _mc_retry mc cp --recursive "$src" "$dst"
    else
        _mc_retry mc mirror --overwrite --retry "$src" "$dst"
    fi
}

