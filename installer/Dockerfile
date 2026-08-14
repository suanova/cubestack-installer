# uv 官方运行镜像(python 3.12)
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

WORKDIR /app

ENV UV_COMPILE_BYTECODE=1     UV_LINK_MODE=copy     UV_PROJECT_ENVIRONMENT=/app/.venv

# 先装依赖(利用构建缓存)
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

# 再拷贝代码
COPY app ./app

EXPOSE 8000

CMD ["uv", "run", "cubestack-installer-installer"]
