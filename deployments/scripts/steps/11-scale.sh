#!/bin/bash
# ============================================================
# 部署模块: 11-scale — 扩容 kubespray 集群(添加新节点, 可重复执行)
#
# 场景一: 新节点为虚拟机(node_type=vm)且尚未创建
#   本模块先准备环境(复用初始部署的同一链路, 全部幂等):
#     ssh_key → vm(检查缺失 VM 并创建/启动, 等待 SSH 就绪)
#     → ssh_passwordless(注入公钥) → worker_bm(bm 节点连通性+装包)
#     → hosts(/etc/hosts, 可选)
#   再重新生成 inventory(新节点进入 hosts.yml), 最后执行 kubespray 扩容
#
# 场景二: 新节点环境已存在(VM 已运行 / 裸金属已就绪)
#   环境准备步骤幂等快速通过, 直接进入 inventory 重生成 + 扩容
#
# 职责边界: 虚拟机/裸金属等基础设施由本模块(deploy-cluster.sh 入口链路)负责;
#           cubestack-offline.sh scale 仅负责 K8s 层面扩容, 假设节点环境已存在
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib-common.sh"
load_config

OFFLINE_SCRIPT="${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh"
[ -f "${OFFLINE_SCRIPT}" ] || { err "未找到 ${OFFLINE_SCRIPT}"; exit 1; }

# --only 未匹配任何节点时给出明确警告(防止拼写错误导致环境准备静默跳过)
SELECTED_NODES=0
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    IFS=, read -r _r hostname _rest <<<"${line}"
    node_matches "${hostname}" && SELECTED_NODES=$((SELECTED_NODES + 1))
done
if [ -n "${ONLY_HOSTS:-}" ] && [ "${SELECTED_NODES}" -eq 0 ]; then
    warn "--only ${ONLY_HOSTS} 未匹配到任何节点(支持全名或短名, 如 worker02), 环境准备将跳过"
fi

# ── 1. 环境准备: 缺失的 VM 创建/启动 + SSH 免密 + bm 连通装包(复用既有步骤, 幂等) ──
say "[1/3] 环境准备(检查缺失 VM 并创建/启动, 配置 SSH 免密) ..."
bash "${SCRIPT_DIR}/steps/02-ssh-key.sh"
bash "${SCRIPT_DIR}/steps/03-vm.sh"
bash "${SCRIPT_DIR}/steps/04-ssh-passwordless.sh"
bash "${SCRIPT_DIR}/steps/05-worker-bm.sh"
bash "${SCRIPT_DIR}/steps/06-hosts.sh"
ok "环境就绪(缺失 VM 已创建, 节点可 SSH)"

# ── 2. 重新生成 inventory: 新节点进入 hosts.yml ──
say "[2/3] 重新生成 inventory(新节点进入 hosts.yml) ..."
bash "${SCRIPT_DIR}/gen-inventory.sh"
ok "inventory 已更新"

# ── 3. kubespray 扩容(镜像预加载/scale.yml/兜底预加载/RBAC 修复/CNI 重启) ──
say "[3/3] 执行 kubespray 扩容 (via cubestack-offline.sh scale) ..."
OFFLINE_ENV=(
    "CUBESTACK_KUBESPRAY_DIR=${KUBESPRAY_DIR}"
    "CUBESTACK_INVENTORY_DIR=${KUBESPRAY_INV_DIR}"
    "CUBESTACK_LOCAL_REPO_DIR=${LOCAL_REPO_DIR}"
)
[ -n "${PRELOAD_IMAGE_PATTERNS+x}" ] && \
    OFFLINE_ENV+=("CUBESTACK_PRELOAD_IMAGE_PATTERNS=${PRELOAD_IMAGE_PATTERNS}")
env "${OFFLINE_ENV[@]}" bash "${OFFLINE_SCRIPT}" scale
ok "集群扩容完成"
