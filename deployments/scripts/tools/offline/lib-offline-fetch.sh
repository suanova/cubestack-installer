#!/bin/bash
# ============================================================
# lib-offline-fetch.sh — fetch-offline-from-minio.sh 的辅助函数(被 source)
#
# 模块边界:
#   · mc 重试/远端大小/期望 sha/清理 stash/传输
#   · 内容寻址增量传输(以远端 SHA256SUMS 为唯一判据, 不依赖 Last-Modified)
#   · 校验失败展示/断点续传修复/发布树校验
#
# ★ 2026-11-04: 释放模式(CLEAN=1)默认走"增量传输", 不再 `mc mirror --overwrite` 整树重传。
#   原因(实测): mc 只在"本地文件比远端对象**更新**"时才跳过; MinIO 的 Last-Modified 由服务端
#   分配, 用 mc mirror 复制出来的新版本目录会让**所有对象**变成"更新" ⇒ 换版本必全量重传
#   (2.0.0→2.0.1 实测 104 GiB 全下, 而真实变化只有 2.8 GiB)。`--overwrite` 还会把"相等"档
#   也变成重传。增量实现见 `_manifest_transfer` + `manifest-plan.py`; `--full` 可回退旧行为。
#
# 全局契约(调用方在调用前必须设置):
#   DST_ROOT, FLAT, RELEASE_ARG, SRC_ROOT, TARGET, REPAIR, REPAIR_DONE,
#   NO_VERIFY, CLEAN, CLEAN_COUNTDOWN, YES, FETCH_RETRY, FETCH_RETRY_DELAY,
#   _CLEAN_STASH, _CLEAN_DST; 可选: CLI_TAR_BASENAME(本次选中的 CLI tar 文件名),
#   FULL_FETCH(1=强制整树 mirror, 跳过增量)
# 日志函数 say/ok/warn/err 由调用方提供。
# ============================================================

# 深度校验提示只打印一次(完整校验成功时)
_DEEP_HINT_SHOWN=0

# 打印"建议单独执行深度校验"的提示(仅在本次确实跳过了 deep 时)。
_print_deep_hint() {   # <tool> <tree-base> <skipped-deep 0|1> [release]
    local tool="$1" base="$2" skipped="$3" rel="${4:-${RELEASE_ARG:-}}" cmd
    [ "${skipped}" = "1" ] || return 0
    [ "${_DEEP_HINT_SHOWN}" = "1" ] && return 0
    _DEEP_HINT_SHOWN=1
    cmd="${tool} --root ${base} --level full --deep"
    [ -n "${rel:-}" ] && cmd="${cmd} --release ${rel}"
    if [ "${FLAT:-0}" = "1" ]; then
        cmd="${cmd} --layout flat"
    else
        cmd="${cmd} --layout release"
    fi
    echo ""
    warn "本次为 full 校验(全量 sha256 + 结构检查), 未做深度校验(镜像 layer digest / 大包完整解压)"
    echo "   建议单独执行深度校验(首次部署、介质搬运后强烈推荐; 耗时更长):"
    echo "     ${cmd}"
    echo ""
}

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
    # 版本身份: MinIO 版本目录名(--release)与树内 release.env 的 RELEASE_VERSION 可能不同
    # (整树复制出的新版本目录, 或待 CI 覆盖元数据时属预期)。校验以**树自身声明**为准,
    # 但仍打印醒目告警, 避免把"拷错版本"当成正常。
    local _rel_verify="${RELEASE_ARG}" _decl=""
    if [ -f "${base}/release.env" ]; then
        _decl="$(awk -F= '$1=="RELEASE_VERSION"{print $2; exit}' "${base}/release.env" 2>/dev/null | tr -d '[:space:]')"
    fi
    if [ -n "${_decl}" ] && [ "${_decl}" != "${RELEASE_ARG}" ]; then
        warn "本地发布树声明 release=${_decl}, 与下载的版本目录 ${RELEASE_ARG} 不一致"
        warn "  按发布树自身版本 ${_decl} 校验(整树复制 / 待 CI 覆盖元数据时属预期; 如需严格匹配请先刷新 release.env)"
        _rel_verify="${_decl}"
    fi
    _vt="$(ensure_offline_verify_tool)" || { err "校验器不可用; 无法校验发布树"; return 1; }
    _json="$(mktemp)"
    local -a _args=(--root "${base}" --release "${_rel_verify}" --level full --json --fail-missing)
    # 默认 full 不做 deep(深度解压/镜像 layer digest 耗时很长); 旧版校验器没有 --no-deep,
    # 探测后才追加, 避免拿发布树里的旧副本时报 "unrecognized arguments"。
    # ⚠ 用命令替换读完输出再匹配: `--help | grep -q` 命中即退出会让左侧收到 SIGPIPE,
    #   pipefail 下可能把"支持 --no-deep"误判成不支持。
    local _skipped_deep=0 _help
    _help="$("${_vt}" --help 2>&1 || true)"
    case "${_help}" in *--no-deep*) _args+=(--no-deep); _skipped_deep=1 ;; esac
    if [ "${FLAT}" = "1" ]; then
        _args+=(--layout flat)
    else
        _args+=(--layout release)
        # CLI tar 路径: 优先本次选中的文件名(CLI_TAR_BASENAME, 下载路径已按远端解析),
        # 其次版本化默认名, 最后兼容旧布局 —— 旧 release.json 可能没有 cli_tar 字段,
        # 校验器自身只会找 release.json 与版本化名, 否则会把已下载的
        # cubestack-installer-cli.tar 在 --require-cli-tar 下误判为缺失。
        local _cli="${root}/cubestack-installer-cli-v${RELEASE_ARG}.tar"
        if [ -n "${CLI_TAR_BASENAME:-}" ] && [ -f "${root}/${CLI_TAR_BASENAME}" ]; then
            _cli="${root}/${CLI_TAR_BASENAME}"
        elif [ ! -f "${_cli}" ] && [ -f "${root}/cubestack-installer-cli.tar" ]; then
            _cli="${root}/cubestack-installer-cli.tar"
        fi
        [ -f "${_cli}" ] && _args+=(--cli-tar "${_cli}")
        _args+=(--require-cli-tar)
    fi
    say "校验发布树(完整 sha256 + CLI tar): ${base}"
    say "  大版本全量校验可能需要数分钟(约 300s 量级), 每 10s 打印进度, 请耐心等待, 不要中断"
    _rc=0
    bash "${_vt}" ${_args[@]+"${_args[@]}"} > "${_json}" || _rc=$?
    if [ "${_rc}" = "0" ]; then
        rm -f "${_json}"
        ok "发布版本 ${RELEASE_ARG} 校验通过"
        _print_deep_hint "${_vt}" "${base}" "${_skipped_deep}" "${_rel_verify}"
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
    # 10#: --clean-countdown 允许前导零(如 08), 但 bash 的 $(( )) 与 printf %d 会把
    # 08 当非法八进制(非 $((10#...)) 方式在 set -e 下会直接中止脚本), 故这里先归一为十进制。
    local desc="$1" i=$((10#${CLEAN_COUNTDOWN:-0}))
    echo -e "\033[41m\033[97m================================================================\033[0m"
    echo -e "\033[41m\033[97m ⚠ 精确同步: 只重下缺失/内容不符的文件, 并删除本地多余文件\033[0m"
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
# ---------------- 8c. 内容寻址增量传输(方案 A, 2026-11-04) ----------------
# 判据 = 远端 offline-files/SHA256SUMS 的内容哈希, 与对象 mtime/ETag 无关:
#   · 缺失/哈希不符 → 只下这几个文件 (mc cp)
#   · 清单外多余文件 → 删除 (保留 .cubestack-* 与 CLI tar)
#   · 哈希缓存 .cubestack-hashes.json 以 (size,mtime_ns) 命中, 避免每次重读 100+ GiB
# 安全兜底: 下载后仍跑全量 sha256 校验; 清单不可用/非法时回退到旧整树 mirror。
_hash_cache_path() {
    # flat 模式下 _clean_begin 会把 .cubestack-* 暂存到 stash; 直接写 stash 那份,
    # _clean_end 归位时即覆盖旧缓存(否则新缓存会被旧缓存反覆盖)。
    if [ -n "${_CLEAN_STASH:-}" ] && [ -f "${_CLEAN_STASH}/.cubestack-hashes.json" ]; then
        printf '%s\n' "${_CLEAN_STASH}/.cubestack-hashes.json"
    else
        printf '%s\n' "${DST_ROOT}/.cubestack-hashes.json"
    fi
}

_manifest_transfer() {   # <src_offline_base> <local_tree_root> <prefix>
    # 返回: 0=增量完成 / 1=下载失败 / 2=清单不可用(调用方回退整树 mirror)
    local src="$1" root="$2" prefix="${3:-}"
    local planner="${SCRIPT_DIR}/manifest-plan.py"
    [ -f "${planner}" ] || { warn "  未找到 ${planner}, 回退整树镜像"; return 2; }
    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/cubestack-fetch-plan.XXXXXX")" || return 1
    local manifest="${tmp}/SHA256SUMS" plan="${tmp}/plan.tsv"
    local _rc=0
    if ! _mc_retry mc cp "${src}/SHA256SUMS" "${manifest}" >/dev/null 2>&1; then
        warn "  无法读取远端 SHA256SUMS, 回退整树镜像"
        rm -rf "${tmp}"
        return 2
    fi
    local cache summary
    cache="$(_hash_cache_path)"
    summary="$(python3 "${planner}" --manifest "${manifest}" --root "${root}" \
        --prefix "${prefix}" --cache "${cache}" --out "${plan}" 2>"${tmp}/plan.err")" || _rc=$?
    if [ "${_rc}" != "0" ]; then
        warn "  增量计划生成失败(rc=${_rc}: $(head -1 "${tmp}/plan.err" 2>/dev/null)), 回退整树镜像"
        rm -rf "${tmp}"
        return 2
    fi

    local op rel n_fetch=0 n_del=0 n_fail=0 dstf
    local fetched="${tmp}/fetched.txt"
    : > "${fetched}"
    while IFS=$'\t' read -r op rel; do
        [ -n "${op:-}" ] || continue
        case "${op}" in
            fetch)
                dstf="${root}/${rel}"
                if ! mkdir -p "$(dirname "${dstf}")" 2>/dev/null; then
                    err "  创建目录失败: $(dirname "${dstf}")"; n_fail=$((n_fail + 1)); continue
                fi
                if _mc_retry mc cp "${src}/${rel}" "${dstf}" >/dev/null 2>&1; then
                    n_fetch=$((n_fetch + 1))
                    printf '%s\n' "${rel}" >> "${fetched}"
                else
                    err "  下载失败: ${rel}"
                    n_fail=$((n_fail + 1))
                fi ;;
            delete)
                if rm -f -- "${root}/${rel}" 2>/dev/null; then
                    n_del=$((n_del + 1))
                else
                    warn "  删除失败(忽略): ${rel}"
                fi ;;
        esac
    done < "${plan}"

    # 删掉因清理而变空的目录(只在本 prefix 内; 失败忽略)
    local scan="${root}/${prefix}"
    [ -d "${scan}" ] && find "${scan}" -mindepth 1 -type d -empty -delete 2>/dev/null || true

    # 下载完成后刷新这些文件的哈希缓存(单次调用, 不逐个起进程)
    if [ -s "${fetched}" ]; then
        python3 "${planner}" --manifest "${manifest}" --root "${root}" --prefix "${prefix}" \
            --cache "${cache}" --out /dev/null --hash-list "${fetched}" >/dev/null 2>&1 || true
    fi

    # 元数据文件不在清单内(SHA256SUMS/_SUCCESS/SIZES), 必须显式同取:
    #   SHA256SUMS 直接用已下载的那份; 其余存在则复制(缺失/老发布树没有时忽略)。
    local m
    cp -f "${manifest}" "${root}/SHA256SUMS" 2>/dev/null \
        || warn "  写入本地 SHA256SUMS 失败: ${root}/SHA256SUMS"
    for m in _SUCCESS SIZES; do
        mc cp "${src}/${m}" "${root}/${m}" >/dev/null 2>&1 || true
    done

    say "  增量结果: 下载 ${n_fetch} 个, 删除 ${n_del} 个, 未变更 $(printf '%s' "${summary}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("kept",0))' 2>/dev/null || echo '?') 个"
    rm -rf "${tmp}"
    [ "${n_fail}" = "0" ] || { err "  ${n_fail} 个文件下载失败(见上)"; return 1; }
    return 0
}

_transfer() {   # <src> <dst> <exact_copy 0|1> [manifest_prefix]
    local src="$1" dst="$2" exact="$3" prefix="${4:-}"
    if [ "${CLEAN}" = "1" ]; then
        _clean_begin "$dst" || return 1
        # 中断/失败也要把 .cubestack-* 移回, 避免留在 stash 里
        trap '_clean_end' EXIT INT TERM
        local _rc=2
        if [ "${FULL_FETCH:-0}" != "1" ] && [ "${RELEASE_MODE:-0}" = "1" ]; then
            # 清单里的相对路径以 offline-files/ 为根: flat 时本地根 = DST_ROOT,
            # 版本目录布局时 = DST_ROOT/offline-files。
            local _local_offline_root="${DST_ROOT}"
            [ "${FLAT:-1}" = "1" ] || _local_offline_root="${DST_ROOT}/offline-files"
            _manifest_transfer "${SRC_ROOT}/offline-files" "${_local_offline_root}" "${prefix}"
            _rc=$?
        fi
        if [ "${_rc}" = "0" ]; then
            _clean_end
            trap - EXIT INT TERM
            return 0
        fi
        if [ "${_rc}" = "1" ]; then
            _clean_end
            trap - EXIT INT TERM
            return 1
        fi
        # _rc=2: 清单不可用 → 回退旧行为(整树 mirror 覆盖 + 清理)
        warn "  使用整树镜像(会重新传输未变更文件)"
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

