#!/bin/bash
# ============================================================
# MODULE: k8s_ntp
# DESC: 集群节点时间同步(NTP/chrony) + 时钟偏差校验
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# 说明: 在 k8s_deploy 之前执行, 防止 etcd/kubeadm 时间敏感故障; 调用 setup-ntp.sh
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

say "集群节点 NTP 时间同步(指向权威时间源) + 偏差校验(≤${NTP_MAX_OFFSET_MS:-2000}ms) ..."
bash "${SCRIPT_DIR}/tools/node/setup-ntp.sh"
ok "节点时间同步完成, 全节点与权威时钟偏差已 ≤ ${NTP_MAX_OFFSET_MS:-2000}ms"