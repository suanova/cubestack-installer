#!/bin/bash
# ============================================================
# refresh-latest-offline.sh — 按上游组件刷新 latest 离线镜像到 MinIO
# ------------------------------------------------------------
# 配置来源 = optimize-online-offline 分支的 image-list.tsv(单一事实源):
#   deployments/offline-files/cubestack-operator/image-list.tsv
#   deployments/offline-files/dev-lab/image-list.tsv
#   列: subdir <TAB> file <TAB> pull_ref <TAB> save_ref
#       pull_ref 留空 = 与 save_ref 相同
#       subdir='.'   = 顶层 (collection 根目录)
#
# 本脚本只处理 save_ref 以 :latest 结尾的滚动镜像; 钉版本的第三方镜像跳过。
# 组件(component)只是 dispatch 选择器, 映射到 subdir:
#   operator-image -> controller-manager
#   portal-image   -> portal
#   dev-lab        -> jupyter + ssh
#   publish        -> .            (operator 本体)
#   bmc            -> bmc
#   (cubepilot/cuberouter 没有 component, 按 repo 选择)
#
# 流程:
#   ① skopeo inspect --raw 取远端 manifest, 归一化为 linux/amd64 digest
#   ② 与 MinIO 上的 <tar>.digest 边车比对, 相同且 tar 存在 → SKIP
#   ③ 变化时 skopeo copy 成单架构 tar, 校验 digest
#   ④ 先上传 tar, 再上传 .digest(中断后下次会重做, 不会假成功)
#
# 设计约束:
#   · 不 source lib-common.sh / 不读 cluster.conf —— GitHub-hosted runner 可直接跑
#   · 只覆盖同名 latest 对象; 不 prune、不删除 MinIO 其他文件
#
# 用法:
#   refresh-latest-offline.sh --list-plan --repo all
#   refresh-latest-offline.sh --preflight --repo suanova/cubestack --component operator-image
#   refresh-latest-offline.sh --dry-run --repo suanova/cuberouter
#   refresh-latest-offline.sh --repo suanova/cubestack-operator --component publish
#   refresh-latest-offline.sh --repo all --sha <commit>          # 全量/manual seed
#
# 环境变量:
#   HARBOR_MIRROR_USER / HARBOR_MIRROR_PASSWORD   或 HARBOR_USER / HARBOR_PASSWORD
#   HARBOR_MIRROR_REGISTRY(默认 harbor.isuanova.com)
#   HARBOR_MIRROR_INSECURE(默认 false)
#   MINIO_ENDPOINT / MINIO_ACCESS_KEY / MINIO_SECRET_KEY
#   MINIO_BUCKET(默认 cubestack-installer) / MINIO_REMOTE_DIR(默认 offline-files)
#   MINIO_INSECURE(默认 false) / MC_BIN(默认 mc)
# 退出码: 0=全部成功/跳过; 1=有镜像失败; 2=参数/配置错误
# ============================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-image-manifest.sh
source "${SELF_DIR}/lib-image-manifest.sh"

REPO_ROOT="${IM_REPO_ROOT}"
DEFAULT_LISTS=(
    "${REPO_ROOT}/deployments/offline-files/cubestack-operator/image-list.tsv"
    "${REPO_ROOT}/deployments/offline-files/dev-lab/image-list.tsv"
)
LISTS=()
WORK_DIR="${RUNNER_TEMP:-/tmp}/refresh-latest-offline"
MIN_FREE_GB=15
MC_BIN="${MC_BIN:-mc}"
MC_ALIAS="cubestackrefresh"
SKOPEO_TIMEOUT_SECONDS="${SKOPEO_TIMEOUT_SECONDS:-3600}"

SEL_REPOS=""
SEL_COMPONENTS=""
SEL_IMAGES=""
SHA=""
LIST_PLAN=0
PREFLIGHT=0
DRY_RUN=0
FORCE=0
SEAL_MISSING=0
SUMMARY_FILE=""
AUTH_FILE=""

HARBOR_HOST="${HARBOR_MIRROR_REGISTRY:-harbor.isuanova.com}"
HARBOR_INSECURE="${HARBOR_MIRROR_INSECURE:-false}"
HARBOR_USER="${HARBOR_MIRROR_USER:-${HARBOR_USER:-}}"
HARBOR_PASSWORD="${HARBOR_MIRROR_PASSWORD:-${HARBOR_PASSWORD:-}}"
MINIO_BUCKET="${MINIO_BUCKET:-cubestack-installer}"
MINIO_REMOTE_DIR="${MINIO_REMOTE_DIR:-offline-files}"
MINIO_INSECURE="${MINIO_INSECURE:-false}"

say()  { printf '\033[36m→  %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✅ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m⚠  %s\033[0m\n' "$*" >&2; }
bad()  { printf '\033[31m❌ %s\033[0m\n' "$*" >&2; }

usage() {
    sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

need_val() { [ $# -ge 2 ] && [ -n "$2" ] || { bad "$1 需要值"; exit 2; }; }

while [ $# -gt 0 ]; do
    case "$1" in
        --list)            need_val "$@"; LISTS+=("$2"); shift 2 ;;
        --list=*)          LISTS+=("${1#*=}"); shift ;;
        --repo)            need_val "$@"; SEL_REPOS="${SEL_REPOS:+${SEL_REPOS},}$2"; shift 2 ;;
        --repo=*)          SEL_REPOS="${SEL_REPOS:+${SEL_REPOS},}${1#*=}"; shift ;;
        --component)       need_val "$@"; SEL_COMPONENTS="${SEL_COMPONENTS:+${SEL_COMPONENTS},}$2"; shift 2 ;;
        --component=*)     SEL_COMPONENTS="${SEL_COMPONENTS:+${SEL_COMPONENTS},}${1#*=}"; shift ;;
        --only)            need_val "$@"; SEL_IMAGES="${SEL_IMAGES:+${SEL_IMAGES},}$2"; shift 2 ;;
        --only=*)          SEL_IMAGES="${SEL_IMAGES:+${SEL_IMAGES},}${1#*=}"; shift ;;
        --sha)             need_val "$@"; SHA="$2"; shift 2 ;;
        --sha=*)           SHA="${1#*=}"; shift ;;
        --work-dir)        need_val "$@"; WORK_DIR="$2"; shift 2 ;;
        --work-dir=*)      WORK_DIR="${1#*=}"; shift ;;
        --min-free-gb)     need_val "$@"; MIN_FREE_GB="$2"; shift 2 ;;
        --min-free-gb=*)   MIN_FREE_GB="${1#*=}"; shift ;;
        --summary-file)    need_val "$@"; SUMMARY_FILE="$2"; shift 2 ;;
        --summary-file=*)  SUMMARY_FILE="${1#*=}"; shift ;;
        --list-plan)       LIST_PLAN=1; shift ;;
        --preflight)       PREFLIGHT=1; shift ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --force)           FORCE=1; shift ;;
        --seal-missing)    SEAL_MISSING=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) bad "未知参数: $1"; usage; exit 2 ;;
    esac
done

[ "${#LISTS[@]}" -gt 0 ] || LISTS=("${DEFAULT_LISTS[@]}")

mkdir -p "${WORK_DIR}" || { bad "工作目录不可写: ${WORK_DIR}"; exit 2; }
umask 077

# ---------- 选择器 ----------
_match_list() {   # <value> <comma/space-separated>
    local v="$1" list="$2" x
    [ -z "${list}" ] && return 0
    for x in ${list//,/ }; do [ "${x}" = "${v}" ] && return 0; done
    return 1
}
_image_from_ref() { local x="${1##*/}"; printf '%s\n' "${x%%:*}"; }
_extra_tags_for_image() {
    case "$1" in
        cubestack-activity-agent) echo "sha" ;;
        *)                        echo "-" ;;
    esac
}

# component -> 所属 repo / 对应 subdir(与 image-list.tsv 的 subdir 列一致)
_component_repo() {
    case "$1" in
        operator-image|portal-image|dev-lab) echo "suanova/cubestack" ;;
        publish|bmc)                         echo "suanova/cubestack-operator" ;;
        *) return 1 ;;
    esac
}
_component_subdirs() {
    case "$1" in
        operator-image) echo "controller-manager" ;;
        portal-image)   echo "portal" ;;
        dev-lab)        echo "jupyter ssh" ;;
        publish)        echo "." ;;
        bmc)            echo "bmc" ;;
        *) return 1 ;;
    esac
}
_repo_subdirs() {
    case "$1" in
        suanova/cubestack)          echo "controller-manager portal jupyter ssh" ;;
        suanova/cubestack-operator) echo ". bmc" ;;
        suanova/cubepilot)          echo "cubepilot" ;;
        suanova/cuberouter)         echo "cuberouter" ;;
        *) return 1 ;;
    esac
}

ALLOWED_SUBDIRS=""
if [ -n "${SEL_COMPONENTS}" ]; then
    for _c in ${SEL_COMPONENTS//,/ }; do
        _cr="$(_component_repo "${_c}")" || { bad "未知 component: ${_c}"; exit 2; }
        if [ -n "${SEL_REPOS}" ] && [ "${SEL_REPOS}" != "all" ] && ! _match_list "${_cr}" "${SEL_REPOS}"; then
            bad "component ${_c} 属于 ${_cr}, 与 --repo ${SEL_REPOS} 不匹配"; exit 2
        fi
        _cs="$(_component_subdirs "${_c}")" || { bad "component 未映射 subdir: ${_c}"; exit 2; }
        ALLOWED_SUBDIRS="${ALLOWED_SUBDIRS} ${_cs}"
    done
elif [ -n "${SEL_REPOS}" ] && [ "${SEL_REPOS}" != "all" ]; then
    for _r in ${SEL_REPOS//,/ }; do
        _rs="$(_repo_subdirs "${_r}")" || { bad "未知 repo: ${_r}"; exit 2; }
        ALLOWED_SUBDIRS="${ALLOWED_SUBDIRS} ${_rs}"
    done
fi
ALLOWED_SUBDIRS="$(printf '%s' "${ALLOWED_SUBDIRS}" | xargs)"

# ---------- 解析 image-list.tsv ----------
# 内部行(管道分隔): collection|subdir|file|pull|save|image|extra_tags
ROWS_FILE="${WORK_DIR}/rows.psv"
: > "${ROWS_FILE}"
declare -A _SEEN_FILE=()
_n_rows=0
_n_selected=0

for _list in "${LISTS[@]}"; do
    [ -f "${_list}" ] || { bad "清单不存在: ${_list}"; exit 1; }
    _collection="$(basename "$(dirname "${_list}")")"
    _lineno=0
    while IFS= read -r _line || [ -n "${_line}" ]; do
        _lineno=$((_lineno + 1))
        _line="${_line%$'\r'}"
        [ -z "${_line}" ] && continue
        case "${_line}" in \#*) continue ;; esac

        IFS=$'\t' read -r _subdir _file _pull _save <<< "${_line}"
        # 兼容 3 列(无 pull)与 4 列(pull 为空): 后两列任一非空即可
        if [ -z "${_save}" ]; then _save="${_pull}"; _pull=""; fi
        _pull="${_pull:-${_save}}"
        [ -n "${_subdir}" ] && [ -n "${_file}" ] && [ -n "${_save}" ] \
            || { bad "${_list}:${_lineno}: 列不完整"; exit 1; }

        # 只处理滚动 latest; 钉版本/第三方固定 tag 跳过
        case "${_save}" in *:latest) : ;; *) continue ;; esac
        # 组件/仓库过滤
        if [ -n "${ALLOWED_SUBDIRS}" ] && ! _match_list "${_subdir}" "${ALLOWED_SUBDIRS}"; then
            continue
        fi
        # 本脚本只产出 .tar; .tar.gz 留给人工/分支工具
        case "${_file}" in *.tar) : ;; *) warn "跳过非 .tar: ${_file}"; continue ;; esac

        _image="$(_image_from_ref "${_save}")"
        _want_file="$(image_tar_name "${_save}")"
        [ "${_file}" = "${_want_file}" ] \
            || { bad "${_list}:${_lineno}: file(${_file}) 与 save_ref(${_save}) 不匹配(期望 ${_want_file})"; exit 1; }
        if [ -n "${SEL_IMAGES}" ] && ! _match_list "${_image}" "${SEL_IMAGES}"; then
            continue
        fi

        case "${_save}" in "${HARBOR_HOST}/"*) : ;; *) bad "${_list}:${_lineno}: save_ref 不在 ${HARBOR_HOST}: ${_save}"; exit 1 ;; esac
        case "${_pull}" in "${HARBOR_HOST}/"*) : ;; *) bad "${_list}:${_lineno}: pull_ref 不在 ${HARBOR_HOST}: ${_pull}"; exit 1 ;; esac
        case "${_save}" in *:*) : ;; *) bad "${_list}:${_lineno}: save_ref 缺少 tag"; exit 1 ;; esac
        case "${_pull}" in *:*) : ;; *) bad "${_list}:${_lineno}: pull_ref 缺少 tag"; exit 1 ;; esac

        _extra="$(_extra_tags_for_image "${_image}")"
        _key="${_collection}|${_subdir}|${_file}"
        [ -z "${_SEEN_FILE[${_key}]:-}" ] || { bad "重复条目: ${_key}"; exit 1; }
        _SEEN_FILE["${_key}"]=1
        _n_rows=$((_n_rows + 1))
        printf '%s|%s|%s|%s|%s|%s|%s\n' \
            "${_collection}" "${_subdir}" "${_file}" "${_pull}" "${_save}" "${_image}" "${_extra}" >> "${ROWS_FILE}"
        _n_selected=$((_n_selected + 1))
    done < "${_list}"
done

[ "${_n_rows}" -gt 0 ] || { bad "没有匹配的 latest 条目(repo=${SEL_REPOS:-all} component=${SEL_COMPONENTS:-all} only=${SEL_IMAGES:-all})"; exit 1; }

_plan_table() {
    printf '  %-24s %-20s %-38s %s\n' "COLLECTION" "SUBDIR" "IMAGE" "FILE"
    while IFS='|' read -r collection subdir file pull save image extra; do
        [ "${subdir}" = "." ] && subdir="(top)"
        printf '  %-24s %-20s %-38s %s\n' "${collection}" "${subdir}" "${image}" "${file}"
        [ "${extra}" = "sha" ] && printf '  %-24s %-20s %-38s %s\n' "" "" "" "  + $(image_tar_name "${save%:*}:${SHA:-<sha>}")"
    done < "${ROWS_FILE}"
}

say "清单: ${LISTS[*]}  选中 ${_n_selected} 条 latest"
say "MinIO 目标根: ${MINIO_BUCKET}/${MINIO_REMOTE_DIR}/  (tar 与 .digest 写在各自子目录下)"
_plan_table

if [ "${LIST_PLAN}" = "1" ]; then
    ok "清单校验通过"
    exit 0
fi

# ---------- 工具与凭据 ----------
_require() { command -v "$1" >/dev/null 2>&1 || { bad "缺少命令: $1"; exit 2; }; }

_minio_env() {
    [ -n "${MINIO_ENDPOINT:-}" ] || { bad "缺少 MINIO_ENDPOINT"; return 1; }
    [ -n "${MINIO_ACCESS_KEY:-}" ] || { bad "缺少 MINIO_ACCESS_KEY"; return 1; }
    [ -n "${MINIO_SECRET_KEY:-}" ] || { bad "缺少 MINIO_SECRET_KEY"; return 1; }
    export MC_CONFIG_DIR="${WORK_DIR}/.mc"
    mkdir -p "${MC_CONFIG_DIR}"

    local ep="${MINIO_ENDPOINT}"
    case "${ep}" in *://*) : ;; *) ep="http://${ep}" ;; esac
    local -a a=("${MC_BIN}")
    [ "${MINIO_INSECURE}" = "true" ] && a+=(--insecure)
    # 与手工验证保持一致: 让 mc 自己处理凭据编码, 不依赖 MC_HOST_ 的 URL 拼装
    "${a[@]}" alias set "${MC_ALIAS}" "${ep}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" >/dev/null \
        || { bad "MinIO alias 配置失败: ${ep}"; return 1; }
}

_need_private() {
    local _c _s _f _p _sv _i _e
    while IFS='|' read -r _c _s _f _p _sv _i _e; do
        case "${_p}" in */suanova-private/*) return 0 ;; esac
    done < "${ROWS_FILE}"
    return 1
}

_harbor_auth() {
    if [ -z "${HARBOR_USER}" ] || [ -z "${HARBOR_PASSWORD}" ]; then
        if _need_private; then
            bad "缺少 Harbor 凭据(HARBOR_MIRROR_USER/HARBOR_MIRROR_PASSWORD): 选中行含 suanova-private 镜像"
            return 1
        fi
        printf '{"auths":{}}' > "${AUTH_FILE}"
        warn "未配置 Harbor 凭据, 按匿名拉取"
    else
        local b64
        b64="$(printf '%s:%s' "${HARBOR_USER}" "${HARBOR_PASSWORD}" | base64 -w0 2>/dev/null \
            || printf '%s:%s' "${HARBOR_USER}" "${HARBOR_PASSWORD}" | base64)"
        printf '{"auths":{"%s":{"auth":"%s"}}}' "${HARBOR_HOST}" "${b64}" > "${AUTH_FILE}"
        unset b64
    fi
    chmod 600 "${AUTH_FILE}"
    export REGISTRY_AUTH_FILE="${AUTH_FILE}"
}

_harbor_tls_args_inspect=()
_harbor_tls_args_src=()
if [ "${HARBOR_INSECURE}" = "true" ]; then
    _harbor_tls_args_inspect=(--tls-verify=false)
    _harbor_tls_args_src=(--src-tls-verify=false)
else
    _harbor_tls_args_src=(--src-tls-verify=true)
fi
_dest_tls_args=(--dest-tls-verify=false)

_mc() {
    local -a a=("${MC_BIN}")
    [ "${MINIO_INSECURE}" = "true" ] && a+=(--insecure)
    "${a[@]}" "$@"
}

_remote_path() {   # <collection> <subdir> <file>
    local p="${MC_ALIAS}/${MINIO_BUCKET}/${MINIO_REMOTE_DIR}/$1"
    [ "$2" != "." ] && p="${p}/$2"
    printf '%s/%s' "${p}" "$3"
}
_remote_tar_exists() { _mc stat "$(_remote_path "$1" "$2" "$3")" >/dev/null 2>&1; }
_remote_sidecar() { _mc cat "$(_remote_path "$1" "$2" "$3.digest")" 2>/dev/null | tr -d '[:space:]'; }

_digest_normalize() {
    python3 -c '
import hashlib, json, sys
raw = sys.stdin.buffer.read()
try:
    d = json.loads(raw)
except Exception:
    sys.exit(1)
ms = d.get("manifests")
if isinstance(ms, list):
    for m in ms:
        p = m.get("platform") or {}
        if p.get("architecture") == "amd64" and p.get("os") == "linux":
            print(m.get("digest", "")); break
    else:
        sys.exit(1)
else:
    print("sha256:" + hashlib.sha256(raw).hexdigest())
'
}

_remote_digest() {   # <ref>
    local ref="$1" raw="" i dg
    for i in 1 2 3; do
        raw="$(skopeo inspect --raw --authfile "${AUTH_FILE}" "${_harbor_tls_args_inspect[@]}" \
            "docker://${ref}" 2>/dev/null || true)"
        [ -n "${raw}" ] && break
        sleep $((i * 2))
    done
    [ -n "${raw}" ] || return 1
    dg="$(printf '%s' "${raw}" | _digest_normalize)" || return 1
    [ -n "${dg}" ] || return 1
    printf '%s\n' "${dg}"
}

# docker-archive 的 raw manifest 可能是 transport 合成的, 其 digest 不等于 registry
# manifest digest; 用 image config digest 校验内容一致。
_remote_config_digest() {   # <ref> <manifest_digest>
    # digest 引用必须是 repo@sha256:..., 不能带 :tag
    local base="$1"
    case "${base##*/}" in *:*) base="${base%:*}" ;; esac
    skopeo inspect --raw --authfile "${AUTH_FILE}" "${_harbor_tls_args_inspect[@]}" \
        "docker://${base}@$2" 2>/dev/null |
        python3 -c '
import json, sys
d = json.load(sys.stdin)
digest = (d.get("config") or {}).get("digest", "")
if not digest:
    sys.exit(1)
print(digest)
'
}

_tar_config_digest() {   # <tar>
    skopeo inspect --raw "docker-archive:$1" 2>/dev/null |
        python3 -c '
import json, sys
d = json.load(sys.stdin)
digest = (d.get("config") or {}).get("digest", "")
if not digest:
    sys.exit(1)
print(digest)
'
}

_save_tar() {   # <pull_ref> <save_ref> <out_tar>
    local pull="$1" save="$2" out="$3" i
    for i in 1 2 3; do
        rm -f "${out}" "${out}.err"
        if timeout "${SKOPEO_TIMEOUT_SECONDS}" skopeo copy --quiet --retry-times 3 \
            --authfile "${AUTH_FILE}" "${_harbor_tls_args_src[@]}" "${_dest_tls_args[@]}" \
            --override-os linux --override-arch amd64 \
            "docker://${pull}" "docker-archive:${out}:${save}" 2>"${out}.err"; then
            rm -f "${out}.err"; return 0
        fi
        [ "${i}" -lt 3 ] && warn "  skopeo copy 失败(第 ${i}/3 次): $(tail -1 "${out}.err" 2>/dev/null | head -c 160)"
        sleep $((i * 3))
    done
    return 1
}

_upload() {   # <local_file> <remote_path>
    local f="$1" remote="$2" lsize rsize
    lsize="$(stat -c%s "${f}")" || return 1
    _mc cp --quiet "${f}" "${remote}" || return 1
    rsize="$(_mc stat --json "${remote}" 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("size",""))' 2>/dev/null || true)"
    if [ -n "${rsize}" ] && [ "${rsize}" != "${lsize}" ]; then
        bad "  远端大小不一致: ${remote} (local=${lsize} remote=${rsize})"; return 1
    fi
    return 0
}

_disk_ok() {
    local avail_kb need_kb
    avail_kb="$(df -Pk "${WORK_DIR}" | awk 'NR==2{print $4}')"
    need_kb=$((MIN_FREE_GB * 1024 * 1024))
    [ "${avail_kb:-0}" -ge "${need_kb}" ]
}

_preflight() {
    _require skopeo; _require "${MC_BIN}"; _require python3; _require timeout; _require curl
    _minio_env || return 1
    _harbor_auth || return 1

    local code curl_opts=(-s -o /dev/null -m 8 -w '%{http_code}')
    [ "${HARBOR_INSECURE}" = "true" ] && curl_opts+=(-k)
    code="$(curl "${curl_opts[@]}" "https://${HARBOR_HOST}/v2/" 2>/dev/null || true)"
    case "${code}" in 200|401|403) ok "Harbor 可达: ${HARBOR_HOST} (HTTP ${code})" ;;
        *) bad "Harbor 不可达: https://${HARBOR_HOST}/v2/ (HTTP ${code:-000})"; return 1 ;; esac

    if _mc ls "${MC_ALIAS}/${MINIO_BUCKET}" >/dev/null 2>&1; then
        ok "MinIO 可达: ${MINIO_BUCKET}"
    else
        bad "MinIO 不可达或 bucket 不存在: ${MINIO_BUCKET}"; return 1
    fi
    if ! _disk_ok; then
        bad "磁盘空间不足: 需要至少 ${MIN_FREE_GB} GiB (${WORK_DIR})"; return 1
    fi
    ok "磁盘空间充足"

    local public_ref="" private_ref="" _c _s _f _p _sv _i _e
    while IFS='|' read -r _c _s _f _p _sv _i _e; do
        case "${_p}" in
            */suanova-private/*) [ -z "${private_ref}" ] && private_ref="${_p}" ;;
            *)                   [ -z "${public_ref}" ] && public_ref="${_p}" ;;
        esac
    done < "${ROWS_FILE}"
    [ -n "${public_ref}" ] && { _remote_digest "${public_ref}" >/dev/null \
        || { bad "无法读取远端 manifest: ${public_ref}"; return 1; }; ok "public 镜像可读"; }
    [ -n "${private_ref}" ] && { _remote_digest "${private_ref}" >/dev/null \
        || { bad "无法读取私有 manifest(检查凭据): ${private_ref}"; return 1; }; ok "private 镜像可读"; }
    return 0
}

AUTH_FILE="${WORK_DIR}/auth.json"
trap 'rm -f "${AUTH_FILE}"; rm -rf "${WORK_DIR}/.mc"' EXIT

if [ "${PREFLIGHT}" = "1" ] || [ "${DRY_RUN}" = "1" ]; then
    _preflight || exit 1
    [ "${PREFLIGHT}" = "1" ] && [ "${DRY_RUN}" = "0" ] && { ok "预检通过"; exit 0; }
fi

_require skopeo; _require "${MC_BIN}"; _require python3; _require timeout
_minio_env || exit 1
_harbor_auth || exit 1

# ---------- 主循环 ----------
UPDATED=0; SKIPPED=0; FAILED=0
FAIL_ROWS=()
: > "${WORK_DIR}/summary.md"
{
    echo "## latest offline refresh"
    echo ""
    echo "| collection | subdir | image | action | digest | file |"
    echo "|---|---|---|---|---|---|"
} >> "${WORK_DIR}/summary.md"

while IFS='|' read -r collection subdir file pull save image extra_tags; do
    _disp_subdir="$subdir"; [ "${_disp_subdir}" = "." ] && _disp_subdir="(top)"
    say "[${collection}/${_disp_subdir}] ${image}"

    remote_digest="$(_remote_digest "${pull}")" \
        || { bad "  无法读取远端 manifest: ${pull}"; FAILED=$((FAILED+1)); FAIL_ROWS+=("${image}: manifest"); continue; }

    local_sidecar="$(_remote_sidecar "${collection}" "${subdir}" "${file}")"
    need=0; reason=""
    if [ "${FORCE}" = "1" ]; then
        need=1; reason="force"
    elif [ -z "${local_sidecar}" ]; then
        need=1; reason="no sidecar"
    elif [ "${local_sidecar}" != "${remote_digest}" ]; then
        need=1; reason="digest changed"
    elif ! _remote_tar_exists "${collection}" "${subdir}" "${file}"; then
        need=1; reason="tar missing"
    fi

    sha_file=""; sha_ref=""
    if [ "${extra_tags}" = "sha" ]; then
        if [ -z "${SHA}" ]; then
            bad "  extra_tags=sha 但没有 --sha(payload 缺 sha?)"
            FAILED=$((FAILED+1)); FAIL_ROWS+=("${image}: missing sha"); continue
        fi
        sha_ref="${save%:*}:${SHA}"
        sha_file="$(image_tar_name "${sha_ref}")"
        if ! _remote_tar_exists "${collection}" "${subdir}" "${sha_file}"; then
            need=1; reason="${reason:-sha tar missing}"
        fi
    fi

    if [ "${need}" = "0" ]; then
        ok "  SKIP (${remote_digest})"; SKIPPED=$((SKIPPED+1))
        printf '| %s | %s | %s | SKIP | `%s` | %s |\n' \
            "${collection}" "${subdir}" "${image}" "${remote_digest}" "${file}" >> "${WORK_DIR}/summary.md"
        continue
    fi

    if [ "${SEAL_MISSING}" = "1" ] && [ -z "${local_sidecar}" ] && [ "${FORCE}" != "1" ] \
        && _remote_tar_exists "${collection}" "${subdir}" "${file}"; then
        printf '%s' "${remote_digest}" > "${WORK_DIR}/${file}.digest"
        if _upload "${WORK_DIR}/${file}.digest" "$(_remote_path "${collection}" "${subdir}" "${file}.digest")"; then
            ok "  已补边车(seal-missing): ${file}.digest"; SKIPPED=$((SKIPPED+1))
            printf '| %s | %s | %s | SEAL | `%s` | %s |\n' \
                "${collection}" "${subdir}" "${image}" "${remote_digest}" "${file}" >> "${WORK_DIR}/summary.md"
            rm -f "${WORK_DIR}/${file}.digest"; continue
        fi
        rm -f "${WORK_DIR}/${file}.digest"; warn "  边车补写失败, 继续重拉"
    fi

    if [ "${DRY_RUN}" = "1" ]; then
        ok "  DRY-RUN: 将更新 (${reason}; ${remote_digest})"; UPDATED=$((UPDATED+1))
        printf '| %s | %s | %s | DRY-RUN %s | `%s` | %s |\n' \
            "${collection}" "${subdir}" "${image}" "${reason}" "${remote_digest}" "${file}" >> "${WORK_DIR}/summary.md"
        continue
    fi

    tmpdir="$(mktemp -d "${WORK_DIR}/tmp.XXXXXX")" || { bad "  mktemp 失败"; FAILED=$((FAILED+1)); continue; }
    tmp_tar="${tmpdir}/${file}"; row_failed=0
    say "  更新 (${reason}) → ${MINIO_REMOTE_DIR}/${collection}/${subdir}/${file}"
    if ! _save_tar "${pull}" "${save}" "${tmp_tar}"; then
        bad "  skopeo copy 失败: ${pull}"; row_failed=1
    fi
    if [ "${row_failed}" = "0" ]; then
        expected_config="$(_remote_config_digest "${pull}" "${remote_digest}")" || expected_config=""
        actual_config="$(_tar_config_digest "${tmp_tar}")"
        if [ -z "${expected_config}" ] || [ -z "${actual_config}" ] \
            || [ "${actual_config}" != "${expected_config}" ]; then
            bad "  tar config digest 不匹配(远端 ${expected_config:-空}, tar ${actual_config:-空})"; row_failed=1
        fi
    fi
    if [ "${row_failed}" = "0" ]; then
        recheck="$(_remote_digest "${pull}")"
        if [ -n "${recheck}" ] && [ "${recheck}" != "${remote_digest}" ]; then
            warn "  latest 在下载期间前进(${remote_digest} → ${recheck}), 放弃本轮上传"; row_failed=1
        fi
    fi
    if [ "${row_failed}" = "0" ]; then
        printf '%s' "${remote_digest}" > "${tmp_tar}.digest"
        if _upload "${tmp_tar}" "$(_remote_path "${collection}" "${subdir}" "${file}")" \
            && _upload "${tmp_tar}.digest" "$(_remote_path "${collection}" "${subdir}" "${file}.digest")"; then
            ok "  已更新: ${file}"
        else
            bad "  上传失败: ${file}"; row_failed=1
        fi
    fi
    if [ "${row_failed}" = "0" ] && [ -n "${sha_file}" ]; then
        sha_tar="${tmpdir}/${sha_file}"
        sha_remote_digest="$(_remote_digest "${sha_ref}")" || sha_remote_digest=""
        sha_expected_config=""
        if [ -n "${sha_remote_digest}" ]; then
            sha_expected_config="$(_remote_config_digest "${sha_ref}" "${sha_remote_digest}")" \
                || sha_expected_config=""
        fi
        if [ -n "${sha_expected_config}" ] && _save_tar "${sha_ref}" "${sha_ref}" "${sha_tar}"; then
            sha_actual="$(_tar_config_digest "${sha_tar}")"
            if [ -n "${sha_actual}" ] && [ "${sha_actual}" = "${sha_expected_config}" ]; then
                printf '%s' "${sha_remote_digest}" > "${sha_tar}.digest"
                if _upload "${sha_tar}" "$(_remote_path "${collection}" "${subdir}" "${sha_file}")" \
                    && _upload "${sha_tar}.digest" "$(_remote_path "${collection}" "${subdir}" "${sha_file}.digest")"; then
                    ok "  已更新 SHA tar: ${sha_file}"
                else
                    bad "  上传失败: ${sha_file}"; row_failed=1
                fi
            else
                bad "  SHA tar digest 不匹配: ${sha_file}"; row_failed=1
            fi
        else
            bad "  SHA tar 生成失败(检查 ${sha_ref}): ${sha_file}"; row_failed=1
        fi
    fi

    rm -rf "${tmpdir}"
    if [ "${row_failed}" = "0" ]; then
        UPDATED=$((UPDATED+1))
        printf '| %s | %s | %s | UPDATE | `%s` | %s |\n' \
            "${collection}" "${subdir}" "${image}" "${remote_digest}" "${file}" >> "${WORK_DIR}/summary.md"
    else
        FAILED=$((FAILED+1)); FAIL_ROWS+=("${image}")
        printf '| %s | %s | %s | FAIL | `%s` | %s |\n' \
            "${collection}" "${subdir}" "${image}" "${remote_digest}" "${file}" >> "${WORK_DIR}/summary.md"
    fi
done < "${ROWS_FILE}"

{
    echo ""
    echo "**updated=${UPDATED} skipped=${SKIPPED} failed=${FAILED}**"
} >> "${WORK_DIR}/summary.md"

if [ -n "${SUMMARY_FILE}" ]; then cat "${WORK_DIR}/summary.md" > "${SUMMARY_FILE}"; fi
echo "---------------------------------------------"
ok "完成: 更新 ${UPDATED}, 跳过 ${SKIPPED}, 失败 ${FAILED}"
if [ "${FAILED}" -gt 0 ]; then
    for f in "${FAIL_ROWS[@]}"; do echo "  - ${f}" >&2; done
    exit 1
fi
exit 0
