#!/bin/bash
# ============================================================
# MODULE: pre_install_check
# DESC: 安装前环境检查(master/worker: SSH/sudo/chronyd/资源容量; 关键项失败即中止)
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# REQUIRES: k8s_passwordless
# 说明:
#   · 只读检查, 不改动节点; 逻辑全在 tools/node/pre-install-check.sh(可单独跑:
#     `bash tools/node/pre-install-check.sh --check [--only <host>]`)。
#   · 检查项: SSH 免密/密码可达、sudo、chronyd 运行与偏差、CPU/内存//var/lib 空间。
#     关键项任一失败 → 非零退出, 部署在 kubespray 之前中止; 建议项只告警。
#   · 定序: k8s_deploy 的 REQUIRES 显式声明本模块, 保证在真正安装之前执行
#     (14 > 06, 与 node_pkgs 同一手法: 序号不足以定序, 补 REQUIRES)。
#   · 阈值: PRE_INSTALL_MIN_CPU / PRE_INSTALL_MIN_MEM_MB / PRE_INSTALL_MASTER_MIN_MEM_MB /
#     PRE_INSTALL_MIN_DISK_GB / PRE_INSTALL_RECOMMENDED_DISK_GB(见 cluster.defaults.conf §2.2b)。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

say "安装前环境检查(SSH/sudo/chronyd/资源容量; 关键项失败将中止部署) ..."
bash "${SCRIPT_DIR}/tools/node/pre-install-check.sh" --check
ok "安装前环境检查通过"
