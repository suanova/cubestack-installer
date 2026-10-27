#!/bin/bash
# ============================================================
# release-sync-images.sh — release-2.0 组件镜像原地刷新(Harbor → MinIO)
# ------------------------------------------------------------
# 用途: 在**已发布**的 <bucket>/<release>/offline-files/ 发布树上, 原地刷新
#       cubestack-operator 集合的镜像 tar/operator chart/CLI tar, 并按
#       tar/digest → release.env/release.json → SHA256SUMS → _SUCCESS 的顺序
#       重建校验元数据。
#
# 设计边界:
#   · 只写 <bucket>/<release>/; 不碰 dev offline-files/;
#   · 只刷新 cubestack-operator 集合(37 个镜像) + operator chart + CLI tar;
#     dev-lab/model-collection/kubespray 等仍走完整 release-publish.sh;
#   · 刷新期间删除 _SUCCESS: fetch 会明确失败而不是拿半套树;
#   · 失败保留 <release>/_REFRESH_PENDING 且无 _SUCCESS, 下次同 scope/all 重跑修复;
#   · 不改 release.json 的 built_at; 只追加 refreshed_*.
#
# 用法:
#   release-sync-images.sh --release 2.0.0 --component all [选项]
#   release-sync-images.sh --release 2.0.0 --component publish --source-dir /path
#   release-sync-images.sh --release 2.0.0 --component cli \
#       --cli-tar /path/cubestack-installer-cli-v2.0.0.tar --cli-image-digest sha256:...
#     (cli = 仅刷新 CLI tar + release.json/SHA256SUMS/_SUCCESS; 不处理镜像/chart)
#
# 选项:
#   --release/--release-dir/--component/--tag/--source-repo
#   --source-dir/--save-tool/--chart-tgz/--chart-digest/--cli-tar/--cli-image-digest
#   --force/--preflight/--dry-run/--recover/--keep-stale/--first-party-only
#   --no-verify-remote/--min-free-gb/--summary-file
#
# 环境变量: MINIO_ENDPOINT/ACCESS_KEY/SECRET_KEY/BUCKET/INSECURE,
#   HARBOR_MIRROR_REGISTRY/USER/PASSWORD/INSECURE, MC_BIN, MINIO_CONF.
# ============================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../../../.." && pwd)"
IMAGES_DIR="${SELF_DIR}"
DEFAULT_SAVE_TOOL="${IMAGES_DIR}/cubestack-platform-save-images.sh"

say()  { printf '\033[36m→  %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✅ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m⚠  %s\033[0m\n' "$*" >&2; }
err()  { printf '\033[31m【错误】%s\033[0m\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() { sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

RELEASE=""
RELEASE_DIR=""
COMPONENT="all"
TAG=""
SOURCE_REPO=""
SOURCE_DIR=""
SAVE_TOOL="${DEFAULT_SAVE_TOOL}"
CHART_TGZ_IN=""
CHART_DIGEST_IN=""
CLI_TAR_IN=""
CLI_DIGEST_IN=""
FORCE=0
PREFLIGHT=0
DRY_RUN=0
RECOVER=0
KEEP_STALE=0
FIRST_PARTY_ONLY=0
VERIFY_REMOTE=1
MIN_FREE_GB=10
SUMMARY_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --release) RELEASE="${2:?--release 需要版本号}"; shift 2 ;;
        --release-dir) RELEASE_DIR="${2:?--release-dir 需要目录}"; shift 2 ;;
        --component) COMPONENT="${2:?--component 需要值}"; shift 2 ;;
        --tag) TAG="${2:?--tag 需要值}"; shift 2 ;;
        --source-repo) SOURCE_REPO="${2:?--source-repo 需要值}"; shift 2 ;;
        --source-dir) SOURCE_DIR="${2:?--source-dir 需要目录}"; shift 2 ;;
        --save-tool) SAVE_TOOL="${2:?--save-tool 需要路径}"; shift 2 ;;
        --chart-tgz) CHART_TGZ_IN="${2:?--chart-tgz 需要路径}"; shift 2 ;;
        --chart-digest) CHART_DIGEST_IN="${2:?--chart-digest 需要路径}"; shift 2 ;;
        --cli-tar) CLI_TAR_IN="${2:?--cli-tar 需要路径}"; shift 2 ;;
        --cli-image-digest) CLI_DIGEST_IN="${2:?--cli-image-digest 需要值}"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --preflight) PREFLIGHT=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --recover) RECOVER=1; shift ;;
        --keep-stale) KEEP_STALE=1; shift ;;
        --first-party-only) FIRST_PARTY_ONLY=1; shift ;;
        --no-verify-remote) VERIFY_REMOTE=0; shift ;;
        --min-free-gb) MIN_FREE_GB="${2:?--min-free-gb 需要值}"; shift 2 ;;
        --summary-file) SUMMARY_FILE="${2:?--summary-file 需要路径}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

[ -n "${RELEASE}" ] || { usage; die "缺少 --release"; }
case "${RELEASE}" in
    ''|.|..|*[!0-9A-Za-z._-]*) die "非法 release: ${RELEASE}" ;;
esac
[ -n "${COMPONENT}" ] || die "缺少 --component"
case "${MIN_FREE_GB}" in ''|*[!0-9]*) die "非法 --min-free-gb: ${MIN_FREE_GB}" ;; esac
if [ -n "${TAG}" ]; then
    case "${TAG}" in *[!0-9A-Za-z._-]*) die "非法 tag: ${TAG}" ;; esac
fi
if [ -n "${SOURCE_REPO}" ]; then
    case "${SOURCE_REPO}" in *[!0-9A-Za-z._/-]*|*..*) die "非法 source_repo: ${SOURCE_REPO}" ;; esac
fi

RELEASE_DIR="${RELEASE_DIR:-${REPO_ROOT}/deployments/releases/${RELEASE}}"
REL_ENV="${RELEASE_DIR}/release.env"
REL_TSV="${RELEASE_DIR}/release-images.tsv"
REL_COMPONENTS="${RELEASE_DIR}/components.tsv"
[ -f "${REL_ENV}" ] || die "缺少 release.env: ${REL_ENV}"
[ -f "${REL_TSV}" ] || die "缺少 release-images.tsv: ${REL_TSV}"
[ -f "${REL_COMPONENTS}" ] || die "缺少 components.tsv: ${REL_COMPONENTS}"
[ -f "${SAVE_TOOL}" ] || die "缺少镜像保存工具: ${SAVE_TOOL}"
[ -d "${SOURCE_DIR:-/nonexistent}" ] || [ -z "${SOURCE_DIR}" ] || die "source-dir 不存在: ${SOURCE_DIR}"

# release.env 是版本真相; 导出后子工具自然采用
set -a
# shellcheck disable=SC1090
. "${REL_ENV}"
set +a
[ "${RELEASE_VERSION:-}" = "${RELEASE}" ] || die "release.env 版本不符: ${RELEASE_VERSION:-<空>} != ${RELEASE}"
OP_TAG="${CUBESTACK_OPERATOR_IMAGE_TAG:-}"
CHART_VER="${CUBESTACK_OPERATOR_CHART_VERSION:-}"
CLI_IMAGE="${CUBESTACK_CLI_IMAGE:-}"
[ -n "${OP_TAG}" ] || warn "release.env 未设置 CUBESTACK_OPERATOR_IMAGE_TAG"
[ -n "${CHART_VER}" ] || warn "release.env 未设置 CUBESTACK_OPERATOR_CHART_VERSION"
case "${OP_TAG}" in *[!0-9A-Za-z._-]*) die "非法 CUBESTACK_OPERATOR_IMAGE_TAG: ${OP_TAG}" ;; esac
case "${CHART_VER}" in *[!0-9A-Za-z._-]*) die "非法 CUBESTACK_OPERATOR_CHART_VERSION: ${CHART_VER}" ;; esac

HARBOR_HOST="${HARBOR_MIRROR_REGISTRY:-harbor.isuanova.com}"
HARBOR_INSECURE="${HARBOR_MIRROR_INSECURE:-false}"
[ "${HARBOR_INSECURE}" = "true" ] && export SAVE_TLS_VERIFY=false
MC_BIN="${MC_BIN:-mc}"
MC_ALIAS="${MC_ALIAS:-}"
MINIO_BUCKET="${MINIO_BUCKET:-cubestack-installer}"
MC_GLOBAL=()
[ "${MINIO_INSECURE:-false}" = "true" ] && MC_GLOBAL+=(--insecure)

SUMMARY=""
_add_summary() { SUMMARY+="$1"$'\n'; }
_flush_summary() {
    [ -n "${SUMMARY_FILE}" ] || return 0
    printf '%s' "${SUMMARY}" > "${SUMMARY_FILE}" 2>/dev/null || warn "无法写 summary: ${SUMMARY_FILE}"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cubestack-release-sync.XXXXXX")"
AUTH_TMP=""
_cleanup() {
    [ -n "${AUTH_TMP}" ] && rm -f "${AUTH_TMP}" 2>/dev/null || true
    rm -rf "${WORK}" 2>/dev/null || true
}
trap _cleanup EXIT

# ---------- 基础命令/工具 ----------
_need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }
_need_cmd python3
_need_cmd sha256sum
_need_cmd tar
_need_cmd "${MC_BIN}"

mcrun() { "${MC_BIN}" ${MC_GLOBAL[@]+"${MC_GLOBAL[@]}"} "$@"; }
_remote() { printf '%s/%s/%s' "${MC_ALIAS}" "${MINIO_BUCKET}" "${RELEASE}"; }

_remote_exists() { mcrun stat "$1" >/dev/null 2>&1; }
_remote_size() {
    mcrun stat --json "$1" 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    d=d[0] if isinstance(d,list) else d
    print(int(d.get("size",0)))
except Exception:
    pass
' 2>/dev/null || true
}
_remote_sha() { mcrun cat "$1" 2>/dev/null | sha256sum | awk '{print $1}'; }
_remote_cat() { mcrun cat "$1" 2>/dev/null; }

# ---------- MinIO ----------
_load_minio_conf() {
    local conf="${MINIO_CONF:-${REPO_ROOT}/deployments/config/minio.conf}"
    if [ -f "${conf}" ]; then
        # shellcheck disable=SC1090
        set -a; . "${conf}"; set +a
    fi
}
_mc_init() {
    _load_minio_conf
    MC_ALIAS="${MC_ALIAS:-${MINIO_ALIAS:-cubestacksync}}"
    MINIO_BUCKET="${MINIO_BUCKET:-cubestack-installer}"
    MC_GLOBAL=()
    [ "${MINIO_INSECURE:-false}" = "true" ] && MC_GLOBAL+=(--insecure)
    [ -n "${MINIO_ENDPOINT:-}" ] || die "缺少 MINIO_ENDPOINT"
    [ -n "${MINIO_ACCESS_KEY:-}" ] || die "缺少 MINIO_ACCESS_KEY"
    [ -n "${MINIO_SECRET_KEY:-}" ] || die "缺少 MINIO_SECRET_KEY"
    export MC_CONFIG_DIR="${WORK}/mc"
    mkdir -p "${MC_CONFIG_DIR}"
    mcrun alias set "${MC_ALIAS}" "${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" >/dev/null 2>&1 \
        || die "mc alias 配置失败(检查 MINIO_ENDPOINT/凭证)"
    mcrun ls "${MC_ALIAS}/${MINIO_BUCKET}" >/dev/null 2>&1 \
        || die "MinIO 桶不可访问: ${MINIO_BUCKET}"
}
_mc_init
REMOTE_ROOT="$(_remote)"
REMOTE_OFF="${REMOTE_ROOT}/offline-files"
MARKER="${REMOTE_ROOT}/_REFRESH_PENDING"
CLI_MARKER="${REMOTE_ROOT}/_CLI_IMAGE_DIGEST"

if [ "${MIN_FREE_GB}" -gt 0 ] && [ "${PREFLIGHT}" = "0" ] && [ "${DRY_RUN}" = "0" ]; then
    _avail_gb="$(( $(df -Pk "${WORK}" | awk 'NR==2{print $4}') / 1024 / 1024 ))"
    [ "${_avail_gb}" -ge "${MIN_FREE_GB}" ] \
        || die "磁盘空间不足: ${_avail_gb}G 可用 < ${MIN_FREE_GB}G(可用 --min-free-gb 调整)"
fi

# ---------- Harbor 认证(skopeo/helm) ----------
# ★ 2026-10-26 CodeRabbit: 凭据必须**成对**选择 —— 旧实现 user 取 mirror、password 单独回落
#   operator, 会拼出 "HARBOR_MIRROR_USER + CUBESTACK_OPERATOR_HARBOR_PASSWORD" 的无效组合;
#   即使 operator 凭据对完整, 认证仍会失败并阻断刷新。规则:
#     ① mirror 对完整 → 用 mirror 对;
#     ② 否则 operator 对完整 → 用 operator 对;
#     ③ 都不完整 → 空(不认证, 回退 docker config/匿名), 绝不跨来源混搭。
_harbor_pick_pair() {
    _HARBOR_USER=""; _HARBOR_PASS=""
    if [ -n "${HARBOR_MIRROR_USER:-}" ] && [ -n "${HARBOR_MIRROR_PASSWORD:-}" ]; then
        _HARBOR_USER="${HARBOR_MIRROR_USER}"; _HARBOR_PASS="${HARBOR_MIRROR_PASSWORD}"; return 0
    fi
    if [ -n "${CUBESTACK_OPERATOR_HARBOR_USER:-}" ] && [ -n "${CUBESTACK_OPERATOR_HARBOR_PASSWORD:-}" ]; then
        _HARBOR_USER="${CUBESTACK_OPERATOR_HARBOR_USER}"; _HARBOR_PASS="${CUBESTACK_OPERATOR_HARBOR_PASSWORD}"; return 0
    fi
    if [ -n "${HARBOR_MIRROR_USER:-}${HARBOR_MIRROR_PASSWORD:-}" ]; then
        warn "HARBOR_MIRROR_USER/PASSWORD 仅配置一项 → 忽略该不完整凭据对(不会与 operator 凭据混搭)"
    fi
}
_harbor_pick_pair
_harbor_auth() {
    if [ -n "${REGISTRY_AUTH_FILE:-}" ] && [ -f "${REGISTRY_AUTH_FILE}" ]; then
        printf '%s\n' "${REGISTRY_AUTH_FILE}"; return 0
    fi
    if [ -n "${_HARBOR_USER}" ] && [ -n "${_HARBOR_PASS}" ]; then
        AUTH_TMP="$(mktemp "${WORK}/harbor-auth.XXXXXX")"; chmod 600 "${AUTH_TMP}"
        _HU="${_HARBOR_USER}" _HP="${_HARBOR_PASS}" _HH="${HARBOR_HOST}" python3 - "${AUTH_TMP}" <<'PY'
import base64, json, os, sys
auth = base64.b64encode(f"{os.environ['_HU']}:{os.environ['_HP']}".encode()).decode()
json.dump({"auths": {os.environ["_HH"]: {"auth": auth}}}, open(sys.argv[1], "w"))
PY
        printf '%s\n' "${AUTH_TMP}"; return 0
    fi
    if [ -f "${HOME}/.docker/config.json" ]; then
        printf '%s\n' "${HOME}/.docker/config.json"; return 0
    fi
    return 1
}
_skopeo_args=()
_skopeo_init() {
    local af
    af="$(_harbor_auth)" || return 1
    _skopeo_args=(--authfile "${af}")
    if [ "${HARBOR_INSECURE}" = "true" ]; then
        _skopeo_args+=(--tls-verify=false)
    fi
}
_skopeo_raw_digest() {   # <ref> -> sha256:...
    _need_cmd skopeo
    local raw
    raw="$(skopeo inspect --raw ${_skopeo_args[@]+"${_skopeo_args[@]}"} "docker://$1" 2>/dev/null)" || return 1
    [ -n "${raw}" ] || return 1
    printf 'sha256:%s' "$(printf '%s' "${raw}" | sha256sum | awk '{print $1}')"
}
_skopeo_copy_cli() {     # <ref> <out.tar>
    _need_cmd skopeo
    skopeo copy --retry-times 3 --override-os linux --override-arch amd64 \
        ${_skopeo_args[@]+"${_skopeo_args[@]}"} \
        "docker://$1" "docker-archive:$2:$1" >/dev/null 2>&1
}

# ---------- 远端元数据(preflight) ----------
mkdir -p "${WORK}/remote" "${WORK}/img" "${WORK}/chart" "${WORK}/cli" "${WORK}/allowed"
_need_cmd "${MC_BIN}"

_remote_cat "${REMOTE_OFF}/SHA256SUMS" > "${WORK}/SHA256SUMS" 2>/dev/null || true
_remote_cat "${REMOTE_OFF}/release.env" > "${WORK}/release.env" 2>/dev/null || true
_remote_cat "${REMOTE_OFF}/release.json" > "${WORK}/release.json" 2>/dev/null || true
[ -s "${WORK}/SHA256SUMS" ] || die "发布树不完整: 缺少 ${REMOTE_OFF}/SHA256SUMS"
[ -s "${WORK}/release.env" ] || die "发布树不完整: 缺少 ${REMOTE_OFF}/release.env"
[ -s "${WORK}/release.json" ] || die "发布树不完整: 缺少 ${REMOTE_OFF}/release.json"

# SHA256SUMS 格式校验
python3 - "${WORK}/SHA256SUMS" <<'PY' || die "SHA256SUMS 格式非法"
import re, sys
seen = set()
n = 0
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        m = re.match(r"^([0-9a-f]{64})  \./(.+)$", line)
        if not m:
            print(f"bad line: {line!r}", file=sys.stderr); sys.exit(1)
        p = m.group(2)
        if p in (".", "SHA256SUMS", "_SUCCESS") or ".." in p.split("/") or p.startswith("/"):
            print(f"bad path: {p!r}", file=sys.stderr); sys.exit(1)
        if p in seen:
            print(f"duplicate path: {p!r}", file=sys.stderr); sys.exit(1)
        seen.add(p); n += 1
if n == 0:
    print("empty SHA256SUMS", file=sys.stderr); sys.exit(1)
PY

# release.env 版本
remote_ver="$(sed -nE 's/^RELEASE_VERSION=([^[:space:]#]+).*/\1/p' "${WORK}/release.env" | head -1)"
[ "${remote_ver}" = "${RELEASE}" ] || die "release.env 版本不符: ${remote_ver:-<空>} != ${RELEASE}"

# release.json 解析
IFS=$'\t' read -r CLI_TAR_NAME CLI_TAR_SHA CLI_TAR_SIZE < <(python3 - "${WORK}/release.json" <<'PY'
import json, os, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print("", "", "", sep="\t"); sys.exit(0)
name = os.path.basename(str(d.get("cli_tar") or "").strip())
sha = str(d.get("cli_tar_sha256") or "").replace("sha256:", "").strip()
size = d.get("cli_tar_size", "")
if not name:
    name = ""
if not isinstance(size, int):
    size = ""
print(name, sha, size, sep="\t")
PY
)
CLI_TAR_NAME="${CLI_TAR_NAME:-cubestack-installer-cli-v${RELEASE#v}.tar}"
case "${CLI_TAR_NAME}" in
    ''|.|..|*/*|*[!0-9A-Za-z._-]*) die "release.json cli_tar 非法: ${CLI_TAR_NAME}" ;;
esac
[ -n "${CLI_TAR_SHA}" ] || die "release.json 缺少 cli_tar_sha256"
CLI_TAR_REMOTE="${REMOTE_ROOT}/${CLI_TAR_NAME}"

# _SUCCESS / marker
SUCCESS_EXISTS=0
RECOVER_MODE=0
MARKER_SUBDIRS=""
MARKER_COMPONENT=""
MARKER_STALE=""
if _remote_exists "${MARKER}"; then
    _remote_cat "${MARKER}" > "${WORK}/marker.json" || die "无法读取 ${MARKER}"
    IFS=$'\t' read -r MARKER_COMPONENT MARKER_SUBDIRS MARKER_STALE < <(python3 - "${WORK}/marker.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("\t\t"); sys.exit(0)
comp = str(d.get("component") or "")
subs = " ".join(sorted({str(x) for x in (d.get("subdirs") or []) if str(x)}))
stale = " ".join(sorted({str(x) for x in (d.get("stale") or []) if str(x)}))
print(comp, subs, stale, sep="\t")
PY
)
    [ -n "${MARKER_COMPONENT}" ] || die "marker 缺少 component: ${MARKER}"
    RECOVER_MODE=1
    warn "检测到未完成刷新 marker: component=${MARKER_COMPONENT} subdirs=${MARKER_SUBDIRS} stale=${MARKER_STALE:-none}"
fi
if _remote_exists "${REMOTE_OFF}/_SUCCESS"; then
    _remote_cat "${REMOTE_OFF}/_SUCCESS" > "${WORK}/_SUCCESS"
    SUCCESS_EXISTS=1
    python3 - "${WORK}/_SUCCESS" "${WORK}/SHA256SUMS" "${RELEASE}" <<'PY' || die "_SUCCESS 校验失败"
import hashlib, sys
want_release, sums, release = sys.argv[3], sys.argv[2], sys.argv[3]
d = {}
for line in open(sys.argv[1], encoding="utf-8"):
    if "=" in line:
        k, v = line.rstrip("\n").split("=", 1); d[k] = v
sha = hashlib.sha256(open(sums, "rb").read()).hexdigest()
if d.get("release") not in (None, release):
    print(f"release mismatch: {d.get('release')} != {release}", file=sys.stderr); sys.exit(1)
if d.get("sha256sums") != sha:
    print(f"sha256sums mismatch: {d.get('sha256sums')} != {sha}", file=sys.stderr); sys.exit(1)
PY
elif [ "${RECOVER_MODE}" = "1" ]; then
    warn "_SUCCESS 缺失但存在 _REFRESH_PENDING: 进入恢复模式"
elif [ "${RECOVER}" = "1" ]; then
    warn "_SUCCESS 缺失且无 marker: --recover 手动恢复模式"
    RECOVER_MODE=1
else
    die "发布未完成/刷新中断: ${REMOTE_OFF}/_SUCCESS 不存在(没有 marker; 如确认手动恢复请加 --recover)"
fi

# ---------- components.tsv + release-images.tsv 选择/校验 ----------
python3 - "${REL_COMPONENTS}" "${REL_TSV}" "${COMPONENT}" "${TAG}" "${SOURCE_REPO}" \
    "${HARBOR_HOST}" "${OP_TAG}" "${FIRST_PARTY_ONLY}" "${WORK}" <<'PY' || die "组件/镜像清单校验失败"
import json, os, re, sys

comp_file, tsv_file, comp_arg, dispatch_tag, source_repo, harbor, op_tag, first_only, out = sys.argv[1:]
first_only = first_only == "1"

def rows(path):
    out = []
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 4:
                print(f"{path}:{lineno}: 列不足", file=sys.stderr); sys.exit(1)
            sub, file, pull, save = parts[0], parts[1], parts[2], parts[3]
            if not sub: sub = "."
            if sub != "." and not re.match(r"^[A-Za-z0-9._-]+$", sub):
                print(f"{path}:{lineno}: 非法 subdir: {sub!r}", file=sys.stderr); sys.exit(1)
            if not file or "/" in file or file in (".", ".."):
                print(f"{path}:{lineno}: 非法 file: {file!r}", file=sys.stderr); sys.exit(1)
            if not pull: pull = save
            out.append({"subdir": sub, "file": file, "pull": pull, "save": save, "line": lineno})
    return out

def tar_name(ref):
    return ref.replace("/", "_").replace(":", "_") + ".tar"

def ref_tag(ref):
    if "@" in ref:
        return None
    if ":" not in ref.rsplit("/", 1)[-1]:
        return None
    return ref.rsplit(":", 1)[1]

comps = {}
with open(comp_file, encoding="utf-8") as f:
    for lineno, line in enumerate(f, 1):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            print(f"{comp_file}:{lineno}: 列不足", file=sys.stderr); sys.exit(1)
        name, repo, subs = parts[0], parts[1], parts[2]
        if name in comps:
            print(f"{comp_file}:{lineno}: component 重复: {name}", file=sys.stderr); sys.exit(1)
        comps[name] = {"repo": repo, "subdirs": subs.split()}

trows = rows(tsv_file)
all_subdirs = sorted({r["subdir"] for r in trows})

selected = []
for c in [x.strip() for x in comp_arg.split(",") if x.strip()]:
    if c not in comps:
        print(f"未知 component: {c}", file=sys.stderr); sys.exit(1)
    if c not in selected:
        selected.append(c)
if not selected:
    print("component 为空", file=sys.stderr); sys.exit(1)

selected_subdirs = []
chart_only = False
cli_only = False
for c in selected:
    subs = comps[c]["subdirs"]
    if subs == ["*"]:
        selected_subdirs.extend(all_subdirs)
    elif subs == ["-"]:
        chart_only = True
    elif subs == ["cli"]:
        cli_only = True
    else:
        selected_subdirs.extend(subs)
selected_subdirs = sorted(set(selected_subdirs))

# 非 -/* 的 subdir 必须在 tvs 中出现
for d in selected_subdirs:
    if d not in all_subdirs:
        print(f"component 子目录不存在于 release-images.tsv: {d}", file=sys.stderr); sys.exit(1)

# source_repo 归属校验
if source_repo:
    for c in selected:
        repo = comps[c]["repo"]
        if repo not in ("", "-") and repo != source_repo:
            print(f"component {c} 属于 {repo}, 与 source_repo={source_repo} 不匹配", file=sys.stderr); sys.exit(1)

def is_first_party(r):
    s = r["save"]
    return s.startswith(harbor + "/suanova/") or s.startswith(harbor + "/suanova-private/")

# tag 校验
by_sub = {}
for r in trows:
    by_sub.setdefault(r["subdir"], []).append(r)
for d in selected_subdirs:
    rows_d = by_sub.get(d, [])
    fp = [r for r in rows_d if is_first_party(r)]
    if d == ".":
        if not op_tag:
            print(". 需要 CUBESTACK_OPERATOR_IMAGE_TAG", file=sys.stderr); sys.exit(1)
        for r in fp:
            t = ref_tag(r["save"])
            if t != op_tag:
                print(f". 行 tag {t} != release.env {op_tag}", file=sys.stderr); sys.exit(1)
        if dispatch_tag and dispatch_tag != op_tag:
            print(f"dispatch tag {dispatch_tag} != release.env {op_tag}", file=sys.stderr); sys.exit(1)
    elif d == "bmc":
        continue
    else:
        tags = sorted({t for r in fp for t in [ref_tag(r["save"])] if t})
        if len(tags) > 1:
            print(f"子目录 {d} 内 first-party tag 不一致: {tags}", file=sys.stderr); sys.exit(1)
        if dispatch_tag and tags and dispatch_tag not in tags:
            print(f"dispatch tag {dispatch_tag} != 子目录 {d} tag {tags}", file=sys.stderr); sys.exit(1)

# 选中行
sel_rows = [r for r in trows if r["subdir"] in selected_subdirs]
if first_only:
    sel_rows = [r for r in sel_rows if is_first_party(r)]
if not sel_rows and not chart_only and not first_only and not cli_only:
    print("选中的 component 没有镜像行", file=sys.stderr); sys.exit(1)

for r in sel_rows:
    if r["file"] != tar_name(r["save"]):
        print(f"{r['subdir']}/{r['file']}: 文件名与 save_ref 不匹配(期望 {tar_name(r['save'])})", file=sys.stderr); sys.exit(1)

with open(os.path.join(out, "selected.tsv"), "w", encoding="utf-8") as f:
    f.write("# filtered by release-sync-images.sh\n")
    for r in sel_rows:
        f.write(f"{r['subdir']}\t{r['file']}\t{r['pull']}\t{r['save']}\n")
with open(os.path.join(out, "subdirs.list"), "w", encoding="utf-8") as f:
    for d in selected_subdirs: f.write(d + "\n")
with open(os.path.join(out, "components.list"), "w", encoding="utf-8") as f:
    for c in selected: f.write(c + "\n")
with open(os.path.join(out, "source_repos.list"), "w", encoding="utf-8") as f:
    for c in selected:
        r = comps[c]["repo"]
        if r not in ("", "-"): f.write(r + "\n")
with open(os.path.join(out, "plan.json"), "w", encoding="utf-8") as f:
    json.dump({"selected": selected, "subdirs": selected_subdirs, "chart_only": chart_only,
               "cli_only": cli_only, "rows": sel_rows, "first_party_only": first_only}, f)
os.makedirs(os.path.join(out, "allowed"), exist_ok=True)
for d in selected_subdirs:
    safe = "_root" if d == "." else d.replace("/", "_")
    with open(os.path.join(out, "allowed", safe + ".list"), "w", encoding="utf-8") as f:
        for r in by_sub.get(d, []):
            f.write(r["file"] + "\n")
PY

mapfile -t SELECTED_SUBDIRS < "${WORK}/subdirs.list" || true
mapfile -t SELECTED_COMPONENTS < "${WORK}/components.list" || true
CHART_ONLY=0
python3 - "${WORK}/plan.json" <<'PY' > "${WORK}/chart_only.flag"
import json,sys
print("1" if json.load(open(sys.argv[1])).get("chart_only") else "0")
PY
CHART_ONLY="$(cat "${WORK}/chart_only.flag")"
CLI_ONLY=0
if printf '%s\n' "${SELECTED_COMPONENTS[@]}" | command grep -qxF -- cli \
   && [ "${#SELECTED_SUBDIRS[@]}" -eq 0 ] && [ "${CHART_ONLY}" = "0" ]; then
    CLI_ONLY=1
fi
if [ "${CLI_ONLY}" = "1" ]; then
    [ -n "${CLI_TAR_IN}" ] || die "--component cli 需要 --cli-tar <文件>"
    [ -f "${CLI_TAR_IN}" ] || die "CLI tar 不存在: ${CLI_TAR_IN}"
    [ -n "${CLI_DIGEST_IN}" ] || die "--component cli 需要 --cli-image-digest <sha256:...>"
    [ -n "${CLI_IMAGE}" ] || die "--component cli 需要 release.env 的 CUBESTACK_CLI_IMAGE"
fi
if [ -n "${CLI_DIGEST_IN}" ]; then
    case "${CLI_DIGEST_IN}" in
        sha256:*) : ;;
        *) CLI_DIGEST_IN="sha256:${CLI_DIGEST_IN}" ;;
    esac
    _cli_hex="${CLI_DIGEST_IN#sha256:}"
    [ -n "${_cli_hex}" ] || die "非法 --cli-image-digest: ${CLI_DIGEST_IN}"
    case "${_cli_hex}" in
        *[!0-9A-Za-z._-]*) die "非法 --cli-image-digest: ${CLI_DIGEST_IN}" ;;
    esac
fi

# marker scope 校验: marker 的 subdirs 必须是本次选中 subdirs 的子集
if [ "${RECOVER_MODE}" = "1" ] && [ -n "${MARKER_SUBDIRS}" ]; then
    missing=""
    for d in ${MARKER_SUBDIRS}; do
        printf '%s\n' "${SELECTED_SUBDIRS[@]}" | command grep -qxF -- "${d}" || missing+=" ${d}"
    done
    [ -z "${missing}" ] || die "存在未完成刷新 marker(${MARKER_COMPONENT}: ${MARKER_SUBDIRS}); 本次 component 未覆盖:${missing}"
fi

# ---------- release.env diff ----------
python3 - "${WORK}/release.env" "${REL_ENV}" "${OP_TAG}" "${CHART_VER}" "${CLI_IMAGE}" "${CLI_ONLY}" "${WORK}" <<'PY' > "${WORK}/envdiff.psv" || die "release.env diff 失败"
import json, re, sys
remote, git, op_tag, chart_ver, cli_image, cli_only, out = sys.argv[1:]
cli_only = (cli_only == "1")

def parse(path):
    d = {}
    dup = set()
    for line in open(path, encoding="utf-8"):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("export "):
            s = s[7:].lstrip()
        if "=" not in s:
            continue
        k, v = s.split("=", 1)
        k = k.strip()
        v = v.strip()
        if k in d:
            dup.add(k)
        d[k] = v
    return d, dup

r, rd = parse(remote)
g, gd = parse(git)
if rd or gd:
    print("release.env 存在重复 key: " + ",".join(sorted(rd | gd)), file=sys.stderr); sys.exit(1)
apply_keys = {"CUBESTACK_CLI_IMAGE"} if cli_only else {"CUBESTACK_OPERATOR_IMAGE_TAG", "CUBESTACK_OPERATOR_CHART_VERSION", "CUBESTACK_CLI_IMAGE"}
ignore_prefix = ("DEV_LAB_", "METAX_", "NVIDIA_")
ignore_exact = {"RDMA_IMAGE_TAG", "MULTUS_IMAGE_TAG", "NGINX_TAG"}
cli_out_of_scope = {"CUBESTACK_OPERATOR_IMAGE_TAG", "CUBESTACK_OPERATOR_CHART_VERSION"}
apply, ignore, fail = [], [], []
for k in sorted(set(r) | set(g)):
    if r.get(k) == g.get(k):
        continue
    if k in apply_keys:
        apply.append(k)
    elif cli_only and k in cli_out_of_scope:
        ignore.append(k)
    elif k in ignore_exact or k.startswith(ignore_prefix):
        ignore.append(k)
    else:
        fail.append(k)
if fail:
    print("release.env 结构性变化, 必须走完整 release-publish: " + ",".join(fail), file=sys.stderr); sys.exit(1)
# 生成替换后的 env
lines = open(remote, encoding="utf-8").read().splitlines()
git_lines = open(git, encoding="utf-8").read().splitlines()
git_map = {}
for line in git_lines:
    s = line.strip()
    if s.startswith("export "):
        s2 = s[7:].lstrip()
    else:
        s2 = s
    if "=" in s2 and not s2.startswith("#"):
        git_map[s2.split("=", 1)[0].strip()] = line
new_lines = []
seen = set()
for line in lines:
    s = line.strip()
    s2 = s[7:].lstrip() if s.startswith("export ") else s
    k = s2.split("=", 1)[0].strip() if "=" in s2 and not s2.startswith("#") else ""
    if k in apply:
        new_lines.append(git_map.get(k, line)); seen.add(k)
    else:
        new_lines.append(line)
for k in apply:
    if k not in seen and k in git_map:
        new_lines.append(git_map[k])
open(out + "/release.env.new", "w", encoding="utf-8").write("\n".join(new_lines) + "\n")
print("APPLY\t" + ",".join(apply))
print("IGNORE\t" + ",".join(ignore))
PY

ENV_APPLY="$(awk -F'\t' '$1=="APPLY"{print $2}' "${WORK}/envdiff.psv" | tail -1)"
ENV_IGNORE="$(awk -F'\t' '$1=="IGNORE"{print $2}' "${WORK}/envdiff.psv" | tail -1)"
ENV_CHANGED=0
if ! cmp -s "${WORK}/release.env" "${WORK}/release.env.new"; then
    ENV_CHANGED=1
fi
[ -n "${ENV_IGNORE}" ] && warn "release.env out-of-scope diff 已忽略(保持树内旧值): ${ENV_IGNORE}"
[ -n "${ENV_APPLY}" ] && _add_summary "- release.env apply: ${ENV_APPLY}"
[ -n "${ENV_IGNORE}" ] && _add_summary "- release.env ignored(out-of-scope): ${ENV_IGNORE}"

# operator tag 变化但未选择 "." -> 拒绝
if printf '%s' "${ENV_APPLY}" | command grep -q 'CUBESTACK_OPERATOR_IMAGE_TAG' 2>/dev/null; then
    printf '%s\n' "${SELECTED_SUBDIRS[@]}" | command grep -qxF -- "." || die "operator tag 变化但 component 未包含 '.'"
fi
CHART_ENV_CHANGED=0
printf '%s' "${ENV_APPLY}" | command grep -q 'CUBESTACK_OPERATOR_CHART_VERSION' 2>/dev/null && CHART_ENV_CHANGED=1
CLI_ENV_CHANGED=0
printf '%s' "${ENV_APPLY}" | command grep -q 'CUBESTACK_CLI_IMAGE' 2>/dev/null && CLI_ENV_CHANGED=1

# ---------- chart 源 ----------
CHART_IN_SCOPE=0
printf '%s\n' "${SELECTED_SUBDIRS[@]}" | command grep -qxF -- "." 2>/dev/null && CHART_IN_SCOPE=1
[ "${CHART_ONLY}" = "1" ] && CHART_IN_SCOPE=1
[ "${CHART_ENV_CHANGED}" = "1" ] && CHART_IN_SCOPE=1
CHART_NAME="cubestack-operator-chart-${CHART_VER}.tgz"
CHART_CHANGED=0
CHART_LOCAL=""
CHART_DIGEST=""
if [ "${CHART_IN_SCOPE}" = "1" ]; then
    [ -n "${CHART_VER}" ] || die "chart 需要同步但 release.env 无 CUBESTACK_OPERATOR_CHART_VERSION"
    if [ -n "${CHART_TGZ_IN}" ]; then
        [ -f "${CHART_TGZ_IN}" ] || die "chart tgz 不存在: ${CHART_TGZ_IN}"
        CHART_LOCAL="${WORK}/chart/${CHART_NAME}"
        cp -f "${CHART_TGZ_IN}" "${CHART_LOCAL}"
        if [ -n "${CHART_DIGEST_IN}" ]; then
            [ -f "${CHART_DIGEST_IN}" ] || die "chart digest 不存在: ${CHART_DIGEST_IN}"
            CHART_DIGEST="$(tr -d '[:space:]' < "${CHART_DIGEST_IN}")"
        elif [ -f "${CHART_TGZ_IN}.digest" ]; then
            CHART_DIGEST="$(tr -d '[:space:]' < "${CHART_TGZ_IN}.digest")"
        else
            die "缺少 chart digest(--chart-digest 或 <tgz>.digest)"
        fi
    else
        _need_cmd helm
        export HELM_REGISTRY_CONFIG="${WORK}/helm-config.json"
        mkdir -p "$(dirname "${HELM_REGISTRY_CONFIG}")"
        helm_args=()
        [ "${HARBOR_INSECURE}" = "true" ] && helm_args+=(--insecure-skip-tls-verify)
        printf '%s' "${_HARBOR_PASS}" | helm registry login "${HARBOR_HOST}" -u "${_HARBOR_USER}" --password-stdin ${helm_args[@]+"${helm_args[@]}"} >/dev/null 2>&1 \
            || die "helm registry login 失败"
        chart_ref="${CUBESTACK_OPERATOR_CHART_REF:-oci://${HARBOR_HOST}/suanova-private/cubestack-operator-chart}"
        out="$(helm pull "${chart_ref}" --version "${CHART_VER}" -d "${WORK}/chart" ${helm_args[@]+"${helm_args[@]}"} 2>&1)" \
            || die "helm pull chart 失败: ${chart_ref}@${CHART_VER}"
        CHART_DIGEST="$(printf '%s\n' "${out}" | sed -n 's/^Digest:[[:space:]]*//p' | head -1)"
        [ -n "${CHART_DIGEST}" ] || die "helm pull 未返回 Digest"
        CHART_LOCAL="${WORK}/chart/${CHART_NAME}"
        [ -f "${CHART_LOCAL}" ] || CHART_LOCAL="$(ls -1t "${WORK}/chart"/*.tgz 2>/dev/null | head -1)"
        [ -n "${CHART_LOCAL}" ] && [ -f "${CHART_LOCAL}" ] || die "helm pull 未产出 tgz"
    fi
    # Chart.yaml version/appVersion
    chart_yaml="$(tar -tzf "${CHART_LOCAL}" 2>/dev/null | command grep '/Chart.yaml$' | head -1 || true)"
    [ -n "${chart_yaml}" ] || die "chart 中找不到 Chart.yaml"
    chart_ver_file="$(tar -xOf "${CHART_LOCAL}" "${chart_yaml}" 2>/dev/null | awk '/^version:/{print $2; exit}' | tr -d '"')"
    chart_app_file="$(tar -xOf "${CHART_LOCAL}" "${chart_yaml}" 2>/dev/null | awk '/^appVersion:/{print $2; exit}' | tr -d '"')"
    [ "${chart_ver_file}" = "${CHART_VER}" ] || die "chart version=${chart_ver_file} != release.env ${CHART_VER}"
    [ "${chart_app_file}" = "${OP_TAG}" ] || die "chart appVersion=${chart_app_file} != release.env operator tag ${OP_TAG}"
    remote_chart_digest="$(mcrun cat "${REMOTE_OFF}/cubestack-operator/charts/${CHART_NAME}.digest" 2>/dev/null | tr -d '[:space:]' || true)"
    if [ "${RECOVER_MODE}" != "1" ] && [ "${FORCE}" != "1" ] \
       && [ "${remote_chart_digest}" = "${CHART_DIGEST}" ] \
       && _remote_exists "${REMOTE_OFF}/cubestack-operator/charts/${CHART_NAME}"; then
        say "chart 未变化(${CHART_DIGEST})"
    else
        CHART_CHANGED=1
    fi
fi

# ---------- CLI 源 ----------
CLI_NEEDS_SYNC=0
if _remote_exists "${CLI_TAR_REMOTE}"; then
    rs="$(_remote_size "${CLI_TAR_REMOTE}")"
    if [ -n "${CLI_TAR_SIZE}" ] && [ "${rs}" != "${CLI_TAR_SIZE}" ]; then
        warn "CLI tar 大小不符(${rs} != ${CLI_TAR_SIZE}), 将重建"
        CLI_NEEDS_SYNC=1
    fi
else
    warn "CLI tar 缺失: ${CLI_TAR_REMOTE}, 将重建"
    CLI_NEEDS_SYNC=1
fi
# 本地显式 tar 与 release.json 记录不一致 → 必须更新。
# (不能只看远端大小: 新旧 tar 可能恰好同大小, 但内容/digest 已变。)
CLI_LOCAL_SHA=""
CLI_LOCAL_SIZE=""
if [ -n "${CLI_TAR_IN}" ] && [ -f "${CLI_TAR_IN}" ]; then
    CLI_LOCAL_SHA="$(sha256sum "${CLI_TAR_IN}" | awk '{print $1}')"
    CLI_LOCAL_SIZE="$(stat -c %s "${CLI_TAR_IN}")"
    if [ "${CLI_LOCAL_SHA}" != "${CLI_TAR_SHA}" ] \
       || { [ -n "${CLI_TAR_SIZE}" ] && [ "${CLI_LOCAL_SIZE}" != "${CLI_TAR_SIZE}" ]; }; then
        say "本地 CLI tar 与 release.json 记录不一致, 将更新"
        CLI_NEEDS_SYNC=1
    fi
fi
CLI_NEW_DIGEST="${CLI_DIGEST_IN}"
if [ -z "${CLI_NEW_DIGEST}" ] && [ -n "${CLI_IMAGE}" ]; then
    _skopeo_init || true
    if command -v skopeo >/dev/null 2>&1; then
        CLI_NEW_DIGEST="$(_skopeo_raw_digest "${CLI_IMAGE}" || true)"
    fi
fi
OLD_CLI_DIGEST=""
if _remote_exists "${CLI_MARKER}"; then
    OLD_CLI_DIGEST="$(mcrun cat "${CLI_MARKER}" 2>/dev/null | tr -d '[:space:]' || true)"
fi
if [ -z "${OLD_CLI_DIGEST}" ]; then
    # 兼容尚未写 _CLI_IMAGE_DIGEST 的发布树: 以 release.json 记录为准。
    OLD_CLI_DIGEST="$(python3 - "${WORK}/release.json" <<'PY' 2>/dev/null || true
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("cli_image_digest") or "")
except Exception:
    pass
PY
)"
fi
CLI_CHANGED=0
if [ "${CLI_ONLY}" = "1" ] || [ -n "${CLI_IMAGE}" ]; then
    if [ "${CLI_ENV_CHANGED}" = "1" ] || [ "${CLI_NEEDS_SYNC}" = "1" ] || [ "${RECOVER_MODE}" = "1" ]; then
        CLI_CHANGED=1
    elif [ -n "${OLD_CLI_DIGEST}" ] && [ -n "${CLI_NEW_DIGEST}" ] && [ "${OLD_CLI_DIGEST}" != "${CLI_NEW_DIGEST}" ]; then
        CLI_CHANGED=1
    elif [ -z "${OLD_CLI_DIGEST}" ] && [ -n "${CLI_NEW_DIGEST}" ] && [ -z "${CLI_TAR_IN}" ]; then
        # 无历史 digest 且未提供本地 tar: 无法证明远端 tar 对应该 digest, 重建以保持一致
        CLI_CHANGED=1
    fi
fi
CLI_LOCAL=""
CLI_NEW_SHA=""
CLI_NEW_SIZE=""
if [ "${CLI_CHANGED}" = "1" ]; then
    [ -n "${CLI_IMAGE}" ] || [ -n "${CLI_TAR_IN}" ] || die "CLI 需要同步但 release.env 无 CUBESTACK_CLI_IMAGE 且未提供 --cli-tar"
    if [ "${PREFLIGHT}" = "1" ] || [ "${DRY_RUN}" = "1" ]; then
        _add_summary "- CLI: would rebuild (${CLI_IMAGE})"
    else
        CLI_LOCAL="${WORK}/cli/${CLI_TAR_NAME}"
        if [ -n "${CLI_TAR_IN}" ]; then
            [ -f "${CLI_TAR_IN}" ] || die "CLI tar 不存在: ${CLI_TAR_IN}"
            cp -f "${CLI_TAR_IN}" "${CLI_LOCAL}"
        else
            _skopeo_init || die "无法准备 Harbor 认证(skopeo)"
            _skopeo_copy_cli "${CLI_IMAGE}" "${CLI_LOCAL}" || die "CLI 镜像拉取失败: ${CLI_IMAGE}"
        fi
        CLI_NEW_SHA="$(sha256sum "${CLI_LOCAL}" | awk '{print $1}')"
        CLI_NEW_SIZE="$(stat -c %s "${CLI_LOCAL}")"
    fi
fi
if [ "${CLI_NEEDS_SYNC}" = "1" ] && [ "${CLI_CHANGED}" = "0" ]; then
    die "CLI tar 缺失/大小不符且无法重建(缺少 CUBESTACK_CLI_IMAGE)"
fi

# ---------- 镜像源 ----------
mapfile -t SEL_ROWS < <(python3 - "${WORK}/plan.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for r in d.get("rows",[]):
    print(f"{r['subdir']}\t{r['file']}")
PY
)
IMG_CHANGED=0
declare -A IMG_LOCAL=()
declare -A IMG_DIGEST=()
if [ "${#SEL_ROWS[@]}" -gt 0 ]; then
    if [ -n "${SOURCE_DIR}" ]; then
        for line in "${SEL_ROWS[@]}"; do
            sub="${line%%$'\t'*}"; file="${line#*$'\t'}"
            rel="$([ "${sub}" = "." ] && printf '%s' "${file}" || printf '%s/%s' "${sub}" "${file}")"
            src="${SOURCE_DIR}/cubestack-operator/${rel}"
            [ -f "${src}" ] || die "source-dir 缺少: ${rel}"
            [ -f "${src}.digest" ] || die "source-dir 缺少 digest: ${rel}.digest"
            if [ "${PREFLIGHT}" = "1" ] || [ "${DRY_RUN}" = "1" ]; then
                d_src="$(tr -d '[:space:]' < "${src}.digest")"
                d_rem="$(mcrun cat "${REMOTE_OFF}/cubestack-operator/${rel}.digest" 2>/dev/null | tr -d '[:space:]' || true)"
                if [ "${FORCE}" = "1" ] || [ "${RECOVER_MODE}" = "1" ] || [ "${d_src}" != "${d_rem}" ] || ! _remote_exists "${REMOTE_OFF}/cubestack-operator/${rel}"; then
                    _add_summary "- ${rel}: would update (${d_rem:-missing} -> ${d_src})"
                else
                    _add_summary "- ${rel}: unchanged"
                fi
            else
                d_src="$(tr -d '[:space:]' < "${src}.digest")"
                d_rem="$(mcrun cat "${REMOTE_OFF}/cubestack-operator/${rel}.digest" 2>/dev/null | tr -d '[:space:]' || true)"
                if [ "${FORCE}" = "1" ] || [ "${RECOVER_MODE}" = "1" ] || [ "${d_src}" != "${d_rem}" ] || ! _remote_exists "${REMOTE_OFF}/cubestack-operator/${rel}"; then
                    mkdir -p "$(dirname "${WORK}/img/${rel}")"
                    cp -f "${src}" "${WORK}/img/${rel}"
                    cp -f "${src}.digest" "${WORK}/img/${rel}.digest"
                    IMG_LOCAL["${rel}"]="${WORK}/img/${rel}"
                    IMG_DIGEST["${rel}"]="${d_src}"
                    IMG_CHANGED=1
                    _add_summary "- ${rel}: update (${d_rem:-missing} -> ${d_src})"
                else
                    _add_summary "- ${rel}: unchanged"
                fi
            fi
        done
    else
        _need_cmd skopeo
        _skopeo_init || die "无法准备 Harbor 认证(skopeo)"
        if [ "${PREFLIGHT}" = "1" ] || [ "${DRY_RUN}" = "1" ]; then
            if ! bash "${SAVE_TOOL}" --list "${WORK}/selected.tsv" --out "${WORK}/img" --dry-run > "${WORK}/save-dry.log" 2>&1; then
                err "$(cat "${WORK}/save-dry.log")"; die "镜像 ref 预检失败"
            fi
            _add_summary '```'
            _add_summary "$(tail -30 "${WORK}/save-dry.log")"
            _add_summary '```'
        else
            if [ "${FORCE}" != "1" ] && [ "${RECOVER_MODE}" != "1" ]; then
                while IFS=$'\t' read -r sub file pull save; do
                    case "${sub}" in \#*|'') continue ;; esac
                    rel="$([ "${sub}" = "." ] && printf '%s' "${file}" || printf '%s/%s' "${sub}" "${file}")"
                    if _remote_exists "${REMOTE_OFF}/cubestack-operator/${rel}"; then
                        mkdir -p "$(dirname "${WORK}/img/${rel}")"
                        mcrun cat "${REMOTE_OFF}/cubestack-operator/${rel}.digest" > "${WORK}/img/${rel}.digest" 2>/dev/null || true
                        [ -s "${WORK}/img/${rel}.digest" ] || rm -f "${WORK}/img/${rel}.digest"
                    fi
                done < "${WORK}/selected.tsv"
            fi
            save_args=(--list "${WORK}/selected.tsv" --out "${WORK}/img")
            [ "${FORCE}" = "1" ] || [ "${RECOVER_MODE}" = "1" ] && save_args+=(--force)
            bash "${SAVE_TOOL}" "${save_args[@]}" > "${WORK}/save.log" 2>&1 || { err "$(tail -40 "${WORK}/save.log")"; die "镜像拉取失败"; }
            while IFS=$'\t' read -r sub file pull save; do
                case "${sub}" in \#*|'') continue ;; esac
                rel="$([ "${sub}" = "." ] && printf '%s' "${file}" || printf '%s/%s' "${sub}" "${file}")"
                if [ -f "${WORK}/img/${rel}" ]; then
                    IMG_LOCAL["${rel}"]="${WORK}/img/${rel}"
                    IMG_DIGEST["${rel}"]="$(tr -d '[:space:]' < "${WORK}/img/${rel}.digest")"
                    IMG_CHANGED=1
                    _add_summary "- ${rel}: pulled"
                else
                    _add_summary "- ${rel}: unchanged"
                fi
            done < "${WORK}/selected.tsv"
        fi
    fi
fi

# preflight/dry-run 到这里就可以退出(不写 marker)
if [ "${PREFLIGHT}" = "1" ] || [ "${DRY_RUN}" = "1" ]; then
    _add_summary ""
    _add_summary "mode: $( [ "${PREFLIGHT}" = "1" ] && echo preflight || echo dry-run )"
    _add_summary "release: ${RELEASE}; components: ${SELECTED_COMPONENTS[*]:-none}; subdirs: ${SELECTED_SUBDIRS[*]:-none}"
    _add_summary "env apply: ${ENV_APPLY:-none}; env ignored: ${ENV_IGNORE:-none}; chart changed: ${CHART_CHANGED}; cli changed: ${CLI_CHANGED}"
    _flush_summary
    printf '%s' "${SUMMARY}"
    ok "预检/演练完成(未写 marker/未上传)"
    exit 0
fi

# ---------- stale tar 清理(计算, 尚未删除) ----------
STALE_RELS=()
if [ "${KEEP_STALE}" != "1" ]; then
    for d in ${SELECTED_SUBDIRS[@]+"${SELECTED_SUBDIRS[@]}"}; do
        [ "${d}" = "." ] && dir="${REMOTE_OFF}/cubestack-operator" || dir="${REMOTE_OFF}/cubestack-operator/${d}"
        [ -n "${d}" ] || continue
        safe="$([ "${d}" = "." ] && echo _root || printf '%s' "${d}" | tr '/' '_')"
        allowed_file="${WORK}/allowed/${safe}.list"
        [ -f "${allowed_file}" ] || continue
        mcrun ls --json "${dir}" 2>/dev/null > "${WORK}/ls.json" || true
        while IFS= read -r name; do
            [ -n "${name}" ] || continue
            case "${name}" in
                *.tar|*.tar.gz)
                    if ! command grep -qxF -- "${name}" "${allowed_file}"; then
                        rel="cubestack-operator/${name}"; [ "${d}" = "." ] || rel="cubestack-operator/${d}/${name}"
                        STALE_RELS+=("${rel}")
                        if _remote_exists "${dir}/${name}.digest"; then STALE_RELS+=("${rel}.digest"); fi
                    fi ;;
                *.tar.digest|*.tar.gz.digest)
                    base="${name%.digest}"
                    if ! command grep -qxF -- "${base}" "${allowed_file}"; then
                        rel="cubestack-operator/${name}"; [ "${d}" = "." ] || rel="cubestack-operator/${d}/${name}"
                        STALE_RELS+=("${rel}")
                    fi ;;
            esac
        done < <(python3 - "${WORK}/ls.json" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8", errors="ignore"):
    line = line.strip()
    if not line: continue
    try: d = json.loads(line)
    except Exception: continue
    if isinstance(d, dict) and d.get("type") == "file":
        k = str(d.get("key") or "")
        if k: print(k.rsplit("/", 1)[-1])
PY
)
    done
fi
if [ "${RECOVER_MODE}" = "1" ] && [ -n "${MARKER_STALE}" ]; then
    for rel in ${MARKER_STALE}; do STALE_RELS+=("${rel}"); done
fi
if [ "${#STALE_RELS[@]}" -gt 0 ]; then
    mapfile -t STALE_RELS < <(printf '%s\n' "${STALE_RELS[@]}" | sort -u)
fi

# ---------- 变更判定 ----------
ANY_CHANGED=0
[ "${IMG_CHANGED}" = "1" ] && ANY_CHANGED=1
[ "${CHART_CHANGED}" = "1" ] && ANY_CHANGED=1
[ "${CLI_CHANGED}" = "1" ] && ANY_CHANGED=1
[ "${ENV_CHANGED}" = "1" ] && ANY_CHANGED=1
[ "${#STALE_RELS[@]}" -gt 0 ] && ANY_CHANGED=1

if [ "${ANY_CHANGED}" = "0" ] && [ "${RECOVER_MODE}" != "1" ]; then
    if [ -n "${CLI_NEW_DIGEST}" ] && [ "${CLI_NEW_DIGEST}" != "${OLD_CLI_DIGEST}" ]; then
        printf '%s' "${CLI_NEW_DIGEST}" > "${WORK}/cli-digest"
        mcrun cp "${WORK}/cli-digest" "${CLI_MARKER}" >/dev/null 2>&1 || warn "写 _CLI_IMAGE_DIGEST 失败"
        _add_summary "- CLI digest marker: adopted ${CLI_NEW_DIGEST}"
    fi
    _add_summary ""
    _add_summary "release: ${RELEASE}; components: ${SELECTED_COMPONENTS[*]:-none}"
    _add_summary "result: no-op (无镜像/chart/env/CLI/stale 变化)"
    _flush_summary
    printf '%s' "${SUMMARY}"
    ok "无变化(no-op)"
    exit 0
fi

# ---------- 进入刷新 ----------
RUN_ID="${GITHUB_RUN_ID:-$$}-$(date -u +%s)"
printf '%s\n' "${SELECTED_SUBDIRS[@]}" > "${WORK}/marker-subdirs.list"
printf '%s\n' "${STALE_RELS[@]}" > "${WORK}/marker-stale.list"
python3 - "${WORK}/marker.json" "${RELEASE}" "${SELECTED_COMPONENTS[*]:-none}" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${RUN_ID}" \
    "${WORK}/marker-subdirs.list" "${WORK}/marker-stale.list" <<'PY'
import json, sys
out, release, component, started, run_id, subf, stalef = sys.argv[1:]
def lines(p):
    try:
        return [x.strip() for x in open(p, encoding="utf-8") if x.strip()]
    except Exception:
        return []
json.dump({"release": release, "component": component,
           "subdirs": lines(subf), "stale": lines(stalef),
           "started_at": started, "run_id": run_id},
          open(out, "w", encoding="utf-8"), ensure_ascii=False)
PY
mcrun cp "${WORK}/marker.json" "${MARKER}" >/dev/null 2>&1 || die "写 _REFRESH_PENDING 失败"
say "写 _REFRESH_PENDING → ${MARKER}"
if _remote_exists "${REMOTE_OFF}/_SUCCESS"; then
    mcrun rm "${REMOTE_OFF}/_SUCCESS" >/dev/null 2>&1 || die "删除 _SUCCESS 失败"
    say "临时删除 _SUCCESS(刷新期间 fetch 会明确失败)"
fi

# ---------- 上传镜像 ----------
declare -A CHANGED=()
for rel in "${!IMG_LOCAL[@]}"; do
    mcrun cp "${IMG_LOCAL[${rel}]}" "${REMOTE_OFF}/cubestack-operator/${rel}" >/dev/null 2>&1 \
        || die "上传失败: ${rel}"
    mcrun cp "${IMG_LOCAL[${rel}]}.digest" "${REMOTE_OFF}/cubestack-operator/${rel}.digest" >/dev/null 2>&1 \
        || die "上传 digest 失败: ${rel}"
    CHANGED["cubestack-operator/${rel}"]="$(sha256sum "${IMG_LOCAL[${rel}]}" | awk '{print $1}')"
    CHANGED["cubestack-operator/${rel}.digest"]="$(sha256sum "${IMG_LOCAL[${rel}]}.digest" | awk '{print $1}')"
    ok "上传 ${rel}"
done

# stale 删除
for rel in ${STALE_RELS[@]+"${STALE_RELS[@]}"}; do
    mcrun rm "${REMOTE_OFF}/${rel}" >/dev/null 2>&1 || warn "删除 stale 失败: ${rel}"
    say "删除 stale: ${rel}"
done

# chart
if [ "${CHART_CHANGED}" = "1" ]; then
    mcrun cp "${CHART_LOCAL}" "${REMOTE_OFF}/cubestack-operator/charts/${CHART_NAME}" >/dev/null 2>&1 \
        || die "上传 chart 失败"
    printf '%s' "${CHART_DIGEST}" > "${WORK}/chart.digest"
    mcrun cp "${WORK}/chart.digest" "${REMOTE_OFF}/cubestack-operator/charts/${CHART_NAME}.digest" >/dev/null 2>&1 \
        || die "上传 chart digest 失败"
    CHANGED["cubestack-operator/charts/${CHART_NAME}"]="$(sha256sum "${CHART_LOCAL}" | awk '{print $1}')"
    CHANGED["cubestack-operator/charts/${CHART_NAME}.digest"]="$(sha256sum "${WORK}/chart.digest" | awk '{print $1}')"
    ok "上传 chart ${CHART_NAME}"
fi

# CLI
if [ "${CLI_CHANGED}" = "1" ]; then
    mcrun cp "${CLI_LOCAL}" "${CLI_TAR_REMOTE}" >/dev/null 2>&1 || die "上传 CLI tar 失败"
    ok "上传 CLI tar ${CLI_TAR_NAME}"
fi

# env
if [ "${ENV_CHANGED}" = "1" ]; then
    mcrun cp "${WORK}/release.env.new" "${REMOTE_OFF}/release.env" >/dev/null 2>&1 || die "上传 release.env 失败"
    CHANGED["release.env"]="$(sha256sum "${WORK}/release.env.new" | awk '{print $1}')"
    ok "更新 release.env"
elif [ "${RECOVER_MODE}" = "1" ]; then
    CHANGED["release.env"]="$(sha256sum "${WORK}/release.env" | awk '{print $1}')"
fi

# release.json
REF_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GIT_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
COMP_CSV="$(IFS=,; printf '%s' "${SELECTED_COMPONENTS[*]:-none}")"
python3 - "${WORK}/release.json" "${WORK}/release.json.new" "${CHART_VER}" "${CLI_IMAGE}" \
    "${CLI_NEW_SHA}" "${CLI_NEW_SIZE}" "${CLI_NEW_DIGEST}" "${REF_AT}" "${COMP_CSV}" "${GIT_COMMIT}" "${ANY_CHANGED}" <<'PY'
import json, sys
src, out, chart, cli, cli_sha, cli_size, cli_digest, at, comps, commit, changed = sys.argv[1:]
d = json.load(open(src, encoding="utf-8"))
if chart:
    d["operator_chart_version"] = chart
if cli:
    d["cli_image"] = cli
if cli_sha:
    d["cli_tar_sha256"] = cli_sha
if cli_size:
    d["cli_tar_size"] = int(cli_size)
if cli_digest:
    d["cli_image_digest"] = cli_digest
if changed == "1":
    d["refreshed_at"] = at
    d["refreshed_components"] = [c for c in comps.split(",") if c]
    d["refreshed_git_commit"] = commit
    d["refreshed_by"] = "release-sync-images.sh"
json.dump(d, open(out, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
open(out, "a", encoding="utf-8").write("\n")
PY
JSON_CHANGED=0
if ! cmp -s "${WORK}/release.json" "${WORK}/release.json.new"; then
    JSON_CHANGED=1
    mcrun cp "${WORK}/release.json.new" "${REMOTE_OFF}/release.json" >/dev/null 2>&1 || die "上传 release.json 失败"
    CHANGED["release.json"]="$(sha256sum "${WORK}/release.json.new" | awk '{print $1}')"
    ok "更新 release.json"
elif [ "${RECOVER_MODE}" = "1" ]; then
    CHANGED["release.json"]="$(sha256sum "${WORK}/release.json" | awk '{print $1}')"
fi

# SHA256SUMS
if [ "${#CHANGED[@]}" -eq 0 ] && [ "${#STALE_RELS[@]}" -eq 0 ] && [ "${RECOVER_MODE}" != "1" ]; then
    die "内部错误: 进入刷新但没有任何变更"
fi
for rel in "${!CHANGED[@]}"; do printf '%s\t%s\n' "${rel}" "${CHANGED[${rel}]}"; done > "${WORK}/changed.tsv"
printf '%s\n' "${STALE_RELS[@]+"${STALE_RELS[@]}"}" > "${WORK}/removed.list"
python3 - "${WORK}/SHA256SUMS" "${WORK}/changed.tsv" "${WORK}/removed.list" "${WORK}/SHA256SUMS.new" <<'PY'
import sys
sums, changed_file, removed_file, out = sys.argv[1:]
changed = {}
for line in open(changed_file, encoding="utf-8"):
    if not line.strip(): continue
    p, h = line.rstrip("\n").split("\t", 1)
    changed[p] = h
removed = {x.strip() for x in open(removed_file, encoding="utf-8") if x.strip()}
lines = []
for line in open(sums, encoding="utf-8"):
    line = line.rstrip("\n")
    if not line: continue
    p = line.split("  ./", 1)[1] if "  ./" in line else ""
    if p in changed or p in removed:
        continue
    lines.append(line)
for p in sorted(changed):
    lines.append(f"{changed[p]}  ./{p}")
open(out, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
mcrun cp "${WORK}/SHA256SUMS.new" "${REMOTE_OFF}/SHA256SUMS" >/dev/null 2>&1 || die "上传 SHA256SUMS 失败"
SUMS_SHA="$(sha256sum "${WORK}/SHA256SUMS.new" | awk '{print $1}')"
ok "更新 SHA256SUMS"

# ---------- 远端验证 ----------
if [ "${VERIFY_REMOTE}" = "1" ]; then
    for rel in "${!CHANGED[@]}"; do
        rh="$(_remote_sha "${REMOTE_OFF}/${rel}")"
        [ "${rh}" = "${CHANGED[${rel}]}" ] || { mcrun rm "${REMOTE_OFF}/_SUCCESS" >/dev/null 2>&1 || true; die "远端校验失败: ${rel}"; }
    done
    if [ "${CLI_CHANGED}" = "1" ]; then
        rh="$(_remote_sha "${CLI_TAR_REMOTE}")"
        [ "${rh}" = "${CLI_NEW_SHA}" ] || { mcrun rm "${REMOTE_OFF}/_SUCCESS" >/dev/null 2>&1 || true; die "远端 CLI tar 校验失败"; }
    fi
    rsu="$(_remote_sha "${REMOTE_OFF}/SHA256SUMS")"
    [ "${rsu}" = "${SUMS_SHA}" ] || { mcrun rm "${REMOTE_OFF}/_SUCCESS" >/dev/null 2>&1 || true; die "远端 SHA256SUMS 校验失败"; }
fi

# CLI 一致性: release.json 必须记录本次镜像 digest
if [ -n "${CLI_NEW_DIGEST}" ]; then
    rcli="$(_remote_cat "${REMOTE_OFF}/release.json" | python3 -c '
import json,sys
try: print(json.load(sys.stdin).get("cli_image_digest",""))
except Exception: pass
' 2>/dev/null || true)"
    [ "${rcli}" = "${CLI_NEW_DIGEST}" ] \
        || die "release.json cli_image_digest 不一致: ${rcli:-<空>} != ${CLI_NEW_DIGEST}"
fi

# CLI digest marker(在 _SUCCESS 之前写: 失败则不发布)
if [ -n "${CLI_NEW_DIGEST}" ]; then
    printf '%s' "${CLI_NEW_DIGEST}" > "${WORK}/cli.digest"
    mcrun cp "${WORK}/cli.digest" "${CLI_MARKER}" >/dev/null 2>&1 || die "写 _CLI_IMAGE_DIGEST 失败"
    rd="$(_remote_cat "${CLI_MARKER}" | tr -d '[:space:]' || true)"
    [ "${rd}" = "${CLI_NEW_DIGEST}" ] || die "远端 _CLI_IMAGE_DIGEST 不一致: ${rd:-<空>} != ${CLI_NEW_DIGEST}"
fi

# _SUCCESS last
OLD_BUILT_AT="$(python3 - "${WORK}/release.json" 2>/dev/null <<'PY' || true
import json,sys
try: print(json.load(open(sys.argv[1])).get("built_at",""))
except Exception: pass
PY
)"
[ -n "${OLD_BUILT_AT}" ] || OLD_BUILT_AT="$(sed -n 's/^built_at=//p' "${WORK}/_SUCCESS" 2>/dev/null | head -1 || true)"
[ -n "${OLD_BUILT_AT}" ] || OLD_BUILT_AT="${REF_AT}"
printf 'release=%s\nbuilt_at=%s\nsha256sums=%s\n' "${RELEASE}" "${OLD_BUILT_AT}" "${SUMS_SHA}" > "${WORK}/_SUCCESS.new"
mcrun cp "${WORK}/_SUCCESS.new" "${REMOTE_OFF}/_SUCCESS" >/dev/null 2>&1 || die "上传 _SUCCESS 失败"
ok "写 _SUCCESS(最后一步)"

if [ "${VERIFY_REMOTE}" = "1" ]; then
    suf="$(_remote_cat "${REMOTE_OFF}/_SUCCESS" | sed -n 's/^sha256sums=//p' | head -1)"
    if [ "${suf}" != "${SUMS_SHA}" ]; then
        mcrun rm "${REMOTE_OFF}/_SUCCESS" >/dev/null 2>&1 || true
        die "远端 _SUCCESS sha 不符"
    fi
fi

# remove marker
mcrun rm "${MARKER}" >/dev/null 2>&1 || warn "删除 _REFRESH_PENDING 失败"

_add_summary ""
_add_summary "release: ${RELEASE}; components: ${SELECTED_COMPONENTS[*]:-none}"
[ "${CLI_ONLY}" = "1" ] && _add_summary "- CLI-only: ${CLI_TAR_NAME} (${CLI_NEW_DIGEST:-?})"
_add_summary "images changed: ${IMG_CHANGED}; chart changed: ${CHART_CHANGED}; cli changed: ${CLI_CHANGED}; env changed: ${ENV_CHANGED}; stale deleted: ${#STALE_RELS[@]}"
_add_summary "SHA256SUMS sha256: ${SUMS_SHA}"
_add_summary "result: success"
_flush_summary
printf '%s' "${SUMMARY}"
ok "同步完成: ${RELEASE} (${SELECTED_COMPONENTS[*]:-none})"
