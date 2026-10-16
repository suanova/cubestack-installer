#!/bin/bash
# ============================================================
# cubestack-platform-save-images.sh — 平台镜像保鲜: Harbor/上游 → 离线 tar(digest 幂等)
# ------------------------------------------------------------
# 数据源(单一事实源): offline-files/cubestack-operator/image-list.tsv(37 行: 本体+平台组件)
# 行为(逐行):
#   ① 取远端 manifest 摘要: sha256(skopeo inspect --raw docker://<pull_ref>)
#      —— 与 `docker pull` 的 Digest 等价(2026-10-16 公开/私有双实测), 零层拉取;
#   ② 与 <out>/<subdir>/<file>.digest 边车比对: 相同 → 跳过(不拉、不写);
#   ③ 变化/无边车(或 --force) → skopeo copy(强制单架构 linux/amd64, 多架构 tar 会
#      让 ctr import 报 "content digest not found")→ 覆盖 tar + 重写边车。
#
# 认证(按优先级):
#   ① 环境 REGISTRY_AUTH_FILE(已有 auth 文件);
#   ② HARBOR_MIRROR_USER + HARBOR_MIRROR_PASSWORD → 写 600 临时 auth 文件(用后即删,
#      不进 argv、不进日志 —— 与 harbor-sync/save 同一纪律);
#   ③ ~/.docker/config.json(存在即用, 兼容已 docker login 的机器)。
# 用法:
#   bash tools/images/cubestack-platform-save-images.sh [选项]
#     --list <tsv>   清单(默认 offline-files/cubestack-operator/image-list.tsv)
#     --out <dir>    输出目录(默认 = 清单所在目录, 即本地 offline-files/cubestack-operator)
#     --only <子串,..>  只处理 subdir 或文件名命中任一子串的行(更新单个组件用)
#     --force        忽略边车, 全部重拉重写
#     --dry-run      只比对与打印计划, 不拉取不写文件
#     --list-check   离线校验清单 ↔ 目录覆盖(不做任何网络操作)
# 退出码: 0=全部成功/跳过; 1=有失败(逐条报告, 其余继续)
# ============================================================
set -euo pipefail

_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib-common.sh
source "${_self}/../../lib-common.sh"

LIST=""
OUT=""
ONLY=""
FORCE=0
DRY=0
LIST_CHECK=0
SEAL_MISSING=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list)       LIST="${2:?}"; shift 2 ;;
        --out)        OUT="${2:?}"; shift 2 ;;
        --only)       ONLY="${2:?}"; shift 2 ;;
        --force)      FORCE=1; shift ;;
        --dry-run)    DRY=1; shift ;;
        --list-check) LIST_CHECK=1; shift ;;
        --seal-missing) SEAL_MISSING=1; shift ;;   # 已有的 tar 未变化时, 仅补写缺失的 .digest 边车(不重拉)
        *) err "未知参数: $1"; exit 1 ;;
    esac
done
LIST="${LIST:-${REPO_ROOT}/deployments/offline-files/cubestack-operator/image-list.tsv}"
OUT="${OUT:-$(dirname "${LIST}")}"
TLS_VERIFY="${SAVE_TLS_VERIFY:-true}"
[ -f "${LIST}" ] || { err "清单不存在: ${LIST}"; exit 1; }

# ---------- 认证文件(② 临时 600; 用后即删) ----------
_AUTH_TMP=""
_cleanup() { [ -n "${_AUTH_TMP}" ] && rm -f "${_AUTH_TMP}" || true; }
trap _cleanup EXIT
AUTH_ARGS=()
if [ -n "${REGISTRY_AUTH_FILE:-}" ]; then
    AUTH_ARGS=(--authfile "${REGISTRY_AUTH_FILE}")
elif [ -n "${HARBOR_MIRROR_USER:-}" ] && [ -n "${HARBOR_MIRROR_PASSWORD:-}" ]; then
    _AUTH_TMP="$(mktemp /tmp/cubestack-save-auth.XXXXXX)"
    chmod 600 "${_AUTH_TMP}"
    _HU="${HARBOR_MIRROR_USER}" _HP="${HARBOR_MIRROR_PASSWORD}" python3 - "${_AUTH_TMP}" <<'PY'
import base64, json, os, sys
auth = base64.b64encode(f"{os.environ['_HU']}:{os.environ['_HP']}".encode()).decode()
json.dump({"auths": {"harbor.isuanova.com": {"auth": auth}}}, open(sys.argv[1], "w"))
PY
    AUTH_ARGS=(--authfile "${_AUTH_TMP}")
elif [ -f "${HOME}/.docker/config.json" ]; then
    AUTH_ARGS=(--authfile "${HOME}/.docker/config.json")   # 兼容已 docker login 的机器
fi

# ---------- 远端摘要: sha256(skopeo --raw) == docker pull 的 Digest ----------
_ref_digest() {   # <ref> → "sha256:..." ; 失败返回非 0
    local raw
    raw="$(skopeo inspect --raw --tls-verify="${TLS_VERIFY}" ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} "docker://$1" 2>/dev/null)" || return 1
    printf '%s' "${raw}" | sha256sum | awk '{print "sha256:"$1}'
}

# ---------- 清单读取(TSV: subdir<TAB>file<TAB>pull_ref<TAB>save_ref) ----------
_rows() {
    command grep -vE '^\s*#|^\s*$' "${LIST}" | while IFS=$'\t' read -r sub file pull save; do
        [ -n "${file}" ] || continue
        [ -n "${pull}" ] || pull="${save}"
        [ -n "${sub}" ] || sub="."
        printf '%s|%s|%s|%s\n' "${sub}" "${file}" "${pull}" "${save}"
    done
}

if [ "${LIST_CHECK}" = "1" ]; then
    ok_n=0; bad_n=0
    while IFS='|' read -r sub file pull save; do
        rel="$([ "${sub}" = "." ] && echo "${file}" || echo "${sub}/${file}")"
        if [ -f "${OUT}/${rel}" ]; then ok_n=$((ok_n+1)); else warn "清单行缺文件: ${rel}"; bad_n=$((bad_n+1)); fi
    done < <(_rows)
    # 反向: 目录里存在但清单没有的 *.tar(排除隐藏目录)
    while IFS= read -r f; do
        rel="${f#"${OUT}"/}"
        _rows | awk -F'|' -v r="${rel}" '{s=$1; f2=$2; x=(s=="."?f2:s"/"f2); if(x==r) found=1} END{exit !found}' \
            || { warn "目录多余 tar(不在清单): ${rel}"; bad_n=$((bad_n+1)); }
    done < <(find "${OUT}" -name '*.tar' -not -path '*/.*' 2>/dev/null)
    [ "${bad_n}" = "0" ] && ok "清单与目录精确一致(${ok_n} 个)" || { err "清单校验失败(${bad_n} 处)"; exit 1; }
    exit 0
fi

# ---------- 主循环 ----------
command -v skopeo >/dev/null 2>&1 || { err "缺少 skopeo(安装: apt-get install -y skopeo)"; exit 1; }
n_ok=0; n_skip=0; n_fail=0
while IFS='|' read -r sub file pull save; do
    if [ -n "${ONLY}" ]; then
        _hit=0
        for _o in ${ONLY//,/ }; do
            case "${sub}/${file}" in *"${_o}"*) _hit=1 ;; esac
        done
        [ "${_hit}" = "1" ] || continue
    fi
    outdir="${OUT}"; [ "${sub}" = "." ] || outdir="${OUT}/${sub}"
    tarpath="${outdir}/${file}"; digfile="${tarpath}.digest"
    d_new="$(_ref_digest "${pull}")" || { err "[${sub}/${file}] 远端摘要获取失败(pull=${pull})"; n_fail=$((n_fail+1)); continue; }
    d_old="$(cat "${digfile}" 2>/dev/null || true)"
    if [ "${SEAL_MISSING}" = "1" ] && [ -z "${d_old}" ] && [ -f "${tarpath}" ]; then
        # 一次性迁移: tar 已在(人工核对与远端一致), 只补边车, 不重拉
        if [ "${DRY}" = "1" ]; then
            say "  [dry-run] 将补写边车: ${sub}/${file}"
        else
            printf '%s' "${d_new}" > "${digfile}"
            say "  补写边车(seal): ${sub}/${file}"
        fi
        n_skip=$((n_skip+1)); continue
    fi
    if [ "${FORCE}" != "1" ] && [ -n "${d_old}" ] && [ "${d_old}" = "${d_new}" ]; then
        say "  跳过(digest 相同): ${sub}/${file}"; n_skip=$((n_skip+1)); continue
    fi
    if [ "${DRY}" = "1" ]; then
        say "  [dry-run] 将更新: ${sub}/${file}(${d_old:-无} → ${d_new})"; n_ok=$((n_ok+1)); continue
    fi
    mkdir -p "${outdir}"
    _tmp="${tarpath}.tmp.$$"
    if skopeo copy --retry-times 3 --tls-verify="${TLS_VERIFY}" ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
           --override-os linux --override-arch amd64 \
           "docker://${pull}" "docker-archive:${_tmp}:${save}" 2>/dev/null; then
        mv -f "${_tmp}" "${tarpath}"
        printf '%s' "${d_new}" > "${digfile}"
        ok "  已更新: ${sub}/${file}(→ ${d_new:0:19}…)"; n_ok=$((n_ok+1))
    else
        rm -f "${_tmp}"
        err "  拉取失败: ${sub}/${file}(pull=${pull})"; n_fail=$((n_fail+1))
    fi
done < <(_rows)

say "──────────────────────────────"
say "  更新 ${n_ok} / 跳过 ${n_skip} / 失败 ${n_fail}  (目录: ${OUT})"
[ "${n_fail}" = "0" ] && exit 0 || exit 1
