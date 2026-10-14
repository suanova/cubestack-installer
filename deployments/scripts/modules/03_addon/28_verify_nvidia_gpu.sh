#!/bin/bash
# ============================================================
# MODULE: verify_nvidia_gpu
# DESC: 端到端验证 NVIDIA GPU Operator: 组件就绪 + ClusterPolicy ready + GPU 资源可调度 +
#       真卡时跑 cuda-vectoradd(离线样例镜像)确认 GPU 真正可用; 无卡集群走组件级边界(如实标注)。
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# REQUIRES: nvidia_gpu_operator k8s_registry
# 说明:
#   · 有卡判据 = 节点 PCI vendor 0x10de(sysfs, 不依赖 nvidia-smi); 有卡但 allocatable 为空 ⇒ 硬失败;
#     无卡 ⇒ 组件级通过 + 醒目边界提示(exit 0), 不把"没验卡"伪装成"已验卡"。
#   · cuda-vectoradd 样例镜像由 nvidia_gpu_operator 模块一并推入集群 registry(离线可用);
#     未就绪时该步明确跳过(不误报)。
# 用法:   sudo ./deploy-cluster.sh --steps verify_nvidia_gpu
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

init_remote_kubectl || exit 1

NS="${NVIDIA_GPU_OPERATOR_NAMESPACE:-gpu-operator}"
REG_BASE="${REGISTRY_DOMAIN:-${REGISTRY_IP}}:${REGISTRY_PORT:-5000}"
SAMPLE_TAG="vectoradd-cuda12.5.0-ubuntu22.04"
# 样例镜像引用按部署模式拼(与 08 模块口径一致): 离线=集群 registry mirrors; 在线=Harbor 前缀或 nvcr.io
if [ "${ONLINE_DEPLOY_NVIDIA_GPU_OPERATOR:-false}" = "true" ]; then
    if [ -n "${NVIDIA_GPU_OPERATOR_ONLINE_IMAGE_BASE:-}" ]; then
        SAMPLE_REF="${NVIDIA_GPU_OPERATOR_ONLINE_IMAGE_BASE%/}/nvcr.io/nvidia/k8s/cuda-sample:${SAMPLE_TAG}"
    else
        SAMPLE_REF="nvcr.io/nvidia/k8s/cuda-sample:${SAMPLE_TAG}"
    fi
else
    SAMPLE_REF="${REG_BASE}/mirrors/nvcr.io/nvidia/k8s/cuda-sample:${SAMPLE_TAG}"
fi
POD="cuda-vectoradd-$$"

# 组件未装 → 跳过(verify 规范: 不满足前置即 exit 0)
if ! SSH "${K} get ns ${NS} >/dev/null 2>&1"; then
    say "未发现 ${NS} 命名空间(NVIDIA GPU Operator 未部署), 跳过"
    exit 0
fi

cleanup() { SSH "${K} -n default delete pod ${POD} --ignore-not-found --wait=false >/dev/null 2>&1" || true; }
trap cleanup EXIT

FAIL=0

# ① 全部 Pod Running/Completed
say "[1/4] 检查 ${NS} 全部 Pod 状态 ..."
_bad="$( (SSH "${K} -n ${NS} get pods --no-headers 2>/dev/null" || true) \
    | awk '$3!="Running" && $3!="Completed" {print "    " $1 " " $3}' )"
if [ -n "${_bad}" ]; then
    err "  存在非 Running/Completed 的 Pod:"; printf '%s\n' "${_bad}"
    FAIL=1
else
    _cnt="$( (SSH "${K} -n ${NS} get pods --no-headers 2>/dev/null" || true) | wc -l )"
    ok "  全部 Pod Running/Completed(共 $(printf '%s' "${_cnt}" | tr -d ' ') 个)"
fi

# ② ClusterPolicy ready
say "[2/4] 检查 ClusterPolicy 状态 ..."
_cp="$( (SSH "${K} get clusterpolicy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null" || true) )"
_cpst="$( (SSH "${K} get clusterpolicy ${_cp} -o jsonpath='{.status.state}' 2>/dev/null" || true) )"
if [ -n "${_cp}" ] && [ "${_cpst}" = "ready" ]; then
    ok "  ClusterPolicy ${_cp}: ready"
else
    err "  ClusterPolicy ${_cp:-<无>} 状态 ${_cpst:-未知}(期望 ready)"
    FAIL=1
fi

# ③ 有卡判据(sysfs PCI vendor 0x10de)
say "[3/4] 探测 NVIDIA 硬件 ..."
GPU_HOSTS=()
for _line in "${NODES[@]:-}"; do
    [ -z "${_line}" ] && continue
    node_parse "${_line}"
    [ -n "${NODE_IP:-}" ] || continue
    _n="$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "${SSH_USER:-ubuntu}@${NODE_IP}" 'grep -l 0x10de /sys/bus/pci/devices/*/vendor 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
    _n="$(printf '%s' "${_n:-0}" | tr -d '[:space:]' | grep -E '^[0-9]+$' || echo 0)"
    [ "${_n}" -gt 0 ] 2>/dev/null && GPU_HOSTS+=("${NODE_HOSTNAME}")
done

if [ "${#GPU_HOSTS[@]}" -eq 0 ]; then
    if [ "${FAIL}" = "1" ]; then
        exit 1
    fi
    echo "---------------------------------------------"
    ok "验证通过(组件级): 无 NVIDIA 卡集群 —— operator/NFD 组件就绪 + ClusterPolicy ready"
    warn "  ⚠ 边界: 本集群无 NVIDIA 硬件, **未验证**驱动加载/容器 GPU 注入/真实算力;"
    warn "     真卡环境请重跑本模块(端到端 cuda-vectoradd) 或插入卡后按文档复查"
    exit 0
fi
ok "  检测到有卡节点: ${GPU_HOSTS[*]}"

# ④ 真卡端到端: allocatable + cuda-vectoradd
say "[4/4] 真卡端到端验证(allocatable + cuda-vectoradd) ..."
_gpu_alloc() {
    (SSH "${K} get nodes -o json 2>/dev/null" || true) | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    for n in d["items"]:
        g=n["status"]["allocatable"].get("nvidia.com/gpu")
        if g: print(n["metadata"]["name"], g)
except Exception: pass'
}
ALLOC=""
for _i in $(seq 1 60); do
    ALLOC="$(_gpu_alloc)"
    [ -n "${ALLOC}" ] && break
    sleep 5
done
unset -f _gpu_alloc
if [ -n "${ALLOC}" ]; then
    ok "  nvidia.com/gpu allocatable:"; echo "${ALLOC}" | sed 's/^/    /'
else
    err "  有卡节点存在, 但 nvidia.com/gpu allocatable 为空(驱动/设备插件未生效)"
    err "    排查: kubectl -n ${NS} get pods,ds / kubectl get clusterpolicy ${_cp} -o yaml(看 driver 段状态)"
    FAIL=1
fi

if [ "${FAIL}" = "1" ]; then
    err "前置检查未过, 跳过 cuda-vectoradd"
    exit 1
fi

say "  运行 cuda-vectoradd(镜像 ${SAMPLE_REF})..."
curl -s -m 6 "http://${REGISTRY_DIRECT:-${REGISTRY_IP}}:${REGISTRY_PORT:-5000}/v2/" >/dev/null 2>&1 \
    || warn "  registry 预检未通过(继续, 由 pod 结果裁决)"
if ! cat <<EOF | SSH "${K} apply -f - >/dev/null 2>&1"
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: default
spec:
  restartPolicy: OnFailure
  containers:
  - name: cuda-vectoradd
    image: "${SAMPLE_REF}"
    imagePullPolicy: IfNotPresent
    resources:
      limits:
        nvidia.com/gpu: 1
EOF
then
    err "  cuda-vectoradd Pod 创建失败(集群不可达?)"; exit 1
fi

_phase=""
for _i in $(seq 1 60); do   # ≤180s
    _phase="$( (SSH "${K} -n default get pod ${POD} -o jsonpath='{.status.phase}' 2>/dev/null" || true) )"
    case "${_phase}" in Succeeded|Failed) break ;; esac
    sleep 3
done
_logs="$( (SSH "${K} -n default logs ${POD} 2>/dev/null" || true) )"
if [ "${_phase}" = "Succeeded" ] && printf '%s' "${_logs}" | grep -q "Test PASSED"; then
    ok "  cuda-vectoradd: Test PASSED(GPU 计算真实可用)"
else
    err "  cuda-vectoradd 未通过(phase=${_phase:-未知}); 容器日志尾部:"
    printf '%s\n' "${_logs}" | tail -8 | sed 's/^/    /'
    (SSH "${K} -n default describe pod ${POD} 2>/dev/null" || true) | grep -A3 "Events:" | sed 's/^/    /' || true
    exit 1
fi

echo "---------------------------------------------"
ok "NVIDIA GPU 端到端验证通过(组件 + ClusterPolicy + allocatable + cuda-vectoradd)"
