#!/bin/bash
# ============================================================
# MODULE: metallb
# DESC: 确保 MetalLB 就绪(controller/speaker Running + IPAddressPool/L2Advertisement 存在)
#       作为 registry 等依赖 MetalLB 组件的**前置检查**, 排在 addon 阶段第一位。
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: METALLB_ENABLED
# 说明:
#   · MetalLB 由 kubespray addon 安装; 本模块仅做**就绪校验**(幂等), 不重复安装。
#   · 依赖顺序: metallb(本模块)→ local-path → registry —— registry 的 LoadBalancer VIP
#     依赖 metallb,故 registry 前先确认 metallb 就绪。
#   · ⚠ SERVICE_EXPOSE_MODE 二选一: nodeport 模式自动关闭 MetalLB(sync-addons-config
#     metallb_enabled=false), 此时本校验须跳过(集群本就不部署 MetalLB), 否则假阳性失败。
#   · 校验: ① metallb-system 命名空间 ② controller/speaker 全部 Running
#     ③ IPAddressPool / L2Advertisement 存在。
# 用法:   sudo ./deploy-cluster.sh --with-k8s(TOGGLE 自动启用) 或 --enable metallb
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

[ "${METALLB_ENABLED:-true}" = "true" ] || { say "METALLB_ENABLED=false, 跳过 metallb 就绪检查"; exit 0; }
[ "${SERVICE_EXPOSE_MODE:-nodeport}" = "nodeport" ] \
    && { say "SERVICE_EXPOSE_MODE=nodeport(自动关闭 MetalLB), 跳过 metallb 就绪检查"; exit 0; }

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
           "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "$@"; }
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

say "检查 MetalLB 就绪(registry 等 LoadBalancer 组件的前置依赖)..."
say "  ① metallb-system 命名空间..."
if ! SSH "${K} get ns metallb-system >/dev/null 2>&1"; then
    err "未找到 metallb-system 命名空间, 检查 addons.yml metallb_enabled 且 kubespray 已部署 metallb"
    exit 1
fi
say "  ② 等待 controller/speaker pod 全部 Running(最长 90s)..."
PODS_OK=0
for i in $(seq 1 18); do
    PODS="$(SSH "${K} -n metallb-system get pods 2>/dev/null" || true)"
    if [ -n "${PODS}" ]; then
        # 要求: 至少 1 个 controller + 1 个 speaker, 且所有 controller/speaker 行都是 1/1 Running
        NONREADY="$(echo "${PODS}" | grep -E 'controller|speaker' | grep -vE '1/1 +Running' || true)"
        HAS_CTL="$(echo "${PODS}" | grep -c controller || true)"
        HAS_SPK="$(echo "${PODS}" | grep -c speaker || true)"
        if [ -z "${NONREADY}" ] && [ "${HAS_CTL:-0}" -ge 1 ] && [ "${HAS_SPK:-0}" -ge 1 ]; then
            PODS_OK=1
            break
        fi
    fi
    sleep 5
done
if [ "${PODS_OK}" != "1" ]; then
    err "metallb controller/speaker 未全部 Running(90s 超时), 执行: kubectl -n metallb-system get pods"
    exit 1
fi
say "  ③ IPAddressPool / L2Advertisement 存在..."
if ! SSH "${K} -n metallb-system get ipaddresspools -o name 2>/dev/null | grep -q ipaddresspool"; then
    err "metallb 地址池未配置, 检查 addons.yml metallb_config.address_pools"
    exit 1
fi
if ! SSH "${K} -n metallb-system get l2advertisements -o name 2>/dev/null | grep -q l2advertisement"; then
    err "metallb L2 通告未配置, 检查 addons.yml metallb_config.layer2"
    exit 1
fi
ok "MetalLB 就绪: controller/speaker Running, IPAddressPool/L2Advertisement 存在"