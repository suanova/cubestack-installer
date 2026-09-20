#!/bin/bash
# ============================================================
# harbor-save-images.sh — Harbor 统一镜像源 → 离线 tar(部署侧第一段)
# ============================================================
# 作用: 读 deployments/config/images.manifest, 把**每个镜像从 Harbor 拉下来并保存为 tar**,
#       落到各组件既有的离线目录(deployments/offline-files/<group>/)。之后由部署模块
#       (08_prometheus / 02_ceph / 15_envoy_gateway / ...)推入集群内置 registry —— 节点只
#       从内置 registry 拉取。全程**不需要上游 registry**, 只要一台能连 Harbor 的机器。
#
# 制品流向(本脚本 = 中间那一段):
#   上游 ──harbor-sync-images.sh──▶ Harbor mirrors/** ──**本脚本**──▶ 离线 tar ──模块──▶ 内置 registry
#
# 与既有 *_save-images.sh 的关系:
#   那些脚本各自直连上游(docker.io/quay.io/...)。本脚本是**统一版**: 一次覆盖全部组件,
#   且源可切换(Harbor 优先), 不改变任何既有脚本的行为 —— 两者产出的 tar 命名一致,
#   可混用、可互相补缺。
#
# ── tar 命名(关键兼容点) ──────────────────────────────────
#   按**上游 ref** 命名(如 registry.k8s.io_kube-state-metrics_kube-state-metrics_v2.20.0.tar),
#   而不是按 Harbor ref —— 因为既有部署模块都用 "*<repo>_<tag>.tar" 通配查找。
#   少数"历史短名"镜像(busybox.tar / nginx.tar)由清单第 3 列显式指定文件名。
#
# ── 幂等 ────────────────────────────────────────────────
#   已有 tar 默认**跳过**(只补缺); --force 强制重下覆盖。
#
# 用法:
#   sudo ./harbor-save-images.sh                     # 全部镜像 → 各自离线目录
#   sudo ./harbor-save-images.sh --list              # 只列清单(不下载)
#   sudo ./harbor-save-images.sh --group prometheus  # 只拉指定分组
#   sudo ./harbor-save-images.sh --exclude-group metax-gpu
#   sudo ./harbor-save-images.sh --force             # 强制重下
#   sudo ./harbor-save-images.sh --from-upstream     # 直连上游(不用 Harbor; 等价 HARBOR_MIRROR_ENABLED=false)
#   sudo ./harbor-save-images.sh --platform all      # 保留多架构(默认 amd64, 与部署目标一致)
# 前置: skopeo; 能连 Harbor(默认匿名 — 项目公开只读; 私有化后配 HARBOR_MIRROR_USER/PASSWORD)
# 退出码: 0=全部成功(含跳过); 1=有失败项
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-image-manifest.sh
source "${SCRIPT_DIR}/lib-image-manifest.sh"

_log_file() { [ -n "${LOG_FILE:-}" ] && echo -e "$*" >> "${LOG_FILE}" 2>/dev/null || true; }
say()  { local m="→  $*"; echo -e "\033[36m${m}\033[0m"; _log_file "${m}"; }
ok()   { local m="✅ $*"; echo -e "\033[32m${m}\033[0m"; _log_file "${m}"; }
warn() { local m="⚠  $*"; echo -e "\033[33m${m}\033[0m"; _log_file "${m}"; }
err()  { local m="【错误】$*"; echo -e "\033[31m${m}\033[0m" >&2; _log_file "${m}"; }

# ---- 参数 ----
MODE="save"; FORCE=0
INCLUDE_GROUPS=""; EXCLUDE_GROUPS=""
FROM_HARBOR=1
PLATFORM_MODE="amd64"        # 部署目标是 amd64 节点, 默认单架构(省一半以上体积)
while [ $# -gt 0 ]; do
    case "$1" in
        --list|-l)        MODE="list" ;;
        --force|-f)       FORCE=1 ;;
        --from-upstream)  FROM_HARBOR=0 ;;
        --group|-g)       INCLUDE_GROUPS="${2:?--group 需要值}"; shift ;;
        --group=*)        INCLUDE_GROUPS="${1#*=}" ;;
        --exclude-group)  EXCLUDE_GROUPS="${2:?--exclude-group 需要值}"; shift ;;
        --exclude-group=*) EXCLUDE_GROUPS="${1#*=}" ;;
        --platform)       PLATFORM_MODE="${2:?--platform 需要值(all|amd64)}"; shift ;;
        --platform=*)     PLATFORM_MODE="${1#*=}" ;;
        --help|-h)        sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "未知参数: $1(--help 看用法)"; exit 1 ;;
    esac
    shift
done

image_manifest_load || exit 1

HARBOR_HOST="${HARBOR_MIRROR_REGISTRY:-harbor.isuanova.com}"
HARBOR_PROJ="${HARBOR_MIRROR_PROJECT:-mirrors}"
HARBOR_USER="${HARBOR_MIRROR_USER:-}"
HARBOR_PASSWORD="${HARBOR_MIRROR_PASSWORD:-}"
HARBOR_INSECURE="${HARBOR_MIRROR_INSECURE:-false}"
# cluster.conf 的 HARBOR_MIRROR_ENABLED=false 等价 --from-upstream(命令行优先)
if [ "${HARBOR_MIRROR_ENABLED:-true}" != "true" ]; then
    FROM_HARBOR=0
fi

_group_selected() {
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

# ---- 展开为 "group<TAB>src_ref<TAB>tar_path<TAB>tar_name<TAB>upstream_ref" ----
LIST_FILE="$(mktemp)"
trap 'rm -f "${LIST_FILE}"' EXIT
while IFS=$'\t' read -r g r n; do
    _group_selected "${g}" || continue
    if [ "${FROM_HARBOR}" = "1" ]; then
        src="$(image_mirror_ref "${r}")" || { warn "ref 非法, 跳过: ${r}"; continue; }
    else
        src="${r}"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "${g}" "${src}" "$(image_tar_path "${g}" "${r}" "${n}")" "$(image_tar_name "${r}" "${n}")" "${r}"
done < <(image_manifest_entries) > "${LIST_FILE}"

TOTAL="$(grep -c . "${LIST_FILE}" || true)"
[ "${TOTAL}" -gt 0 ] || { err "清单为空(检查 --group/--exclude-group 过滤)"; exit 1; }

if [ "${FROM_HARBOR}" = "1" ]; then
    say "镜像来源: Harbor 统一镜像源 ${HARBOR_HOST}/${HARBOR_PROJ}/**(共 ${TOTAL} 个)"
else
    say "镜像来源: **上游 registry 直连**(HARBOR_MIRROR_ENABLED=false / --from-upstream; 共 ${TOTAL} 个)"
fi
say "配置来源: ${IM_CONF_FILE}"

if [ "${MODE}" = "list" ]; then
    echo "将保存的镜像(源 → 离线 tar):"
    while IFS=$'\t' read -r g src dest name _up; do
        exists="-"; [ -f "${dest}" ] && exists="[已有]"
        printf '  [%-18s] %-58s → %s %s\n' "${g}" "${src}" "${dest#*/deployments/offline-files/}" "${exists}"
    done < "${LIST_FILE}"
    echo
    echo "分组统计:"
    cut -f1 "${LIST_FILE}" | sort | uniq -c | awk '{printf "  %-20s %s\n", $2, $1}'
    exit 0
fi

command -v skopeo >/dev/null 2>&1 || { err "未找到 skopeo(apt-get install -y skopeo)"; exit 1; }
_sudo=""; [ "$(id -u)" -ne 0 ] && _sudo="sudo"
# skopeo 默认 auth 文件路径在容器内/非 root 下常不可读 → 显式指向自己可控的文件(踩过)
AUTH_FILE="$(mktemp)"; chmod 600 "${AUTH_FILE}"
trap 'rm -f "${LIST_FILE}" "${AUTH_FILE}"' EXIT
if [ -n "${HARBOR_USER}" ] && [ -n "${HARBOR_PASSWORD}" ]; then
    _b64="$(printf '%s:%s' "${HARBOR_USER}" "${HARBOR_PASSWORD}" | base64 -w0 2>/dev/null \
            || printf '%s:%s' "${HARBOR_USER}" "${HARBOR_PASSWORD}" | base64)"
    printf '{"auths":{"%s":{"auth":"%s"}}}' "${HARBOR_HOST}" "${_b64}" > "${AUTH_FILE}"
    unset _b64
    say "凭据: 私有 auth 文件(600, 退出即删)"
else
    printf '{"auths":{}}' > "${AUTH_FILE}"
    say "凭据: 匿名(Harbor 项目 ${HARBOR_PROJ} 公开只读; 私有化后配 HARBOR_MIRROR_USER/PASSWORD)"
fi
export REGISTRY_AUTH_FILE="${AUTH_FILE}"

# skopeo 参数: 源侧 TLS 按 HARBOR_MIRROR_INSECURE(仅 Harbor 源时需要)
SRC_TLS=( --src-tls-verify=true )
[ "${FROM_HARBOR}" = "1" ] && [ "${HARBOR_INSECURE}" = "true" ] && SRC_TLS=( --src-tls-verify=false )
ARCH=()
if [ "${PLATFORM_MODE}" = "all" ]; then
    ARCH=( --all )
else
    ARCH=( --override-arch "${PLATFORM_MODE}" --override-os linux )
fi

# ---- 主循环 ----
SAVED=0; SKIPPED=0; FAILED=0
FAIL_LIST=()
N=0
while IFS=$'\t' read -r group src dest name up_ref; do
    [ -z "${src}" ] && continue
    N=$((N + 1))
    printf '\033[36m[%d/%d] [%s] %s\033[0m\n' "${N}" "${TOTAL}" "${group}" "${src}"
    echo "        → ${dest}"

    if [ -f "${dest}" ] && [ "${FORCE}" != "1" ]; then
        ok "  tar 已存在, 跳过(--force 可覆盖)"
        SKIPPED=$((SKIPPED + 1)); continue
    fi

    # 目标目录(offline-files 各组件子目录); 需要时补建并归属当前用户
    _dir="$(dirname "${dest}")"
    mkdir -p "${_dir}" 2>/dev/null || ${_sudo} mkdir -p "${_dir}"

    # ⚠ `docker-archive:<file>:<ref>` 末尾的 ref **不能省**: 省了 skopeo 写出 RepoTags=[],
    #   而 lib-common 的 tar_first_image_tag 正是读 RepoTags 来识别 tar 内容(内容兜底匹配、
    #   ensure_registry_nginx 等都依赖它)。这里填**上游 ref**, 与 docker save 产出的 tar 一致。
    _src_ref="docker://${src}"
    # ⚠ 先写临时文件、成功后再 mv 落位(踩过, 会真丢东西):
    #   ① skopeo **不能覆盖已存在的 docker-archive**("doesn't support modifying existing images"),
    #      所以 --force 想覆盖时, 目标路径必须不存在 —— 直接写 ${dest} 会连试 3 次全失败;
    #   ② 失败分支**绝不能删 ${dest}** —— 那是上一轮留下的好 tar(实测丢过一个 226MB 的镜像)。
    _dst_tmp="${dest}.part"
    _dst_ref="docker-archive:${_dst_tmp}:${up_ref}"
    rm -f "${_dst_tmp}" 2>/dev/null || ${_sudo} rm -f "${_dst_tmp}" 2>/dev/null || true
    _ok=0
    for _try in 1 2 3; do
        if skopeo copy --quiet "${SRC_TLS[@]}" "${ARCH[@]}" \
                --dest-tls-verify=false \
                "${_src_ref}" "${_dst_ref}" 2>/tmp/.harbor-save-err.$$; then
            _ok=1; break
        fi
        if [ "${_try}" -lt 3 ]; then
            warn "  失败(第 ${_try}/3 次): $(tail -1 /tmp/.harbor-save-err.$$ 2>/dev/null | head -c 180)"
            sleep 3
        fi
    done
    if [ "${_ok}" != "1" ]; then
        err "  保存失败: ${src}"
        err "    原因: $(tail -1 /tmp/.harbor-save-err.$$ 2>/dev/null | head -c 300)"
        FAILED=$((FAILED + 1)); FAIL_LIST+=("${src}")
        rm -f "${_dst_tmp}" /tmp/.harbor-save-err.$$    # 只删本次的临时件, 不动已有 tar
        continue
    fi
    rm -f /tmp/.harbor-save-err.$$
    mv -f "${_dst_tmp}" "${dest}" 2>/dev/null || ${_sudo} mv -f "${_dst_tmp}" "${dest}"
    chmod 644 "${dest}" 2>/dev/null || ${_sudo} chmod 644 "${dest}" 2>/dev/null || true
    ok "  已保存: $(du -h "${dest}" 2>/dev/null | awk '{print $1}')"
    SAVED=$((SAVED + 1))
done < "${LIST_FILE}"

# ---- 汇总 ----
echo "---------------------------------------------"
ok "保存完成: 新下载 ${SAVED} 个, 已存在跳过 ${SKIPPED} 个, 失败 ${FAILED} 个"
echo "  离线目录: ${IMAGE_OFFLINE_ROOT:-${IM_REPO_ROOT}/deployments/offline-files}/"
echo "  下一步:   把 offline-files/ 拷到部署机 → 集群部署模块会自动推入内置 registry"
if [ "${FAILED}" -gt 0 ]; then
    err "以下镜像保存失败:"
    for _f in "${FAIL_LIST[@]}"; do echo "    - ${_f}"; done
    if [ "${FROM_HARBOR}" = "1" ]; then
        echo "  排查: Harbor 是否已同步该镜像(tools/images/check-image-manifest.sh --harbor);"
        echo "        或在 CI 侧跑 .github/workflows/sync-images-to-harbor.yml 补齐"
    else
        echo "  排查: 上游是否可达 / tag 是否存在 / 网络代理"
    fi
    exit 1
fi
exit 0
