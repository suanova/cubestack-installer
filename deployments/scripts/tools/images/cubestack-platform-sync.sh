#!/bin/bash
# ============================================================
# cubestack-platform-sync.sh — 平台/组件镜像保鲜编排: Harbor → 离线 tar → MinIO(内网)
# ------------------------------------------------------------
# 定位: 跑在**能同时访问 Harbor 与 MinIO 的机器**上(Harbor 服务器 / 安装机; 2026-10-16 定案 ——
#   MinIO 无 TLS, 不走公网/CI 托管 runner, 避免明文传密码与大流量公网传输)。
# 集合(collections; 每个 = offline-files/<集合>/ 目录 + 其 image-list.tsv 清单):
#   · cubestack-operator  平台 Operator 与各组件镜像(37 件)
#   · model-collection    模型推理镜像 sglang / vllm-metax(6 件 ≈95G, 大件建议 .tar.gz)
#   · dev-lab             开发镜像 jupyter / ssh(6 件)
#   默认全部处理; --collection 可只跑其中若干(逗号/空格分隔)。
# 流程(逐集合):
#   ① 从 MinIO 拉回现有 *.digest 边车(--exclude '*.tar' '*.tar.gz', 只拉小文件)
#      → 让第②步的"未变化即跳过"生效(增量, 不重复拉大镜像);
#   ② 调用 cubestack-platform-save-images.sh: 逐镜像 digest 比对, 变化才 skopeo 拉取+重写 tar;
#   ③ 上传: mc mirror --overwrite 状态目录 → <桶>/<前缀>/<集合>/
#      (只上传本地存在者; 默认**不删**远端 —— 需要收敛历史残留时显式 --prune);
#   ④ 校验: 汇总本地/远端 tar(.tar/.tar.gz)数并对照。
#
# 配置(环境变量, 或 --conf <file> 指向 600 的 env 文件; 与 cluster.conf 同名):
#   MINIO_ENDPOINT(如 http://minio:9000) MINIO_ACCESS_KEY MINIO_SECRET_KEY
#   MINIO_BUCKET(默认 cubestack-installer) MINIO_REMOTE_DIR(默认 offline-files)
#   HARBOR_MIRROR_USER / HARBOR_MIRROR_PASSWORD(或 REGISTRY_AUTH_FILE; 否则用 ~/.docker/config.json)
# 用法:
#   bash tools/images/cubestack-platform-sync.sh [--state-dir <d>] [--conf <envfile>]
#        [--collection <name,..>] [--only <子串,..>] [--force] [--no-pull-state] [--prune]
#        [--seal-missing] [--dry-run] [--print-systemd]
# 退出码: 0=成功; 1=有集合失败(其余集合继续)
# ============================================================
set -euo pipefail

_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib-common.sh
source "${_self}/../../lib-common.sh"

STATE_DIR="${CUBESTACK_SYNC_STATE:-/var/lib/cubestack-platform-sync}"
CONF=""
COLLECTIONS=""
ONLY=""
FORCE=0
PULL_STATE=1
PRUNE=0
SEAL=0
DRY=0
PRINT_SYSTEMD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --state-dir) STATE_DIR="${2:?}"; shift 2 ;;
        --conf)      CONF="${2:?}"; shift 2 ;;
        --collection) COLLECTIONS="${COLLECTIONS} ${2//,/ }"; shift 2 ;;
        --only)      ONLY="${2:?}"; shift 2 ;;
        --force)     FORCE=1; shift ;;
        --no-pull-state) PULL_STATE=0; shift ;;
        --prune)     PRUNE=1; shift ;;
        --seal-missing) SEAL=1; shift ;;
        --dry-run)   DRY=1; shift ;;
        --print-systemd) PRINT_SYSTEMD=1; shift ;;
        *) err "未知参数: $1"; exit 1 ;;
    esac
done
[ -n "${CONF}" ] && { [ -f "${CONF}" ] || { err "配置文件不存在: ${CONF}"; exit 1; }; set -a; . "${CONF}"; set +a; }
COLLECTIONS="${COLLECTIONS:-${CUBESTACK_SYNC_COLLECTIONS:-cubestack-operator model-collection dev-lab}}"

MINIO_BUCKET="${MINIO_BUCKET:-cubestack-installer}"
MINIO_REMOTE_DIR="${MINIO_REMOTE_DIR:-offline-files}"
ALIAS="cubestack-sync"

if [ "${PRINT_SYSTEMD}" = "1" ]; then
    cat <<EOF
# ==== /etc/systemd/system/cubestack-platform-sync.service ====
[Unit]
Description=CubeStack image collections refresh (Harbor -> tars -> MinIO)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/cubestack-platform-sync.env
ExecStart=/usr/bin/bash ${_self}/cubestack-platform-sync.sh --state-dir ${STATE_DIR}

# ==== /etc/systemd/system/cubestack-platform-sync.timer ====
[Unit]
Description=Daily CubeStack image collections refresh

[Timer]
OnCalendar=*-*-* 03:37:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target

# ==== 使用 ====
#   1) 写 /etc/cubestack-platform-sync.env(权限 600):
#        MINIO_ENDPOINT=<http://minio-host:9000>
#        MINIO_ACCESS_KEY=...
#        MINIO_SECRET_KEY=...
#        HARBOR_MIRROR_USER=...
#        HARBOR_MIRROR_PASSWORD=...
#   2) systemctl daemon-reload && systemctl enable --now cubestack-platform-sync.timer
#   3) 手动验一把: bash ${_self}/cubestack-platform-sync.sh --conf /etc/cubestack-platform-sync.env
#   (默认覆盖全部集合; 单集合: --collection cubestack-operator 等)
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
[ -n "${MC}" ] || MC="$(command -v mc || true)"
[ -n "${MC}" ] || MC="$(ls "${REPO_ROOT}"/deployments/offline-files/os/mc-*-linux-amd64 2>/dev/null | head -1 || true)"
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

# mc 隔离配置(不碰用户 ~/.mc, 也不污染 offline-files 挂载)
export MC_CONFIG_DIR="${MC_CONFIG_DIR:-/tmp/.cubestack-platform-sync-mc}"
mkdir -p "${MC_CONFIG_DIR}"
"${MC}" alias set "${ALIAS}" "${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" >/dev/null

# 本地产出清单计数(.tar 与 .tar.gz 都算; 排除隐藏目录)
_local_tarn() { find "$1" \( -name '*.tar' -o -name '*.tar.gz' \) -not -path '*/.*' 2>/dev/null | wc -l; }

# ---------- 逐集合同步 ----------
declare -i RC=0
declare -a SUMMARY=()
for COL in ${COLLECTIONS}; do
    [ -n "${COL}" ] || continue
    say "════ 集合: ${COL} ════"
    STATE_SUB="${STATE_DIR}/offline-files/${COL}"
    REMOTE="${ALIAS}/${MINIO_BUCKET}/${MINIO_REMOTE_DIR}/${COL}/"
    REPO_SUB="${REPO_ROOT}/deployments/offline-files/${COL}"
    LIST="${REPO_SUB}/image-list.tsv"
    mkdir -p "${STATE_SUB}"
    if [ ! -f "${LIST}" ]; then
        warn "  清单不存在: ${LIST}(跳过该集合)"
        SUMMARY+=("${COL}: 跳过(无清单)"); continue
    fi

    # ① 拉回现有边车(增量前提)
    if [ "${PULL_STATE}" = "1" ]; then
        say "[1/4] 从 MinIO 拉回现有 *.digest 边车(--exclude tars)..."
        "${MC}" mirror --overwrite --exclude '*.tar' --exclude '*.tar.gz' ${DRY:+--dry-run} \
            "${REMOTE}" "${STATE_SUB}/" 2>/dev/null || warn "  边车拉取失败(首次运行/前缀不存在? 继续全量)"
    fi

    # ② 保鲜(拉取+save; --seal-missing 仅补边车不重拉)
    say "[2/4] 逐镜像 digest 比对与保鲜..."
    SAVE_ARGS=(--list "${LIST}" --out "${STATE_SUB}")
    [ -n "${ONLY}" ] && SAVE_ARGS+=(--only "${ONLY}")
    [ "${FORCE}" = "1" ] && SAVE_ARGS+=(--force)
    [ "${SEAL}" = "1" ] && SAVE_ARGS+=(--seal-missing)
    [ "${DRY}" = "1" ] && SAVE_ARGS+=(--dry-run)
    SAVE_RC=0
    bash "${_self}/cubestack-platform-save-images.sh" "${SAVE_ARGS[@]}" || SAVE_RC=1
    # README 保鲜(仓库里有就带上)
    [ -f "${REPO_SUB}/README.md" ] && cp -f "${REPO_SUB}/README.md" "${STATE_SUB}/README.md"

    # ③ 上传(防呆: --prune 且本地 0 个 tar ⇒ 拒绝, 防清空远端)
    L_PRE="$(_local_tarn "${STATE_SUB}")"
    if [ "${L_PRE}" = "0" ]; then
        if [ "${PRUNE}" = "1" ]; then
            err "  集合 ${COL} 状态目录无任何 tar 且给了 --prune —— 拒绝上传(会清空远端)"
            err "    --state-dir 应指向**包含 offline-files/ 的根**; 先 --dry-run 核对"
            RC+=1; SUMMARY+=("${COL}: 失败(空目录+prune)"); continue
        fi
        warn "  集合 ${COL} 本地 0 个 tar, 跳过上传"
        SUMMARY+=("${COL}: 跳过(无本地 tar)"); continue
    fi
    say "[3/4] 上传到 MinIO: ${REMOTE}(本地 tar=${L_PRE})"
    UP_ARGS=(mirror --overwrite --exclude '.backup*' --exclude '.mc*')
    [ "${PRUNE}" = "1" ] && UP_ARGS+=(--remove)
    [ "${DRY}" = "1" ] && UP_ARGS+=(--dry-run)
    if ! "${MC}" "${UP_ARGS[@]}" "${STATE_SUB}/" "${REMOTE}"; then
        err "  mc mirror 上传失败(${COL})"; RC+=1; SUMMARY+=("${COL}: 失败(上传)"); continue
    fi

    # ④ 校验
    say "[4/4] 校验(本地/远端 tar 数对照)..."
    L_N="$(_local_tarn "${STATE_SUB}")"
    R_N="$("${MC}" ls -r "${REMOTE}" 2>/dev/null | command grep -v '/\.' | command grep -cE '\.tar(\.gz)?$' || true)"
    say "  本地 tar=${L_N}  远端 tar=${R_N}"
    if [ "${DRY}" = "1" ]; then
        SUMMARY+=("${COL}: dry-run")
    elif [ "${L_N}" = "${R_N}" ] && [ "${SAVE_RC}" = "0" ]; then
        SUMMARY+=("${COL}: OK(${L_N})")
    else
        err "  集合 ${COL} 数量不一致或保鲜有失败(本地 ${L_N} / 远端 ${R_N}, save_rc=${SAVE_RC})"
        RC+=1; SUMMARY+=("${COL}: 失败(校验 ${L_N}/${R_N})")
    fi
done

echo "════════════════════════════════"
say "汇总: ${SUMMARY[*]}"
if [ "${DRY}" = "1" ]; then
    ok "dry-run 完成(未实际上传)"
else
    [ "${RC}" = "0" ] && ok "全部集合同步完成" || { err "有 ${RC} 个集合未完成(见上)"; exit 1; }
fi
