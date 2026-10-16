#!/bin/bash
# ============================================================
# MODULE: model_images
# DESC: 模型推理镜像(sglang / vllm-metax, 来源 suanova/model-collection 仓库)离线 tar → 集群内置 registry(排在 dev_lab 之后; 默认 push, digest 幂等)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: MODEL_IMAGES_ENABLED
# REQUIRES: k8s_deploy k8s_registry
# 说明:
#   · 镜像集 = offline-files/model-collection/image-list.tsv(单一事实源; 6 件 ≈95G:
#     suanova/sglang ×3 变体(主版本 + qwen21-dev + h3-patch), suanova/vllm-metax ×2,
#     yangle/vllm-metax ×1(0.25 py310 变体, 见 model-collection 仓库 refs))。
#   · 离线 tar: deployments/offline-files/model-collection/{sglang,vllm}/(子目录; .tar 与 .tar.gz 均可);
#     缺某个 tar → 该镜像 warn 跳过(不阻断部署), 结尾汇总(不伪装成功)。
#   · 目标 ref: <集群 registry>/<ref 去注册域后的路径>(suanova/… 与 yangle/… 原样保路径, 与 dev_lab 同款映射)。
#   · 幂等: 目标 digest == 源 digest → 跳过(比 digest 防重建漂移, 不只看 tag)。
#   · 默认启用 = 默认 push(MODEL_IMAGES_ENABLED 默认 true); 跳过: --skip model_images 或置 false。
#   · 顺序(2026-10-16 用户口径): **部署完集群与全部 operator 之后**才 push —— 模块文件排 37
#     (dev_lab=36 之后)⇒ ≈95G 的大推送不占用关键链路时间, 前面组件先完成先验收;
#     覆盖安装反序卸载时本模块无卸载动作(registry 镜像随集群/registry 覆盖消亡)。
# 数据源: cluster.conf (MODEL_IMAGES_* / REGISTRY_* / NODES / SSH_KEY_NAME)
# 用法:   sudo ./deploy-cluster.sh --steps model_images
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---- 开关(默认启用: 每次默认部署自动加载; 排在末位不影响关键链路) ----
[ "${MODEL_IMAGES_ENABLED:-true}" = "true" ] || { say "MODEL_IMAGES_ENABLED=false, 跳过模型推理镜像加载"; exit 0; }

init_remote_kubectl || exit 1

# ---------------- 派生变量(全部来自 cluster.conf / load_config, 无硬编码) ----------------
SAVE_DIR="${MODEL_IMAGES_SAVE_DIR:-${REPO_ROOT}/deployments/offline-files/model-collection}"
LIST="${SAVE_DIR}/image-list.tsv"
HARBOR_HOST="harbor.isuanova.com"
# 集群内置 registry 双端点(与 dev_lab / multus / rdma 同款): REG_DIRECT=推送直连, REG_BASE=节点引用
REG_DIRECT="${REGISTRY_DIRECT:-${REGISTRY_IP:-$(first_master_ip)}:${REGISTRY_PORT:-5000}}"
REG_BASE="${REGISTRY_DOMAIN:-${REGISTRY_IP}}:${REGISTRY_PORT:-5000}"

say "模型推理镜像 → 集群内置 registry(源 ${SAVE_DIR})..."
if [ ! -d "${SAVE_DIR}" ]; then
    warn "离线目录不存在: ${SAVE_DIR}"
    warn "  备料: 联网机 docker pull/save(见 ${SAVE_DIR}/README.md), 或经 Harbor→MinIO 保鲜管道同步"
    exit 0
fi
if [ ! -f "${LIST}" ]; then
    warn "镜像清单缺失: ${LIST}(跳过; 见目录 README)"
    exit 0
fi

skopeo_require "model_images"
wait_registry_ready "http://${REG_DIRECT}/v2/" 30 \
    || { err "集群内置 registry ${REG_DIRECT}/v2/ 30s 内不可达(检查 SERVICE_EXPOSE_MODE / registry pod / REGISTRY_DIRECT)"; exit 1; }

# ---------------- 主循环: 逐行(TSV: subdir<TAB>file<TAB>pull_ref<TAB>save_ref) ----------------
_n_push=0; _n_skip=0; _n_miss=0; _n_fail=0
while IFS=$'\t' read -r _sub _file _pull _save; do
    case "${_sub}" in ''|\#*) continue ;; esac
    [ -n "${_file}" ] || continue
    [ -n "${_save}" ] || _save="${_pull}"
    # tar 定位: 先精确(子目录 → 顶层兼容; .tar → .tar.gz), 再交给共享助手兜底
    _tar=""
    for _c in "${SAVE_DIR}/${_sub}/${_file}" "${SAVE_DIR}/${_sub}/${_file}.gz" \
              "${SAVE_DIR}/${_file}" "${SAVE_DIR}/${_file}.gz"; do
        [ -f "${_c}" ] && { _tar="${_c}"; break; }
    done
    [ -n "${_tar}" ] || _tar="$(find_offline_tar "/${_save#*/}" "*.tar" "${SAVE_DIR}/${_sub}" "${SAVE_DIR}" 2>/dev/null || true)"
    if [ -z "${_tar}" ]; then
        warn "  缺离线 tar: ${_file}(跳过; 备料见 ${SAVE_DIR}/README.md)"
        _n_miss=$((_n_miss + 1)); continue
    fi
    # 目标 ref: 去 Harbor 注册域, 保完整路径(suanova/…|yangle/…; 与 dev_lab 同款映射)
    _path="${_save#"${HARBOR_HOST}"/}"
    _dst="docker://${REG_DIRECT}/${_path}"
    _dst_ref="${REG_BASE}/${_path}"
    # 幂等: digest 比对(防重建漂移)
    _d_dst="$(image_digest_raw "${_dst}")"
    _d_src="$(image_digest_raw "docker-archive:${_tar}")"
    if [ -n "${_d_dst}" ] && [ -n "${_d_src}" ] && [ "${_d_dst}" = "${_d_src}" ]; then
        ok "  ${_path}: 内容未变(digest ${_d_dst:0:19}...), 跳过推送"
        _n_skip=$((_n_skip + 1)); continue
    fi
    if push_image_skopeo "docker-archive:${_tar}" "${_dst}"; then
        ok "  ${_path}: 已推送(源 $(basename "${_tar}")${_d_dst:+, 旧 digest ${_d_dst:0:19}...})"
        _n_push=$((_n_push + 1))
    else
        warn "  ${_path}: 推送失败(重试 3 次后); 检查 registry 可达/磁盘空间"
        _n_fail=$((_n_fail + 1))
    fi
done < <(command grep -vE '^[[:space:]]*#|^[[:space:]]*$' "${LIST}")
unset _sub _file _pull _save _tar _c _path _dst _dst_ref _d_dst _d_src

echo "---------------------------------------------"
say "模型推理镜像加载: 新推 ${_n_push} / digest 跳过 ${_n_skip} / 缺 tar ${_n_miss} / 失败 ${_n_fail}"
[ "${_n_miss}" -gt 0 ] && warn "  有 ${_n_miss} 个镜像缺离线 tar(备料见 ${SAVE_DIR}/README.md)"
[ "${_n_fail}" -gt 0 ] && warn "  有 ${_n_fail} 个镜像推送失败(重跑本模块自动续推, 已推的按 digest 跳过)"
if [ $((_n_push + _n_skip)) -gt 0 ]; then
    ok "模型推理镜像处理完成(引用: ${REG_BASE}/suanova/… 或 yangle/…; 节点从此 registry 拉取)"
    # 优雅覆盖登记(集群内资产: registry 镜像内容; 无独立卸载动作 —— 随集群/registry 覆盖消亡)
    record_installed_component "model_images"
else
    warn "无镜像可加载(全部缺离线 tar) —— 本模块本次等效跳过, 不登记"
fi
