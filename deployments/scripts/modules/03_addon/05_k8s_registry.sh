#!/bin/bash
# ============================================================
# MODULE: k8s_registry
# DESC: 配置集群内置 docker registry addon(节点 hosts + containerd certs.d; REGISTRY_EXPOSE_HOST=1 时可选宿主机对外 DNAT)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: REGISTRY_ENABLED
# 说明:
#   · 集群内 registry(kubespray addon), **默认部署**(REGISTRY_ENABLED 默认 1/true)
#   · 对**已部署**集群幂等配置内置 registry, 需集群就绪后显式执行
#   · 启用方式: deploy-cluster.sh --enable k8s_registry 或 REGISTRY_ENABLED=true
#   · 集群外镜像仓库 Harbor 为预留配置(modules/01_env/04_harbor.sh, 未来实现, 默认关闭)
#   · 复用 deploy-registry.sh: 各节点 /etc/hosts 解析 REGISTRY_DOMAIN → REGISTRY_IP(MetalLB VIP),
#     containerd certs.d 信任该 HTTP registry; REGISTRY_EXPOSE_HOST=1 时配宿主机 DNAT 对外 push 入口(默认 0 只用 VIP)
#   · REGISTRY_ENABLED 控制 addons.yml 中 registry addon 是否安装(见 sync-addons-config.sh)
# 数据源: cluster.conf (REGISTRY_DOMAIN / REGISTRY_IP / REGISTRY_PORT / NODES)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# 开关: 默认不部署, REGISTRY_ENABLED=1/true 或 --steps/--enable 显式启用
if [ "${REGISTRY_ENABLED:-0}" != "1" ] && [ "${REGISTRY_ENABLED:-false}" != "true" ]; then
    say "跳过内置 registry(集群内 registry 默认不部署, 配置 REGISTRY_ENABLED=true 可启用)"
    exit 0
fi

say "配置集群内置 docker registry(域名=${REGISTRY_DOMAIN:-registry.cubestack.io})..."
bash "${SCRIPT_DIR}/tools/lb/deploy-registry.sh"
ok "内置 registry 配置完成"
