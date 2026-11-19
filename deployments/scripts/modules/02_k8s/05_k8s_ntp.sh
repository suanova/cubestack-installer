#!/bin/bash
# ============================================================
# MODULE: k8s_ntp
# DESC: 集群节点时间同步(NTP/chrony) + 时钟偏差校验(必需步骤; 只同步不装包)
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# REQUIRES: k8s_passwordless chrony_pkgs
#   · chrony_pkgs 是**可选**装包步骤(默认关); 声明在此仅用于"两者都在计划里"时的
#     拓扑定序(先装包、后同步)。未启用时该依赖不在计划内, 拓扑排序按"已满足"处理,
#     不影响默认 NTP-only 流程。
# 说明:
#   · NTP 同步是**必需步骤**, 在 k8s_deploy 之前执行, 防止 etcd/kubeadm 时间敏感故障。
#   · 本模块只做同步(调用 setup-ntp.sh apply): installer **不安装 OS 包** —— chrony 由节点
#     黄金镜像/运维预装(2.1 口径)。
#   · **装包与同步解耦(2026-11-19)**: 需要 installer 离线安装 chrony 时, 启用独立可选模块
#     chrony_pkgs(CHRONY_PKGS_ENABLED=true / --steps chrony_pkgs); 本模块只假设 chrony 已存在。
#   · 权威(首 master)缺 chrony → 硬失败并提示启用 chrony_pkgs(不会静默跳过);
#     客户端缺 chrony 回退 systemd-timesyncd, 二者都无 → 硬失败。
#     (符合"NTP 同步必须"的约束。)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

say "集群节点 NTP 时间同步(指向权威时间源) + 偏差校验(≤${NTP_MAX_OFFSET_MS:-2000}ms) ..."
bash "${SCRIPT_DIR}/tools/node/setup-ntp.sh"
ok "节点时间同步完成, 全节点与权威时钟偏差已 ≤ ${NTP_MAX_OFFSET_MS:-2000}ms"