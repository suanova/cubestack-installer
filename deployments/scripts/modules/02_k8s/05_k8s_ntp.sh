#!/bin/bash
# ============================================================
# MODULE: k8s_ntp
# DESC: 集群节点时间同步(NTP/chrony) + 时钟偏差校验(必需步骤; 只同步不装包)
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# REQUIRES: k8s_passwordless
# 说明:
#   · NTP 同步是**必需步骤**, 在 k8s_deploy 之前执行, 防止 etcd/kubeadm 时间敏感故障。
#   · 本模块只做同步(调用 setup-ntp.sh apply): installer **默认不安装 OS 包** —— chrony 由节点
#     黄金镜像/运维预装(2.1 口径)。
#   · 权威缺 chrony, 或客户端既无 chrony 也无 systemd-timesyncd → 硬失败并给出安装指引
#     (不会静默跳过; 符合"NTP 同步必须"的约束)。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

say "集群节点 NTP 时间同步(指向权威时间源) + 偏差校验(≤${NTP_MAX_OFFSET_MS:-2000}ms) ..."
bash "${SCRIPT_DIR}/tools/node/setup-ntp.sh"
ok "节点时间同步完成, 全节点与权威时钟偏差已 ≤ ${NTP_MAX_OFFSET_MS:-2000}ms"