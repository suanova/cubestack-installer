.PHONY: help dev installer ui build package image image-stop docker docker-stop test stop clean

help: ## 显示帮助
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

dev: ## 一键启动前后端开发环境
	bash scripts/dev.sh

installer: ## 启动后端安装器(FastAPI :8000,uv 管理)
	cd installer && uv sync && uv run cubestack-installer-installer

ui: ## 启动前端(Vite :5173)
	cd ui && npm run dev

build: ## 构建前端生产包 + 后端发行包
	cd ui && npm run build
	cd installer && uv build

package: ## 构建 UI 并打包进后端(单端口部署)
	cd ui && npm run build
	rm -rf installer/app/static
	cp -r ui/dist installer/app/static
	cd installer && uv build

test: ## 运行后端测试(uv)
	cd installer && uv run pytest -q

stop: ## 停止所有服务
	-pkill -f 'uvicorn app.main:app'
	-pkill -f vite

IMAGE := harbor.isuanova.com/cubestack/cubestack-installer:latest

image: ## 构建并运行单镜像(podman,含全部依赖)
	podman build --format docker -t $(IMAGE) .
	podman rm -f cubestack-installer 2>/dev/null; podman run -d --replace -p 8008:8000 -v csi-data:/app/data --name cubestack-installer $(IMAGE)
	@echo "访问 http://localhost:8008"

image-push: ## 推送到 Harbor 私有仓库
	podman push $(IMAGE)

image-stop: ## 停止并删除容器
	-podman stop cubestack-installer
	-podman rm cubestack-installer

# docker 别名(兼容 docker CLI)
docker: image
docker-stop: image-stop

clean: ## 清理数据库与构建产物
	rm -f installer/userhub.db
	rm -rf installer/dist installer/*.egg-info