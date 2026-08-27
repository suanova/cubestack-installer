#!/bin/bash
# ============================================================
# MODULE: vm_create
# DESC: 创建/启动虚拟机(默认关 — 虚拟机创建由 tools/vm/create-vms.sh 独立执行)
# PHASE: env
# DEFAULT: 0
# REPEAT: 1
# 说明:
#   · **主程序不创建虚拟机、不判断虚拟机/裸金属**: cluster.conf 的 NODES(5字段)对节点一视同仁;
#     需要创建虚拟机的节点在 tools/vm/vm-nodes.conf(10字段)定义, 由
#     `sudo ./deployments/scripts/tools/vm/create-vms.sh` 独立执行(创建/启动 + 自动注入 NODES)。
#   · 本模块保留为手动入口: `--steps vm_create` 等价于直接执行 create-vms.sh(幂等)。
#   · vm-nodes.conf 缺失/为空 → 幂等跳过(纯裸金属集群)。
# 数据源: tools/vm/vm-nodes.conf + cluster.conf(网络/镜像/默认密码)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

say "vm_create: 调用 tools/vm/create-vms.sh(虚拟机创建独立执行, 默认不由主程序调度) ..."
bash "${SCRIPT_DIR}/tools/vm/create-vms.sh"
ok "虚拟机模块完成"
