#!/bin/bash
# ============================================================
# sync-to-minio.sh — 本地 offline-files 增量/全量同步到 MinIO
# ------------------------------------------------------------
# 用途: 把本机 offline-files(已清理后的精简部署必需文件)同步到 MinIO,
#       供其他部署机 fetch-offline-from-minio.sh 拉取 —— 保证 MinIO 侧也只存
#       部署必需文件, 不冗余。
# 命令(等价):
#   mc mirror --overwrite ./offline-files/ minio/cubestack-installer/offline-files/
#
# 行为:
#   · 已有 mc alias 时优先复用(不要求 cluster.conf 填 MINIO_*); 无可用 alias 才回退
#     cluster.conf MINIO_* 或交互录入
#   · 桶/目录自适应: 默认桶 cubestack-installer; 远端目录 = 与本地源同名(默认 offline-files),
#     保证 MinIO 侧布局与本地一致(兼容 cubestack-offline 旧布局)
#   · mc mirror --overwrite 增量同步: 只上传本地新增/变更文件, 已一致跳过
#   · 可选 --prune: 删除远端有而本地没有的文件(保持 MinIO 与本地一致,
#     需谨慎 —— 远端其他集群共享时勿用)
# 用法:
#   ./sync-to-minio.sh               # 同步(默认 --overwrite 增量)
#   ./sync-to-minio.sh --prune       # 同步 + 删除远端多余文件(与本地严格一致)
#   ./sync-to-minio.sh --dry-run     # 仅预览(不实际同步)
# 数据源: config/cluster.conf (MINIO_ALIAS / MINIO_ENDPOINT / MINIO_ACCESS_KEY /
#                              MINIO_SECRET_KEY / MINIO_BUCKET / MINIO_REMOTE_DIR / OFFLINE_FILES_DIR)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

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
if ! command -v mc >/dev/null 2>&1; then
    err "未找到 mc(MinIO Client)。安装: curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc && chmod +x /usr/local/bin/mc; 或用 CLI 容器(已内置)"
fi

# ---------------- 2. MinIO alias 配置(复用 cluster.conf / 探测 / 交互) ----------------
MINIO_ALIAS="${MINIO_ALIAS:-minio}"
# 默认桶 = 源布局桶 cubestack-installer(与 fetch-offline-from-minio.sh 一致); 旧 cubestack-offline 为回退探测
MINIO_BUCKET="${MINIO_BUCKET:-cubestack-installer}"
MINIO_REMOTE_DIR="${MINIO_REMOTE_DIR:-offline-files}"

mc_has() { mc ls "$1" 2>/dev/null | grep -q .; }

mc_alias_ready=0
# 已有可用 mc alias 时优先复用(不再要求 cluster.conf 的 MINIO_*):
#   探测顺序 = 默认 alias(minio)+ 全部已配置 alias, 桶 = 默认桶 + cubestack-installer + cubestack-offline,
#   首个可访问的 <alias>/<桶> 即为目标; 全都不行才回退到 cluster.conf MINIO_* 或交互录入。
if [ "${MINIO_ENDPOINT:-}${MINIO_ACCESS_KEY:-}${MINIO_SECRET_KEY:-}" != "" ] && [ -n "${MINIO_ENDPOINT:-}" ]; then
    say "cluster.conf 提供 MinIO 配置 → 配置 alias ${MINIO_ALIAS}: ${MINIO_ENDPOINT}"
    mc alias set "${MINIO_ALIAS}" "${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" >/dev/null 2>&1 \
        || { err "mc alias 配置失败(检查 MINIO_ENDPOINT/凭证/网络)"; exit 1; }
    ok "alias ${MINIO_ALIAS} 配置就绪"
    mc_alias_ready=1
else
    say "探测本机已有 mc alias(已有 alias 时优先复用; 无则用 cluster.conf MINIO_* 或交互录入) ..."
    for al in "${MINIO_ALIAS}" $(mc alias list 2>/dev/null | awk '/^[A-Za-z0-9_.-]+[[:space:]]*$/{print $1}'); do
        [ -n "${al}" ] || continue
        for _b in "${MINIO_BUCKET}" "cubestack-installer" "cubestack-offline"; do
            if mc_has "${al}/${_b}"; then
                ok "已有 alias '${al}' 可访问桶 ${_b}"
                MINIO_ALIAS="${al}"; MINIO_BUCKET="${_b}"; mc_alias_ready=1; break 2
            fi
        done
    done
fi
if [ "${mc_alias_ready}" != "1" ]; then
    # 已有 alias 但没探测到候选桶 → 列出 alias 下真实存在的桶, 让用户选择或确认新建;
    # 完全无可用 alias 时才交互录入凭证。
    # 注意: 此处 LOCAL_SRC 尚未定义, 不引用它(远端目录统一为 offline-files)。
    _avail="$(mc ls "${MINIO_ALIAS}" 2>/dev/null | awk '{print $NF}' | sed 's#/$##' | grep -vE '^(cuberouter|cubestack-install-full-offline-files)$' | tr '\n' ' ' | sed 's/ *$//')"
    if [ -n "${_avail:-}" ]; then
        say "alias '${MINIO_ALIAS}' 下已有桶: $(echo ${_avail} | tr '\n' ' ')"
        # 候选桶存在 → 直接用(取第一个候选); 否则保留默认桶 cubestack-installer 并自动新建
        _picked=""
        for _b in "${MINIO_BUCKET}" "cubestack-installer" "cubestack-offline"; do
            case " ${_avail} " in *" ${_b} "*) _picked="${_b}"; break ;; esac
        done
        if [ -n "${_picked}" ]; then
            MINIO_BUCKET="${_picked}"
            say "  复用桶: ${MINIO_BUCKET}"
        else
            warn "候选桶(${MINIO_BUCKET:-cubestack-installer}/cubestack-installer/cubestack-offline)均不存在, 将新建桶 ${MINIO_BUCKET:-cubestack-installer} 并同步到 minio/${MINIO_BUCKET:-cubestack-installer}/offline-files"
        fi
        mc_alias_ready=1   # 已有可用 alias; 桶不存在时后续自动创建
    fi
    if [ "${mc_alias_ready}" != "1" ]; then
        warn "未检测到可用的 MinIO 配置, 请交互录入(或先在 cluster.conf 配置 MINIO_* 变量):"
        read -r -p "  MinIO 服务地址 (如 http://192.168.16.6:9000): " _ept
        read -r -p "  AccessKey: " _ak
        read -r -s -p "  SecretKey: " _sk; echo ""
        [ -n "${_ept}" ] || { err "未输入 MinIO 地址"; exit 1; }
        mc alias set "${MINIO_ALIAS}" "${_ept}" "${_ak}" "${_sk}" >/dev/null 2>&1 \
            || { err "alias 配置失败(检查地址/凭证/网络)"; exit 1; }
        ok "alias ${MINIO_ALIAS} 配置就绪: ${_ept}"
    fi
fi

# ---------------- 3. 本地源目录 + 远端目标 ----------------
LOCAL_SRC="${OFFLINE_FILES_DIR:-${REPO_ROOT}/deployments/offline-files}"
[ -d "${LOCAL_SRC}" ] || { err "本地 offline-files 目录不存在: ${LOCAL_SRC}"; exit 1; }
# 远端目录 = 与本地源同名的目录名(默认 offline-files): 让 MinIO 侧布局与本地一致。
#   例: 源 ${LOCAL_SRC}=.../offline-files → 目标 minio/<桶>/offline-files
REMOTE_SUBDIR="$(basename "${LOCAL_SRC}")"
REMOTE_DIR="${MINIO_REMOTE_DIR:-${REMOTE_SUBDIR:-offline-files}}"
REMOTE_DST="${MINIO_ALIAS}/${MINIO_BUCKET}/${REMOTE_DIR}"

# 桶存在性: 不存在则创建(探测已通过时一定存在; 显式 MINIO_BUCKET 指向新桶时这里自动创建)
#   注: 探测仅"桶可访问"即可(空桶 mc_has 为假会误判"不存在", 故这里以 mc ls 桶顶层成功为准,
#   空桶仍视为存在不重建)。
if ! mc ls "${MINIO_ALIAS}/${MINIO_BUCKET}" >/dev/null 2>&1; then
    say "桶 ${MINIO_BUCKET} 不存在, 创建 ..."
    mc mb "${MINIO_ALIAS}/${MINIO_BUCKET}" >/dev/null 2>&1 \
        || { err "创建桶失败(检查权限)"; exit 1; }
fi

say "同步本地 offline-files → MinIO"
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
