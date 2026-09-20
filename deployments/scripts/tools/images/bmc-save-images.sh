#!/bin/bash
# ============================================================
# bmc-save-images.sh — BMC exporter 2 镜像 → 离线 tar
# 用途: 在**联网机**上把 BMC exporter 的镜像从私服 Harbor 导出为 tar, 供离线部署用:
#   deployments/offline-files/bmc/<repo>_<tag>.tar      (文件名规则: / 与 : → _)
#   例: harbor.isuanova.com_suanova_bmc-oem-exporter_latest.tar
# 镜像清单(2 个; 与 chart cubestack-bmc-exporter-chart 的 values 键一一对应):
#   bmc-oem-exporter  → bmcOemExporter.image   (PCIeDevices OEM 字段, /probe 多目标)
#   idrac-exporter    → idracExporter.image    (标准 Redfish 分组, /metrics 多目标)
# ⚠ 两个都要 —— 部署模块把 chart 里**两个** image.repository 都指向内置 registry,
#   只备一个另一个仍会 ImagePullBackOff。
# 获取顺序(与 cubepilot-save-images.sh 一致, 逐级兜底):
#   ① 本地 docker 已有该镜像 → docker save
#   ② docker pull(5 次重试)→ docker save
#   ③ skopeo copy docker:// → docker-archive(docker 不可用时兜底)
# 同步写 <tar>.digest 边车(源镜像的 digest): 部署模块 33_bmc_exporter 靠它判断
#   "私服上这个 tag 变没变" —— 上游只发 :latest, 会漂移; 有边车才不白传。
# 独立运行: 不依赖 lib-common.sh / cluster.conf(自带最小日志与路径推导, 缺 policy.json 自动生成)。
# 幂等: 已存在的 tar 默认**跳过**(加 --force 强制重新下载覆盖)。
# 用法:   sudo ./bmc-save-images.sh                  # 下载 2 个镜像
#         sudo ./bmc-save-images.sh --list           # 只列出要下载的镜像清单(不下载)
#         sudo ./bmc-save-images.sh --force          # 强制重新下载(覆盖已有 tar)
# 前置:   docker(推荐)或 skopeo; 私服可选凭据(该 Harbor 公开只读, 通常免登录)
# ============================================================
set -euo pipefail

# ---- 独立运行: 自带最小日志与路径(不 source lib-common.sh / 不 load_config) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# skopeo 的最小 trust policy(无容器运行时配置的机器上, 缺 /etc/containers/policy.json 会 fatal)
ensure_skopeo_policy() {
    [ -f "/etc/containers/policy.json" ] && return 0
    mkdir -p /etc/containers 2>/dev/null || return 0
    cat > /etc/containers/policy.json <<'POLICY_EOF'
{
    "default": [
        {
            "type": "insecureAcceptAnything"
        }
    ],
    "transports": {}
}
POLICY_EOF
}

BMC_EXPORTER_HARBOR="${BMC_EXPORTER_HARBOR:-harbor.isuanova.com}"
BMC_EXPORTER_PROJECT="${BMC_EXPORTER_PROJECT:-suanova}"
BMC_EXPORTER_IMAGE_TAG="${BMC_EXPORTER_IMAGE_TAG:-latest}"
BMC_EXPORTER_SAVE_DIR="${BMC_EXPORTER_SAVE_DIR:-${REPO_ROOT}/deployments/offline-files/bmc}"
IMAGE_BASE="${BMC_EXPORTER_HARBOR}/${BMC_EXPORTER_PROJECT}"

# ---- 参数解析: --list / --force ----
MODE="save"; FORCE=0
for a in "$@"; do
    case "${a}" in
        --list|-l)  MODE="list" ;;
        --force|-f) FORCE=1 ;;
        *) err "未知参数: ${a}(支持 --list / --force)"; exit 1 ;;
    esac
done

# 默认镜像清单(可用 BMC_EXPORTER_IMAGE_LIST 覆盖; 每行一个源镜像 ref)
BMC_EXPORTER_IMAGE_LIST="${BMC_EXPORTER_IMAGE_LIST:-}"
if [ -z "${BMC_EXPORTER_IMAGE_LIST}" ]; then
    BMC_EXPORTER_IMAGE_LIST="${IMAGE_BASE}/bmc-oem-exporter:${BMC_EXPORTER_IMAGE_TAG}
${IMAGE_BASE}/idrac-exporter:${BMC_EXPORTER_IMAGE_TAG}"
fi

fname_of() { echo "$(echo "$1" | sed 's#/#_#g; s#:#_#g').tar"; }

if [ "${MODE}" = "list" ]; then
    echo "BMC exporter 需下载的镜像清单(保存目录: ${BMC_EXPORTER_SAVE_DIR}):"
    while IFS= read -r src; do
        [ -z "${src}" ] && continue
        f="$(fname_of "${src}")"
        if [ -f "${BMC_EXPORTER_SAVE_DIR}/${f}" ]; then
            printf '  %-70s [已有] %s\n' "${src}" "${f}"
        else
            printf '  %-70s [待下载] %s\n' "${src}" "${f}"
        fi
    done <<< "${BMC_EXPORTER_IMAGE_LIST}"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { err "需要 root(docker/skopeo 访问与写入 /etc/containers), 请 sudo 执行"; exit 1; }
mkdir -p "${BMC_EXPORTER_SAVE_DIR}"
say "配置: 私服=${BMC_EXPORTER_HARBOR} 镜像 tag=${BMC_EXPORTER_IMAGE_TAG} 保存目录=${BMC_EXPORTER_SAVE_DIR}"

HAS_DOCKER=0; command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && HAS_DOCKER=1
HAS_SKOPEO=0; command -v skopeo >/dev/null 2>&1 && HAS_SKOPEO=1
[ "${HAS_DOCKER}" = "1" ] || [ "${HAS_SKOPEO}" = "1" ] \
    || { err "docker 与 skopeo 均不可用, 至少要有一个(建议 docker)"; exit 1; }
# 提供凭据时先 docker login(该 Harbor 公开只读, 通常无需; 私有化后才需要)
if [ "${HAS_DOCKER}" = "1" ] && [ -n "${BMC_EXPORTER_HARBOR_USER:-}" ] && [ -n "${BMC_EXPORTER_HARBOR_PASSWORD:-}" ]; then
    say "docker login ${BMC_EXPORTER_HARBOR}(用户 ${BMC_EXPORTER_HARBOR_USER})..."
    printf '%s' "${BMC_EXPORTER_HARBOR_PASSWORD}" | docker login "${BMC_EXPORTER_HARBOR}" \
        -u "${BMC_EXPORTER_HARBOR_USER}" --password-stdin >/dev/null 2>&1 \
        && ok "  登录成功" || warn "  docker login 失败(继续尝试, 可能本机已有登录态或镜像已存在)"
fi

# 取源镜像 digest(写边车用): 优先 skopeo inspect, 退化到 docker inspect
remote_digest() {   # <src>
    local src="$1" dg=""
    if [ "${HAS_SKOPEO}" = "1" ]; then
        ensure_skopeo_policy
        local creds=()
        if [ -n "${BMC_EXPORTER_HARBOR_USER:-}" ] && [ -n "${BMC_EXPORTER_HARBOR_PASSWORD:-}" ]; then
            creds=( --creds "${BMC_EXPORTER_HARBOR_USER}:${BMC_EXPORTER_HARBOR_PASSWORD}" )
        fi
        dg="$(skopeo inspect --format '{{.Digest}}' --tls-verify=false "${creds[@]}" "docker://${src}" 2>/dev/null || true)"
    fi
    if [ -z "${dg}" ] && [ "${HAS_DOCKER}" = "1" ]; then
        dg="$(docker image inspect --format '{{index .RepoDigests 0}}' "${src}" 2>/dev/null | sed 's/.*@//' || true)"
    fi
    printf '%s' "${dg}"
}

# 保存单个镜像(三级兜底)
save_one() {
    local src="$1" dest="$2" fname="$3"
    local retry
    # ① 本地 docker 已有 → 直接 save
    if [ "${HAS_DOCKER}" = "1" ] && docker image inspect "${src}" >/dev/null 2>&1; then
        say "  本地已有 ${src}, 直接 save..."
        if docker save "${src}" -o "${dest}"; then
            chmod 644 "${dest}"; ok "保存完成(本地已有): ${fname}"; return 0
        fi
        warn "  docker save 失败, 尝试重新拉取..."
        rm -f "${dest}"
    fi
    # ② docker pull(5 次重试)→ save
    if [ "${HAS_DOCKER}" = "1" ]; then
        say "  docker pull ${src}(最多 5 次)..."
        retry=1
        while ! docker pull "${src}" >/dev/null 2>&1; do
            [ "${retry}" -ge 5 ] && { warn "  docker pull 失败(5 次): ${src}"; break; }
            retry=$((retry + 1)); sleep 3
        done
        if docker image inspect "${src}" >/dev/null 2>&1; then
            if docker save "${src}" -o "${dest}"; then
                chmod 644 "${dest}"; ok "保存完成(pull+save): ${fname}"; return 0
            fi
            warn "  docker save 失败: ${src}"
        fi
    fi
    # ③ skopeo 兜底(docker 不可用 / docker pull 失败)
    if [ "${HAS_SKOPEO}" = "1" ]; then
        ensure_skopeo_policy
        say "  skopeo copy ${src} → docker-archive:${dest} ..."
        # ⚠ 用 "${creds[@]}" 而非 "${creds[@]:-}": 后者在**空数组**时会展开出一个空字符串参数
        #   (bash 5.1 实测 argc=1) → skopeo 收到空位置参数直接失败。set -u 下空数组用 "${arr[@]}" 是安全的。
        local creds=()
        if [ -n "${BMC_EXPORTER_HARBOR_USER:-}" ] && [ -n "${BMC_EXPORTER_HARBOR_PASSWORD:-}" ]; then
            creds=( --src-creds "${BMC_EXPORTER_HARBOR_USER}:${BMC_EXPORTER_HARBOR_PASSWORD}" )
        fi
        if skopeo copy --quiet --src-tls-verify=false "${creds[@]}" "docker://${src}" "docker-archive:${dest}"; then
            chmod 644 "${dest}"; ok "保存完成(skopeo): ${fname}"; return 0
        fi
        warn "  skopeo copy 失败: ${src}"
    fi
    rm -f "${dest}"
    err "  镜像保存失败: ${src}"
    return 1
}

say "开始导出 BMC exporter 镜像 → ${BMC_EXPORTER_SAVE_DIR} ..."
count=0; skip=0; fail=0
while IFS= read -r src; do
    [ -z "${src}" ] && continue
    dest="${BMC_EXPORTER_SAVE_DIR}/$(fname_of "${src}")"
    if [ -f "${dest}" ] && [ "${FORCE}" != "1" ]; then
        echo "  [跳过] $(basename "${dest}")(已存在; --force 可覆盖)"
        skip=$((skip + 1)); continue
    fi
    if save_one "${src}" "${dest}" "$(basename "${dest}")"; then
        count=$((count + 1))
        # 写 digest 边车: 部署模块 33_bmc_exporter 的 online 模式靠它判断"tag 是否漂移",
        # 有边车才不会每次都重新 pull(上游只发 :latest, 漂移是常态)。
        dg="$(remote_digest "${src}")"
        if [ -n "${dg}" ]; then
            printf '%s' "${dg}" > "${dest}.digest"
            chmod 644 "${dest}.digest"
            say "    已写 digest 边车: $(basename "${dest}").digest(源 digest ${dg:0:19}...)"
        else
            warn "    取不到源 digest, 未写边车(部署模块会把它当'未知'→ 下次 online 会重下)"
        fi
    else
        fail=$((fail + 1))
    fi
done <<< "${BMC_EXPORTER_IMAGE_LIST}"

echo "---------------------------------------------"
if [ "${fail}" -gt 0 ]; then
    err "保存完成但有失败: 新增 ${count} 个, 跳过 ${skip} 个, **失败 ${fail} 个**(见上方错误)"
    echo "  排查: 私服可达? 镜像 tag 存在?(BMC_EXPORTER_IMAGE_TAG 默认 latest)"
    exit 1
fi
ok "保存完成: 新增 ${count} 个, 跳过 ${skip} 个(已存在), 目录: ${BMC_EXPORTER_SAVE_DIR}"
du -sh "${BMC_EXPORTER_SAVE_DIR}" 2>/dev/null | awk '{print "  总大小: "$1}'
echo "  下一步: 把 ${BMC_EXPORTER_SAVE_DIR}/ 与 chart tgz 拷到部署机,"
echo "          部署机 cluster.conf 置 BMC_EXPORTER_MODE=offline 后 --steps bmc_exporter(模块会推入集群内置 registry)"
echo "  ⚠ 仅在\"离线机没有私服访问\"时才需要本脚本; 部署机若可访问私服,"
echo "    BMC_EXPORTER_MODE=online(默认) 会在部署时自动完成同样的同步(见模块 33_bmc_exporter.sh)"
