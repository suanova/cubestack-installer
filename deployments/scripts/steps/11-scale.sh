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
#
# 自动检测新节点(无 --only 时):
#   查询运行中集群的节点列表 → 与 cluster.conf 中 worker IP 对比
#   → 不在集群中的 worker 自动识别为新增节点 → 放入 new_node 组
#   → VM 不存在则自动创建, BM 节点直接加入
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib-common.sh"
load_config

OFFLINE_SCRIPT="${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh"
[ -f "${OFFLINE_SCRIPT}" ] || { err "未找到 ${OFFLINE_SCRIPT}"; exit 1; }

# ── 自动检测新节点: 查询运行中集群, 对比 cluster.conf 找出未加入的 worker ──
# 返回: 逗号分隔的新节点 hostname 列表
_auto_detect_new_nodes() {
    # 找到第一个 master 的连接信息
    local m_ip="" m_user="ubuntu"
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        IFS=, read -r role hostname ip mac mem cpu disk user pw node_type <<<"${line}"
        if [ "${role}" = "master" ]; then
            m_ip="${ip}"; m_user="${user}"
            break
        fi
    done
    [ -z "${m_ip}" ] && { warn "cluster.conf 中无 master 节点, 无法自动检测" >&2; return 1; }

    local ssh_key="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
    # 获取集群中已有节点的 InternalIP(每行一个)
    local existing_ips
    existing_ips=$(ssh -i "${ssh_key}" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
        "${m_user}@${m_ip}" \
        "sudo kubectl get nodes --no-headers -o wide 2>/dev/null | awk '{print \$6}'" 2>/dev/null || echo "")

    if [ -z "${existing_ips}" ]; then
        warn "无法获取集群节点列表(API Server 不可达或集群未就绪), 将所有 worker 视为新节点" >&2
        local all=""
        for line in "${NODES[@]:-}"; do
            [ -z "${line}" ] && continue
            IFS=, read -r role hostname ip _rest <<<"${line}"
            [ "${role}" = "worker" ] || continue
            [ -n "${ip}" ] && all="${all},${hostname}"
        done
        echo "${all#,}"
        return 0
    fi

    # 对比: cluster.conf 中 IP 不在集群中的 worker → 新节点
    local new_hosts=""
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        IFS=, read -r role hostname ip mac mem cpu disk user pw node_type <<<"${line}"
        [ "${role}" != "worker" ] && continue
        [ -z "${ip}" ] && continue

        if echo "${existing_ips}" | grep -qx "${ip}"; then
            vlog "  [${hostname}](${ip}) 已在集群中, 跳过" >&2
            continue
        fi
        new_hosts="${new_hosts},${hostname}"
        say "  检测到新节点: ${hostname} (${ip}, type=${node_type:-vm})" >&2
    done
    # 仅输出结果到 stdout(被 $() 捕获), 诊断信息已重定向到 stderr
    echo "${new_hosts#,}"
}

# ── 收集本次 scale 的目标节点 ──
SELECTED_NODES=0
NEW_NODE_HOSTS=""

if [ -n "${ONLY_HOSTS:-}" ]; then
    # 手动模式: 按 --only 过滤(支持 hostname 和 group 名, group 已在 deploy-cluster.sh 展开)
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        IFS=, read -r _r hostname _rest <<<"${line}"
        if node_matches "${hostname}"; then
            SELECTED_NODES=$((SELECTED_NODES + 1))
            NEW_NODE_HOSTS="${NEW_NODE_HOSTS},${hostname}"
        fi
    done
    NEW_NODE_HOSTS="${NEW_NODE_HOSTS#,}"
    if [ "${SELECTED_NODES}" -eq 0 ]; then
        warn "--only ${ONLY_HOSTS} 未匹配到任何节点(支持 hostname 或 group 名), 环境准备将跳过"
    fi
else
    # 自动检测模式: 对比运行中集群, 找出未加入的 worker
    say "自动检测新节点(对比 cluster.conf 与运行中集群的节点 IP)..."
    NEW_NODE_HOSTS=$(_auto_detect_new_nodes) || { err "自动检测失败"; exit 1; }

    if [ -z "${NEW_NODE_HOSTS}" ]; then
        ok "未检测到新节点 — 所有 worker 已在集群中, 无需扩容"
        exit 0
    fi
    SELECTED_NODES=$(echo "${NEW_NODE_HOSTS}" | tr ',' '\n' | grep -c . || echo 0)
    say "检测到 ${SELECTED_NODES} 个新节点: ${NEW_NODE_HOSTS}"
fi

# ── 1. 环境准备: 缺失的 VM 创建/启动 + SSH 免密 + bm 连通装包(复用既有步骤, 幂等) ──
say "[1/3] 环境准备(检查缺失 VM 并创建/启动, 配置 SSH 免密) ..."
bash "${SCRIPT_DIR}/steps/02-ssh-key.sh"
bash "${SCRIPT_DIR}/steps/03-vm.sh"
bash "${SCRIPT_DIR}/steps/04-ssh-passwordless.sh"
bash "${SCRIPT_DIR}/steps/05-worker-bm.sh"
bash "${SCRIPT_DIR}/steps/06-hosts.sh"
ok "环境就绪(缺失 VM 已创建, 节点可 SSH)"

# ── 2. 重新生成 inventory: 新节点进入 hosts.yml(含扩容专用组) ──
SCALE_GROUP_NAME="${SCALE_GROUP_NAME:-new_node}"
say "[2/3] 重新生成 inventory(新节点 → ${SCALE_GROUP_NAME} 组: ${NEW_NODE_HOSTS}) ..."
export SCALE_NODES="${NEW_NODE_HOSTS}"
export SCALE_GROUP_NAME
bash "${SCRIPT_DIR}/gen-inventory.sh"
unset SCALE_NODES SCALE_GROUP_NAME
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
