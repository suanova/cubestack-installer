#!/usr/bin/env bash
# ============================================================
# verify-offline-files.sh — offline-files 完整性校验器入口
#
# 实现已模块化为 verifier/ 包; 运行形态:
#   · 有 verify-offline-files.pyz → 直接执行 zipapp(发布/在线安装);
#   · 无 pyz → PYTHONPATH 指向本目录, `python3 -m verifier`(源码开发).
# 用法/参数/退出码见:
#   ./verify-offline-files.sh --help
#   ./verify-offline-files.sh --version
# ============================================================
set -euo pipefail
if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ 需要 python3(>=3.8); 请安装 python3 后重试" >&2
    exit 2
fi
_SELF="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
    _SELF="$(readlink -f "${_SELF}" 2>/dev/null || printf '%s' "${_SELF}")"
fi
_TOOL_DIR="$(cd "$(dirname "${_SELF}")" && pwd)"
export CUBESTACK_VERIFY_TOOL_DIR="${_TOOL_DIR}"
export PYTHONIOENCODING=utf-8
if [ -f "${_TOOL_DIR}/verify-offline-files.pyz" ]; then
    exec python3 "${_TOOL_DIR}/verify-offline-files.pyz" "$@"
fi
export PYTHONPATH="${_TOOL_DIR}${PYTHONPATH:+:${PYTHONPATH}}"
exec python3 -m verifier "$@"
