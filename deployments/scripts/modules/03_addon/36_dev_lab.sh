#!/bin/bash
# ============================================================
# MODULE: dev_lab
# DESC: 开发镜像(cpu/maca/cuda 家族)离线 tar → 集群内置 registry(**排在全部部署模块末位**; 默认 push, config-digest 幂等 + 层/镜像并行)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: DEV_LAB_ENABLED
# REQUIRES: k8s_deploy k8s_registry
# 说明:
#   · 镜像(3 个; 上游均在本台 Harbor 的 suanova 项目 —— 不镜像到 mirrors/, save 直接用原始 ref):
#       harbor.isuanova.com/suanova/cpu-pytorch:${DEV_LAB_CPU_TAG}(默认随 DEV_LAB_IMAGE_TAG=latest)
#       harbor.isuanova.com/suanova/maca-pytorch:${DEV_LAB_MACA_TAG}
#       harbor.isuanova.com/suanova/cuda-pytorch:${DEV_LAB_CUDA_TAG}
#     ⚠ 三家 Harbor tag 命名不一致, 发布版本按镜像分别钉不可变 tag(release.env)。
#   · 一个 accelerator 一个镜像: jupyter / ssh 模式由运行时 CUBSTACK_TYPE 决定, 不再按模式拆镜像。
#   · 离线 tar: deployments/offline-files/dev-lab/ 顶层平铺(联网机: harbor-save-images.sh --group dev-lab;
#     Harbor→MinIO 保鲜管道按 offline-files/dev-lab/image-list.tsv 增量维护);
#     .tar 与 .tar.gz 均可(大件可就地 gzip 省盘; plain 内容校验 / .gz 文件名匹配, 见 README);
#     缺某个 tar → 该镜像 warn 跳过(不阻断部署), 结尾汇总(🅰 诚实: 不伪装成功)。
#     release.env 的 DEV_LAB_*_TAG 是**完整不可变 tag**(如 3.9.0.12-py310-torch2.4-v2.0.0),
#     tar 内 RepoTag 必须逐字匹配; 不做旧后缀兼容/前缀猜测(防 *-hotfix 冒充钉死 tag)。
#   · 目标 ref: <集群 registry>/suanova/<name>:<tag>(去 Harbor 注册域保 suanova/ 路径,
#     与 25_cubestack_operator 的自研镜像映射同款)。
#   · 幂等: 目标 digest == 源 digest → 跳过 —— tag 是滚动的 latest, **必须比 digest**,
#     不能只看 tag 存在(与 25 模块同款教训)。
#     ★ 2026-10-19 修正: 改比 **config digest**(push 会重压缩层, manifest/layer digest 会变;
#       config blob digest 稳定), 否则每轮部署都会重推。
#   · 加速: 层并行(--image-parallel-copies)+ 跳过已有层(--dest-precompute-digests)+
#     首个镜像 base-first、其余有界并行; 配置 IMAGE_PUSH_*; 详见 docs/image-push-optimization.md。
#   · 默认启用 = 默认 push: DEV_LAB_ENABLED 默认 true(见 cluster.conf.example 顶部开关区)
#     ⇒ 每次默认部署自动把 tar 推入集群 registry; 跳过: --skip dev_lab 或 DEV_LAB_ENABLED=false。
#   · 顺序(2026-10-13 用户口径): 模块文件排在 03_addon **末位 36**(全部 operator/组件/验证之后)
#     —— 开发镜像无任何依赖(全仓无消费者, 已核对)⇒ ≈21G 的大推送不占用关键链路时间,
#     前面的组件/验证先完成先验收; 覆盖安装"反序卸载"时 dev_lab 无卸载动作, 顺序变化无副作用。
# 数据源: cluster.conf (DEV_LAB_* / REGISTRY_* / IMAGE_PUSH_* / NODES / SSH_KEY_NAME)
# 用法:   sudo ./deploy-cluster.sh --steps dev_lab
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---- 开关(默认启用: 每次默认部署自动加载) ----
[ "${DEV_LAB_ENABLED:-true}" = "true" ] || { say "DEV_LAB_ENABLED=false, 跳过开发镜像加载"; exit 0; }

init_remote_kubectl || exit 1

# ---------------- 派生变量(全部来自 cluster.conf / load_config, 无硬编码) ----------------
SAVE_DIR="${DEV_LAB_SAVE_DIR:-${REPO_ROOT}/deployments/offline-files/dev-lab}"
# per-image tag: 发布版本三家 tag 命名不一致, 不能共用一个 DEV_LAB_IMAGE_TAG。
_devlab_tag() {
    case "$1" in
        cpu-pytorch)  echo "${DEV_LAB_CPU_TAG:-${DEV_LAB_IMAGE_TAG:-latest}}" ;;
        maca-pytorch) echo "${DEV_LAB_MACA_TAG:-${DEV_LAB_IMAGE_TAG:-latest}}" ;;
        cuda-pytorch) echo "${DEV_LAB_CUDA_TAG:-${DEV_LAB_IMAGE_TAG:-latest}}" ;;
        *)            echo "${DEV_LAB_IMAGE_TAG:-latest}" ;;
    esac
}
HARBOR_HOST="harbor.isuanova.com"                        # 上游注册域(与 images.manifest dev-lab 组一致)
# 集群内置 registry 双端点(与 multus/rdma/gpu 同款): REG_DIRECT=推送直连, REG_BASE=节点引用
REG_DIRECT="${REGISTRY_DIRECT:-${REGISTRY_IP:-$(first_master_ip)}:${REGISTRY_PORT:-5000}}"
REG_BASE="${REGISTRY_DOMAIN:-${REGISTRY_IP}}:${REGISTRY_PORT:-5000}"

IMAGES=(
    cpu-pytorch
    maca-pytorch
    cuda-pytorch
)

say "开发镜像 → 集群内置 registry(共 ${#IMAGES[@]} 个; 源 ${SAVE_DIR}; per-image tag)..."
if [ ! -d "${SAVE_DIR}" ]; then
    warn "离线目录不存在: ${SAVE_DIR}"
    warn "  生成离线 tar: sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group dev-lab"
    exit 0
fi

skopeo_require "dev_lab"
wait_registry_ready "http://${REG_DIRECT}/v2/" 30 \
    || { err "集群内置 registry ${REG_DIRECT}/v2/ 30s 内不可达(检查 REGISTRY_SERVICE_TYPE / registry pod / REGISTRY_DIRECT)"; exit 1; }

# 大镜像 push 加速: 层并行 + 跳过 registry 已有层(参数见 lib-common image_push_args_init)
image_push_args_init
PUSH_PARALLEL_IMAGES="${IMAGE_PUSH_PARALLEL_IMAGES:-2}"
case "${PUSH_PARALLEL_IMAGES}" in ''|*[!0-9]*|0) PUSH_PARALLEL_IMAGES=1 ;; esac
PUSH_RESULT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cubestack-dev-lab-push.XXXXXX")"
trap 'rm -rf "${PUSH_RESULT_DIR}"' EXIT

# 单镜像 worker(后台子 shell 执行; 结果写 ${PUSH_RESULT_DIR}/<idx>.result)
# 参数: "<idx>|<img>"(避免把含空格的路径拆开)
_devlab_push_one() {
    local task="$1" _idx _img _tag _sd _tar _dst _dst_ref
    local _c_dst _c_src _d_dst _d_src _t0 _dt _size _rate
    _idx="${task%%|*}"; _img="${task#*|}"
    _tag="$(_devlab_tag "${_img}")"
    # 离线 tar 顶层平铺: accelerator 家族镜像不再按模式/家族分子目录。
    # 只做**精确 tag**匹配(RepoTag 必须逐字等于 <img>:<tag>); 不做旧后缀/前缀猜测。
    _sd="${SAVE_DIR}"
    _tar="$(find_offline_tar "${_img}:${_tag}" "*.tar" "${_sd}" 2>/dev/null || true)"
    if [ -z "${_tar}" ]; then
        printf 'miss\t缺离线 tar: %s:%s(跳过; 生成: sudo tools/images/harbor-save-images.sh --group dev-lab)\n' \
            "${_img}" "${_tag}" > "${PUSH_RESULT_DIR}/${_idx}.result"
        return 0
    fi
    # 目标 ref: 去 Harbor 注册域, 保 suanova/ 路径(与 25 模块同款映射)
    _dst="docker://${REG_DIRECT}/suanova/${_img}:${_tag}"
    _dst_ref="${REG_BASE}/suanova/${_img}:${_tag}"
    # 幂等(2026-10-19 修正): 优先比 **config digest** —— push 会重新压缩层, manifest/layer
    # digest 会变(实测), 但 config blob digest 稳定; 老逻辑比 manifest digest 会每次重推。
    _c_dst="$(image_config_digest_raw "${_dst}")"
    _c_src="$(image_config_digest_raw "docker-archive:${_tar}")"
    if [ -n "${_c_dst}" ] && [ "${_c_dst}" = "${_c_src}" ]; then
        printf 'skip\t%s: 内容未变(config digest %s...), 跳过推送\n' "${_img}" "${_c_dst:0:19}" \
            > "${PUSH_RESULT_DIR}/${_idx}.result"
        return 0
    fi
    # 多架构/取不到 config digest 时回退 manifest digest(保守: 不相等即推送)
    if [ -z "${_c_dst}" ] || [ -z "${_c_src}" ]; then
        _d_dst="$(image_digest_raw "${_dst}")"
        _d_src="$(image_digest_raw "docker-archive:${_tar}")"
        if [ -n "${_d_dst}" ] && [ "${_d_dst}" = "${_d_src}" ]; then
            printf 'skip\t%s: 内容未变(manifest digest %s...), 跳过推送\n' "${_img}" "${_d_dst:0:19}" \
                > "${PUSH_RESULT_DIR}/${_idx}.result"
            return 0
        fi
    fi
    _t0="$(date +%s)"
    say "  [${_img}] 开始推送(源 $(basename "${_tar}"), 层并发 ${IMAGE_PUSH_PARALLEL_LAYERS:-4})..."
    if push_image_skopeo "docker-archive:${_tar}" "${_dst}" ${IMAGE_PUSH_ARGS[@]+"${IMAGE_PUSH_ARGS[@]}"}; then
        _dt=$(( $(date +%s) - _t0 )); [ "${_dt}" -lt 1 ] && _dt=1
        _size="$(stat -c %s "${_tar}" 2>/dev/null || echo 0)"
        _rate=$(( _size / 1024 / 1024 / _dt ))
        printf 'push\t%s: 已推送(源 %s, %ss, ~%s MB/s)\n' "${_img}" "$(basename "${_tar}")" "${_dt}" "${_rate}" \
            > "${PUSH_RESULT_DIR}/${_idx}.result"
    else
        printf 'fail\t%s: 推送失败(重试 3 次后); 检查 registry 可达/磁盘空间\n' "${_img}" \
            > "${PUSH_RESULT_DIR}/${_idx}.result"
    fi
    return 0
}

# base-first: 先同步推第一个镜像(填充共享 base 层), 其余按 IMAGE_PUSH_PARALLEL_IMAGES 并行
_DEVLAB_TASKS=()
for _i in $(seq 0 $((${#IMAGES[@]} - 1))); do
    _DEVLAB_TASKS+=("${_i}|${IMAGES[$_i]}")
done
_devlab_push_one "${_DEVLAB_TASKS[0]}"
[ "${#_DEVLAB_TASKS[@]}" -gt 1 ] \
    && parallel_run "${PUSH_PARALLEL_IMAGES}" _devlab_push_one "${_DEVLAB_TASKS[@]:1}"

# 汇总(按原顺序; worker 在子 shell, 计数在父 shell 完成)
_n_push=0; _n_skip=0; _n_miss=0; _n_fail=0
for _i in $(seq 0 $((${#IMAGES[@]} - 1))); do
    _res="${PUSH_RESULT_DIR}/${_i}.result"
    if [ ! -f "${_res}" ]; then
        warn "  ${IMAGES[$_i]}: 推送进程异常退出(无结果)"
        _n_fail=$((_n_fail + 1)); continue
    fi
    _st=""; _msg=""
    IFS=$'\t' read -r _st _msg < "${_res}" || true
    case "${_st}" in
        push) ok "  ${_msg}"; _n_push=$((_n_push + 1)) ;;
        skip) ok "  ${_msg}"; _n_skip=$((_n_skip + 1)) ;;
        miss) warn "  ${_msg}"; _n_miss=$((_n_miss + 1)) ;;
        *)    warn "  ${_msg:-${IMAGES[$_i]}: 推送失败(无结果信息)}"; _n_fail=$((_n_fail + 1)) ;;
    esac
done
unset _DEVLAB_TASKS _i _res _st _msg _img

echo "---------------------------------------------"
say "开发镜像加载: 新推 ${_n_push} / digest 跳过 ${_n_skip} / 缺 tar ${_n_miss} / 失败 ${_n_fail}"
[ "${_n_miss}" -gt 0 ] && warn "  有 ${_n_miss} 个镜像缺离线 tar(生成: harbor-save-images.sh --group dev-lab)"
[ "${_n_fail}" -gt 0 ] && warn "  有 ${_n_fail} 个镜像推送失败(重跑本模块自动续推, 已推的按 digest 跳过)"
if [ $((_n_push + _n_skip)) -gt 0 ]; then
    ok "开发镜像处理完成(引用: ${REG_BASE}/suanova/<name>:<per-image tag>; 节点从此 registry 拉取)"
    # 优雅覆盖登记(集群内资产: registry 镜像内容; 无独立卸载动作 —— 随集群/registry 覆盖消亡)
    record_installed_component "dev_lab"
else
    warn "无镜像可加载(全部缺离线 tar) —— 本模块本次等效跳过, 不登记"
fi
