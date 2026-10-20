#!/bin/bash
# ============================================================
# fetch-offline-files.sh — [兼容薄壳] 转发到 fetch-offline-from-minio.sh
# ------------------------------------------------------------
# 2026-10-16 收敛: 本脚本旧实现(落盘扁平化 + 旧桶默认 cubestack-offline)已并入功能更全的
# fetch-offline-from-minio.sh(独立 minio.conf/MINIO_* 配置、嵌套 --sub、--dest、--list 下钻、
# --auto 大磁盘、磁盘空间预检、容器/宿主机双模式)。本文件仅作**兼容转发**, 不再含独立逻辑
# —— 避免两份实现行为漂移(曾出现"改了这份、那份没改")。
#
# 用法(与旧版兼容):
#   ./fetch-offline-files.sh kubespray                    ≡ 新脚本 --sub kubespray
#   ./fetch-offline-files.sh cubestack-operator/portal    ≡ 新脚本 --sub cubestack-operator/portal
#   ./fetch-offline-files.sh --dest /data/offline-files   # 选项原样透传(含取值)
#   ./fetch-offline-files.sh --list --sub cubestack-operator
# 建议直接使用新脚本: tools/offline/fetch-offline-from-minio.sh --help(会打印全部可用子目录)
# ============================================================
set -euo pipefail
_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dest|--sub|--kubespray-version|--min-free) args+=("$1" "$2"); shift 2 ;;
        -y|--yes|--all|--list|--auto|--force|-h|--help) args+=("$1"); shift ;;
        --*) args+=("$1"); shift ;;          # 未知选项透传, 由新脚本统一报错
        *)   args+=(--sub "$1"); shift ;;    # 旧用法的裸位置参数 = 桶内子目录
    esac
done
echo "[兼容壳] fetch-offline-files.sh → fetch-offline-from-minio.sh ${args[*]:-}(建议直接用新脚本; --help 看全部子目录)" >&2
exec bash "${_self}/fetch-offline-from-minio.sh" ${args[@]+"${args[@]}"}
