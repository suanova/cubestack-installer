#!/bin/bash
# ============================================================
# sync-to-minio.sh — 本地 offline-files 全量镜像同步到 MinIO(结构一致)
# ------------------------------------------------------------
# 用途: 把本机 offline-files(kubespray/lws/metax-gpu/os/virtual-machine ...)
#       **所有子目录**整体镜像到 MinIO 的 <桶>/offline-files/ 下, 远端目录结构与本地
#       完全一致; 供其他部署机 fetch-offline-from-minio.sh 拉取(下载侧逻辑不变)。
# 命令(等价):
#   mc mirror --overwrite ./offline-files/ minio/cubestack-installer/offline-files/
# 行为:
#   · 目标固定 = <alias>/cubestack-installer/offline-files(fetch 默认读取路径;
#     需改桶/目录时用 cluster.conf 的 MINIO_BUCKET / MINIO_REMOTE_DIR)
#   · alias: 已配置的 minio 别名优先复用; 否则用 cluster.conf MINIO_* 自动配置;
#     都没有则报错并给指引(不再做多别名/多桶启发式探测)
#   · mc mirror --overwrite 增量同步全部子目录(自动发现新增/变更文件), 远端结构 = 本地结构
#   · 同步前可读性预检: mc mirror 对不可读文件(如 root 0600 的 docker save tar)会**静默跳过**,
#     预检发现即报错给指引, 避免"某个组件目录没同步过去"这类部分同步假成功
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
OFFLINE_FILES_ROOT_RAW="${OFFLINE_FILES_ROOT:-}"

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config
# 判定同步源(sync 的源是 **offline-files 总根** —— kubespray/lws/metax-gpu/os… 全部组件):
#   ① 用户在**环境里**显式设了 OFFLINE_FILES_DIR(旧语义) → 用它(兼容老用法)
#   ② 否则用 OFFLINE_FILES_ROOT(显式设的, 或 lib-common 派生的真根)
# ⚠ 2026-09-30 修: 此前用"路径形状哨兵"猜(*/offline-files/kubespray)来判断"是不是 lib-common
#   的派生默认" —— 形状只在默认位置成立: OFFLINE_FILES_ROOT 一旦指向别处(夹具 / /data/offline-files
#   / 容器挂载), 派生值就不匹配哨兵 ⇒ 误判成"用户显式" ⇒ 源目录退化成单个版本目录,
#   只同步 kubespray 一个组件、其余静默不同步。现按**来源**(RAW 捕获于 source 之前)判定, 不再猜形状。
if [ -n "${OFFLINE_FILES_DIR_RAW}" ]; then
    OFFLINE_FILES_DIR_EXPLICIT="${OFFLINE_FILES_DIR_RAW}"
else
    OFFLINE_FILES_DIR_EXPLICIT=""
fi

PRUNE=0
DRY_RUN=0
FORCE_FULL_PRUNE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --prune)  PRUNE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --force-full-prune) FORCE_FULL_PRUNE=1; shift ;;
        # --plan-versions: 只读计划(扫 LOCAL_ONLY 标记, 打印"将上传/将跳过"), 不碰 mc、不联网。
        #   与下面的 LOCAL_SRC 同源(此处提前算, 以避开 mc 依赖) —— 改一处要改两处。
        --plan-versions)
            _src="${OFFLINE_FILES_DIR_EXPLICIT:-${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}}"
            printf '源目录: %s\n' "${_src}"
            _n_up=0; _n_skip=0
            shopt -s nullglob
            for _d in "${_src}"/*/*/; do
                _comp="$(basename "$(dirname "${_d}")")"; _ver="$(basename "${_d}")"
                { [ -f "${_d}/tree.tar.gz" ] || [ -f "${_d}/VERSION.profile" ] || [ -f "${_d}/LOCAL_ONLY" ] || [ -d "${_d}/images" ]; } || continue
                if [ -f "${_d}/LOCAL_ONLY" ]; then
                    printf '将跳过(本地临时版本, 不上传): %s/%s\n' "${_comp}" "${_ver}"; _n_skip=$((_n_skip+1))
                else
                    printf '将上传: %s/%s\n' "${_comp}" "${_ver}"; _n_up=$((_n_up+1))
                fi
            done
            shopt -u nullglob
            printf '合计: 上传 %d 个版本目录, 跳过 %d 个(本地临时)\n' "${_n_up}" "${_n_skip}"
            exit 0 ;;
        -h|--help) head -25 "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "未知参数: $1(可用 --prune/--dry-run/--force-full-prune/--plan-versions)"; exit 1 ;;
    esac
done

# 版本目录扫描(2026-09-30): ① LOCAL_ONLY 一律不上传(设计 D4)② 存在版本目录时收窄 --prune
#   —— 全根 mc mirror --remove 会删掉远端**其它版本**的对象(多版本共存下是数据损失)。
VERSION_RELS=(); LOCAL_ONLY_RELS=()
shopt -s nullglob
for _d in "${OFFLINE_FILES_DIR_EXPLICIT:-${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}}"/*/*/; do
    { [ -f "${_d}/tree.tar.gz" ] || [ -f "${_d}/VERSION.profile" ] || [ -f "${_d}/LOCAL_ONLY" ] || [ -d "${_d}/images" ]; } || continue
    _rel="$(basename "$(dirname "${_d}")")/$(basename "${_d}")/"
    VERSION_RELS+=("${_rel}")
    [ -f "${_d}/LOCAL_ONLY" ] && LOCAL_ONLY_RELS+=("${_rel}")
done
shopt -u nullglob

# --prune 收窄: 存在版本目录时, 全根 --remove 会互删各版本 ⇒ 必须显式 --force-full-prune
if [ "${PRUNE}" = "1" ] && [ "${DRY_RUN}" = "0" ] && [ "${FORCE_FULL_PRUNE}" != "1" ] && [ "${#VERSION_RELS[@]}" -gt 0 ]; then
    err "拒绝执行 --prune: 本地存在 ${#VERSION_RELS[@]} 个版本目录, 全根 --remove 会删除远端**其它版本**的对象"
    err "  → 先看计划: $0 --prune --dry-run"
    err "  → 确认要全根对齐(远端多余对象会被删)再加 --force-full-prune"
    exit 1
fi

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
LOCAL_SRC="${OFFLINE_FILES_DIR_EXPLICIT:-${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}}"
[ -d "${LOCAL_SRC}" ] || { err "本地 offline-files 目录不存在: ${LOCAL_SRC}"; exit 1; }
REMOTE_DST="${MINIO_ALIAS}/${MINIO_BUCKET}/${MINIO_REMOTE_DIR}"

# 可读性预检: mc mirror 对不可读文件会静默跳过(曾致 root-0600 的 docker-save tar 未同步,
# 却仍报"同步完成")。同步前先全量扫描, 发现不可读文件立即报错给指引, 杜绝部分同步假成功。
_UNREADABLE="$(find "${LOCAL_SRC}" -type f ! -readable 2>/dev/null)"
if [ -n "${_UNREADABLE}" ]; then
    _N="$(printf '%s\n' "${_UNREADABLE}" | wc -l)"
    err "发现 ${_N} 个不可读文件(mc mirror 会静默跳过 → 部分目录不同步):"
    printf '%s\n' "${_UNREADABLE}" | head -10 | sed 's/^/  /'
    [ "${_N}" -gt 10 ] && err "  ... 等 ${_N} 个"
    err "修复(任选其一)后重跑:"
    err "  ① 放开读权限: sudo chmod -R a+r \"${LOCAL_SRC}\""
    err "  ② 整脚本以 root 运行: sudo ./sync-to-minio.sh(root 的 mc alias 需已配置)"
    exit 1
fi

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
# 本地临时版本不上传(设计 D4): mc --exclude(含目录内全部内容)
if [ "${#LOCAL_ONLY_RELS[@]}" -gt 0 ]; then
    for _rel in "${LOCAL_ONLY_RELS[@]}"; do
        MC_ARGS+=(--exclude "${_rel}*")
        say "  跳过本地临时版本(不上传): ${_rel%/}"
    done
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
