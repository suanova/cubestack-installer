#!/bin/bash
# ============================================================
# MODULE: lws
# DESC: 单独更新平台组件 lws(只推该组件镜像 + CR values/version + 组件滚动; **不重跑 cubestack_operator**)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# 说明:
#   · 默认全量部署仍由 cubestack_operator 负责全部组件; 本模块只在 --steps lws 时单独更新该组件。
#   · **不声明 REQUIRES: cubestack_operator** —— 否则 --steps lws 会把整个 operator 重跑一遍
#     (REPEAT:1 不会被断点状态跳过)。运行时由工具校验 CubeStackCluster CR 已存在。
#   · 更新逻辑: tools/k8s/cubestack-component-update.sh(只推该组件 tar + patch CR + 滚动该组件 Deployment)。
#   · 可选环境变量: CUBESTACK_COMPONENT_VERSION / CUBESTACK_COMPONENT_VALUES_FILE /
#     CUBESTACK_COMPONENT_VALUES_KEY /
#     CUBESTACK_COMPONENT_PULL_POLICY / CUBESTACK_COMPONENT_RESTART(见工具头注释)。
# 数据源: cluster.conf (CUBESTACK_OPERATOR_* / REGISTRY_* / NODES / SSH_KEY_NAME)
# 用法:   sudo ./deploy-cluster.sh --steps lws
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# 默认 LWS values: master placement + CPU request 200m / memory 200Mi(不设 limits)。
# 统一使用 CR 形态的 lws-cr-values.yaml(全量部署与单组件更新同源, 不再维护扁平副本)。
# 可用 CUBESTACK_COMPONENT_VALUES_FILE 覆盖(覆盖后默认不按 KEY 提取, 除非同时显式设置 KEY)。
if [ -z "${CUBESTACK_COMPONENT_VALUES_FILE:-}" ]; then
    CUBESTACK_COMPONENT_VALUES_FILE="${REPO_ROOT}/deployments/cubestack-addon/cubestack-operator/lws-cr-values.yaml"
    : "${CUBESTACK_COMPONENT_VALUES_KEY:=clusterCR.spec.components.lws.values}"
fi
export CUBESTACK_COMPONENT_VALUES_FILE
if [ -n "${CUBESTACK_COMPONENT_VALUES_KEY:-}" ]; then
    export CUBESTACK_COMPONENT_VALUES_KEY
fi

bash "${SCRIPT_DIR}/tools/k8s/cubestack-component-update.sh" "lws"
