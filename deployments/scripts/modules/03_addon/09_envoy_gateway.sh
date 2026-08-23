#!/bin/bash
# ============================================================
# MODULE: envoy_gateway
# DESC: Envoy AI 网关(集群统一流量入口, P1 刚需)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: ENVOY_GATEWAY_ENABLED
# 说明:
#   【P1-9 规划模块·伪代码占位】Envoy AI Gateway:
#   · 搭建集群统一流量入口, 路由配置与转发测试
#   · 保障外部业务 URL 可正常稳定访问(后续 P2 Keycloak 对接统一认证)
#   · 接入方法: 将下方 STEPS 伪代码替换为真实命令, 或 ADDON_STUB_EXEC=1 试执行
# 数据源: cluster.conf (ENVOY_GATEWAY_ENABLED / NODES)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if [ "${ENVOY_GATEWAY_ENABLED:-false}" != "true" ]; then
    say "跳过 Envoy AI 网关(配置 ENVOY_GATEWAY_ENABLED=true 可启用)"
    exit 0
fi

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH="ssh -i ${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${FIRST_MASTER}"
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

# ── 伪代码步骤(占位): 替换为真实实现 ──
ENVOY_GATEWAY_STEPS=(
  "创建 envoy-gateway 命名空间|${SSH} \"${K} create ns envoy-gateway 2>/dev/null || true\""
  "部署 Envoy AI Gateway(离线 helm/manifest)|${SSH} \"${K} apply -f /opt/cubestack/addons/envoy-ai-gateway.yaml 2>/dev/null || true\""
  "等待 GatewayClass/网关控制器就绪|${SSH} \"${K} rollout status deploy/envoy-ai-gateway-controller -n envoy-gateway --timeout=3m 2>/dev/null || true\""
  "创建 Gateway 资源(绑定 MetalLB 入口)|${SSH} \"${K} apply -f /opt/cubestack/addons/envoy-gateway.yaml 2>/dev/null || true\""
  "配置 HTTPRoute 路由规则(业务 URL 转发)|${SSH} \"${K} apply -f /opt/cubestack/addons/envoy-httproute.yaml 2>/dev/null || true\""
  "验证外部业务 URL 转发可达|${SSH} \"curl -s -o /dev/null -w '%{http_code}' http://<gateway-ip>/<path> 2>/dev/null || true\""
)
addon_stub "envoy_gateway" ENVOY_GATEWAY_STEPS
