#!/bin/bash
# ============================================================
# fetch-offline-files.sh — 从 MinIO 下载离线安装 binary 和镜像, 自动拷贝到 deployments/offline-files
# 用途: 离线安装需要 binary(kubeadm/etcd/...)+ 镜像 tar + 系统包; 本脚本用 MinIO Client(mc)
#       把离线文件从 MinIO 同步到本机 OFFLINE_FILES_DIR(默认 deployments/offline-files), 幂等。
# 前置: mc(MinIO Client)已安装(见 Dockerfile-cli / 手工安装); 变量见 cluster.conf 或环境变量。
# 用法: sudo ./fetch-offline-files.sh [--remote-dir <桶内目录>]
#       示例: sudo ./fetch-offline-files.sh
#             MINIO_ENDPOINT=https://minio.example.com MINIO_ACCESS_KEY=... MINIO_SECRET_KEY=... \
#               sudo ./fetch-offline-files.sh
# 数据源: cluster.conf (MINIO_ALIAS / MINIO_ENDPOINT / MINIO_ACCESS_KEY / MINIO_SECRET_KEY /
#                       MINIO_BUCKET / MINIO_REMOTE_DIR / OFFLINE_FILES_DIR)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

command -v mc >/dev/null 2>&1 || { err "未找到 mc(MinIO Client); 请先安装(如: curl -O https://dl.min.io/client/mc/release/linux-amd64/mc && install mc /usr/local/bin/), 或使用 Dockerfile-cli 镜像"; exit 1; }

MINIO_ALIAS="${MINIO_ALIAS:-minio}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-}"
MINIO_BUCKET="${MINIO_BUCKET:-cubestack-offline}"
MINIO_REMOTE_DIR="${1:-${MINIO_REMOTE_DIR:-kubespray}}"
DEST_DIR="${OFFLINE_FILES_DIR:-${REPO_ROOT}/deployments/offline-files}"

# ---------------- 参数校验 ----------------
[ -n "${MINIO_ENDPOINT}" ] || { err "未配置 MINIO_ENDPOINT(cluster.conf 或环境变量)"; exit 1; }
[ -n "${MINIO_ACCESS_KEY}" ] || { err "未配置 MINIO_ACCESS_KEY"; exit 1; }
[ -n "${MINIO_SECRET_KEY}" ] || { err "未配置 MINIO_SECRET_KEY"; exit 1; }

say "MinIO: ${MINIO_ENDPOINT}  桶: ${MINIO_BUCKET}  远程目录: ${MINIO_REMOTE_DIR}"
say "下载目标: ${DEST_DIR}(幂等, 已存在文件跳过)"
mkdir -p "${DEST_DIR}"

# ---------------- 配置 mc alias ----------------
say "配置 mc alias ${MINIO_ALIAS} ..."
mc alias set "${MINIO_ALIAS}" "${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" >/dev/null 2>&1 \
    || { err "mc alias 配置失败(检查 endpoint/凭证/网络)"; exit 1; }
ok "mc alias 就绪"

# ---------------- 检查远程目录是否存在 ----------------
mc ls "${MINIO_ALIAS}/${MINIO_BUCKET}/${MINIO_REMOTE_DIR}" >/dev/null 2>&1 \
    || { err "MinIO 中不存在目录 ${MINIO_ALIAS}/${MINIO_BUCKET}/${MINIO_REMOTE_DIR}(检查 MINIO_BUCKET / MINIO_REMOTE_DIR)"; exit 1; }

# ---------------- 同步(镜像到 OFFLINE_FILES_DIR) ----------------
# mc mirror: 增量同步(已存在且相同则跳过); --overwrite 保证内容一致
say "同步 ${MINIO_ALIAS}/${MINIO_BUCKET}/${MINIO_REMOTE_DIR}/ → ${DEST_DIR}/ ..."
mc mirror --overwrite "${MINIO_ALIAS}/${MINIO_BUCKET}/${MINIO_REMOTE_DIR}" "${DEST_DIR}" \
    || { err "同步失败(检查网络/磁盘空间)"; exit 1; }

echo "---------------------------------------------"
ok "离线文件同步完成 → ${DEST_DIR}"
du -sh "${DEST_DIR}" 2>/dev/null | awk '{print "  总大小: "$1}'
echo "  结构参考:"
echo "    ${DEST_DIR}/kubespray/          kubespray 离线仓库(镜像 images/ + 二进制 + packages/)"
echo "    ${DEST_DIR}/metax-gpu/          沐曦 GPU Operator 离线文件(可选)"
echo "    ${DEST_DIR}/lws/                LWS 控制器镜像 tar(可选)"
echo "    ${DEST_DIR}/envoy/              Envoy Gateway/AI Gateway 镜像 tar(可选)"
check_offline_files || true
