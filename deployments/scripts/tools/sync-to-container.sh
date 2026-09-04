#!/bin/bash
# ============================================================
# TOOL: sync-to-container
# DESC: 同步 dev 仓库部署脚本到部署容器(cubestack-install:/opt/cubestack-installer)
# 背景: 部署实际在容器内执行; dev 仓库(本机 /home/supperadm/cubestack-installer)修改后
#   需同步到容器。此前靠手工 docker cp(易漏文件/漏目录), 本脚本统一处理。
# 用法:
#   sync-to-container.sh                 # 全量同步 scripts/ 到容器
#   sync-to-container.sh --check         # 只显示将同步的文件数(不实际同步)
#   sync-to-container.sh <文件或目录...>  # 只同步指定路径(相对 deployments/ 或仓库根)
# 数据源: 无(cluster.conf 不参与同步 —— 各环境配置不同, 手工维护)
# ============================================================
set -euo pipefail

# 仓库根: 脚本位于 deployments/scripts/tools/ → 上溯 3 级
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TOOL_DIR}/../../.." && pwd)"
CONTAINER="${SYNC_CONTAINER:-cubestack-install}"
REMOTE_BASE="/opt/cubestack-installer"

# 默认同步范围: 部署脚本全集(cluster.conf 除外 —— 各环境配置独立)
DEFAULT_PATHS=(
    "deployments/scripts/lib-common.sh"
    "deployments/scripts/lib-module.sh"
    "deployments/scripts/deploy-cluster.sh"
    "deployments/scripts/modules"
    "deployments/scripts/tools"
    "deployments/cubestack-addon"
)

say()  { echo -e "\033[36m→  $*\033[0m"; }
ok()   { echo -e "\033[32m✅ $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m"; }
err()  { echo -e "\033[31m【错误】$*\033[0m" >&2; }

# ---- 容器存活检查 ----
container_ok() {
    sudo docker inspect "${CONTAINER}" >/dev/null 2>&1 || { err "容器 ${CONTAINER} 不存在或未运行(部署容器名可用 SYNC_CONTAINER 覆盖)"; return 1; }
    sudo docker exec "${CONTAINER}" true >/dev/null 2>&1 || { err "容器 ${CONTAINER} 不可执行(检查 sudo docker 权限)"; return 1; }
}

# ---- 同步一个路径(src 为仓库相对路径) ----
sync_one() {
    local rel="$1" src="${REPO_ROOT}/${rel}" dst="${REMOTE_BASE}/${rel}"
    [ -e "${src}" ] || { warn "  跳过(不存在): ${rel}"; return 0; }
    if [ -d "${src}" ]; then
        # 目录: 复制内容到远端对应目录(尾部斜杠防嵌套)
        sudo docker exec "${CONTAINER}" mkdir -p "$(dirname "${dst}")" 2>/dev/null || true
        sudo docker cp "${src}/." "${CONTAINER}:${dst}/"
    else
        sudo docker cp "${src}" "${CONTAINER}:${dst}"
    fi
    ok "  已同步: ${rel}"
}

# ---- 同步后校验: 容器内 bash -n + check-modules ----
verify_container() {
    say "容器内静态校验(bash -n + check-modules)..."
    if sudo docker exec "${CONTAINER}" bash -lc \
        "cd ${REMOTE_BASE} && for f in deployments/scripts/lib-common.sh deployments/scripts/lib-module.sh deployments/scripts/deploy-cluster.sh; do bash -n \$f || exit 1; done && bash deployments/scripts/tools/check-modules.sh" \
        >/dev/null 2>&1; then
        ok "容器内校验通过"
    else
        warn "容器内校验未通过(请检查: sudo docker exec ${CONTAINER} bash deployments/scripts/tools/check-modules.sh)"
    fi
}

# ---------------- main ----------------
CHECK=0
PATHS=()
for a in "$@"; do
    case "${a}" in
        --check|-c) CHECK=1 ;;
        *) PATHS+=("${a}") ;;
    esac
done
[ "${#PATHS[@]}" -gt 0 ] || PATHS=("${DEFAULT_PATHS[@]}")

container_ok || exit 1

if [ "${CHECK}" = "1" ]; then
    say "将同步以下路径到 ${CONTAINER}:${REMOTE_BASE}(--check 不实际同步):"
    for rel in "${PATHS[@]}"; do
        [ -e "${REPO_ROOT}/${rel}" ] && echo "  · ${rel}"
    done
    exit 0
fi

say "同步 dev 仓库 → ${CONTAINER}:${REMOTE_BASE} ..."
for rel in "${PATHS[@]}"; do
    sync_one "${rel}"
done
verify_container
ok "同步完成"
