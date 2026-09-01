#!/bin/bash
# ============================================================
# MODULE: lb_haproxy
# DESC: HAProxy 服务器 HAProxy 配置 — K8s API 四层负载均衡(集群部署前准备)
# PHASE: env
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: HAPROXY_ENABLED
# 说明:
#   · 从 cluster.conf 生成 HAProxy 配置(API 入口 → 所有 master apiserver)
#   · 复用 sync-haproxy.sh(生成 /etc/haproxy/haproxy.cfg + 重启服务)
#   · ⚠ 执行位置: 必须在 **HAProxy 所在服务器**(持久化机器)上运行, 而非临时 installer
#     服务器 —— installer 部署完成会被删除, 在其上配置的 haproxy 无意义且容器内无 systemd。
#     在 haproxy 服务器放好仓库 + cluster.conf 后执行本模块(需 root + haproxy 已安装)。
#   · 属于环境准备阶段: 在部署 kubespray 之前把 API 负载均衡入口准备好
#   · 幂等: 每次执行重新收敛 master 列表; 需 root
# 数据源: cluster.conf (APISERVER_ADDRESS / NODES / HAPROXY_ENABLED)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# 开关: cluster.conf HAPROXY_ENABLED=true 或 --steps/--enable 显式启用
if [ "${HAPROXY_ENABLED:-false}" != "true" ]; then
    say "跳过 HAProxy 配置(配置 HAPROXY_ENABLED=true 可启用)"
    exit 0
fi
[ "$(id -u)" -eq 0 ] || { err "需要 root: sudo $0"; exit 1; }

say "同步 HAProxy 配置(K8s API 四层负载均衡)..."
bash "${SCRIPT_DIR}/tools/lb/sync-haproxy.sh"
ok "HAProxy 配置完成"
