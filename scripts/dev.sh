#!/usr/bin/env bash
# 一键启动前后端开发环境(uv 管理后端)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

command -v uv >/dev/null 2>&1 || { echo "未检测到 uv,请先安装: pip install --user uv 或 https://astral.sh/uv"; exit 1; }

cd "$ROOT/installer"
uv sync
uv run cubestack-installer-installer &
BACKEND_PID=$!

cd "$ROOT/ui"
npm install --silent
npm run dev &
FRONTEND_PID=$!

trap 'kill $BACKEND_PID $FRONTEND_PID 2>/dev/null' EXIT
echo ""
echo "  installer -> http://localhost:8000/docs"
echo "  ui        -> http://localhost:5173"
echo "  Ctrl+C 停止"
wait
