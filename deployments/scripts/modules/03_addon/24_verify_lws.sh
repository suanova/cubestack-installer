#!/bin/bash
# ============================================================
# MODULE: verify_lws
# DESC: 端到端验证 LeaderWorkerSet(LWS) 真正工作(复用 tools/k8s/verify-lws.sh):
#       ① controller pod Ready → ② CRD 注册 → ③ 创建测试 LeaderWorkerSet
#       → ④ 等待 leader+worker pod 全部 Ready → ⑤ 校验控制器管理(worker-index=0 为 leader)
#       → ⑥ DisaggregatedSet CR 可创建 → ⑦ 清理测试资源(trap 兜底)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# REQUIRES: gpu_lws
# 说明:
#   · 验证模块不设 TOGGLE(避免被安装流程自动启用); DEFAULT:0, 由 --steps verify_lws 执行。
#   · **门禁看实际部署, 不看配置开关**: 只要 LWS controller 实际在跑(无论 LWS_ENABLED 是 true 还是 false,
#     例如 --steps gpu_lws 单独部署过、未写 cluster.conf)就执行验证; 仅当"controller 未运行 且 LWS_ENABLED≠true"才跳过。
#   · 复用 tools/k8s/verify-lws.sh(与 verify_metax_gpu 复用 verify-metax-gpu.sh 同一模式)。
# 数据源: cluster.conf (LWS_NAMESPACE / NODES / SSH_KEY_NAME)
# 用法:   sudo ./deploy-cluster.sh --steps verify_lws   或  sudo ./tools/k8s/verify-lws.sh
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

init_remote_kubectl || exit 1

LWS_NAMESPACE="${LWS_NAMESPACE:-lws-system}"

# 门禁: 以实际部署为准(controller 是否在跑), 而非 LWS_ENABLED 配置开关。
#   · controller 在跑 → 验证(即使用 --steps gpu_lws 部署、cluster.conf 里 LWS_ENABLED 仍为 false);
#   · controller 不在 且 未启用 → 跳过(避免 --steps verify 全量验证时对未装组件报错);
#   · controller 不在 但 已启用 → 继续验证, 由 verify-lws.sh 给出"controller 未 Running, 先部署"的可执行报错。
DEPLOYED="$( (SSH "${K} -n ${LWS_NAMESPACE} get pods --no-headers 2>/dev/null" || true) \
    | grep -cE 'controller-manager.*1/1.*Running' || true)"
if [ "${DEPLOYED:-0}" -eq 0 ] && [ "${LWS_ENABLED:-false}" != "true" ]; then
    say "LWS 未部署(controller 未运行且 LWS_ENABLED≠true), 跳过验证(先 --steps gpu_lws 部署)"
    exit 0
fi

# 实际验证逻辑在独立脚本(与 verify_metax_gpu 同模式), 失败退出码向上传递
bash "${SCRIPT_DIR}/tools/k8s/verify-lws.sh"
