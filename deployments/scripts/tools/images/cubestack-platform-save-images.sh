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
#   ③ 回退 CUBESTACK_OPERATOR_HARBOR_USER/PASSWORD(同一台 Harbor 的私有项目账号;
#      2026-10-19 起支持, 避免只配了 operator 凭据时私有 operator tar 拉取 401);
#   ④ ~/.docker/config.json(存在即用, 兼容已 docker login 的机器)。
# 用法:
#   bash tools/images/cubestack-platform-save-images.sh [选项]
#     --list <tsv>   清单(默认 offline-files/cubestack-operator/image-list.tsv)
#     --out <dir>    输出目录(默认 = 清单所在目录, 即本地 offline-files/cubestack-operator)
#     --only <子串,..>  只处理 subdir 或文件名命中任一子串的行(更新单个组件用)
#     --force        忽略边车, 全部重拉重写
#     --dry-run      只比对与打印计划, 不拉取不写文件
#     --list-check   离线校验清单 ↔ 目录覆盖(不做任何网络操作)
#     --verify-remote 逐行比对远端 manifest digest ↔ 本地 .digest 边车(需 Harbor 网络;
#                    缺库/改 tag/清单滞后会失败, 用于发版前一键核对)
#     --seal-missing 已有的 tar 未变化时, 仅补写缺失的 .digest 边车(不重拉)
# 退出码: 0=全部成功/跳过; 1=有失败(逐条报告, 其余继续)
# ============================================================
set -euo pipefail

_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib-common.sh
source "${_self}/../../lib-common.sh"

# 读取 cluster.conf 的凭据变量(环境变量优先; 三个文件都是 ${VAR:-...} 写法)。
# 不调用 load_config: 本工具可能跑在 CI/无集群机器上, load_config 的版本档案逻辑会硬失败。
# 目的: 只配了 cluster.conf 的 CUBESTACK_OPERATOR_HARBOR_* 时, 私有 operator tar 也能拉取。
for _c in "${REPO_ROOT}/deployments/config/cluster.conf.example" \
          "${REPO_ROOT}/deployments/config/cluster.defaults.conf" \
          "${REPO_ROOT}/deployments/config/cluster.conf"; do
    [ -f "${_c}" ] || continue
    set +u; . "${_c}" >/dev/null 2>&1 || true; set -u
done
unset _c

LIST=""
OUT=""
ONLY=""
FORCE=0
DRY=0
LIST_CHECK=0
SEAL_MISSING=0
VERIFY_REMOTE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list)       LIST="${2:?}"; shift 2 ;;
        --out)        OUT="${2:?}"; shift 2 ;;
        --only)       ONLY="${2:?}"; shift 2 ;;
        --force)      FORCE=1; shift ;;
        --dry-run)    DRY=1; shift ;;
        --list-check) LIST_CHECK=1; shift ;;
        --verify-remote) VERIFY_REMOTE=1; shift ;;
        --seal-missing) SEAL_MISSING=1; shift ;;   # 已有的 tar 未变化时, 仅补写缺失的 .digest 边车(不重拉)
        *) err "未知参数: $1"; exit 1 ;;
    esac
done
LIST="${LIST:-${REPO_ROOT}/deployments/offline-files/cubestack-operator/image-list.tsv}"
OUT="${OUT:-$(dirname "${LIST}")}"
TLS_VERIFY="${SAVE_TLS_VERIFY:-true}"
[ -f "${LIST}" ] || { err "清单不存在: ${LIST}"; exit 1; }

# ---------- 认证文件(临时 600; 用后即删) ----------
# 凭据优先级: REGISTRY_AUTH_FILE > HARBOR_MIRROR_* > CUBESTACK_OPERATOR_HARBOR_* > docker config。
# ★ 2026-10-19: 私有项目(operator 本体)只配 CUBESTACK_OPERATOR_HARBOR_* 是常态; 旧实现只看
#   HARBOR_MIRROR_*, 会静默退化成匿名 → 私有 tar 401, 保鲜管道整条失败。
_AUTH_TMP=""
_cleanup() { [ -n "${_AUTH_TMP}" ] && rm -f "${_AUTH_TMP}" || true; }
trap _cleanup EXIT
AUTH_ARGS=()
_AUTH_HOST="${CUBESTACK_OPERATOR_HARBOR_HOST:-${HARBOR_MIRROR_REGISTRY:-harbor.isuanova.com}}"
_AUTH_USER=""; _AUTH_PASS=""
if [ -n "${HARBOR_MIRROR_USER:-}" ] && [ -n "${HARBOR_MIRROR_PASSWORD:-}" ]; then
    _AUTH_USER="${HARBOR_MIRROR_USER}"; _AUTH_PASS="${HARBOR_MIRROR_PASSWORD}"
elif [ -n "${CUBESTACK_OPERATOR_HARBOR_USER:-}" ] && [ -n "${CUBESTACK_OPERATOR_HARBOR_PASSWORD:-}" ]; then
    _AUTH_USER="${CUBESTACK_OPERATOR_HARBOR_USER}"; _AUTH_PASS="${CUBESTACK_OPERATOR_HARBOR_PASSWORD}"
fi
if [ -n "${REGISTRY_AUTH_FILE:-}" ]; then
    AUTH_ARGS=(--authfile "${REGISTRY_AUTH_FILE}")
elif [ -n "${_AUTH_USER}" ] && [ -n "${_AUTH_PASS}" ]; then
    _AUTH_TMP="$(mktemp /tmp/cubestack-save-auth.XXXXXX)"
    chmod 600 "${_AUTH_TMP}"
    _HU="${_AUTH_USER}" _HP="${_AUTH_PASS}" _HH="${_AUTH_HOST}" python3 - "${_AUTH_TMP}" <<'PY'
import base64, json, os, sys
auth = base64.b64encode(f"{os.environ['_HU']}:{os.environ['_HP']}".encode()).decode()
json.dump({"auths": {os.environ["_HH"]: {"auth": auth}}}, open(sys.argv[1], "w"))
PY
    AUTH_ARGS=(--authfile "${_AUTH_TMP}")
elif [ -f "${HOME}/.docker/config.json" ]; then
    AUTH_ARGS=(--authfile "${HOME}/.docker/config.json")   # 兼容已 docker login 的机器
fi
unset _AUTH_USER _AUTH_PASS

# ---------- 远端摘要: sha256(skopeo --raw) == docker pull 的 Digest ----------
_ref_digest() {   # <ref> → "sha256:..."; 3 次重试(连续逐查多镜像时偶发网络抖动, 2026-10-16 实测)
    local raw="" _i
    for _i in 1 2 3; do
        raw="$(skopeo inspect --raw --tls-verify="${TLS_VERIFY}" ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} "docker://$1" 2>/dev/null)"             && [ -n "${raw}" ] && break
        sleep 2
    done
    [ -n "${raw}" ] || return 1
    printf '%s' "${raw}" | sha256sum | awk '{print "sha256:"$1}'
}

# ---------- 镜像内容身份: config digest(比 manifest digest 更适合 tar↔Harbor 比对) ----------
# docker-archive 由 skopeo 重打包时 manifest 字节会变(RepoTags/媒体类型), 但 config digest
# 不变(层次内容身份)。25_cubestack_operator.sh 的推送幂等也用同一口径。
# 远端多架构 index → 先取 amd64/linux 条目, 再 inspect 该 manifest; archive → 直接读 manifest。
_config_digest() {   # <docker://ref | docker-archive:path> → "sha256:..."
    local ref="$1" raw="" mdig=""
    raw="$(skopeo inspect --raw --tls-verify="${TLS_VERIFY}" ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} "${ref}" 2>/dev/null)" || return 0
    [ -n "${raw}" ] || return 0
    mdig="$(printf '%s' "${raw}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d.get("manifests"), list):
    for m in d["manifests"]:
        p = m.get("platform") or {}
        if p.get("architecture") == "amd64" and p.get("os") == "linux":
            print(m.get("digest", "")); break
' 2>/dev/null || true)"
    if [ -n "${mdig}" ]; then
        raw="$(skopeo inspect --raw --tls-verify="${TLS_VERIFY}" ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} "${ref%@*}@${mdig}" 2>/dev/null)" || return 0
        [ -n "${raw}" ] || return 0
    fi
    printf '%s' "${raw}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print((d.get("config") or {}).get("digest", ""))
' 2>/dev/null || true
}

# ---------- 清单读取(TSV: subdir<TAB>file<TAB>pull_ref<TAB>save_ref) ----------
# ⚠ 用 awk -F'\t' 解析: bash 的 `IFS=$'\t' read` 会把**连续 tab 当空白折叠**, 从而把
#   "pull_ref 留空(占位)"的行读成 pull=save_ref、save="" —— skopeo copy 目标退化成
#   `docker-archive:<path>:`(空 tag) 而失败。2026-10-19 实测: 所有自研滚动镜像因此
#   永远无法刷新(verify-remote 只看 pull 字段, 所以没暴露)。
_rows() {
    command grep -vE '^\s*#|^\s*$' "${LIST}" | awk -F'\t' '
        {
            sd = $1; file = $2; pull = $3; save = $4
            if (file == "") next
            if (sd == "") sd = "."
            if (pull == "") pull = save
            printf "%s|%s|%s|%s\n", sd, file, pull, save
        }'
}

if [ "${LIST_CHECK}" = "1" ]; then
    ok_n=0; bad_n=0
    while IFS='|' read -r sub file pull save; do
        rel="$([ "${sub}" = "." ] && echo "${file}" || echo "${sub}/${file}")"
        if [ -f "${OUT}/${rel}" ] || [ -f "${OUT}/${rel}.gz" ]; then ok_n=$((ok_n+1)); else warn "清单行缺文件: ${rel}(或 .gz)"; bad_n=$((bad_n+1)); fi
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

# ---------- 远端一致性核对(清单 ↔ Harbor) ----------
# 这是"发版前防镜像 gap"的入口: 只要 image-list 里的 pull_ref 在 Harbor 不存在, 或本地
# .digest 边车与远端 manifest 摘要不一致, 就失败。2026-10-19 的 gateway v1.9.2 事故
# (chart 已升级、离线 tar 仍是 v1.9.1)就是这类偏差, 把它挡在部署之前。
if [ "${VERIFY_REMOTE}" = "1" ]; then
    command -v skopeo >/dev/null 2>&1 || { err "缺少 skopeo(安装: apt-get install -y skopeo)"; exit 1; }
    ok_n=0; bad_n=0
    while IFS='|' read -r sub file pull save; do
        if [ -n "${ONLY}" ]; then
            _hit=0
            for _o in ${ONLY//,/ }; do case "${sub}/${file}" in *"${_o}"*) _hit=1 ;; esac; done
            [ "${_hit}" = "1" ] || continue
        fi
        rel="$([ "${sub}" = "." ] && echo "${file}" || echo "${sub}/${file}")"
        tarpath="${OUT}/${rel}"
        d_new="$(_ref_digest "${pull}")" || {
            err "远端缺失/不可达: ${rel}(pull=${pull})"; bad_n=$((bad_n+1)); continue
        }
        d_old="$(cat "${tarpath}.digest" 2>/dev/null || true)"
        if [ -z "${d_old}" ]; then
            warn "无 .digest 边车: ${rel}(远端=${d_new:0:19}...)"; bad_n=$((bad_n+1)); continue
        fi
        if [ "${d_new}" != "${d_old}" ]; then
            err "边车不一致: ${rel}(远端=${d_new:0:19}... 本地边车=${d_old:0:19}...)"
            bad_n=$((bad_n+1)); continue
        fi
        # 再比**tar 本体**与 Harbor 的 config digest(内容身份; docker-archive 重打包会改
        # manifest 字节, 但 config digest 不变 —— 与 operator 模块推送幂等同口径)。
        if [ ! -f "${tarpath}" ]; then
            err "缺 tar: ${rel}"; bad_n=$((bad_n+1)); continue
        fi
        d_tar="$(  _config_digest "docker-archive:${tarpath}")"
        d_harbor="$(_config_digest "docker://${pull}")"
        if [ -n "${d_tar}" ] && [ -n "${d_harbor}" ] && [ "${d_tar}" != "${d_harbor}" ]; then
            err "tar↔Harbor 不一致: ${rel}(tar config=${d_tar:0:19}... Harbor config=${d_harbor:0:19}...)"
            bad_n=$((bad_n+1)); continue
        fi
        ok "  一致: ${rel}(${d_new:0:19}...; tar↔Harbor config ${d_tar:0:19}...)"
        ok_n=$((ok_n+1))
    done < <(_rows)
    echo "---------------------------------------------"
    [ "${bad_n}" = "0" ] && { ok "远端一致性核对通过(${ok_n} 个)"; exit 0; } \
                         || { err "远端一致性核对失败(${bad_n} 处)"; exit 1; }
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
    if [ "${SEAL_MISSING}" = "1" ] && [ -z "${d_old}" ] && { [ -f "${tarpath}" ] || [ -f "${tarpath}.gz" ]; }; then
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
        # 迁移期: 旧 .gz 存档(及边车)被普通 .tar 取代 —— 移除防双份/歧义
        if [ -f "${tarpath}.gz" ]; then
            rm -f "${tarpath}.gz" "${tarpath}.gz.digest"
            warn "  已移除旧 .gz 存档(被本次 .tar 取代): $(basename "${tarpath}").gz"
        fi
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
