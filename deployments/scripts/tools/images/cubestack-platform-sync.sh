#!/bin/bash
# ============================================================
# cubestack-platform-sync.sh — 平台镜像保鲜编排: Harbor → 离线 tar → MinIO(内网)
# ------------------------------------------------------------
# 定位: 跑在**能同时访问 Harbor 与 MinIO 的机器**上(Harbor 服务器 / 安装机; 2026-10-16 定案 ——
#   MinIO 无 TLS, 不走公网/CI 托管 runner, 避免明文传密码与大流量公网传输)。
# 流程:
#   ① (默认)从 MinIO 拉回现有 *.digest 边车(--exclude '*.tar', 只拉小文件)
#      → 让第②步的"未变化即跳过"生效(增量, 不重复拉 8GB 镜像);
#   ② 调用 cubestack-platform-save-images.sh: 逐镜像 digest 比对, 变化才 skopeo 拉取+重写 tar;
#   ③ 上传: mc mirror --overwrite 状态目录 → <桶>/<前缀>/cubestack-operator/
#      (只上传本地存在者; 默认**不删**远端 —— 需要收敛历史残留时显式 --prune);
#   ④ 校验: 汇总本地/远端 tar 数并对照。
#
# 配置(环境变量, 或 --conf <file> 指向 600 的 env 文件; 与 cluster.conf 同名):
#   MINIO_ENDPOINT(http://minio-host:9000) MINIO_ACCESS_KEY MINIO_SECRET_KEY
#   MINIO_BUCKET(默认 cubestack-installer) MINIO_REMOTE_DIR(默认 offline-files)
#   HARBOR_MIRROR_USER / HARBOR_MIRROR_PASSWORD(或 REGISTRY_AUTH_FILE; 否则用 ~/.docker/config.json)
# 用法:
#   bash tools/images/cubestack-platform-sync.sh [--state-dir <d>] [--conf <envfile>]
#        [--only <子串,..>] [--force] [--no-pull-state] [--prune] [--dry-run] [--print-systemd]
# 退出码: 0=成功; 1=有镜像失败或上传/校验失败
# ============================================================
set -euo pipefail

_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib-common.sh
source "${_self}/../../lib-common.sh"

STATE_DIR="${CUBESTACK_SYNC_STATE:-/var/lib/cubestack-platform-sync}"
CONF=""
ONLY=""
FORCE=0
PULL_STATE=1
PRUNE=0
DRY=0
PRINT_SYSTEMD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --state-dir) STATE_DIR="${2:?}"; shift 2 ;;
        --conf)      CONF="${2:?}"; shift 2 ;;
        --only)      ONLY="${2:?}"; shift 2 ;;
        --force)     FORCE=1; shift ;;
        --no-pull-state) PULL_STATE=0; shift ;;
        --prune)     PRUNE=1; shift ;;
        --dry-run)   DRY=1; shift ;;
        --print-systemd) PRINT_SYSTEMD=1; shift ;;
        *) err "未知参数: $1"; exit 1 ;;
    esac
done
[ -n "${CONF}" ] && { [ -f "${CONF}" ] || { err "配置文件不存在: ${CONF}"; exit 1; }; set -a; . "${CONF}"; set +a; }

MINIO_BUCKET="${MINIO_BUCKET:-cubestack-installer}"
MINIO_REMOTE_DIR="${MINIO_REMOTE_DIR:-offline-files}"
ALIAS="cubestack-sync"
SUB="cubestack-operator"
STATE_SUB="${STATE_DIR}/offline-files/${SUB}"

if [ "${PRINT_SYSTEMD}" = "1" ]; then
    cat <<EOF
# ==== /etc/systemd/system/cubestack-platform-sync.service ====
[Unit]
Description=CubeStack platform images refresh (Harbor -> tars -> MinIO)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/cubestack-platform-sync.env
ExecStart=/usr/bin/bash ${_self}/cubestack-platform-sync.sh --state-dir ${STATE_DIR}

# ==== /etc/systemd/system/cubestack-platform-sync.timer ====
[Unit]
Description=Daily CubeStack platform images refresh

[Timer]
OnCalendar=*-*-* 03:37:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target

# ==== 使用 ====
#   1) 写 /etc/cubestack-platform-sync.env(权限 600):
#        MINIO_ENDPOINT=http://minio-host:9000
#        MINIO_ACCESS_KEY=...
#        MINIO_SECRET_KEY=...
#        HARBOR_MIRROR_USER=...
#        HARBOR_MIRROR_PASSWORD=...
#   2) systemctl daemon-reload && systemctl enable --now cubestack-platform-sync.timer
#   3) 手动验一把: bash ${_self}/cubestack-platform-sync.sh --conf /etc/cubestack-platform-sync.env
EOF
    exit 0
fi

# ---------- 前置 ----------
for v in MINIO_ENDPOINT MINIO_ACCESS_KEY MINIO_SECRET_KEY; do
    [ -n "${!v:-}" ] || { err "缺少 ${v}(--conf 或环境变量)"; exit 1; }
done
command -v skopeo >/dev/null 2>&1 || { err "缺少 skopeo(apt-get install -y skopeo)"; exit 1; }

# mc: MC_BIN > PATH > 仓库内置(offline-files/os/mc-*)> 自动下载(aistor 官方地址, 2026-10 起)
MC="${MC_BIN:-}"
if [ -z "${MC}" ]; then
    MC="$(command -v mc || true)"
fi
if [ -z "${MC}" ]; then
    MC="$(ls "${REPO_ROOT}"/deployments/offline-files/os/mc-*-linux-amd64 2>/dev/null | head -1 || true)"
fi
if [ -z "${MC}" ]; then
    MC="${STATE_DIR}/bin/mc"
    if [ ! -x "${MC}" ]; then
        say "mc 未找到, 下载(aistor 官方地址)..."
        mkdir -p "$(dirname "${MC}")"
        curl -fsSL --retry 3 -o "${MC}.tmp" https://dl.min.io/aistor/mc/release/linux-amd64/mc \
            && chmod +x "${MC}.tmp" && mv "${MC}.tmp" "${MC}" \
            || { err "mc 下载失败; 可手动放置到 ${MC} 或设 MC_BIN"; exit 1; }
    fi
fi
say "  工具: skopeo=$(command -v skopeo)  mc=${MC}"

# mc 隔离配置(不碰用户 ~/.mc)
export MC_CONFIG_DIR="${MC_CONFIG_DIR:-/tmp/.cubestack-platform-sync-mc}"   # 独立配置目录, 不碰用户 ~/.mc, 也不污染 offline-files 挂载
mkdir -p "${MC_CONFIG_DIR}" "${STATE_SUB}"
"${MC}" alias set "${ALIAS}" "${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" >/dev/null
REMOTE="${ALIAS}/${MINIO_BUCKET}/${MINIO_REMOTE_DIR}/${SUB}/"

# ---------- ① 拉回现有边车(增量前提) ----------
if [ "${PULL_STATE}" = "1" ]; then
    say "[1/4] 从 MinIO 拉回现有 *.digest 边车(--exclude '*.tar')..."
    "${MC}" mirror --overwrite --exclude '*.tar' ${DRY:+--dry-run} "${REMOTE}" "${STATE_SUB}/" 2>/dev/null || warn "  边车拉取失败(首次运行/前缀不存在? 继续全量)"
fi

# ---------- ② 保鲜(拉取+save) ----------
say "[2/4] 逐镜像 digest 比对与保鲜..."
SAVE_ARGS=(--out "${STATE_SUB}")
[ -n "${ONLY}" ] && SAVE_ARGS+=(--only "${ONLY}")
[ "${FORCE}" = "1" ] && SAVE_ARGS+=(--force)
[ "${DRY}" = "1" ] && SAVE_ARGS+=(--dry-run)
SAVE_RC=0
bash "${_self}/cubestack-platform-save-images.sh" "${SAVE_ARGS[@]}" || SAVE_RC=1
# README 保鲜(仓库里有就带上)
[ -f "$(dirname "${_self}")/../../../offline-files/${SUB}/README.md" ] \
    && cp -f "$(dirname "${_self}")/../../../offline-files/${SUB}/README.md" "${STATE_SUB}/README.md"

# ---------- ③ 上传 ----------
# ★ 防呆护栏(2026-10-16 dry-run 实测教训): 状态目录为空时上传毫无意义, --prune 更会**清空远端**
#   (多为 --state-dir/-conf 传错所致, 如把"离线目录本身"当成"包含 offline-files/ 的根")。
L_PRE="$(find "${STATE_SUB}" -name '*.tar' -not -path '*/.*' 2>/dev/null | wc -l)"
if [ "${L_PRE}" = "0" ]; then
    err "状态目录里没有任何 tar: ${STATE_SUB}"
    err "  --state-dir 应指向**包含 offline-files/ 的根**(如 /var/lib/cubestack-platform-sync 或"
    err "  本地布局的 deployments 目录); 先跑一次不带 --prune 的 --dry-run 核对路径。"
    exit 1
fi
say "[3/4] 上传到 MinIO: ${REMOTE}(本地 tar=${L_PRE})"
UP_ARGS=(mirror --overwrite --exclude '.backup*' --exclude '.mc*')
[ "${PRUNE}" = "1" ] && UP_ARGS+=(--remove)
[ "${DRY}" = "1" ] && UP_ARGS+=(--dry-run)
"${MC}" "${UP_ARGS[@]}" "${STATE_SUB}/" "${REMOTE}" || { err "  mc mirror 上传失败"; exit 1; }

# ---------- ④ 校验 ----------
say "[4/4] 校验(本地/远端 tar 数对照)..."
L_N="$(find "${STATE_SUB}" -name '*.tar' -not -path '*/.*' | wc -l)"
R_N="$("${MC}" ls -r "${REMOTE}" 2>/dev/null | command grep -v '/\.' | command grep -c '\.tar$' || true)"
say "  本地 tar=${L_N}  远端 tar=${R_N}"
if [ "${DRY}" = "1" ]; then
    ok "dry-run 完成(未实际上传)"
elif [ "${L_N}" = "${R_N}" ] && [ "${SAVE_RC}" = "0" ]; then
    ok "同步完成且数量一致"
else
    err "同步后数量不一致或保鲜有失败(本地 ${L_N} / 远端 ${R_N}, save_rc=${SAVE_RC})"
    exit 1
fi
