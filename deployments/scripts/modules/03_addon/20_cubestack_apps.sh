#!/bin/bash
# ============================================================
# MODULE: cubestack_apps
# DESC: CubeStack 自研模块部署占位符(自研应用/平台组件)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: CUBESTACK_APPS_ENABLED
# REQUIRES: k8s_deploy k8s_registry
# 说明:
#   【自研模块占位符】CubeStack 平台自研组件统一在此部署。
#   序号约定: 03_addon/ 下 01~19 为第三方中间件预留;
#             20 起为 CubeStack 自研模块(cubestack_apps 起始)。
#   · 后续新增自研组件: 在 20_ 之后追加序号(20_cubestack_xxx.sh), 互不影响
#   · 接入方法: 将下方 STEPS 伪代码替换为真实部署命令(helm/kubectl/manifest),
#     或 ADDON_STUB_EXEC=1 试执行
# 数据源: cluster.conf (CUBESTACK_APPS_ENABLED / NODES)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if [ "${CUBESTACK_APPS_ENABLED:-false}" != "true" ]; then
    say "跳过 CubeStack 自研模块(配置 CUBESTACK_APPS_ENABLED=true 可启用)"
    exit 0
fi

init_remote_kubectl || exit 1

# ── 伪代码步骤(占位): 替换为真实的自研组件部署 ──
CUBESTACK_APPS_STEPS=(
  "创建 cubestack 命名空间|${SSH_CMD} \"${K} create ns cubestack 2>/dev/null || true\""
  "部署自研组件 A(示例: 平台后端)|${SSH_CMD} \"${K} apply -f /opt/cubestack/addons/cubestack-backend.yaml 2>/dev/null || true\""
  "部署自研组件 B(示例: 平台前端/网关)|${SSH_CMD} \"${K} apply -f /opt/cubestack/addons/cubestack-frontend.yaml 2>/dev/null || true\""
  "等待自研组件就绪|${SSH_CMD} \"${K} -n cubestack rollout status deploy --timeout=5m 2>/dev/null || true\""
  "验证自研服务访问|${SSH_CMD} \"${K} -n cubestack get svc,pods -o wide 2>/dev/null || true\""
)
addon_stub "cubestack_apps" CUBESTACK_APPS_STEPS
