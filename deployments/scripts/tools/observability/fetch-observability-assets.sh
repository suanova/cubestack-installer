#!/bin/bash
# ============================================================
# fetch-observability-assets.sh — CubeStack observability 资产(recording rules + Grafana dashboards)拉取
# 用途: 在**联网机**上把 cubestack 源仓库(suanova/cubestack)的 observability 资产拉到本地:
#   <输出目录>/recording-rules/*.yaml      6 个 PrometheusRule
#   <输出目录>/dashboards/grafana/*.json   11 个 Grafana dashboard
#   <输出目录>/SOURCE.txt                  本次拉取的来源 repo@commit(版本锚点)
# 独立运行: 本脚本**不依赖 lib-common.sh / cluster.conf**, 自带最小日志与路径推导,
#   在无任何部署配置的联网准备机上可直接运行; 仓库/分支/输出目录均可用环境变量覆盖。
# 注意:
#   · 资产的**权威来源是 cubestack 源仓库**(与 kube-prometheus-stack chart 一样属于上游产物);
#     本仓库只 vendor 一份副本供离线部署, 因此**升级资产 = 重跑本脚本**再提交。
#   · 输出目录两种用法:
#       ① 默认 → 本仓库 vendored 目录(deployments/cubestack-addon/observability/cubestack/),
#          部署模块 08_prometheus 直接读它; 离线产物随仓库一起走。
#       ② 离线包 → CUBESTACK_OBSERVABILITY_DIR=/opt/cubestack/observability 并加 --dir 指定,
#          与 observability/docs/installer-requirements.md §5 的节点目录约定一致。
#   · 拉取方式优先级: **gh api → curl(raw) → git(sparse-checkout)**。前两者走
#     api.github.com / raw.githubusercontent.com, 通常可用; git 协议走 github.com:443,
#     在受限网络里常被掐断(实测: TCP 能连上但握手卡死到 130s 超时), 故只作**限时兜底**。
# 用法:   ./fetch-observability-assets.sh                       # 刷新仓库内 vendored 副本
#         ./fetch-observability-assets.sh --dir /opt/cubestack/observability
#         CUBESTACK_SRC_REF=v1.2.3 ./fetch-observability-assets.sh   # 钉到正式 tag
#         CUBESTACK_FETCH_MODE=curl ./fetch-observability-assets.sh  # 强制走某条路径(排障用)
# 前置:   gh 或 curl 之一(推荐); git 仅作限时兜底; 网络可达 api.github.com / raw.githubusercontent.com
# ============================================================
set -euo pipefail

# ---- 独立运行: 自带最小日志与路径(不 source lib-common.sh / 不 load_config) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 定位仓库根: 从脚本所在目录向上找含本项目标识(deployments/scripts + cubestack-addon)的目录;
# 脚本被单独拷到别处时回退到当前工作目录(输出目录仍可用 --dir 显式指定)。
REPO_ROOT=""
_d="${SCRIPT_DIR}"
while [ "${_d}" != "/" ] && [ -z "${REPO_ROOT}" ]; do
    if [ -d "${_d}/deployments/scripts" ] && [ -d "${_d}/deployments/cubestack-addon" ]; then
        REPO_ROOT="${_d}"
    fi
    _d="$(dirname "${_d}")"
done
REPO_ROOT="${REPO_ROOT:-${PWD}}"

_log_file() { [ -n "${LOG_FILE:-}" ] && echo -e "$*" >> "${LOG_FILE}" 2>/dev/null || true; }
say()  { local m="→  $*"; echo -e "\033[36m${m}\033[0m"; _log_file "${m}"; }
ok()   { local m="✅ $*"; echo -e "\033[32m${m}\033[0m"; _log_file "${m}"; }
warn() { local m="⚠  $*"; echo -e "\033[33m${m}\033[0m"; _log_file "${m}"; }
err()  { local m="【错误】$*"; echo -e "\033[31m${m}\033[0m" >&2; _log_file "${m}"; }

# ---- 参数 ----
OUT_DIR=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir) OUT_DIR="${2:-}"; shift 2 ;;
        --dir=*) OUT_DIR="${1#--dir=}"; shift ;;
        -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "未知参数: $1(可用: --dir <目录>)"; exit 1 ;;
    esac
done

CUBESTACK_SRC_REPO="${CUBESTACK_SRC_REPO:-suanova/cubestack}"   # GitHub owner/repo
CUBESTACK_SRC_REF="${CUBESTACK_SRC_REF:-main}"                  # 分支 / tag / commit
# 输出目录: --dir 优先, 其次 CUBESTACK_OBSERVABILITY_DIR, 最后仓库内 vendored 目录
OUT_DIR="${OUT_DIR:-${CUBESTACK_OBSERVABILITY_DIR:-${REPO_ROOT}/deployments/cubestack-addon/observability/cubestack}}"
SRC_SUBDIR="observability"          # 源仓库内的子目录
_SUBDIRS=(recording-rules dashboards/grafana)

say "配置: 来源=${CUBESTACK_SRC_REPO}@${CUBESTACK_SRC_REF}  输出=${OUT_DIR}"

_TMPD="$(mktemp -d)"
trap 'rm -rf "${_TMPD}"' EXIT

# ---- 拉取(三选一), 统一落到 ${_TMPD}/src/<SRC_SUBDIR>/... ----
_SRC_ROOT="${_TMPD}/src"
_RESOLVED_COMMIT=""
_FETCHER=""

_fetch_git() {
    command -v git >/dev/null 2>&1 || return 1
    say "拉取(git sparse-checkout, 限时 ${_GIT_TIMEOUT}s)..."
    # ⚠ 限时: github.com 的 git 协议在受限网络里会卡到 130s+ 才超时, 不能让它拖死整个脚本
    # --filter=blob:none + sparse-checkout: 只取 observability/ 下的 blob, 不拉整仓历史
    timeout "${_GIT_TIMEOUT}" git clone --quiet --depth 1 --filter=blob:none --sparse \
        --branch "${CUBESTACK_SRC_REF}" \
        "https://github.com/${CUBESTACK_SRC_REPO}.git" "${_TMPD}/repo" 2>/dev/null || return 1
    timeout "${_GIT_TIMEOUT}" git -C "${_TMPD}/repo" sparse-checkout set --no-cone "${SRC_SUBDIR}" >/dev/null 2>&1 \
        || return 1
    [ -d "${_TMPD}/repo/${SRC_SUBDIR}/recording-rules" ] || return 1
    _RESOLVED_COMMIT="$(git -C "${_TMPD}/repo" rev-parse HEAD 2>/dev/null || true)"
    cp -a "${_TMPD}/repo/${SRC_SUBDIR}" "${_SRC_ROOT}" 2>/dev/null || return 1
    _FETCHER="git"
    return 0
}

# 逐文件下载(gh api 或 curl 二选一); <api-base 前缀> 由调用方决定
_fetch_perfile() {
    local _mode="$1"        # gh | curl
    say "拉取(逐文件 ${_mode})..."
    local _f _url _dest
    # 先取文件清单(contents API 返回 JSON 数组; 无 jq 用 python3 解析)
    _list_files() {   # <repo-relative-dir>
        local _pid="$1"
        if [ "${_mode}" = "gh" ]; then
            gh api "repos/${CUBESTACK_SRC_REPO}/contents/${_pid}?ref=${CUBESTACK_SRC_REF}" --jq '.[] | select(.type=="file") | .path' 2>/dev/null
        else
            curl -fsSL "https://api.github.com/repos/${CUBESTACK_SRC_REPO}/contents/${_pid}?ref=${CUBESTACK_SRC_REF}" 2>/dev/null \
                | python3 -c 'import json,sys
try:
    for e in json.load(sys.stdin):
        if e.get("type")=="file": print(e["path"])
except Exception:
    pass'
        fi
    }
    local _any=0
    for _sub in "${_SUBDIRS[@]}"; do
        while IFS= read -r _f; do
            [ -n "${_f}" ] || continue
            _any=1
            _dest="${_SRC_ROOT}/${_f}"
            mkdir -p "$(dirname "${_dest}")"
            # 带重试: raw/api 端点偶发 429/超时/截断(实测过一次), 一次失败不该让整个刷新白跑。
            # 每次重试**先删目标文件**再写, 避免半截文件被后续的 JSON 校验误判成"内容错"。
            local _try _ok=0
            for _try in 1 2 3; do
                rm -f "${_dest}"
                if [ "${_mode}" = "gh" ]; then
                    gh api "repos/${CUBESTACK_SRC_REPO}/contents/${_f}?ref=${CUBESTACK_SRC_REF}" --jq '.content' 2>/dev/null \
                        | base64 -d > "${_dest}" 2>/dev/null && [ -s "${_dest}" ] && { _ok=1; break; }
                else
                    curl -fsSL --max-time 120 --retry 2 \
                        "https://raw.githubusercontent.com/${CUBESTACK_SRC_REPO}/${CUBESTACK_SRC_REF}/${_f}" \
                        -o "${_dest}" 2>/dev/null && [ -s "${_dest}" ] && { _ok=1; break; }
                fi
                [ "${_try}" -lt 3 ] && { warn "    下载失败(第 ${_try}/3 次): ${_f}, 2s 后重试..."; sleep 2; }
            done
            if [ "${_ok}" != "1" ]; then
                rm -f "${_dest}"
                err "  下载失败(重试 3 次): ${_f}"
                err "    排查: ① 网络/代理; ② GitHub 匿名 API 限额(每小时 60 次/IP, 稍后重试或用 gh 登录态)"
                return 1
            fi
        done < <(_list_files "${SRC_SUBDIR}/${_sub}")
    done
    [ "${_any}" = "1" ] || return 1
    # 解析 commit SHA(逐文件模式下 best-effort; 拿不到就写 <unknown>, 不影响拉取)
    # ⚠ 用 api.github.com 而非仓库端: 匿名即可读公开仓库, 限额内(每 IP 每小时 60 次)
    if [ "${_mode}" = "gh" ]; then
        _RESOLVED_COMMIT="$(gh api "repos/${CUBESTACK_SRC_REPO}/commits/${CUBESTACK_SRC_REF}" --jq '.sha' 2>/dev/null || true)"
    else
        _RESOLVED_COMMIT="$(curl -fsSL --max-time 20 "https://api.github.com/repos/${CUBESTACK_SRC_REPO}/commits/${CUBESTACK_SRC_REF}" 2>/dev/null \
            | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("sha",""))
except Exception: pass' 2>/dev/null || true)"
    fi
    _FETCHER="${_mode}"
    return 0
}

_GIT_TIMEOUT="${CUBESTACK_FETCH_GIT_TIMEOUT:-90}"   # git 兜底路径的单步超时(秒)
# 拉取方式: auto(默认, gh→curl→git) | gh | curl | git —— 显式指定时**只试那一条**,
# 失败即报错(不回退), 便于排障与在受限网络里锁定可用路径。
FETCH_MODE="${CUBESTACK_FETCH_MODE:-auto}"

_fetch_auto() {
    case "${FETCH_MODE}" in
        gh)   command -v gh >/dev/null 2>&1   && _fetch_perfile gh   && return 0; return 1 ;;
        curl) command -v curl >/dev/null 2>&1 && _fetch_perfile curl && return 0; return 1 ;;
        git)  _fetch_git && return 0; return 1 ;;
        auto)
            if command -v gh >/dev/null 2>&1 && _fetch_perfile gh; then
                return 0
            elif command -v curl >/dev/null 2>&1 && _fetch_perfile curl; then
                return 0
            elif _fetch_git; then
                return 0
            fi
            return 1 ;;
        *) err "CUBESTACK_FETCH_MODE 仅支持 auto|gh|curl|git(当前=${FETCH_MODE})"; exit 1 ;;
    esac
}

if ! _fetch_auto; then
    err "拉取失败(mode=${FETCH_MODE}): gh / curl / git 都不可用或均失败"
    err "  核对: ① 网络可达 api.github.com 与 raw.githubusercontent.com(或 github.com);"
    err "        ② CUBESTACK_SRC_REPO=${CUBESTACK_SRC_REPO} 与 CUBESTACK_SRC_REF=${CUBESTACK_SRC_REF} 是否存在"
    err "  手动取法: git clone --depth 1 --filter=blob:none --sparse https://github.com/${CUBESTACK_SRC_REPO}.git"
    exit 1
fi

# ---- 校验拿到的资产(数量+可解析), 缺一个就不写盘 ----
_RULES_N="$(ls -1 "${_SRC_ROOT}/${SRC_SUBDIR}/recording-rules"/*.yaml 2>/dev/null | wc -l)"
_DASH_N="$(ls -1 "${_SRC_ROOT}/${SRC_SUBDIR}/dashboards/grafana"/*.json 2>/dev/null | wc -l)"
[ "${_RULES_N}" -ge 1 ] || { err "recording-rules 一个都没拉到(${_SRC_ROOT}/${SRC_SUBDIR}/recording-rules)"; exit 1; }
[ "${_DASH_N}" -ge 1 ] || { err "dashboards 一个都没拉到(${_SRC_ROOT}/${SRC_SUBDIR}/dashboards/grafana)"; exit 1; }
# dashboard 必须是合法 JSON(截断/错误页会在这里暴露), 免得把坏文件 vendor 进仓库
_BAD_JSON=""
while IFS= read -r _j; do
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${_j}" 2>/dev/null \
        || _BAD_JSON="${_BAD_JSON} $(basename "${_j}")"
done < <(ls -1 "${_SRC_ROOT}/${SRC_SUBDIR}/dashboards/grafana"/*.json 2>/dev/null)
[ -z "${_BAD_JSON}" ] || { err "以下 dashboard 不是合法 JSON:${_BAD_JSON}"; exit 1; }

# ---- 落盘(覆盖式; 只在全部校验通过后才动输出目录) ----
mkdir -p "${OUT_DIR}/recording-rules" "${OUT_DIR}/dashboards/grafana"
# 先删旧的同名文件再拷: 上游删除某个 dashboard 时, 本地不留残骸(否则会一直往集群导旧看板)
rm -f "${OUT_DIR}/recording-rules"/*.yaml "${OUT_DIR}/dashboards/grafana"/*.json
cp -a "${_SRC_ROOT}/${SRC_SUBDIR}/recording-rules/." "${OUT_DIR}/recording-rules/"
cp -a "${_SRC_ROOT}/${SRC_SUBDIR}/dashboards/grafana/." "${OUT_DIR}/dashboards/grafana/"
# 上游 dashboards/grafana/README.md 不是资产, 挪出去避免被当成 dashboard(模块按 *.json 通配, 无影响但会误导人)
rm -f "${OUT_DIR}/dashboards/grafana/README.md"

{
    echo "# 本目录由 tools/observability/fetch-observability-assets.sh 自动拉取, 请勿手工编辑。"
    echo "# 升级方式: 重跑该脚本后提交本目录的变更。"
    echo "source_repo: ${CUBESTACK_SRC_REPO}"
    echo "source_ref: ${CUBESTACK_SRC_REF}"
    echo "source_commit: ${_RESOLVED_COMMIT:-<unknown>}"
    echo "fetcher: ${_FETCHER}"
    echo "recording_rules: ${_RULES_N}"
    echo "dashboards: ${_DASH_N}"
    echo "fetched_at_utc: $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '<unknown>')"
} > "${OUT_DIR}/SOURCE.txt"

echo "---------------------------------------------"
ok "observability 资产已拉取"
echo "  来源:     ${CUBESTACK_SRC_REPO}@${CUBESTACK_SRC_REF} (commit ${_RESOLVED_COMMIT:-<unknown>}, via ${_FETCHER})"
echo "  输出:     ${OUT_DIR}"
echo "  recording rules: ${_RULES_N} 个"
echo "  dashboards:      ${_DASH_N} 个"
if [ -n "${_RESOLVED_COMMIT}" ] && [ "${OUT_DIR}" = "${REPO_ROOT}/deployments/cubestack-addon/observability/cubestack" ]; then
    echo "  下一步:   git add ${OUT_DIR} && git commit(把刷新后的副本提交, 供离线部署使用)"
fi
