#!/bin/bash
# ============================================================
# TOOL: nvidia-save-images
# DESC: NVIDIA GPU Operator 离线镜像备料(联网机执行) —— 拉取并保存为 docker-archive tar。
# 备料集(与 08_nvidia_gpu_operator 模块同口径, 唯一来源 tools/images/nvidia-chart-images.sh):
#   ① chart 所需组件镜像(渲染提取; driver 占位行丢弃)
#   ② 预编译驱动镜像 driver:<分支>-<内核>-ubuntu22.04(逐内核; **先做 NGC 存在性预检**)
#   ③ verify 样例镜像(cuda-sample; 端到端验证用)
# 数据源: cluster.conf (NVIDIA_GPU_OPERATOR_VERSION / NVIDIA_GPU_DRIVER_BRANCH /
#         NVIDIA_GPU_DRIVER_PRECOMPILED_KERNELS / NVIDIA_GPU_OPERATOR_OFFLINE_DIR)
# 用法:   ./nvidia-save-images.sh [--list]
#           --list = 只打印将保存的镜像与 save 命令, 不下载(供人工核对/手工备料)
# 说明:   · 只需 skopeo(无需 docker/root)。
#         · **取源链(Harbor 优先, 2026-10-14 用户口径)**: ① Harbor mirrors(CI 按 images.manifest
#           同步的镜像副本, 匿名可拉) → ② 上游直拉(nvcr.io / registry.k8s.io)。
#           适配"docker.io/nvcr.io 等上游不可达、以 Harbor 为唯一镜像源"的环境;
#           Harbor 不可达时自动回退上游。内核预检同口径(① Harbor ② 上游)。
#         · tar 命名 = 上游 ref 的 "/",":" → "_"(与全仓约定一致; find_offline_tar 按内容尾匹配);
#         · 幂等: 已存在且内容 tag 一致的 tar 跳过(重跑只补缺);
#         · ⚠ chart 升级后重跑本工具会按新版本补齐(旧版 tar 不自动清理, 确认无引用后手工删)。
# 相关: 等价的组通用通道 = tools/images/harbor-save-images.sh --group nvidia-gpu-operator
#       (纯 Harbor 拉取; 不覆盖 NFD —— NFD 登记在 k8s-base 组, 由本工具专门兜住)。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

LIST=0
[ "${1:-}" = "--list" ] && LIST=1

CHART_VER="${NVIDIA_GPU_OPERATOR_VERSION:-v26.7.2}"
CHART_TGZ="${REPO_ROOT}/deployments/cubestack-addon/nvidia-gpu-operator/gpu-operator-${CHART_VER}.tgz"
BRANCH="${NVIDIA_GPU_DRIVER_BRANCH:-595}"
KERNELS="${NVIDIA_GPU_DRIVER_PRECOMPILED_KERNELS:-5.15.0-186-generic}"
OUT="${NVIDIA_GPU_OPERATOR_OFFLINE_DIR:-${REPO_ROOT}/deployments/offline-files/nvidia-gpu-operator}"
IMG_TOOL="${REPO_ROOT}/deployments/scripts/tools/images/nvidia-chart-images.sh"
VERIFY_SAMPLE="nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0-ubuntu22.04"

[ -f "${CHART_TGZ}" ] || { err "chart 缺失: ${CHART_TGZ}(先按 cubestack-addon/nvidia-gpu-operator/CUBSTACK.md 拉取并提交)"; exit 1; }
command -v helm >/dev/null 2>&1 || { err "未找到 helm(提取镜像集需要)"; exit 1; }
command -v skopeo >/dev/null 2>&1 || { err "未找到 skopeo(备料必需)"; exit 1; }

# ---- 组装备料集 ----
REFS=()
while IFS= read -r _l; do
    [ -z "${_l}" ] && continue
    case "${_l}" in */driver:*) continue ;; esac   # 渲染中的 driver 占位行(真实镜像是内核化 tag)
    REFS+=("${_l}")
done < <( bash "${IMG_TOOL}" "${CHART_TGZ}" )
IFS=',' read -r -a _KL <<< "${KERNELS}"
KERNEL_REFS=()
for _k in "${_KL[@]:-}"; do
    _k="$(printf '%s' "${_k}" | tr -d '[:space:]')"
    [ -n "${_k}" ] && KERNEL_REFS+=("nvcr.io/nvidia/driver:${BRANCH}-${_k}-ubuntu22.04")
done
REFS+=( "${KERNEL_REFS[@]}" "${VERIFY_SAMPLE}" )

say "备料集(${#REFS[@]} 个镜像, 输出目录 ${OUT}):"
for _r in "${REFS[@]}"; do echo "  ${_r}"; done

if [ "${LIST}" = "1" ]; then
    echo "=============================================="
    for _r in "${REFS[@]}"; do
        _f="$(printf '%s' "${_r}" | tr '/:' '__')"
        echo "  skopeo copy docker://${_r} docker-archive:${OUT}/${_f}.tar:${_r}"
    done
    echo "=============================================="
    echo "  依赖: skopeo(无需 docker); 目标机器须能访问 nvcr.io / registry.k8s.io"
    exit 0
fi

mkdir -p "${OUT}"
ensure_skopeo_policy
_HARBOR="${HARBOR_MIRROR_REGISTRY:-harbor.isuanova.com}"

# 预编译驱动镜像存在性预检(内核覆盖门禁的备料侧 —— 缺了就早失败, 不留到部署时才炸)
# 取源同主流程: ① Harbor mirrors ② 上游 —— "Harbor 为准"的环境也能通过预检
_have_src() {   # <ref> → 0=某源存在
    skopeo inspect --no-creds "docker://${_HARBOR}/mirrors/$1" >/dev/null 2>&1 && return 0
    skopeo inspect --no-creds "docker://$1" >/dev/null 2>&1 && return 0
    return 1
}
for _r in "${KERNEL_REFS[@]:-}"; do
    [ -n "${_r}" ] || continue
    if _have_src "${_r}"; then
        ok "  预编译驱动覆盖预检通过: ${_r}"
    else
        err "预编译驱动镜像不存在: ${_r}(Harbor mirrors 与上游均查无)"
        err "  → 该内核不在覆盖列表(或 Harbor 尚未经 CI 同步该镜像)。速查:"
        err "    skopeo list-tags docker://nvcr.io/nvidia/driver | python3 -m json.tool | grep '\"${BRANCH}-'"
        err "  → 换内核/改 NVIDIA_GPU_DRIVER_BRANCH, 或改用'自制带包驱动镜像'退路(见 docs/nvidia-gpu-operator.md)"
        exit 1
    fi
done

_n_ok=0; _n_skip=0; _n_fail=0
for _r in "${REFS[@]}"; do
    _f="$(printf '%s' "${_r}" | tr '/:' '__')"
    _dest="${OUT}/${_f}.tar"
    if [ -f "${_dest}" ]; then
        _inner="$(tar_first_image_tag "${_dest}" || true)"
        if [ "${_inner}" = "${_r}" ]; then
            _n_skip=$((_n_skip+1)); continue
        fi
        warn "  ${_f}.tar 已存在但内容为 ${_inner:-?}, 覆盖重拉"
    fi
    say "  save ${_r}"
    _ok_save=0
    # 取源链(Harbor 优先): ① ${_HARBOR}/mirrors/<ref>(CI 按 manifest 同步的副本, 匿名可拉)
    #                        → ② 上游直拉 <ref>(Harbor 不可达/未同步时的回退)
    if skopeo copy --quiet "docker://${_HARBOR}/mirrors/${_r}" "docker-archive:${_dest}:${_r}" 2>/dev/null; then
        _ok_save=1
    else
        say "  Harbor 未命中, 回退上游直拉 ${_r} ..."
        skopeo copy --quiet "docker://${_r}" "docker-archive:${_dest}:${_r}" 2>/dev/null && _ok_save=1 || true
    fi
    if [ "${_ok_save}" = "1" ]; then
        chmod 644 "${_dest}"   # 供非 root 同步/部署读取
        _n_ok=$((_n_ok+1))
    else
        if [ "${_r}" = "${VERIFY_SAMPLE}" ]; then
            warn "  验证样例镜像保存失败(verify 端到端步将不可用): ${_r}"
        else
            err "  保存失败(Harbor 与上游均不可达): ${_r}"
        fi
        rm -f "${_dest}"; _n_fail=$((_n_fail+1))
    fi
done

echo "---------------------------------------------"
ok "备料完成: 新保存 ${_n_ok} 个, 已就绪跳过 ${_n_skip} 个, 失败 ${_n_fail} 个"
du -sh "${OUT}" 2>/dev/null | awk '{print "  目录大小: "$1}'
echo "  下一步: 把本目录同步到目标环境(离线机), 部署模块自动按 tar 推送; 或走 Harbor mirrors 通道"
[ "${_n_fail}" -eq 0 ] || exit 1
