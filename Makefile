SHELL := /bin/bash

# TODO(layout): move installer-cli and netshoot-rdma Dockerfiles under images/
# in a follow-up repository-layout PR.

.PHONY: help dev installer ui build package image image-stop docker docker-stop test stop clean netshoot-rdma

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

IMAGE := harbor.isuanova.com/suanova/cubestack-installer:latest

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

# ---------------------------------------------------------------------------
# netshoot-rdma: RDMA diagnostic image. Build and optionally push it.
#
#   make netshoot-rdma NETSHOOT_RDMA_TAG=26.04.17
#   make netshoot-rdma NETSHOOT_RDMA_TAG=26.04.17 NETSHOOT_RDMA_PUSH=1
#
# TODO(layout): move the Dockerfile to images/netshoot-rdma/Dockerfile in a
# follow-up repository-layout PR.
# ---------------------------------------------------------------------------
NETSHOOT_RDMA_IMAGE ?= harbor.isuanova.com/suanova/netshoot-rdma
NETSHOOT_RDMA_DOCKERFILE ?= deployments/scripts/tools/images/netshoot-rdma.Dockerfile
NETSHOOT_RDMA_BASE_IMAGE ?= nicolaka/netshoot:latest
NETSHOOT_RDMA_TAG ?=
NETSHOOT_RDMA_PERFTEST_VERSION ?=
NETSHOOT_RDMA_APK_MIRROR ?=
NETSHOOT_RDMA_PUSH ?= 0

netshoot-rdma: ## 构建 RDMA 诊断镜像（可选 push）
	@set -euo pipefail; \
	tag="$(NETSHOOT_RDMA_TAG)"; \
	case "$$tag" in \
		''|*[!0-9A-Za-z._-]*|latest) echo "error: NETSHOOT_RDMA_TAG is required and must not be latest: '$$tag'" >&2; exit 1 ;; \
	esac; \
	perftest="$(NETSHOOT_RDMA_PERFTEST_VERSION)"; \
	[ -n "$$perftest" ] || perftest="$${tag%-r*}"; \
	image="$(NETSHOOT_RDMA_IMAGE)"; \
	ref="$${image}:$$tag"; \
	dockerfile="$(NETSHOOT_RDMA_DOCKERFILE)"; \
	base_image="$(NETSHOOT_RDMA_BASE_IMAGE)"; \
	apk_mirror="$(NETSHOOT_RDMA_APK_MIRROR)"; \
	push="$(NETSHOOT_RDMA_PUSH)"; \
	case "$$push" in true|1|yes|on) push=1 ;; *) push=0 ;; esac; \
	[ -f "$$dockerfile" ] || { echo "error: Dockerfile not found: $$dockerfile" >&2; exit 1; }; \
	for c in docker curl gzip; do command -v "$$c" >/dev/null 2>&1 || { echo "error: $$c is required" >&2; exit 1; }; done; \
	ctx="$$(mktemp -d)"; trap 'rm -rf "$$ctx"' EXIT; \
	src="$$ctx/perftest-src.tar.gz"; \
	url="https://github.com/linux-rdma/perftest/archive/refs/tags/$${perftest}.tar.gz"; \
	echo "==> downloading $$url"; \
	ok=0; \
	for i in 1 2 3; do \
		if curl -fsSL -o "$$src" "$$url"; then ok=1; break; fi; \
		[ "$$i" -lt 3 ] && { echo "    retry $$i/3 in 3s" >&2; sleep 3; }; \
	done; \
	[ "$$ok" = "1" ] || { echo "error: failed to download perftest source" >&2; exit 1; }; \
	gzip -t "$$src" || { echo "error: downloaded perftest source is not gzip" >&2; exit 1; }; \
	cp "$$dockerfile" "$$ctx/Dockerfile"; \
	echo "==> docker build $$ref (base=$$base_image, perftest=$$perftest)"; \
	docker build -f "$$ctx/Dockerfile" \
		--build-arg "BASE_IMAGE=$$base_image" \
		--build-arg "PERFTEST_VERSION=$$perftest" \
		--build-arg "APK_MIRROR=$$apk_mirror" \
		-t "$$ref" "$$ctx"; \
	echo "==> container self-check"; \
	docker run --rm "$$ref" sh -c 'set -e; missing=""; for b in ibv_devices ibv_devinfo ib_write_bw ib_write_lat ib_read_bw tcpdump ip ss ethtool mtr ping nslookup; do command -v "$$b" >/dev/null 2>&1 || missing="$$missing $$b"; done; [ -z "$$missing" ] || { echo "MISSING:$$missing"; exit 1; }'; \
	if [ "$$push" = "1" ]; then \
		if docker manifest inspect "$$ref" >/dev/null 2>&1; then \
			echo "error: tag already exists, refusing to overwrite: $$ref" >&2; exit 1; \
		fi; \
		echo "==> docker push $$ref"; \
		docker push "$$ref"; \
		digest="$$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$$ref" | awk -F@ -v r="$$ref" '$$1==r {print $$2; exit}')"; \
		[ -n "$$digest" ] && echo "pushed: $$ref@$$digest" || echo "pushed: $$ref"; \
	fi; \
	echo "done: $$ref"