#!/bin/bash
# ============================================================
# MODULE: keycloak
# DESC: Keycloak 统一认证(身份认证/权限管控, P2 能力增强)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: KEYCLOAK_ENABLED
# 说明:
#   【P2-1 规划模块·伪代码占位】Keycloak:
#   · 部署 Keycloak, 实现集群统一身份认证、用户权限管控
#   · 对接 Envoy 网关统一登录鉴权; 兼容 P1 兜底认证方案平滑过渡
#   · 接入方法: 将下方 STEPS 伪代码替换为真实命令, 或 ADDON_STUB_EXEC=1 试执行
# 数据源: cluster.conf (KEYCLOAK_ENABLED / NODES)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if [ "${KEYCLOAK_ENABLED:-false}" != "true" ]; then
    say "跳过 Keycloak(配置 KEYCLOAK_ENABLED=true 可启用)"
    exit 0
fi

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH="ssh -i ${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${FIRST_MASTER}"
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

# ── 伪代码步骤(占位): 替换为真实实现 ──
KEYCLOAK_STEPS=(
  "创建 keycloak 命名空间|${SSH} \"${K} create ns keycloak 2>/dev/null || true\""
  "部署 Keycloak(离线 helm, 指定存储类/密码)|${SSH} \"helm install keycloak /opt/cubestack/addons/keycloak -n keycloak --set auth.adminPassword=<ADMIN_PW> --set postgresql.persistence.storageClass=${LOCAL_PATH_ENABLED:+local-path} 2>/dev/null || true\""
  "等待 Keycloak 就绪|${SSH} \"${K} -n keycloak rollout status deploy/keycloak --timeout=5m 2>/dev/null || true\""
  "创建 Realm 与 Client(统一认证域)|${SSH} \"${K} -n keycloak exec deploy/keycloak -- kcadm.sh create realms -s realm=cubestack 2>/dev/null || true\""
  "对接 Envoy 网关 ext_authz(统一登录鉴权)|${SSH} \"${K} apply -f /opt/cubestack/addons/envoy-extauthz-keycloak.yaml 2>/dev/null || true\""
  "验证统一登录与鉴权流程|${SSH} \"curl -s -o /dev/null -w '%{http_code}' https://<gateway>/auth 2>/dev/null || true\""
)
addon_stub "keycloak" KEYCLOAK_STEPS
