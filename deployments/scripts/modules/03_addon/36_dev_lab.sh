#!/bin/bash
# ============================================================
# MODULE: dev_lab
# DESC: 开发镜像(jupyter/ssh 系列)离线 tar → 集群内置 registry(**排在全部部署模块末位**; 默认 push, digest 幂等)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: DEV_LAB_ENABLED
# REQUIRES: k8s_deploy k8s_registry
# 说明:
#   · 镜像(6 个; 上游均在本台 Harbor 的 suanova 项目 —— 不镜像到 mirrors/, save 直接用原始 ref):
#       harbor.isuanova.com/suanova/jupyter-minimal:${DEV_LAB_IMAGE_TAG}
#       harbor.isuanova.com/suanova/jupyter-maca-pytorch:${DEV_LAB_IMAGE_TAG}
#       harbor.isuanova.com/suanova/jupyter-cuda-pytorch:${DEV_LAB_IMAGE_TAG}
#       harbor.isuanova.com/suanova/ssh-ubuntu22.04:${DEV_LAB_IMAGE_TAG}
#       harbor.isuanova.com/suanova/ssh-maca-pytorch:${DEV_LAB_IMAGE_TAG}
#       harbor.isuanova.com/suanova/ssh-cuda-pytorch:${DEV_LAB_IMAGE_TAG}
#   · 离线 tar: deployments/offline-files/dev-lab/{jupyter,ssh}/(2026-10-16 起按家族分子目录,
#     顶层平铺兼容双读; 联网机: harbor-save-images.sh --group dev-lab; Harbor→MinIO 保鲜管道
#     按 offline-files/dev-lab/image-list.tsv 增量维护);
#     .tar 与 .tar.gz 均可(大件可就地 gzip 省盘; plain 内容校验 / .gz 文件名匹配, 见 README);
#     缺某个 tar → 该镜像 warn 跳过(不阻断部署), 结尾汇总(🅰 诚实: 不伪装成功)。
#   · 目标 ref: <集群 registry>/suanova/<name>:<tag>(去 Harbor 注册域保 suanova/ 路径,
#     与 25_cubestack_operator 的自研镜像映射同款)。
#   · 幂等: 目标 digest == 源 digest → 跳过 —— tag 是滚动的 latest, **必须比 digest**,
#     不能只看 tag 存在(与 25 模块同款教训)。
#   · 默认启用 = 默认 push: DEV_LAB_ENABLED 默认 true(见 cluster.conf.example 顶部开关区)
#     ⇒ 每次默认部署自动把 tar 推入集群 registry; 跳过: --skip dev_lab 或 DEV_LAB_ENABLED=false。
#   · 顺序(2026-10-13 用户口径): 模块文件排在 03_addon **末位 36**(全部 operator/组件/验证之后)
#     —— 开发镜像无任何依赖(全仓无消费者, 已核对)⇒ ≈45G 的大推送不占用关键链路时间,
#     前面的组件/验证先完成先验收; 覆盖安装"反序卸载"时 dev_lab 无卸载动作, 顺序变化无副作用。
# 数据源: cluster.conf (DEV_LAB_* / REGISTRY_* / NODES / SSH_KEY_NAME)
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
TAG="${DEV_LAB_IMAGE_TAG:-latest}"
HARBOR_HOST="harbor.isuanova.com"                        # 上游注册域(与 images.manifest dev-lab 组一致)
# 集群内置 registry 双端点(与 multus/rdma/gpu 同款): REG_DIRECT=推送直连, REG_BASE=节点引用
REG_DIRECT="${REGISTRY_DIRECT:-${REGISTRY_IP:-$(first_master_ip)}:${REGISTRY_PORT:-5000}}"
REG_BASE="${REGISTRY_DOMAIN:-${REGISTRY_IP}}:${REGISTRY_PORT:-5000}"

IMAGES=(
    jupyter-minimal
    jupyter-maca-pytorch
    jupyter-cuda-pytorch
    ssh-ubuntu22.04
    ssh-maca-pytorch
    ssh-cuda-pytorch
)

say "开发镜像 → 集群内置 registry(共 ${#IMAGES[@]} 个; 源 ${SAVE_DIR}, tag=${TAG})..."
if [ ! -d "${SAVE_DIR}" ]; then
    warn "离线目录不存在: ${SAVE_DIR}"
    warn "  生成离线 tar: sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group dev-lab"
    exit 0
fi

skopeo_require "dev_lab"
wait_registry_ready "http://${REG_DIRECT}/v2/" 30 \
    || { err "集群内置 registry ${REG_DIRECT}/v2/ 30s 内不可达(检查 SERVICE_EXPOSE_MODE / registry pod / REGISTRY_DIRECT)"; exit 1; }

_n_push=0; _n_skip=0; _n_miss=0; _n_fail=0
for _img in "${IMAGES[@]}"; do
    # 目录分类(2026-10-16): jupyter/ 与 ssh/ 子目录优先, 兼容顶层平铺(迁移期双读)
    case "${_img}" in
        jupyter-*) _sd="${SAVE_DIR}/jupyter" ;;
        ssh-*)     _sd="${SAVE_DIR}/ssh" ;;
        *)         _sd="${SAVE_DIR}" ;;
    esac
    _tar="$(find_offline_tar "${_img}:${TAG}" "*.tar" "${_sd}" "${SAVE_DIR}" 2>/dev/null || true)"
    if [ -z "${_tar}" ]; then
        warn "  缺离线 tar: ${_img}:${TAG}(跳过; 生成: sudo tools/images/harbor-save-images.sh --group dev-lab)"
        _n_miss=$((_n_miss + 1)); continue
    fi
    # 目标 ref: 去 Harbor 注册域, 保 suanova/ 路径(与 25 模块同款映射)
    _dst="docker://${REG_DIRECT}/suanova/${_img}:${TAG}"
    _dst_ref="${REG_BASE}/suanova/${_img}:${TAG}"
    # 幂等: digest 比对(latest 滚动 tag 必须比 digest, 不能只看 tag 存在)
    _d_dst="$(image_digest_raw "${_dst}")"
    _d_src="$(image_digest_raw "docker-archive:${_tar}")"
    if [ -n "${_d_dst}" ] && [ -n "${_d_src}" ] && [ "${_d_dst}" = "${_d_src}" ]; then
        ok "  ${_img}: 内容未变(digest ${_d_dst:0:19}...), 跳过推送"
        _n_skip=$((_n_skip + 1)); continue
    fi
    if push_image_skopeo "docker-archive:${_tar}" "${_dst}"; then
        _d_dst="$(image_digest_raw "${_dst}")"
        ok "  ${_img}: 已推送(源 $(basename "${_tar}")${_d_dst:+, digest ${_d_dst:0:19}...})"
        _n_push=$((_n_push + 1))
    else
        warn "  ${_img}: 推送失败(重试 3 次后); 检查 registry 可达/磁盘空间"
        _n_fail=$((_n_fail + 1))
    fi
done
unset _img _tar _dst _dst_ref _d_dst _d_src

echo "---------------------------------------------"
say "开发镜像加载: 新推 ${_n_push} / digest 跳过 ${_n_skip} / 缺 tar ${_n_miss} / 失败 ${_n_fail}"
[ "${_n_miss}" -gt 0 ] && warn "  有 ${_n_miss} 个镜像缺离线 tar(生成: harbor-save-images.sh --group dev-lab)"
[ "${_n_fail}" -gt 0 ] && warn "  有 ${_n_fail} 个镜像推送失败(重跑本模块自动续推, 已推的按 digest 跳过)"
if [ $((_n_push + _n_skip)) -gt 0 ]; then
    ok "开发镜像处理完成(引用: ${REG_BASE}/suanova/<name>:${TAG}; 节点从此 registry 拉取)"
    # 优雅覆盖登记(集群内资产: registry 镜像内容; 无独立卸载动作 —— 随集群/registry 覆盖消亡)
    record_installed_component "dev_lab"
else
    warn "无镜像可加载(全部缺离线 tar) —— 本模块本次等效跳过, 不登记"
fi
