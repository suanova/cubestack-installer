#!/usr/bin/env bash
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/installer"
command -v uv >/dev/null 2>&1 || { echo "未检测到 uv,请先安装: pip install --user uv 或 https://astral.sh/uv"; exit 1; }
uv sync
exec uv run cubestack-installer-installer
