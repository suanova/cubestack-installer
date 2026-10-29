#!/bin/bash
# ============================================================
# release-publish.sh — CubeStack 发布版本构建/校验/发布(参考实现)
# ------------------------------------------------------------
# 目标(详见 docs/release-management.md):
#   MinIO: <bucket>/<版本>/offline-files/ + <bucket>/<版本>/cubestack-installer-cli-v<版本>.tar
#   本地:  <stage-dir>/offline-files/       + <stage-dir>/cubestack-installer-cli-v<版本>.tar
#
# 子命令:
#   stage    从 Harbor 拉取镜像 → 本地 staging 树(含 release.env/release.json/SHA256SUMS/CLI tar)
#   verify   校验 staging: SHA256SUMS + 清单覆盖 + CLI tar sha + chart/dev-lab 存在
#   publish  上传到 MinIO <bucket>/<版本>/; 拒绝覆盖; _SUCCESS 最后写
#
# 用法:
#   release-publish.sh stage   --release 2.0.0 [--stage-dir /data/release-staging/2.0.0] [--source-dir <dev offline-files>] [--force|--resume]
#   release-publish.sh verify  --release 2.0.0 [--stage-dir ...]
#   release-publish.sh publish --release 2.0.0 [--stage-dir ...] [--bucket cubestack-installer]
#                              [--dry-run] [--no-verify-remote]
#
#   --force   staging 非空时清空重建
#   --resume  staging 非空时复用(已完成的镜像 tar/边车跳过, 只补齐缺失项; 适合中断续跑;
#             旧版本 operator chart 会在复制时清理, 发布树只保留当前版本)
#
# 数据源:
#   deployments/releases/<版本>/release.env       版本变量(发布树真相)
#   deployments/releases/<版本>/release-images.tsv 平台/自研组件镜像清单
#   deployments/config/images.manifest            上游 + dev-lab 镜像清单
#   deployments/offline-files/model-collection/image-list.tsv 模型镜像清单
#
# 前置: skopeo / mc / python3 / sha256sum; Harbor 凭据(REGISTRY_AUTH_FILE 或
#       HARBOR_MIRROR_USER/PASSWORD, 或 cluster.conf 中已有)；MinIO 凭据(minio.conf 或 MINIO_*)。
# 退出码: 0=成功; 1=失败/前置缺失。
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
IMAGES_DIR="${REPO_ROOT}/deployments/scripts/tools/images"
# shellcheck source=../../lib-common.sh
. "${REPO_ROOT}/deployments/scripts/lib-common.sh"
OFFLINE_DIR=""   # 由 --source-dir 设置(默认仓库 dev offline-files)
MINIO_CONF="${MINIO_CONF:-${REPO_ROOT}/deployments/config/minio.conf}"

say()  { echo -e "\033[36m→  $*\033[0m"; }
ok()   { echo -e "\033[32m✅ $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m"; }
err()  { echo -e "\033[31m【错误】$*\033[0m" >&2; }

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

CMD="${1:-}"; [ $# -gt 0 ] && shift
[ -n "${CMD}" ] || { usage; exit 2; }

RELEASE=""; STAGE_DIR=""; SOURCE_DIR=""; BUCKET="${MINIO_BUCKET:-cubestack-installer}"
ALIAS="${MINIO_ALIAS:-minio}"; DRY_RUN=0; VERIFY_REMOTE=1; FORCE=0; RESUME=0
BUCKET_SET=0; ALIAS_SET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --release) RELEASE="${2:?--release 需要版本号}"; shift 2 ;;
        --stage-dir) STAGE_DIR="${2:?--stage-dir 需要目录}"; shift 2 ;;
        --source-dir) SOURCE_DIR="${2:?--source-dir 需要目录}"; shift 2 ;;
        --bucket) BUCKET="${2:?--bucket 需要桶名}"; BUCKET_SET=1; shift 2 ;;
        --alias) ALIAS="${2:?--alias 需要 mc alias}"; ALIAS_SET=1; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --no-verify-remote) VERIFY_REMOTE=0; shift ;;
        --force) FORCE=1; shift ;;
        --resume) RESUME=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) err "未知参数: $1"; usage; exit 2 ;;
    esac
done
[ -n "${RELEASE}" ] || { err "缺少 --release <版本>"; exit 2; }
OFFLINE_DIR="${SOURCE_DIR:-${REPO_ROOT}/deployments/offline-files}"

RELEASE_DIR="${REPO_ROOT}/deployments/releases/${RELEASE}"
[ -f "${RELEASE_DIR}/release.env" ] || { err "发布定义不存在: ${RELEASE_DIR}/release.env"; exit 1; }
[ -f "${RELEASE_DIR}/release-images.tsv" ] || { err "发布镜像清单不存在: ${RELEASE_DIR}/release-images.tsv"; exit 1; }

# release.env 是版本真相; 导出后子工具(cluster.defaults 的 ${VAR:-} 写法)自然采用
set -a
# shellcheck disable=SC1090
source "${RELEASE_DIR}/release.env"
set +a
[ "${RELEASE_VERSION:-}" = "${RELEASE}" ] || { err "release.env 版本不符: ${RELEASE_VERSION:-<空>} != ${RELEASE}"; exit 1; }
[ -n "${KUBESPRAY_VERSION:-}" ] || { err "release.env 缺少 KUBESPRAY_VERSION"; exit 1; }

STAGE_DIR="${STAGE_DIR:-/data/release-staging/${RELEASE}}"
STAGE_TREE="${STAGE_DIR}/offline-files"
CLI_IMAGE="${CUBESTACK_CLI_IMAGE:-harbor.isuanova.com/suanova/cubestack-installer-cli:${RELEASE}}"
# CLI tar 文件名必须带发布版本(2026-10-25 用户口径): 同一本地桶根/下载目录可并存多个版本,
# 避免不同版本的 cubestack-installer-cli.tar 互相覆盖。旧布局名仅由 fetch 侧兼容读取。
CLI_TAR_NAME="cubestack-installer-cli-v${RELEASE#v}.tar"
CLI_TAR="${STAGE_DIR}/${CLI_TAR_NAME}"
CHART_NAME="cubestack-operator-chart"
CHART_TGZ="${CHART_NAME}-${CUBESTACK_OPERATOR_CHART_VERSION:-${RELEASE}}.tgz"

_need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "缺少命令: $1"; exit 1; }; }

# ---------- MinIO / Harbor 凭据 ----------
_MC_READY=0
_load_minio_conf() {
    if [ -f "${MINIO_CONF}" ]; then
        # shellcheck disable=SC1090
        set -a; source "${MINIO_CONF}"; set +a
        [ "${ALIAS_SET}" = "1" ] || ALIAS="${MINIO_ALIAS:-${ALIAS}}"
        [ "${BUCKET_SET}" = "1" ] || BUCKET="${MINIO_BUCKET:-${BUCKET}}"
    fi
}
_mc_setup() {
    _need_cmd mc
    _load_minio_conf
    if [ -n "${MINIO_ENDPOINT:-}" ] && [ -n "${MINIO_ACCESS_KEY:-}" ] && [ -n "${MINIO_SECRET_KEY:-}" ]; then
        mc alias set "${ALIAS}" "${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" >/dev/null 2>&1 \
            || { err "mc alias 配置失败(检查 MINIO_ENDPOINT/凭证)"; exit 1; }
    elif [ -n "$(mc alias list 2>/dev/null | awk -v a="${ALIAS}" '$1==a{print; exit}' || true)" ]; then
        :
    else
        err "未配置 mc alias '${ALIAS}': 设置 MINIO_* 或 minio.conf"
        exit 1
    fi
    _mc_has "${ALIAS}/${BUCKET}" || { err "MinIO 桶不存在: ${ALIAS}/${BUCKET}"; exit 1; }
    _MC_READY=1
}
_mc_has() { [ -n "$(mc ls "$1" 2>/dev/null)" ]; }

_SKOPEO_AUTH_ARGS=(); _AUTH_TMP=""
_cleanup() { [ -n "${_AUTH_TMP}" ] && rm -f "${_AUTH_TMP}" || true; }
trap _cleanup EXIT
# cluster.conf 里的 Harbor 凭据(仅提取, 不污染 release.env 的版本变量)
_harbor_creds_from_conf() {
    local conf="${REPO_ROOT}/deployments/config/cluster.conf"
    [ -f "${conf}" ] || return 0
    (
        set +u
        # shellcheck disable=SC1090
        . "${conf}" >/dev/null 2>&1 || true
        printf '%s\n%s\n' "${HARBOR_MIRROR_USER:-}" "${HARBOR_MIRROR_PASSWORD:-}"
    )
}
_skopeo_auth_init() {
    if [ -n "${REGISTRY_AUTH_FILE:-}" ]; then
        _SKOPEO_AUTH_ARGS=(--authfile "${REGISTRY_AUTH_FILE}")
        return 0
    fi
    HARBOR_MIRROR_USER="${HARBOR_MIRROR_USER:-${CUBESTACK_OPERATOR_HARBOR_USER:-}}"
    HARBOR_MIRROR_PASSWORD="${HARBOR_MIRROR_PASSWORD:-${CUBESTACK_OPERATOR_HARBOR_PASSWORD:-}}"
    if [ -z "${HARBOR_MIRROR_USER:-}" ] || [ -z "${HARBOR_MIRROR_PASSWORD:-}" ]; then
        local _creds _u _p
        _creds="$(_harbor_creds_from_conf)"
        _u="$(printf '%s\n' "${_creds}" | sed -n '1p')"
        _p="$(printf '%s\n' "${_creds}" | sed -n '2p')"
        [ -n "${_u}" ] && [ -n "${_p}" ] && { HARBOR_MIRROR_USER="${_u}"; HARBOR_MIRROR_PASSWORD="${_p}"; }
        unset _creds _u _p
    fi
    if [ -n "${HARBOR_MIRROR_USER:-}" ] && [ -n "${HARBOR_MIRROR_PASSWORD:-}" ]; then
        _AUTH_TMP="$(mktemp)"; chmod 600 "${_AUTH_TMP}"
        local _b64
        _b64="$(printf '%s:%s' "${HARBOR_MIRROR_USER}" "${HARBOR_MIRROR_PASSWORD}" | base64 -w0 2>/dev/null \
                || printf '%s:%s' "${HARBOR_MIRROR_USER}" "${HARBOR_MIRROR_PASSWORD}" | base64)"
        printf '{"auths":{"%s":{"auth":"%s"}}}' \
            "${HARBOR_MIRROR_REGISTRY:-harbor.isuanova.com}" "${_b64}" > "${_AUTH_TMP}"
        unset _b64
        _SKOPEO_AUTH_ARGS=(--authfile "${_AUTH_TMP}")
    fi
}

# ---------- staging 辅助 ----------
_copy_kubespray_nonimage() {
    local src="${OFFLINE_DIR}/kubespray/${KUBESPRAY_VERSION}"
    local dst="${STAGE_TREE}/kubespray/${KUBESPRAY_VERSION}"
    [ -d "${src}" ] || { err "缺少 kubespray 离线资产: ${src}"; exit 1; }
    mkdir -p "${dst}"
    say "复制 kubespray 非镜像资产(排除 images/): ${src}"
    tar -C "${src}" --exclude=images --exclude='.backup*' -cf - . | tar -C "${dst}" -xf -
}
_copy_glob() {   # <src-dir> <glob>
    local src="$1" pat="$2" dst
    dst="${STAGE_TREE}/$(basename "${src}")"
    mkdir -p "${dst}"
    shopt -s nullglob
    local files=("${src}"/${pat})
    shopt -u nullglob
    if [ "${#files[@]}" -eq 0 ]; then
        warn "未找到 ${src}/${pat}(跳过)"
        return 0
    fi
    cp -a "${files[@]}" "${dst}/"
}
_copy_chart() {
    local src="${OFFLINE_DIR}/cubestack-operator/charts/${CHART_TGZ}"
    if [ ! -f "${src}" ]; then
        err "chart 缺失: ${CHART_TGZ}"
        err "  放到 ${OFFLINE_DIR}/cubestack-operator/charts/(命名 cubestack-operator-chart-<版本>.tgz;"
        err "  版本默认取 RELEASE=${RELEASE}, 可用 release.env 的 CUBESTACK_OPERATOR_CHART_VERSION 覆盖)"
        err "  helm pull ${CUBESTACK_OPERATOR_CHART_REF:-oci://harbor.isuanova.com/suanova-private/cubestack-operator-chart} --version ${CUBESTACK_OPERATOR_CHART_VERSION:-${RELEASE}} -d ${OFFLINE_DIR}/cubestack-operator/charts"
        exit 1
    fi
    local dst="${STAGE_TREE}/cubestack-operator/charts"
    mkdir -p "${dst}"
    # --resume 复用 staging 时可能残留旧版本 chart; 发布树只允许当前版本.
    prune_operator_chart_dir "${dst}" "${CHART_NAME}" "${CHART_TGZ}" >/dev/null
    cp -a "${src}" "${dst}/"
    if [ -f "${src}.digest" ]; then
        cp -a "${src}.digest" "${STAGE_TREE}/cubestack-operator/charts/"
    fi
    if [ -f "$(dirname "${src}")/README.md" ]; then
        cp -a "$(dirname "${src}")/README.md" "${STAGE_TREE}/cubestack-operator/charts/"
    fi
    return 0
}
_copy_metax() {
    case " ${RELEASE_GROUPS:-} " in *" metax-gpu "*) : ;; *) return 0 ;; esac
    [ -d "${OFFLINE_DIR}/metax-gpu" ] || { warn "RELEASE_GROUPS 含 metax-gpu 但 ${OFFLINE_DIR}/metax-gpu 不存在, 跳过"; return 0; }
    mkdir -p "${STAGE_TREE}/metax-gpu"
    say "复制 metax-gpu 离线资产(tars + 资源包/chart)"
    tar -C "${OFFLINE_DIR}/metax-gpu" --exclude=_work --exclude='.backup*' -cf - . | tar -C "${STAGE_TREE}/metax-gpu" -xf -
}
# NVIDIA 模块在 NFD_ENABLED=false(默认)时使用 operator 内嵌 NFD, 只从
# offline-files/nvidia-gpu-operator/ 找 nfd/node-feature-discovery 镜像 tar。
# 该镜像在 images.manifest 里登记为 k8s-base(NFD_VERSION), 发布阶段落在
# kubespray/<ver>/images/; 这里把它补进 nvidia 组目录, 保证发布树自包含(不读 dev)。
_copy_nvidia_nfd() {
    case " ${RELEASE_GROUPS:-} " in *" nvidia-gpu-operator "*) : ;; *) return 0 ;; esac
    local dst="${STAGE_TREE}/nvidia-gpu-operator"
    [ -d "${dst}" ] || { warn "nvidia-gpu-operator 组目录不存在, 跳过 NFD 补入"; return 0; }
    if compgen -G "${dst}/*nfd*node-feature-discovery*.tar" >/dev/null; then
        return 0
    fi
    local -a _nfd_src=()
    shopt -s nullglob
    _nfd_src=("${STAGE_TREE}/kubespray/${KUBESPRAY_VERSION}/images/"*nfd*node-feature-discovery*.tar)
    shopt -u nullglob
    if [ "${#_nfd_src[@]}" -eq 0 ]; then
        warn "未在发布树 kubespray/${KUBESPRAY_VERSION}/images/ 找到 NFD 镜像 tar(NFD_ENABLED=false 时 NVIDIA 部署会缺料)"
        return 0
    fi
    cp -a "${_nfd_src[0]}" "${dst}/"
    say "补入 NFD 镜像 tar → nvidia-gpu-operator/$(basename "${_nfd_src[0]}")"
}
_copy_cli_tar() {
    say "生成 CLI tar: ${CLI_IMAGE}"
    # 优先用本机 docker 已构建的镜像直接 docker save —— 避免 skopeo 1.16.x 在
    # docker-archive 转换时对部分 manifest media type 报 "Unknown media type"
    # (2026-10-23 实机: Docker 29 推送的镜像)。本机无该镜像时再回退 skopeo 拉取。
    if command -v docker >/dev/null 2>&1; then
        local -a _dk=(docker)
        [ "$(id -u)" -ne 0 ] && _dk=(sudo docker)
        if "${_dk[@]}" image inspect "${CLI_IMAGE}" >/dev/null 2>&1; then
            "${_dk[@]}" save -o "${CLI_TAR}" "${CLI_IMAGE}" \
                || { err "CLI 镜像导出失败(docker save): ${CLI_IMAGE}"; exit 1; }
            return 0
        fi
    fi
    _need_cmd skopeo
    _skopeo_auth_init
    skopeo copy --retry-times 3 --override-os linux --override-arch amd64 \
        ${_SKOPEO_AUTH_ARGS[@]+"${_SKOPEO_AUTH_ARGS[@]}"} \
        "docker://${CLI_IMAGE}" "docker-archive:${CLI_TAR}:${CLI_IMAGE}" \
        || { err "CLI 镜像拉取失败: ${CLI_IMAGE}"; exit 1; }
}
_write_release_json() {
    local cli_sha cli_size git_commit git_tag
    cli_sha="$(sha256sum "${CLI_TAR}" | awk '{print $1}')"
    cli_size="$(stat -c %s "${CLI_TAR}")"
    git_commit="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
    git_tag="$(git -C "${REPO_ROOT}" describe --tags --always --dirty 2>/dev/null || echo unknown)"
    python3 - "${RELEASE}" "${KUBESPRAY_VERSION}" "${CUBESTACK_OPERATOR_CHART_VERSION:-${RELEASE}}" \
        "${RELEASE_GROUPS:-}" "${CLI_IMAGE}" "${cli_sha}" "${cli_size}" \
        "${git_commit}" "${git_tag}" "${CLI_TAR_NAME}" "${STAGE_TREE}/release.json" <<'PY'
import json, sys, datetime
(release, k8s, chart, groups, cli, cli_sha, cli_size, commit, tag, cli_name, out) = sys.argv[1:]
data = {
    "release": release,
    "installer_version": release,
    "git_commit": commit,
    "git_tag": tag,
    "built_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "built_by": "release-publish.sh",
    "kubespray_version": k8s,
    "operator_chart_version": chart,
    "groups": [g for g in groups.split() if g],
    "cli_image": cli,
    "cli_tar": f"../{cli_name}",
    "cli_tar_sha256": cli_sha,
    "cli_tar_size": int(cli_size),
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}
_write_sha256sums() {
    say "生成 SHA256SUMS..."
    ( cd "${STAGE_TREE}" && find . -type f \
        ! -name SHA256SUMS ! -name SIZES ! -name _SUCCESS ! -name '.cubestack-*' -print0 \
        | sort -z | xargs -0 sha256sum ) > "${STAGE_TREE}/SHA256SUMS"
}

# 发布树随带校验器(2026-10-28): 纯宿主机部署也有离线副本; 由 SHA256SUMS 覆盖
_copy_verify_tool() {
    local dir="${REPO_ROOT}/deployments/scripts/tools/offline"
    [ -x "${dir}/verify-offline-files.sh" ] || { err "缺少校验器: ${dir}/verify-offline-files.sh"; exit 1; }
    [ -f "${dir}/verify-offline-files.pyz" ] || { err "缺少校验器 pyz: ${dir}/verify-offline-files.pyz"; exit 1; }
    mkdir -p "${STAGE_TREE}/tools"
    cp -f "${dir}/verify-offline-files.sh" "${STAGE_TREE}/tools/verify-offline-files.sh"
    cp -f "${dir}/verify-offline-files.pyz" "${STAGE_TREE}/tools/verify-offline-files.pyz"
    chmod 0755 "${STAGE_TREE}/tools/verify-offline-files.sh" "${STAGE_TREE}/tools/verify-offline-files.pyz"
    ok "  校验器就位: tools/verify-offline-files.sh + .pyz"
}

# ---------- 子命令: stage ----------
_stage() {
    _need_cmd sha256sum; _need_cmd python3
    [ -f "${IMAGES_DIR}/harbor-save-images.sh" ] || { err "缺少 ${IMAGES_DIR}/harbor-save-images.sh"; exit 1; }
    [ -f "${IMAGES_DIR}/cubestack-platform-save-images.sh" ] || { err "缺少 ${IMAGES_DIR}/cubestack-platform-save-images.sh"; exit 1; }

    if [ -d "${STAGE_DIR}" ] && [ -n "$(ls -A "${STAGE_DIR}" 2>/dev/null)" ]; then
        if [ "${FORCE}" = "1" ]; then
            warn "清空已有 staging: ${STAGE_DIR}"
            rm -rf "${STAGE_DIR}"
        elif [ "${RESUME}" = "1" ]; then
            warn "复用已有 staging(--resume): ${STAGE_DIR}(已完成的镜像按 digest/文件存在跳过)"
        else
            err "staging 已存在且非空: ${STAGE_DIR}(确认可删后加 --force; 中断续跑用 --resume)"
            exit 1
        fi
    fi
    mkdir -p "${STAGE_TREE}"

    say "[1/7] 上游镜像 + dev-lab → ${STAGE_TREE}"
    IMAGE_OFFLINE_ROOT="${STAGE_TREE}" \
        bash "${IMAGES_DIR}/harbor-save-images.sh" \
            --exclude-group cubestack-operator,cubestack-platform,netshoot

    say "[2/7] 平台/自研组件 → ${STAGE_TREE}/cubestack-operator"
    bash "${IMAGES_DIR}/cubestack-platform-save-images.sh" \
        --list "${RELEASE_DIR}/release-images.tsv" \
        --out "${STAGE_TREE}/cubestack-operator"

    say "[3/7] model-collection → ${STAGE_TREE}/model-collection"
    bash "${IMAGES_DIR}/cubestack-platform-save-images.sh" \
        --list "${OFFLINE_DIR}/model-collection/image-list.tsv" \
        --out "${STAGE_TREE}/model-collection"
    cp -f "${OFFLINE_DIR}/model-collection/image-list.tsv" "${STAGE_TREE}/model-collection/image-list.tsv"
    [ -f "${OFFLINE_DIR}/model-collection/README.md" ] \
        && cp -f "${OFFLINE_DIR}/model-collection/README.md" "${STAGE_TREE}/model-collection/README.md" || true

    say "[4/7] 非镜像资产(kubespray/os/netshoot/observability/chart/metax)"
    _copy_kubespray_nonimage
    if [ -d "${OFFLINE_DIR}/os" ]; then
        mkdir -p "${STAGE_TREE}/os"
        tar -C "${OFFLINE_DIR}/os" --exclude='.backup*' -cf - . | tar -C "${STAGE_TREE}/os" -xf - \
            || { err "复制 os/ 失败"; exit 1; }
    else
        warn "os/ 不存在, 跳过"
    fi
    _copy_glob "${OFFLINE_DIR}/netshoot" "netshoot-rdma-*.tar*"
    if [ -d "${OFFLINE_DIR}/cubestack-operator/observability" ]; then
        cp -a "${OFFLINE_DIR}/cubestack-operator/observability" "${STAGE_TREE}/cubestack-operator/"
    fi
    _copy_chart
    _copy_metax
    _copy_nvidia_nfd

    say "[5/7] 生成 CLI tar"
    _copy_cli_tar

    say "[6/7] 生成 release.env / release.json"
    _copy_verify_tool
    cp -f "${RELEASE_DIR}/release.env" "${STAGE_TREE}/release.env"
    _write_release_json

    say "[7/7] 生成 SHA256SUMS"
    _write_sha256sums

    echo ""
    ok "staging 完成: ${STAGE_DIR}"
    echo "  发布树: ${STAGE_TREE}"
    echo "  CLI tar: ${CLI_TAR}"
    echo "  下一步: $0 verify --release ${RELEASE} --stage-dir ${STAGE_DIR}"
}

# ---------- 子命令: verify ----------
_verify() {
    _need_cmd sha256sum; _need_cmd python3
    [ -d "${STAGE_TREE}" ] || { err "staging 不存在: ${STAGE_TREE}"; exit 1; }
    [ -f "${STAGE_TREE}/SHA256SUMS" ] || { err "缺少 ${STAGE_TREE}/SHA256SUMS"; exit 1; }
    [ -f "${CLI_TAR}" ] || { err "缺少 CLI tar: ${CLI_TAR}"; exit 1; }
    [ -f "${STAGE_TREE}/release.json" ] || { err "缺少 ${STAGE_TREE}/release.json"; exit 1; }
    local json_cli_name
    json_cli_name="$(_cli_tar_name_from_json "${STAGE_TREE}/release.json")"
    [ "${json_cli_name}" = "${CLI_TAR_NAME}" ] \
        || { err "release.json cli_tar=${json_cli_name} 与发布版本命名不符(期望 ${CLI_TAR_NAME}; 旧布局请重新 stage 或迁移)"; exit 1; }

    say "校验发布树 sha256..."
    ( cd "${STAGE_TREE}" && sha256sum -c SHA256SUMS >/dev/null ) || { err "SHA256SUMS 校验失败"; exit 1; }

    say "校验平台清单覆盖..."
    bash "${IMAGES_DIR}/cubestack-platform-save-images.sh" --list-check \
        --list "${RELEASE_DIR}/release-images.tsv" --out "${STAGE_TREE}/cubestack-operator"
    bash "${IMAGES_DIR}/cubestack-platform-save-images.sh" --list-check \
        --list "${STAGE_TREE}/model-collection/image-list.tsv" --out "${STAGE_TREE}/model-collection"

    say "校验 dev-lab / chart / CLI tar..."
    local n
    n="$(find "${STAGE_TREE}/dev-lab" -maxdepth 1 -type f \( -name '*.tar' -o -name '*.tar.gz' \) 2>/dev/null | wc -l)"
    [ "${n}" -ge 3 ] || { err "dev-lab 镜像不足: ${n}(期望 3)"; exit 1; }
    for grp in metax-gpu nvidia-gpu-operator; do
        case " ${RELEASE_GROUPS:-} " in
            *" ${grp} "*)
                n="$(find "${STAGE_TREE}/${grp}" -maxdepth 1 -type f \( -name '*.tar' -o -name '*.tar.gz' \) 2>/dev/null | wc -l)"
                [ "${n}" -ge 1 ] || { err "${grp} 组无镜像 tar(发布树不完整)"; exit 1; } ;;
        esac
    done
    # NVIDIA 默认 NFD_ENABLED=false → operator 内嵌 NFD, 模块只从本组目录找 NFD 镜像;
    # 只允许"kubespray images 有、nvidia 组没有"会在部署时缺料, 必须拦在发布前。
    case " ${RELEASE_GROUPS:-} " in
        *" nvidia-gpu-operator "*)
            compgen -G "${STAGE_TREE}/nvidia-gpu-operator/*nfd*node-feature-discovery*.tar" >/dev/null \
                || { err "nvidia-gpu-operator 组缺少 NFD 镜像 tar(NFD_ENABLED=false 时 operator 内嵌 NFD 需要; 由 stage 从 kubespray images 补入)"; exit 1; } ;;
    esac
    [ -f "${STAGE_TREE}/cubestack-operator/charts/${CHART_TGZ}" ] \
        || { err "缺少 operator chart: ${STAGE_TREE}/cubestack-operator/charts/${CHART_TGZ}"; exit 1; }
    [ -f "${STAGE_TREE}/cubestack-operator/charts/${CHART_TGZ}.digest" ] \
        || warn "缺少 chart digest 边车: ${CHART_TGZ}.digest(离线可用, 在线比对会失效)"
    local chart_extras
    chart_extras="$(operator_chart_dir_extras "${STAGE_TREE}/cubestack-operator/charts" \
        "${CHART_NAME}" "${CHART_TGZ}")"
    [ -z "${chart_extras}" ] \
        || { err "发布树含非当前版本 chart: $(printf '%s' "${chart_extras}" | tr '\n' ' ')(只允许 ${CHART_TGZ})"; exit 1; }
    # chart 内 Chart.yaml 的 version 必须与 release.env 的 CHART_VERSION 一致
    # (release.env 可省略 CHART_VERSION: 默认按发布版本 <RELEASE> 校验/命名)
    local chart_yaml chart_ver _want_chart_ver
    _want_chart_ver="${CUBESTACK_OPERATOR_CHART_VERSION:-${RELEASE}}"
    chart_yaml="$(tar -tzf "${STAGE_TREE}/cubestack-operator/charts/${CHART_TGZ}" 2>/dev/null \
        | command grep '/Chart.yaml$' | head -1)"
    chart_ver=""
    [ -n "${chart_yaml}" ] && chart_ver="$(tar -xOf "${STAGE_TREE}/cubestack-operator/charts/${CHART_TGZ}" "${chart_yaml}" 2>/dev/null \
        | awk '/^version:/{print $2; exit}')"
    if [ -n "${chart_ver}" ] && [ "${chart_ver}" != "${_want_chart_ver}" ]; then
        err "chart 版本不符: Chart.yaml version=${chart_ver} != release.env ${_want_chart_ver}(可省略, 默认取 RELEASE)"
        exit 1
    fi
    [ -n "${chart_ver}" ] || warn "无法读取 chart Chart.yaml version, 仅按文件名校验"

    # chart appVersion ↔ operator 镜像 tag: 部署时 installer 不传 image.tag, 镜像 tag 由
    # chart 的 appVersion/values 决定 —— 二者不一致会把错误 tag 推到集群, 必须在此拦下。
    local chart_app _want_op_tag
    _want_op_tag="${CUBESTACK_OPERATOR_IMAGE_TAG:-}"
    chart_app=""
    [ -n "${chart_yaml}" ] && chart_app="$(tar -xOf "${STAGE_TREE}/cubestack-operator/charts/${CHART_TGZ}" "${chart_yaml}" 2>/dev/null \
        | awk '/^appVersion:/{print $2; exit}')"
    if [ -n "${_want_op_tag}" ] && [ -n "${chart_app}" ] && [ "${chart_app}" != "${_want_op_tag}" ]; then
        err "chart appVersion=${chart_app} != release.env CUBESTACK_OPERATOR_IMAGE_TAG=${_want_op_tag}"
        exit 1
    fi
    [ -n "${chart_app}" ] || warn "无法读取 chart appVersion, 跳过与 operator 镜像 tag 的比对"
    # release-images.tsv 必须登记同一个 operator 镜像 tag
    if [ -n "${_want_op_tag}" ]; then
        command grep -vE '^[[:space:]]*#' "${RELEASE_DIR}/release-images.tsv" \
            | command grep -Eq "cubestack-operator:${_want_op_tag}([[:space:]]|$)" \
            || { err "release-images.tsv 未登记 cubestack-operator:${_want_op_tag}(与 release.env 不一致)"; exit 1; }
    fi

    # RELEASE_GROUPS 中每组必须在发布树里落位(防止整组漏拷/漏拉, SHA256SUMS 只能证明"有什么")
    say "校验 RELEASE_GROUPS 文件落位..."
    local grp gdir
    for grp in ${RELEASE_GROUPS:-}; do
        case "${grp}" in
            kubespray) gdir="${STAGE_TREE}/kubespray/${KUBESPRAY_VERSION}" ;;
            ceph)      gdir="${STAGE_TREE}/kubespray/${KUBESPRAY_VERSION}/images" ;;
            *)         gdir="${STAGE_TREE}/${grp}" ;;
        esac
        [ -d "${gdir}" ] || { err "发布组缺失目录: ${grp} → ${gdir}"; exit 1; }
        if [ "${grp}" = "ceph" ]; then
            n="$(find "${gdir}" -maxdepth 1 -type f \( -name '*ceph*' -o -name '*rook*' -o -name '*csi*' -o -name '*snapshot*' \) 2>/dev/null | wc -l)"
        else
            n="$(find "${gdir}" -type f 2>/dev/null | wc -l)"
        fi
        [ "${n}" -ge 1 ] || { err "发布组无文件: ${grp}(${gdir})"; exit 1; }
    done

    local cli_sha actual
    cli_sha="$(python3 - "${STAGE_TREE}/release.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("cli_tar_sha256", ""))
PY
)"
    actual="$(sha256sum "${CLI_TAR}" | awk '{print $1}')"
    [ "${cli_sha}" = "${actual}" ] || { err "CLI tar sha256 不符: ${actual} != ${cli_sha}"; exit 1; }

    # release 定义里不得再出现 :latest(注释行除外)
    if [ -n "$(command grep -vE '^[[:space:]]*#' "${RELEASE_DIR}/release-images.tsv" | command grep ':latest' || true)" ]; then
        err "release-images.tsv 仍含 :latest"; exit 1
    fi
    if [ -n "$(command grep -vE '^[[:space:]]*#' "${RELEASE_DIR}/release.env" | command grep '=latest' || true)" ]; then
        err "release.env 仍含 =latest"; exit 1
    fi

    ok "verify 通过: ${RELEASE}"
}

# ---------- 子命令: publish ----------
# 从 release.json 的 cli_tar 字段解析文件名(兼容只有 cli_tar_sha256 的旧 release.json);
# 缺省回退到当前版本的带版本名。
_cli_tar_name_from_json() {
    local json="$1" name=""
    if [ -f "${json}" ]; then
        name="$(python3 - "${json}" <<'PY' 2>/dev/null || true
import json, os, sys
try:
    v = json.load(open(sys.argv[1])).get("cli_tar") or ""
except Exception:
    v = ""
print(os.path.basename(v) if v else "")
PY
)"
    fi
    printf '%s' "${name:-${CLI_TAR_NAME}}"
}

_verify_remote() {
    local remote="$1" hash path rhash
    say "校验远端 sha256(逐文件; 大版本较慢, 可 --no-verify-remote)..."
    while read -r hash path; do
        [ -n "${hash}" ] || continue
        path="${path#./}"
        rhash="$(mc cat "${remote}/offline-files/${path}" 2>/dev/null | sha256sum | awk '{print $1}')"
        [ "${rhash}" = "${hash}" ] || { err "远端不一致: ${path}(${rhash} != ${hash})"; return 1; }
    done < "${STAGE_TREE}/SHA256SUMS"
    local cli_sha cli_actual cli_name
    cli_sha="$(python3 - "${STAGE_TREE}/release.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("cli_tar_sha256", ""))
PY
)"
    cli_name="$(_cli_tar_name_from_json "${STAGE_TREE}/release.json")"
    cli_actual="$(mc cat "${remote}/${cli_name}" 2>/dev/null | sha256sum | awk '{print $1}')"
    [ "${cli_sha}" = "${cli_actual}" ] || { err "远端 CLI tar sha256 不符"; return 1; }
    ok "远端校验通过"
}

_publish() {
    _need_cmd sha256sum; _need_cmd python3
    _mc_setup
    local remote="${ALIAS}/${BUCKET}/${RELEASE}"
    if _mc_has "${remote}"; then
        err "远端已存在版本目录: ${remote}(拒绝覆盖; 修复请发新 patch 版本)"
        exit 1
    fi
    if [ "${DRY_RUN}" = "1" ]; then
        say "[dry-run] mc mirror ${STAGE_TREE} ${remote}/offline-files"
        say "[dry-run] mc cp ${CLI_TAR} ${remote}/${CLI_TAR_NAME}"
        say "[dry-run] 最后写 ${remote}/offline-files/_SUCCESS"
        return 0
    fi

    say "上传发布树 → ${remote}/offline-files"
    mc mirror --overwrite "${STAGE_TREE}" "${remote}/offline-files" \
        || { err "上传发布树失败; 远端残留需人工清理: mc rm --recursive --force ${remote}"; exit 1; }
    say "上传 CLI tar → ${remote}/${CLI_TAR_NAME}"
    mc cp "${CLI_TAR}" "${remote}/${CLI_TAR_NAME}" \
        || { err "上传 CLI tar 失败"; exit 1; }

    if [ "${VERIFY_REMOTE}" = "1" ]; then
        _verify_remote "${remote}" || exit 1
    fi

    local tmp sums_sha
    tmp="$(mktemp)"
    sums_sha="$(sha256sum "${STAGE_TREE}/SHA256SUMS" | awk '{print $1}')"
    printf 'release=%s\nbuilt_at=%s\nsha256sums=%s\n' \
        "${RELEASE}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${sums_sha}" > "${tmp}"
    say "写 _SUCCESS(最后一步)→ ${remote}/offline-files/_SUCCESS"
    mc cp "${tmp}" "${remote}/offline-files/_SUCCESS" || { rm -f "${tmp}"; err "_SUCCESS 写入失败"; exit 1; }
    # 本地 staging 同步落一份 _SUCCESS: 发布完成后 staging 即完整发布树,
    # 可直接作为 CUBESTACK_RELEASE_ROOT 做 fetch --verify-only / 离线安装演练。
    cp -f "${tmp}" "${STAGE_TREE}/_SUCCESS" \
        || warn "远端 _SUCCESS 已写入, 但本地 staging 写入失败: ${STAGE_TREE}/_SUCCESS"
    rm -f "${tmp}"

    ok "发布完成: ${remote}"
    echo "  取件: fetch-offline-from-minio.sh --release ${RELEASE} --dest <本地桶根>"
}

case "${CMD}" in
    stage)   _stage ;;
    verify)  _verify ;;
    publish) _publish ;;
    *) err "未知子命令: ${CMD}(可用 stage|verify|publish)"; usage; exit 2 ;;
esac
