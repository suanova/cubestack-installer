# =====================================================================
# CubeStackInstaller 单镜像(前端产物 + 后端全部依赖)
# 构建:  docker build -t cubestack-installer .
# 启动:  docker run -d -p 8000:8000 -v csi-data:/app cubestack-installer
# 访问:  http://localhost:8000 (页面 + /api 接口,单端口)
# =====================================================================

# ---------- Stage 1:构建前端 UI ----------
FROM node:20-alpine AS ui-build
WORKDIR /build
COPY ui/package.json ui/package-lock.json ./
RUN npm ci --no-fund --no-audit || npm install --no-fund --no-audit
COPY ui/ .
RUN npm run build

# ---------- Stage 2:后端运行时(uv 安装全部依赖) ----------
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim AS runtime

WORKDIR /app

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DATABASE_URL=sqlite:////app/data/userhub.db

# 后端依赖清单(pyproject + uv.lock)
COPY installer/pyproject.toml installer/uv.lock ./

# 后端源码(包含 app 包)
COPY installer/app ./app

# 安装全部运行依赖 + 项目(生成 console script: cubestack-installer-installer)
RUN uv sync --frozen --no-dev

# 前端构建产物 -> 后端静态目录(FastAPI 直接托管,单端口)
COPY --from=ui-build /build/dist ./app/static

# 健康检查
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/health')" || exit 1

EXPOSE 8000

# 一键启动:一个命令起前后端(FastAPI 托管 UI + API)
ENTRYPOINT ["uv", "run", "--no-sync", "cubestack-installer-installer"]
