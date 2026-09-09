#!/bin/bash
# ============================================================
# MODULE: k8s_scale
# DESC: 扩容 kubespray 集群(添加新节点, 可重复执行)
# PHASE: k8s
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: K8S_SCALE_ENABLED
# REQUIRES: k8s_deploy
#
# 场景一: 新节点为虚拟机且尚未创建
#   虚拟机创建由 tools/vm/create-vms.sh 独立执行(不经过主程序): 先在 tools/vm/vm-nodes.conf
#   添加新节点并单独执行 sudo ./deployments/scripts/tools/vm/create-vms.sh, 再执行本模块扩容。
#   本模块只做集群侧准备(全部幂等):
#     vm_sshkey → k8s_passwordless(全部节点注入公钥) → k8s_workerbm(worker 离线装包)
#     → k8s_hosts(部署机 /etc/hosts, 可选) → k8s_ntp(新节点时间同步, kubeadm join 前)
#     → [1.5/3] 新节点 /etc/hosts 同步 API/registry 域名(幂等; 新增 worker 解析
#       k8s-api.cubestack.io / registry.cubestack.io → 首 master IP)
#   再重新生成 inventory(新节点进入 hosts.yml), 最后执行 kubespray 扩容
#
# 场景二: 新节点环境已存在(VM 已运行 / 裸金属已就绪)
#   环境准备步骤幂等快速通过, 直接进入 inventory 重生成 + 扩容
#
# 职责边界: 节点环境(虚拟机创建/裸金属就绪)由 tools/vm/create-vms.sh 独立准备;
#           cubestack-offline.sh scale 仅负责 K8s 层面扩容, 假设节点环境已存在
#
# 自动检测新节点(无 --only 时):
#   查询运行中集群的节点列表 → 与 cluster.conf 中 worker IP 对比
#   → 不在集群中的 worker 自动识别为新增节点 → 放入 new_node 组
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
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
        node_parse "${line}"
        if [ "${NODE_ROLE}" = "master" ]; then
            m_ip="${NODE_IP}"; m_user="${NODE_USER}"
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
            node_parse "${line}"
            [ "${NODE_ROLE}" = "worker" ] || continue
            [ -n "${NODE_IP}" ] && all="${all},${NODE_HOSTNAME}"
        done
        echo "${all#,}"
        return 0
    fi

    # 对比: cluster.conf 中 IP 不在集群中的 worker → 新节点
    local new_hosts=""
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        [ "${NODE_ROLE}" != "worker" ] && continue
        [ -z "${NODE_IP}" ] && continue

        if echo "${existing_ips}" | grep -qx "${NODE_IP}"; then
            vlog "  [${NODE_HOSTNAME}](${NODE_IP}) 已在集群中, 跳过" >&2
            continue
        fi
        new_hosts="${new_hosts},${NODE_HOSTNAME}"
        say "  检测到新节点: ${NODE_HOSTNAME} (${NODE_IP})" >&2
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
        node_parse "${line}"
        if node_matches "${NODE_HOSTNAME}"; then
            SELECTED_NODES=$((SELECTED_NODES + 1))
            NEW_NODE_HOSTS="${NEW_NODE_HOSTS},${NODE_HOSTNAME}"
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

# ── 1. 环境准备: SSH 免密(全部节点)+ worker 离线装包 + hosts + NTP(复用既有模块, 幂等) ──
# 虚拟机创建由 tools/vm/create-vms.sh 独立执行(不经过主程序): 新 VM 请先在
# tools/vm/vm-nodes.conf 添加并单独执行 sudo ./deployments/scripts/tools/vm/create-vms.sh
say "[1/3] 环境准备(SSH 免密 / worker 离线装包 / NTP) ..."
bash "${SCRIPT_DIR}/modules/01_env/02_vm_sshkey.sh"
bash "${SCRIPT_DIR}/modules/02_k8s/01_k8s_passwordless.sh"
bash "${SCRIPT_DIR}/modules/02_k8s/02_k8s_workerbm.sh"
bash "${SCRIPT_DIR}/modules/02_k8s/03_k8s_hosts.sh"
bash "${SCRIPT_DIR}/modules/02_k8s/05_k8s_ntp.sh"
ok "环境就绪(节点可 SSH, 时间已同步)"

# ── 1.5 新节点 /etc/hosts 域名同步(API/registry 域名 → 首 master IP; 幂等) ──
# ★ 2026-09-09(用户要求): 扩容时新增 worker 也必须拿到 k8s-api.cubestack.io /
#   registry.cubestack.io 解析 —— 03_k8s_hosts 只写**部署机** /etc/hosts,
#   节点侧此处补上(与 deploy-registry.sh 同款远端脚本: 先删旧域名行再追加当前 IP,
#   换集群/换 IP 不残留)。API_IP/REGISTRY_IP 由 load_config 派生(nodeport=首 master IP)。
if [ -n "${NEW_NODE_HOSTS}" ] && [ -n "${API_IP:-}" ]; then
    say "[1.5/3] 新节点 /etc/hosts 同步 API/registry 域名(${API_DOMAIN} / ${REGISTRY_DOMAIN}) ..."
    _HOSTS_SCRIPT="$(mktemp)"
    cat > "${_HOSTS_SCRIPT}" <<EOF
#!/bin/bash
set -e
_rd1="\$(echo '${API_DOMAIN}' | sed 's/\\./\\\\\\./g')"
sed -i -E "/[[:space:]]\${_rd1}([[:space:]]|\$)/d" /etc/hosts 2>/dev/null || true
echo "${API_IP} ${API_DOMAIN}" >> /etc/hosts
_rd2="\$(echo '${REGISTRY_DOMAIN}' | sed 's/\\./\\\\\\./g')"
sed -i -E "/[[:space:]]\${_rd2}([[:space:]]|\$)/d" /etc/hosts 2>/dev/null || true
echo "${REGISTRY_IP} ${REGISTRY_DOMAIN}" >> /etc/hosts
EOF
    _node_hosts_sync() {   # <ip> <user> <pw> → 0=成功(密钥 BatchMode 优先, 失败回退 sshpass 密码)
        local ip="$1" user="$2" pw="$3"
        local key="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
        if [ -f "${key}" ]; then
            ssh -i "${key}" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
                "${user}@${ip}" "sudo bash -s" < "${_HOSTS_SCRIPT}" 2>/dev/null && return 0
        fi
        if [ -n "${pw}" ] && command -v sshpass >/dev/null 2>&1; then
            env SSHPASS="${pw}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=8 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                "${user}@${ip}" "sudo bash -s" < "${_HOSTS_SCRIPT}" 2>/dev/null && return 0
        fi
        return 1
    }
    for _hn in ${NEW_NODE_HOSTS//,/ }; do
        [ -z "${_hn}" ] && continue
        for line in "${NODES[@]:-}"; do
            [ -z "${line}" ] && continue
            node_parse "${line}"
            [ "${NODE_HOSTNAME}" = "${_hn}" ] || continue
            if _node_hosts_sync "${NODE_IP}" "${NODE_USER}" "${NODE_PW}"; then
                ok "  ${_hn}(${NODE_IP}) /etc/hosts 已同步(${API_DOMAIN} / ${REGISTRY_DOMAIN})"
            else
                warn "  ${_hn}(${NODE_IP}) /etc/hosts 同步失败(密钥/密码均不可达; 检查 k8s_passwordless)"
            fi
            break
        done
    done
    rm -f "${_HOSTS_SCRIPT}"
fi

# ── 2. 重新生成 inventory: 新节点进入 hosts.yml(含扩容专用组) ──
SCALE_GROUP_NAME="${SCALE_GROUP_NAME:-new_node}"
say "[2/3] 重新生成 inventory(新节点 → ${SCALE_GROUP_NAME} 组: ${NEW_NODE_HOSTS}) ..."
export SCALE_NODES="${NEW_NODE_HOSTS}"
export SCALE_GROUP_NAME
bash "${SCRIPT_DIR}/tools/k8s/gen-inventory.sh"
unset SCALE_NODES SCALE_GROUP_NAME
ok "inventory 已更新"

# ── 3. kubespray 扩容(镜像预加载/scale.yml/兜底预加载/RBAC 修复/CNI 重启) ──
say "[3/3] 执行 kubespray 扩容 (via cubestack-offline.sh scale) ..."
OFFLINE_ENV=(
    "CUBESTACK_KUBESPRAY_DIR=${KUBESPRAY_DIR}"
    "CUBESTACK_INVENTORY_DIR=${KUBESPRAY_INV_DIR}"
    "OFFLINE_FILES_DIR=${OFFLINE_FILES_DIR}"
    "CUBESTACK_LOCAL_REPO_DIR=${LOCAL_REPO_DIR}"
)
[ -n "${PRELOAD_IMAGE_PATTERNS+x}" ] && \
    OFFLINE_ENV+=("CUBESTACK_PRELOAD_IMAGE_PATTERNS=${PRELOAD_IMAGE_PATTERNS}")
env "${OFFLINE_ENV[@]}" bash "${OFFLINE_SCRIPT}" scale
ok "集群扩容完成"
