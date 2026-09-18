#!/bin/bash
# ============================================================
# check-image-manifest.sh — 镜像清单静态校验(开发期 + CI 门禁)
# ============================================================
# 目的: images.manifest 是"唯一数据源", 一旦它错了, CI 会照着错清单同步、部署机照着错清单
#       备料 —— 错误会一路传到集群。本脚本在**不联网**的前提下把关:
#   ① 清单能被解析, 所有 ${VAR} 都能展开(变量未声明/为空 → 报错)
#   ② 每条 ref 全限定(带注册域), 且能推出合法 Harbor 目标路径
#   ③ 无重复 ref(同一镜像声明两次 → 同步两遍)
#   ④ group 都有对应的离线目录(拼得出来路径)
#   ⑤ [--kubespray] k8s-base 组与 tools/offline/trim-offline-files.sh 的 PRELOAD_IMAGE_PATTERNS
#      交叉核对 —— 两者不一致会导致镜像被裁掉(真实事故类型: 清单加了镜像却被 trim 删除)
#   ⑥ [--harbor] 联网比对 Harbor 现状: 列出"清单有但 Harbor 没有 / tag 不一致"的漂移项
#
# 用法:
#   bash check-image-manifest.sh              # 静态校验(离线, 快)
#   bash check-image-manifest.sh --kubespray  # 额外做 kubespray 交叉核对
#   bash check-image-manifest.sh --harbor     # 额外查 Harbor(需网络; 匿名即可)
#   bash check-image-manifest.sh --harbor --harbor-user u --harbor-pass p
# 退出码: 0=通过; 1=有违规
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-image-manifest.sh
source "${SCRIPT_DIR}/lib-image-manifest.sh"

say()  { echo -e "\033[36m→ $*\033[0m"; }
ok()   { echo -e "\033[32m✅ $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m"; }
bad()  { echo -e "\033[31m❌ $*\033[0m"; }
FAIL=0
ck() { bad "$*"; FAIL=1; }

DO_KUBESPRAY=0; DO_HARBOR=0
# 凭据: 命令行优先, 其次环境变量(CI 里由 GitHub Secrets 注入 HARBOR_MIRROR_*)
HARBOR_USER_CLI="${HARBOR_MIRROR_USER:-}"; HARBOR_PASS_CLI="${HARBOR_MIRROR_PASSWORD:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --kubespray) DO_KUBESPRAY=1 ;;
        --harbor)    DO_HARBOR=1 ;;
        --harbor-user) HARBOR_USER_CLI="${2:?}"; shift ;;
        --harbor-pass) HARBOR_PASS_CLI="${2:?}"; shift ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
    shift
done

echo "════════ 镜像清单校验(images.manifest) ════════"
image_manifest_load || exit 1
MF="$(image_manifest_path)"
say "清单:   ${MF}"
say "配置源: ${IM_CONF_FILE}"

# ---------- ① 可解析 + 展开 ----------
ENTRIES="$(mktemp)"; trap 'rm -f "${ENTRIES}"' EXIT
if ! image_manifest_entries > "${ENTRIES}"; then
    ck "清单解析失败(见上方错误)"
    exit 1
fi
TOTAL="$(grep -c . "${ENTRIES}" || true)"
[ "${TOTAL}" -gt 0 ] || { ck "清单为空"; exit 1; }
ok "① 解析成功: ${TOTAL} 条镜像声明"

# ---------- ② ref 全限定 + 目标路径可推 ----------
N_BAD_REF=0; N_BAD_MIRROR=0
while IFS=$'\t' read -r g r n; do
    # 全限定: 第一段必须形如 <域名> 或 <域名:端口>(含 '.' 或 ':')
    head_seg="${r%%/*}"
    case "${head_seg}" in
        *.*|*:*) : ;;
        *) ck "② ref 未全限定(缺注册域): ${r}(group=${g}; 短名要写成 docker.io/library/xxx)"; N_BAD_REF=$((N_BAD_REF+1)) ;;
    esac
    # tag 必须存在且非空
    case "${r}" in
        *:*) : ;;
        *) ck "② ref 缺 tag: ${r}"; N_BAD_REF=$((N_BAD_REF+1)) ;;
    esac
    image_mirror_ref "${r}" >/dev/null 2>&1 || { ck "② 无法推出 Harbor 目标路径: ${r}"; N_BAD_MIRROR=$((N_BAD_MIRROR+1)); }
done < "${ENTRIES}"
[ "${N_BAD_REF}" = "0" ] && ok "② 全部 ref 全限定且带 tag"
[ "${N_BAD_MIRROR}" = "0" ] && ok "② 全部可推出 Harbor 目标路径"

# ---------- ③ 重复 ref ----------
DUPS="$(cut -f2 "${ENTRIES}" | sort | uniq -d)"
if [ -n "${DUPS}" ]; then
    ck "③ 存在重复 ref(同一镜像声明多次):"
    printf '     %s\n' ${DUPS}
else
    ok "③ 无重复 ref"
fi

# ---------- ④ group 目录 ----------
N_DIR=0
while read -r g; do
    d="$(image_group_dir "${g}")"
    [ -n "${d}" ] || { ck "④ group 无对应目录: ${g}"; N_DIR=$((N_DIR+1)); }
done < <(image_groups)
[ "${N_DIR}" = "0" ] && ok "④ 全部 group 均有对应离线目录"

# ---------- ⑤ kubespray PRELOAD_IMAGE_PATTERNS 交叉核对 ----------
if [ "${DO_KUBESPRAY}" = "1" ]; then
    TRIM="${IM_REPO_ROOT}/deployments/scripts/tools/offline/trim-offline-files.sh"
    if [ ! -f "${TRIM}" ]; then
        warn "⑤ 找不到 ${TRIM}, 跳过交叉核对"
    else
        # 取 trim 脚本里的默认 PRELOAD_IMAGE_PATTERNS(该行形如 PRELOAD_IMAGE_PATTERNS="${VAR:-...默认...}")
        PATS="$(grep -m1 '^PRELOAD_IMAGE_PATTERNS=' "${TRIM}" | sed 's/.*:-//; s/}".*//')"
        if [ -z "${PATS}" ]; then
            warn "⑤ 未能从 trim-offline-files.sh 解析出 PRELOAD_IMAGE_PATTERNS, 跳过"
        else
            N_MISS=0
            # k8s-base 组每条 ref 的 tar 文件名, 必须能被某个 pattern 命中(否则 trim 会删掉它)
            while IFS=$'\t' read -r g r n; do
                [ "${g}" = "k8s-base" ] || continue
                f="$(image_tar_name "${r}" "${n}")"
                hit=0
                for p in ${PATS}; do
                    case "${p}" in
                        *.tar) [ "${f}" = "${p}" ] && hit=1 ;;
                        *)     case "${f}" in *"${p}"*) hit=1 ;; esac ;;
                    esac
                    [ "${hit}" = "1" ] && break
                done
                if [ "${hit}" != "1" ]; then
                    ck "⑤ k8s-base 镜像不在 PRELOAD_IMAGE_PATTERNS 内, 会被 trim 删除: ${f}"
                    N_MISS=$((N_MISS+1))
                fi
            done < "${ENTRIES}"
            if [ "${N_MISS}" = "0" ]; then
                ok "⑤ k8s-base 组与 kubespray PRELOAD_IMAGE_PATTERNS 一致"
            else
                warn "⑤ 修法: 把上面镜像的关键片段补进 ${TRIM} 的 PRELOAD_IMAGE_PATTERNS(两者必须同步)"
            fi
        fi
    fi
else
    say "⑤ 跳过 kubespray 交叉核对(--kubespray 启用)"
fi

# ---------- ⑥ Harbor 漂移(可选) ----------
if [ "${DO_HARBOR}" = "1" ]; then
    HARBOR_HOST="${HARBOR_MIRROR_REGISTRY:-harbor.isuanova.com}"
    HARBOR_PROJ="${HARBOR_MIRROR_PROJECT:-mirrors}"
    API="${HARBOR_MIRROR_API:-https://${HARBOR_HOST}}"
    CU=(); [ -n "${HARBOR_USER_CLI}" ] && CU=( -u "${HARBOR_USER_CLI}:${HARBOR_PASS_CLI}" )
    [ "${HARBOR_MIRROR_INSECURE:-false}" = "true" ] && CU+=( -k )
    say "⑥ 比对 Harbor(${HARBOR_PROJ}) 现状 ..."
    if ! curl -s -o /dev/null -w '%{http_code}' "${CU[@]}" "${API}/api/v2.0/projects/${HARBOR_PROJ}" 2>/dev/null | grep -q '^200$'; then
        warn "⑥ Harbor 项目 ${HARBOR_PROJ} 不可达或不存在, 跳过漂移检查"
    else
        N_DRIFT=0; N_SAME=0
        while IFS=$'\t' read -r g r n; do
            # "上游就是本台 Harbor"的镜像**不镜像到 mirrors/**(预期行为, 见 harbor-sync-images.sh):
            # metax / cubepilot 本就在本台 Harbor 上, 部署模块直接从其原项目拉取。
            # 不排除的话, 每次漂移检查都会把 16 个"永远不该出现"的镜像报成缺失, 噪声淹没真问题。
            case "${r}" in
                "${HARBOR_HOST}"/*) N_SAME=$((N_SAME+1)); continue ;;
            esac
            dst="$(image_mirror_ref "${r}")"
            # Harbor API 细节(实测, 易踩):
            #   ① 路径里的 repository 名**不含项目前缀**(项目已在路径段里), 要从 <host>/<project>/ 之后切;
            #   ② repository 名必须**双重 URL 编码**(含 '/' → %252F), 单重 %2F 一律 404 ——
            #      曾因此把 63 个已存在的镜像全报成"缺失"。
            path="${dst#"${HARBOR_HOST}/${HARBOR_PROJ}/"}"
            tag="${path##*:}"
            repo="${path%:*}"
            enc_repo="$(printf '%s' "${repo}" | sed 's#/#%252F#g')"
            enc_tag="$(printf '%s' "${tag}" | sed 's#/#%252F#g')"
            code="$(curl -s -o /dev/null -w '%{http_code}' "${CU[@]}" \
                "${API}/api/v2.0/projects/${HARBOR_PROJ}/repositories/${enc_repo}/artifacts/${enc_tag}" 2>/dev/null || echo 000)"
            if [ "${code}" != "200" ]; then
                echo "     [缺失] ${dst}"
                N_DRIFT=$((N_DRIFT+1))
            fi
        done < "${ENTRIES}"
        if [ "${N_DRIFT}" = "0" ]; then
            ok "⑥ Harbor 已含清单内全部应镜像的 $((${TOTAL}-${N_SAME})) 个镜像(无漂移)"
            [ "${N_SAME}" -gt 0 ] && say "   已跳过 ${N_SAME} 个\"本就在本台 Harbor 上\"的镜像(metax/cubepilot; 预期不镜像)"
        else
            warn "⑥ Harbor 缺 ${N_DRIFT}/$((${TOTAL}-${N_SAME})) 个应镜像的镜像(如上)。执行 harbor-sync-images.sh 补齐"
            [ "${N_SAME}" -gt 0 ] && say "   另已跳过 ${N_SAME} 个\"本就在本台 Harbor 上\"的镜像(预期不镜像)"
        fi
    fi
else
    say "⑥ 跳过 Harbor 漂移检查(--harbor 启用)"
fi

echo "════════════════════════════════════════"
if [ "${FAIL}" = "0" ]; then
    ok "清单校验通过(${TOTAL} 个镜像)"
    exit 0
fi
bad "清单校验失败(见上方 ❌)"
exit 1
