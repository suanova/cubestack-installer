#!/bin/bash
# ============================================================
# sync-to-minio.sh — 本地 offline-files 全量镜像同步到 MinIO(结构一致)
# ------------------------------------------------------------
# 用途: 把本机 offline-files(envoy/kubespray/lws/metax-gpu/os/virtual-machine ...)
#       **所有子目录**整体镜像到 MinIO 的 <桶>/offline-files/ 下, 远端目录结构与本地
#       完全一致; 供其他部署机 fetch-offline-from-minio.sh 拉取(下载侧逻辑不变)。
# 命令(等价):
#   mc mirror --overwrite ./offline-files/ minio/cubestack-installer/offline-files/
# 行为:
#   · 目标固定 = <alias>/cubestack-installer/offline-files(fetch 默认读取路径;
#     需改桶/目录时用 cluster.conf 的 MINIO_BUCKET / MINIO_REMOTE_DIR)
#   · alias: 已配置的 minio 别名优先复用; 否则用 cluster.conf MINIO_* 自动配置;
#     都没有则报错并给指引(不再做多别名/多桶启发式探测)
#   · mc mirror --overwrite 增量同步全部子目录, 远端结构 = 本地结构
#   · 可选 --prune: 删除远端有而本地没有的文件(与本地严格一致, 远端其他集群共享时勿用)
#   · 可选 --dry-run: 只预览不实际同步
# 用法:
#   ./sync-to-minio.sh            # 同步(默认 --overwrite 增量)
#   ./sync-to-minio.sh --prune    # 同步 + 删除远端多余文件(与本地严格一致)
#   ./sync-to-minio.sh --dry-run  # 仅预览(不实际同步)
# 数据源: config/cluster.conf (MINIO_ALIAS / MINIO_ENDPOINT / MINIO_ACCESS_KEY /
#                              MINIO_SECRET_KEY / MINIO_BUCKET / MINIO_REMOTE_DIR / OFFLINE_FILES_DIR)
# ============================================================
set -euo pipefail

# 捕获"进程环境显式传入的 OFFLINE_FILES_DIR"(须在 load_config 之前, 否则已被 lib-common 默认覆盖)
OFFLINE_FILES_DIR_RAW="${OFFLINE_FILES_DIR:-}"

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config
# 判定"用户显式 OFFLINE_FILES_DIR"(同上 fetch-offline-from-minio.sh):
#   lib-common 会把未设置时的默认导出为 .../offline-files/kubespray(部署脚本专用内层语义),
#   sync 的源是 offline-files 总根(envoy/kubespray/lws/metax-gpu/os/virtual-machine 全部子目录),
#   不能误用该内层默认 → 仅在用户显式设置时采用, 否则回退 offline-files 总根。
OFFLINE_FILES_DIR_EXPLICIT=""
if [ -n "${OFFLINE_FILES_DIR_RAW:-}" ]; then
    OFFLINE_FILES_DIR_EXPLICIT="${OFFLINE_FILES_DIR_RAW}"
elif [ -n "${OFFLINE_FILES_DIR:-}" ]; then
    case "${OFFLINE_FILES_DIR}" in
        */offline-files/kubespray) OFFLINE_FILES_DIR_EXPLICIT="" ;;  # lib-common 默认内层, 忽略
        *) OFFLINE_FILES_DIR_EXPLICIT="${OFFLINE_FILES_DIR}" ;;      # 用户显式根
    esac
fi

PRUNE=0
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --prune)  PRUNE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) head -25 "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "未知参数: $1(可用 --prune/--dry-run)"; exit 1 ;;
    esac
done

# ---------------- 1. mc client 检测 ----------------
say "检查 mc(MinIO Client) ..."
command -v mc >/dev/null 2>&1 || {
    err "未找到 mc(MinIO Client)。安装: curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc && chmod +x /usr/local/bin/mc; 或用 CLI 容器(已内置)"; exit 1; }
ok "mc 已安装: $(command -v mc)"

# ---------------- 2. alias 解析(确定性: 已有别名 / cluster.conf MINIO_* / 报错指引) ----------------
MINIO_ALIAS="${MINIO_ALIAS:-minio}"
# 目标 = fetch-offline-from-minio.sh 默认读取的路径(桶/目录可经 cluster.conf 覆盖)
MINIO_BUCKET="${MINIO_BUCKET:-cubestack-installer}"
MINIO_REMOTE_DIR="${MINIO_REMOTE_DIR:-offline-files}"

if [ -n "${MINIO_ENDPOINT:-}${MINIO_ACCESS_KEY:-}${MINIO_SECRET_KEY:-}" ] && [ -n "${MINIO_ENDPOINT:-}" ]; then
    say "cluster.conf 提供 MinIO 配置 → 配置 alias ${MINIO_ALIAS}: ${MINIO_ENDPOINT}"
    mc alias set "${MINIO_ALIAS}" "${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" >/dev/null 2>&1 \
        || { err "mc alias 配置失败(检查 MINIO_ENDPOINT/凭证/网络)"; exit 1; }
    ok "alias ${MINIO_ALIAS} 配置就绪"
elif mc alias list 2>/dev/null | grep -q "^${MINIO_ALIAS}[[:space:]]*$"; then
    ok "复用已有 alias '${MINIO_ALIAS}'"
else
    err "未配置 mc alias '${MINIO_ALIAS}'。请任选其一:"
    err "  ① mc alias set ${MINIO_ALIAS} <endpoint> <accesskey> <secretkey>"
    err "  ② 在 cluster.conf 填 MINIO_ENDPOINT / MINIO_ACCESS_KEY / MINIO_SECRET_KEY"
    exit 1
fi

# ---------------- 3. 本地源目录 + 远端目标(结构一致) ----------------
LOCAL_SRC="${OFFLINE_FILES_DIR_EXPLICIT:-${REPO_ROOT}/deployments/offline-files}"
[ -d "${LOCAL_SRC}" ] || { err "本地 offline-files 目录不存在: ${LOCAL_SRC}"; exit 1; }
REMOTE_DST="${MINIO_ALIAS}/${MINIO_BUCKET}/${MINIO_REMOTE_DIR}"

# 桶存在性: 不存在则创建(mc ls 桶顶层成功即视为存在, 空桶不误判)
if ! mc ls "${MINIO_ALIAS}/${MINIO_BUCKET}" >/dev/null 2>&1; then
    say "桶 ${MINIO_BUCKET} 不存在, 创建 ..."
    mc mb "${MINIO_ALIAS}/${MINIO_BUCKET}" >/dev/null 2>&1 \
        || { err "创建桶失败(检查权限)"; exit 1; }
fi

say "同步本地 offline-files → MinIO(全部子目录, 远端结构 = 本地结构)"
say "  源:     ${LOCAL_SRC}"
say "  目标:   ${REMOTE_DST}"
say "  模式:   $([ "${DRY_RUN}" = "1" ] && echo 'DRY-RUN 预览(不同步)' || echo 'mc mirror --overwrite')"

# ---------------- 4. 执行同步 ----------------
MC_ARGS=(mirror)
if [ "${DRY_RUN}" = "1" ]; then
    MC_ARGS+=(--dry-run)
else
    MC_ARGS+=(--overwrite)
    [ "${PRUNE}" = "1" ] && MC_ARGS+=(--remove)   # --remove = 删除远端多余文件
fi
MC_ARGS+=("${LOCAL_SRC}/" "${REMOTE_DST}/")

say "执行: mc ${MC_ARGS[*]}"
if [ "${DRY_RUN}" = "1" ]; then
    mc "${MC_ARGS[@]}" 2>&1 | tail -20
else
    mc "${MC_ARGS[@]}" || { err "mc mirror 同步失败"; exit 1; }
fi

echo "---------------------------------------------"
if [ "${DRY_RUN}" = "1" ]; then
    ok "预览完成(未实际同步)。去掉 --dry-run 执行同步"
else
    ok "同步完成: ${LOCAL_SRC} → ${REMOTE_DST}"
    echo "  其他部署机拉取: ./fetch-offline-from-minio.sh(默认排除 virtual-machine; --sub/--all 按需)"
    [ "${PRUNE}" = "1" ] && echo "  已启用 --remove: 远端多余文件已删除(MinIO 与本地一致)"
fi
