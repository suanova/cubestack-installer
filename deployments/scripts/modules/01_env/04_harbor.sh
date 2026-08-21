#!/bin/bash
# ============================================================
# MODULE: harbor
# DESC: Harbor 镜像仓库 — 集群外私有仓库(部署前在宿主机就绪, P1 刚需)
# PHASE: env
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: HARBOR_ENABLED
# 说明:
#   【P1-4 规划模块·伪代码占位】Harbor 企业级镜像仓库:
#   · 定位: 集群外容器镜像仓库的唯一方案(外部开发机/CI push, 集群节点 pull)
#   · 属于环境准备阶段: 在部署 kubespray 之前于宿主机(或独立仓库机)就绪,
#     为后续集群部署提供镜像源(替代原本地 docker registry)
#   · 支持镜像推送、拉取、目录同步(GC/复制); 集群内 registry 为 kubespray
#     addon(modules/03_addon/03_k8s_registry.sh), 默认不部署
#   · 接入方法: 将下方 STEPS 伪代码替换为真实命令, 或 ADDON_STUB_EXEC=1 试执行
# 数据源: cluster.conf (HARBOR_ENABLED / HARBOR_DOMAIN / HARBOR_IP / HARBOR_STORAGE_CLASS)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if [ "${HARBOR_ENABLED:-false}" != "true" ]; then
    say "跳过 Harbor(配置 HARBOR_ENABLED=true 可启用)"
    exit 0
fi

# 环境准备阶段: 在宿主机(部署机)以容器方式运行 Harbor, 不依赖 K8s 集群
# ── 伪代码步骤(占位): 替换为真实实现 ──
HARBOR_STEPS=(
  "检查宿主机容器运行时(docker/nerdctl/podman)|docker version >/dev/null 2>&1 && echo OK || nerdctl version >/dev/null 2>&1 && echo OK || podman version >/dev/null 2>&1 && echo OK || echo '缺少容器运行时'"
  "准备 Harbor 数据目录(/opt/harbor)|mkdir -p /opt/harbor/data /opt/harbor/cert 2>/dev/null || true"
  "生成 Harbor HTTPS 证书(自签, 域名 ${HARBOR_DOMAIN:-harbor.local})|openssl req -x509 -newkey rsa:4096 -nodes -days 3650 -keyout /opt/harbor/cert/tls.key -out /opt/harbor/cert/tls.crt -subj '/CN=${HARBOR_DOMAIN:-harbor.local}' 2>/dev/null || true"
  "启动 Harbor 容器(离线镜像 harbor/installer 或 docker compose)|docker run -d --name harbor --restart=unless-stopped -p 80:80 -p 443:443 -v /opt/harbor:/data goharbor/harbor-offline-installer 2>/dev/null || docker compose -f /opt/harbor/docker-compose.yml up -d 2>/dev/null || true"
  "验证 Harbor 健康接口可达|curl -sk https://127.0.0.1/api/v2.0/health 2>/dev/null || curl -s http://127.0.0.1/api/v2.0/health 2>/dev/null || true"
  "导入离线镜像到 Harbor(替代原 env_registry)|docker load -i ${LOCAL_REPO_DIR}/images/xxx.tar && docker tag xxx ${HARBOR_DOMAIN:-harbor.local}/library/xxx:tag && docker push ${HARBOR_DOMAIN:-harbor.local}/library/xxx:tag 2>/dev/null || true"
)
addon_stub "harbor" HARBOR_STEPS
