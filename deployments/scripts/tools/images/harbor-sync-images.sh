#!/bin/bash
# ============================================================
# harbor-sync-images.sh — 上游原始镜像 → Harbor 统一镜像源(在线源)
# ============================================================
# 作用: 读 deployments/config/images.manifest, 把**每一个上游原始镜像**同步到
#       harbor.isuanova.com/mirrors/**:项目不存在自动创建, 镜像已存在且 digest 未变则跳过。
#       跑完之后 Harbor 就是本仓库唯一的在线镜像源 —— 部署机只需能连 Harbor,
#       不再需要访问 docker.io / quay.io / registry.k8s.io / ghcr.io。
#
# 制品流向(全链):
#   上游 registry ──本脚本──▶ Harbor mirrors/** ──harbor-save-images.sh──▶ 离线 tar
#                                                                    ──模块──▶ 集群内置 registry ──▶ 节点
#
# ── 谁在跑本脚本 ──────────────────────────────────────────
#   · CI       : .github/workflows/sync-images-to-harbor.yml(GitHub Actions; 凭据走 Secrets)
#   · 联网机器 : 手动执行(首次建仓 / 补镜像 / 版本升级后重同步)
#
# ── 凭据(不落盘、不进 git) ────────────────────────────────
#   HARBOR_MIRROR_USER / HARBOR_MIRROR_PASSWORD(环境变量; CI 用 GitHub Secrets 注入)。
#   留空 = 匿名(该项目默认公开只读; 但**创建项目**必须带凭据, 匿名会 401)。
#   ⚠ Harbor 项目默认 public=true → 部署机匿名即可 pull, 不需要分发凭据。
#
# ── 幂等 / 增量 ──────────────────────────────────────────
#   每个镜像先比 digest(源 vs Harbor): 相同且 tag 在 → 跳过(不白传);
#   不同(上游更新了 tag, 如 :latest / main 线)或缺失 → 重新同步。
#   强制全覆盖: --force。
#
# 用法:
#   ./harbor-sync-images.sh                        # 同步全部(幂等增量)
#   ./harbor-sync-images.sh --list                 # 只列出将同步的镜像(不联网)
#   ./harbor-sync-images.sh --group prometheus,envoy   # 只同步指定分组
#   ./harbor-sync-images.sh --exclude-group metax-gpu  # 排除大体积分组
#   ./harbor-sync-images.sh --include-same-harbor      # 连"上游就是本台 Harbor"的镜像一起镜像
#                                                     # (默认**不镜像**这些: metax/cubepilot 本就在
#                                                     #  本台 Harbor 上, 部署模块直接从其原项目拉,
#                                                     #  再复制一份只多占 8.4 GB 且升级要重跑)
#   ./harbor-sync-images.sh --force                # 强制重新同步(忽略 digest 相同)
#   ./harbor-sync-images.sh --platform amd64       # 只同步单架构(默认 --all 保留多架构)
#   HARBOR_MIRROR_USER=u HARBOR_MIRROR_PASSWORD=p ./harbor-sync-images.sh
# 退出码: 0=全部成功(含跳过); 1=有失败项
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-image-manifest.sh
source "${SCRIPT_DIR}/lib-image-manifest.sh"

# ---- 最小日志(与仓库其它工具脚本同风格; 不依赖 lib-common.sh, CI 可直接跑) ----
_log_file() { [ -n "${LOG_FILE:-}" ] && echo -e "$*" >> "${LOG_FILE}" 2>/dev/null || true; }
say()  { local m="→  $*"; echo -e "\033[36m${m}\033[0m"; _log_file "${m}"; }
ok()   { local m="✅ $*"; echo -e "\033[32m${m}\033[0m"; _log_file "${m}"; }
warn() { local m="⚠  $*"; echo -e "\033[33m${m}\033[0m"; _log_file "${m}"; }
err()  { local m="【错误】$*"; echo -e "\033[31m${m}\033[0m" >&2; _log_file "${m}"; }

# ---- 参数 ----
MODE="sync"; FORCE=0; DRY_RUN=0; NO_CREATE=0
PLATFORM_MODE="all"                     # all(默认, 保留多架构 manifest list) | 单架构值(如 amd64)
INCLUDE_GROUPS=""; EXCLUDE_GROUPS=""
SAME_HARBOR="exclude"                   # 默认**不镜像**"上游就是本台 Harbor"的镜像; 见 --include-same-harbor
while [ $# -gt 0 ]; do
    case "$1" in
        --list|-l)        MODE="list" ;;
        --force|-f)       FORCE=1 ;;
        --dry-run|-n)     DRY_RUN=1 ;;
        --no-create)      NO_CREATE=1 ;;
        --platform)       PLATFORM_MODE="${2:?--platform 需要值(如 amd64)}"; shift ;;
        --platform=*)     PLATFORM_MODE="${1#*=}" ;;
        --group|-g)       INCLUDE_GROUPS="${2:?--group 需要值}"; shift ;;
        --group=*)        INCLUDE_GROUPS="${1#*=}" ;;
        --exclude-group)  EXCLUDE_GROUPS="${2:?--exclude-group 需要值}"; shift ;;
        --exclude-group=*) EXCLUDE_GROUPS="${1#*=}" ;;
        --exclude-same-harbor) SAME_HARBOR="exclude" ;;
        --include-same-harbor) SAME_HARBOR="include" ;;
        --help|-h)        sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "未知参数: $1(--help 看用法)"; exit 1 ;;
    esac
    shift
done

HARBOR_HOST="${HARBOR_MIRROR_REGISTRY:-harbor.isuanova.com}"
HARBOR_PROJ="${HARBOR_MIRROR_PROJECT:-mirrors}"
HARBOR_USER="${HARBOR_MIRROR_USER:-}"
HARBOR_PASSWORD="${HARBOR_MIRROR_PASSWORD:-}"
HARBOR_INSECURE="${HARBOR_MIRROR_INSECURE:-false}"
# Harbor API 基址(https; 某些内网只有 http 时用 HARBOR_MIRROR_API 覆盖)
HARBOR_API="${HARBOR_MIRROR_API:-https://${HARBOR_HOST}}"

image_manifest_load || exit 1

# ---- 分组过滤 ----
_group_selected() {   # <group> → 0=选中
    local g="$1" x
    if [ -n "${INCLUDE_GROUPS}" ]; then
        local hit=1
        for x in ${INCLUDE_GROUPS//,/ }; do [ "${x}" = "${g}" ] && hit=0; done
        [ "${hit}" = "0" ] || return 1
    fi
    if [ -n "${EXCLUDE_GROUPS}" ]; then
        for x in ${EXCLUDE_GROUPS//,/ }; do [ "${x}" = "${g}" ] && return 1; done
    fi
    return 0
}

# ---- 收集清单(过滤后) ----
# 默认**跳过"上游就是本台 Harbor"的镜像**(metax / cubepilot): 它们是 Harbor → Harbor 的同台复制,
# 目标"集群不访公网"对它们**已经达成**(部署模块现在就分别从 harbor.isuanova.com/metax 与
# /suanova 拉取, 无需任何改动)。再复制一份到 mirrors/ 只会: ①多占一份存储(实测 8.4 GB, 其中
# maca 5.3 GB); ②每次版本升级都要重跑一次。
# 判据是**推导**出来的(注册域 == HARBOR_MIRROR_REGISTRY), 不是硬编码名单 ——
# 将来若某个组件改成从公网拉, 它会自动重新进入镜像范围。
# 少数情况下确实想要那份副本: --include-same-harbor。
# ⚠ 跳过是**显式报告**的(汇总列出被跳过的项), 不会造成"看起来全同步了"的错觉。
SAME_HARBOR_SKIPPED=()
LIST_FILE="$(mktemp)"
while IFS=$'\t' read -r g r _n; do
    _group_selected "${g}" || continue
    if [ "${SAME_HARBOR}" = "exclude" ]; then
        _reg="${r%%/*}"
        [ "${_reg}" = "${HARBOR_HOST}" ] && { SAME_HARBOR_SKIPPED+=("${g}:${r}"); continue; }
    fi
    printf '%s\t%s\n' "${g}" "${r}"
done < <(image_manifest_entries) > "${LIST_FILE}"

TOTAL="$(wc -l < "${LIST_FILE}" | tr -d ' ')"
[ "${TOTAL}" -gt 0 ] || { err "清单为空(检查 --group/--exclude-group 过滤条件与 ${IMAGE_MANIFEST:-images.manifest})"; exit 1; }

say "镜像源同步: 上游 → ${HARBOR_HOST}/${HARBOR_PROJ}/**(共 ${TOTAL} 个镜像)"
say "配置来源: ${IM_CONF_FILE}"
say "Harbor:    ${HARBOR_API}(用户: ${HARBOR_USER:-<匿名>}; TLS 校验: $([ "${HARBOR_INSECURE}" = true ] && echo 关 || echo 开))"

# ---- --list: 只打印 ----
if [ "${MODE}" = "list" ]; then
    echo "将同步的镜像清单:"
    while IFS=$'\t' read -r g r; do
        printf '  [%-18s] %-64s → %s\n' "${g}" "${r}" "$(image_mirror_ref "${r}")"
    done < "${LIST_FILE}"
    echo
    echo "分组统计:"
    cut -f1 "${LIST_FILE}" | sort | uniq -c | awk '{printf "  %-20s %s\n", $2, $1}'
    exit 0
fi

# ---- 前置: skopeo ----
command -v skopeo >/dev/null 2>&1 || {
    err "未找到 skopeo; 安装: apt-get install -y skopeo(或 dnf install skopeo)"
    exit 1
}
# skopeo 在没有容器运行时配置的机器上, 缺 /etc/containers/policy.json 会 fatal
if [ ! -f "/etc/containers/policy.json" ]; then
    if mkdir -p /etc/containers 2>/dev/null; then
        cat > /etc/containers/policy.json <<'POLICY_EOF'
{
    "default": [
        {
            "type": "insecureAcceptAnything"
        }
    ]
}
POLICY_EOF
    else
        warn "无法写 /etc/containers/policy.json(非 root); 若 skopeo 报 trust policy 错误请补上"
    fi
fi

# ---- Harbor 项目自动创建 ----
# Harbor 的**仓库**(repository)在首次 push 时自动创建, 但**项目**(project)必须预先存在。
# 因此这里先确保项目存在。需要凭据(匿名建项会 401)。
# 可选参数(认证 / -k)用数组拼装 —— 避免在 ${VAR:+...} 里嵌引号(bash 不支持嵌套引号)
_harbor_curl_auth() {
    HARBOR_CURL_OPTS=()
    [ "${HARBOR_INSECURE}" = "true" ] && HARBOR_CURL_OPTS+=( -k )
    if [ -n "${HARBOR_USER}" ] && [ -n "${HARBOR_PASSWORD}" ]; then
        HARBOR_CURL_OPTS+=( -u "${HARBOR_USER}:${HARBOR_PASSWORD}" )
    fi
    return 0
}

ensure_harbor_project() {
    local code
    _harbor_curl_auth
    # ① 已存在?
    code="$(curl -s -o /dev/null -w '%{http_code}' "${HARBOR_CURL_OPTS[@]}" \
        "${HARBOR_API}/api/v2.0/projects/${HARBOR_PROJ}" 2>/dev/null || echo 000)"
    if [ "${code}" = "200" ]; then
        ok "Harbor 项目已存在: ${HARBOR_PROJ}"
        return 0
    fi
    if [ "${NO_CREATE}" = "1" ]; then
        warn "--no-create 已指定且项目不存在(HTTP ${code}); 若 push 失败请手动建项"
        return 0
    fi
    if [ -z "${HARBOR_USER}" ] || [ -z "${HARBOR_PASSWORD}" ]; then
        err "Harbor 项目 ${HARBOR_PROJ} 不存在(HTTP ${code}), 且未提供凭据无法创建"
        err "  解决: 提供 HARBOR_MIRROR_USER / HARBOR_MIRROR_PASSWORD(建项需要登录),"
        err "        或在 Harbor 界面手动创建项目 ${HARBOR_PROJ}(勾选公开)"
        return 1
    fi
    # ② 创建(公开只读, 便于部署机匿名拉取)
    say "创建 Harbor 项目: ${HARBOR_PROJ}(public=true)..."
    local body http
    body="$(curl -s -w '\n%{http_code}' -X POST "${HARBOR_API}/api/v2.0/projects" \
        "${HARBOR_CURL_OPTS[@]}" -H 'Content-Type: application/json' \
        -d "{\"project_name\":\"${HARBOR_PROJ}\",\"metadata\":{\"public\":\"true\"},\"storage_limit\":-1}" 2>/dev/null || true)"
    http="$(printf '%s' "${body}" | tail -1)"
    case "${http}" in
        201) ok "  项目已创建: ${HARBOR_PROJ}(公开只读)" ;;
        409) ok "  项目已存在(并发创建, 视为成功)" ;;
        *)   err "  创建项目失败(HTTP ${http:-?}): $(printf '%s' "${body}" | sed '$d' | head -c 300)"
             return 1 ;;
    esac
    return 0
}

if [ "${DRY_RUN}" != "1" ]; then
    ensure_harbor_project || exit 1
else
    say "--dry-run: 跳过项目创建检查"
fi

# ---- skopeo 参数 ----
# ⚠ `copy` 与 `inspect` 的 TLS 旗标名**不同**(实测 skopeo 1.16):
#     copy   : --src-tls-verify / --dest-tls-verify
#     inspect: --tls-verify(单数)  ← 传 --src-tls-verify 会 "unknown flag" 且被 2>/dev/null 吞掉,
#                                   表现为"永远取不到 digest" → 每次都全量重传(idempotency 静默失效)
#   故两套参数分开维护。
SKOPEO_SRC_OPTS=( --src-tls-verify=true --retry-times 3 )
SKOPEO_DST_OPTS=( --dest-tls-verify=true )
INSPECT_SRC_OPTS=( --tls-verify=true --retry-times 3 )
INSPECT_DST_OPTS=( --tls-verify=true --retry-times 3 )
if [ "${HARBOR_INSECURE}" = "true" ]; then
    SKOPEO_DST_OPTS=( --dest-tls-verify=false )
    INSPECT_DST_OPTS=( --tls-verify=false --retry-times 3 )
fi

# ---- 凭据: 写进私有 auth 文件, **不走 argv** ----
# 两个原因(都踩过):
#   ① 安全: --dest-creds "u:p" 会把密码暴露在 ps / CI 日志里;
#   ② 可用性: skopeo 默认读 $XDG_RUNTIME_DIR/containers/auth.json, 无该变量时用
#      /run/containers/<uid>/auth.json —— 容器内/非 root 场景该目录常不可读, skopeo 直接
#      fatal "reading JSON file /run/containers/NNN/auth.json: permission denied",
#      连公开镜像都拉不动。显式指定一个自己可控的 auth 文件即可根治。
SKOPEO_AUTH_FILE=""
_cleanup_auth() { [ -n "${SKOPEO_AUTH_FILE}" ] && rm -f "${SKOPEO_AUTH_FILE}" 2>/dev/null || true; }
trap '_cleanup_auth; rm -f "${LIST_FILE}" 2>/dev/null || true' EXIT
if [ -n "${HARBOR_USER}" ] && [ -n "${HARBOR_PASSWORD}" ]; then
    SKOPEO_AUTH_FILE="$(mktemp)"
    chmod 600 "${SKOPEO_AUTH_FILE}"
    # auth.json 格式: {"auths":{"<registry>":{"auth":"<base64(user:pass)>"}}}
    _b64="$(printf '%s:%s' "${HARBOR_USER}" "${HARBOR_PASSWORD}" | base64 -w0 2>/dev/null \
            || printf '%s:%s' "${HARBOR_USER}" "${HARBOR_PASSWORD}" | base64)"
    printf '{"auths":{"%s":{"auth":"%s"}}}' "${HARBOR_HOST}" "${_b64}" > "${SKOPEO_AUTH_FILE}"
    unset _b64
    # 上游若要凭据(私有上游), 一并写进同一个 auth 文件
    if [ -n "${HARBOR_SRC_USER:-}" ] && [ -n "${HARBOR_SRC_PASSWORD:-}" ]; then
        warn "HARBOR_SRC_USER 已设置: 上游凭据请自行写入 REGISTRY_AUTH_FILE 指向的文件(本脚本只托管 Harbor 凭据)"
    fi
    export REGISTRY_AUTH_FILE="${SKOPEO_AUTH_FILE}"
    say "凭据: 写入私有 auth 文件(600, 不进 argv; 退出时删除) → ${SKOPEO_AUTH_FILE}"
else
    # 无凭据: 仍显式指向一个可写空文件, 规避 /run/containers/<uid>/auth.json 不可读导致 skopeo fatal
    SKOPEO_AUTH_FILE="$(mktemp)"
    chmod 600 "${SKOPEO_AUTH_FILE}"
    printf '{"auths":{}}' > "${SKOPEO_AUTH_FILE}"
    export REGISTRY_AUTH_FILE="${SKOPEO_AUTH_FILE}"
    say "凭据: 未提供(匿名); auth 文件指向可写路径以规避 skopeo 默认路径不可读"
fi

SKOPEO_AUTH_SRC=(); SKOPEO_AUTH_DST=()
# 多架构: --all 保留 manifest list(推荐, 为将来 arm64 留路); 指定单架构则用 --override-arch
SKOPEO_ARCH=()
if [ "${PLATFORM_MODE}" = "all" ]; then
    SKOPEO_ARCH=( --all )
else
    SKOPEO_ARCH=( --override-arch "${PLATFORM_MODE}" --override-os linux )
fi

_skopeo() {  # 统一入口(便于 --dry-run 拦截)
    if [ "${DRY_RUN}" = "1" ]; then
        echo "  [dry-run] skopeo $*" >&2
        return 0
    fi
    skopeo "$@"
}

# 取某个 ref 的 digest(不存在/无权限返回空)。凭据经 REGISTRY_AUTH_FILE 自动生效。
_remote_digest() {   # <ref> <tls-opts...>
    local ref="$1"; shift
    _skopeo inspect --format '{{.Digest}}' "$@" "docker://${ref}" 2>/dev/null || true
}

# ---- 主循环 ----
SYNCED=0; SKIPPED=0; FAILED=0
FAIL_LIST=()
N=0
while IFS=$'\t' read -r group src_ref; do
    [ -z "${src_ref}" ] && continue
    N=$((N + 1))
    dst_ref="$(image_mirror_ref "${src_ref}")" || { FAILED=$((FAILED+1)); FAIL_LIST+=("${src_ref}(ref 非法)"); continue; }

    printf '\033[36m[%d/%d] [%s] %s\033[0m\n' "${N}" "${TOTAL}" "${group}" "${src_ref}"
    echo "        → ${dst_ref}"

    if [ "${FORCE}" != "1" ]; then
        # 比 digest: 源(上游) vs 目的地(Harbor)。凭据由 REGISTRY_AUTH_FILE 提供。
        # 源侧取不到(网络不通/无权限)→ 退化为"直接同步", 让 copy 给出真实错误。
        _src_dg="$(_remote_digest "${src_ref}" "${INSPECT_SRC_OPTS[@]}")"
        _dst_dg="$(_remote_digest "${dst_ref}" "${INSPECT_DST_OPTS[@]}")"
        if [ -n "${_src_dg}" ] && [ -n "${_dst_dg}" ] && [ "${_src_dg}" = "${_dst_dg}" ]; then
            ok "  digest 未变, 跳过(${_src_dg:0:19}...)"
            SKIPPED=$((SKIPPED + 1)); unset _src_dg _dst_dg; continue
        fi
        if [ -n "${_dst_dg}" ] && [ -z "${_src_dg}" ]; then
            warn "  取不到上游 digest(网络/权限?), 跳过比对直接同步"
        fi
        # 两边都能取到但不同 → 打印两个 digest。
        # 原实现这里什么都不打印, 于是"为什么又传了一遍"完全无法从日志判断(2026-09-18 实测
        # registry.k8s.io/pause:3.10 出现此情况但看不出原因)。带上 digest 才能事后追查:
        #   · 上游确实换了内容(浮动 tag 的正常情况) → 重传正确;
        #   · 两边都不变却每次都重传 → 说明是**镜像元数据层面的差异**(如 manifest list 的
        #     mediaType/attestation 条目在搬运中被改写), 属已知的重复传输, 不影响可用性。
        if [ -n "${_dst_dg}" ] && [ -n "${_src_dg}" ] && [ "${_src_dg}" != "${_dst_dg}" ]; then
            warn "  digest 不一致, 重新同步:"
            echo "        源: ${_src_dg}"
            echo "        库: ${_dst_dg}"
        fi
        unset _src_dg _dst_dg
    fi

    # 同步: 网络抖动重试 3 次。
    # --preserve-digests: 要求 skopeo 原样保留源侧 manifest(list) 的 digest —— 对"镜像"而言
    #   这是语义上正确的选择(镜像应逐字节一致)。
    #   ⚠ 实测(2026-09-18): 该旗标**未能解决** registry.k8s.io/pause:3.10 的 digest 不一致问题
    #     (加旗标前后源/库 digest 完全相同), 根因**未定位** —— 见下方说明与
    #     docs/troubleshooting.md §四.3.7。它就是镜像语义的正确默认, 故保留, 但**不要**
    #     把它当作那个问题的解法。
    #   个别镜像确实无法保 digest 时 skopeo 会报错, 此时立即回退普通搬运并告警, 不中断整批。
    #
    # ⚠ 已知未解问题: registry.k8s.io/pause:3.10 每次同步都会被整包重传(约 552 MB / 64 秒)。
    #   证据: 源 digest sha256:ee6521f290b2168b... 与库 digest sha256:e9622b01071c38e4...
    #   在连续多次运行中**各自稳定且始终不等** ⇒ 确定性的元数据差异, 不是上游内容变化。
    #   旁证: 库侧 list 有 7 条(含两条 amd64/windows, 属 pause 的正常多 windows 版本形态);
    #   同批的 node-exporter(6 平台 list)digest 则完全一致 ⇒ 特定镜像触发, 非普遍现象。
    #   卡点: registry.k8s.io 的 manifest 请求也会 302 到 pkg.dev, 而该域名在可控环境里不可达
    #   ⇒ 拿不到源侧 raw manifest 逐条对比。**下一步**: 在 CI 里 dump 源侧 raw manifest
    #   (skopeo inspect --raw)与库侧逐条比对平台条目, 即可定位; 在此之前属"可接受的已知损耗"。
    _ok=0
    for _try in 1 2 3; do
        if _skopeo copy --quiet --preserve-digests \
                "${SKOPEO_SRC_OPTS[@]}" "${SKOPEO_ARCH[@]}" \
                "${SKOPEO_DST_OPTS[@]}" \
                "docker://${src_ref}" "docker://${dst_ref}" 2>/tmp/.harbor-sync-err.$$; then
            _ok=1; break
        fi
        # 保 digest 不被支持的镜像: 立刻改用普通搬运(不再耗完 3 次重试)
        if grep -qiE 'preserve|digest' /tmp/.harbor-sync-err.$$ 2>/dev/null; then
            warn "  该镜像不支持 --preserve-digests, 回退普通搬运"
            if _skopeo copy --quiet \
                    "${SKOPEO_SRC_OPTS[@]}" "${SKOPEO_ARCH[@]}" \
                    "${SKOPEO_DST_OPTS[@]}" \
                    "docker://${src_ref}" "docker://${dst_ref}" 2>/tmp/.harbor-sync-err.$$; then
                _ok=1; break
            fi
        fi
        if [ "${_try}" -lt 3 ]; then
            warn "  同步失败(第 ${_try}/3 次): $(tail -1 /tmp/.harbor-sync-err.$$ 2>/dev/null | head -c 200)"
            sleep 5
        fi
    done
    rm -f /tmp/.harbor-sync-err.$$
    if [ "${_ok}" = "1" ]; then
        ok "  已同步"
        SYNCED=$((SYNCED + 1))
    else
        err "  同步失败: ${src_ref}"
        FAILED=$((FAILED + 1)); FAIL_LIST+=("${src_ref}")
    fi
done < "${LIST_FILE}"

# ---- 汇总 ----
echo "---------------------------------------------"
ok "同步完成: 新同步 ${SYNCED} 个, digest 未变跳过 ${SKIPPED} 个, 失败 ${FAILED} 个"
if [ "${#SAME_HARBOR_SKIPPED[@]}" -gt 0 ]; then
    warn "另有 ${#SAME_HARBOR_SKIPPED[@]} 个镜像**本就在本台 Harbor 上, 不镜像到 mirrors/**(这是预期行为):"
    for _s in "${SAME_HARBOR_SKIPPED[@]}"; do echo "    - ${_s}"; done
    echo "  说明: 这些组件的部署模块直接从其现有项目(metax/ 与 suanova/)拉取, 无需改代码、无重复存储。"
    echo "  确实想要 mirrors/ 下的副本时: ./harbor-sync-images.sh --include-same-harbor --group metax-gpu,cubepilot"
fi
echo "  Harbor:  ${HARBOR_API}/${HARBOR_PROJ}/"
echo "  下一步:  联网机执行 tools/images/harbor-save-images.sh 生成离线 tar"
if [ "${FAILED}" -gt 0 ]; then
    err "以下镜像同步失败:"
    for _f in "${FAIL_LIST[@]}"; do echo "    - ${_f}"; done
    echo "  排查: 上游是否可达 / tag 是否存在 / Harbor 凭据与权限(建项需登录) / TLS 校验(HARBOR_MIRROR_INSECURE)"
    exit 1
fi
exit 0
