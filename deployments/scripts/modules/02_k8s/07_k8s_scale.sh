#!/bin/bash
# ============================================================
# MODULE: k8s_scale
# DESC: 扩容 kubespray 集群(添加新 worker 节点, 可重复执行; 先登录首个 master 核对实际集群)
# PHASE: k8s
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: K8S_SCALE_ENABLED
#
# 场景一: 新节点为虚拟机且尚未创建
#   虚拟机创建由 tools/vm/create-vms.sh 独立执行(不经过主程序): 先在 tools/vm/vm-nodes.conf
#   添加新节点并单独执行 sudo ./deployments/scripts/tools/vm/create-vms.sh, 再执行本模块扩容。
#   本模块只做集群侧准备(全部幂等):
#     登录首个 master 核对实际集群节点 → diff 出未加入集群的 worker(新节点)
#     → 仅对新节点: SSH 免密 / worker 离线装包 / NTP 时间同步 / /etc/hosts + registry certs.d
#     → 重生成 inventory(新节点进 new_node 组) → kubespray 离线扩容(--limit new_node)
#
# 场景二: 新节点环境已存在(VM 已运行 / 裸金属已就绪)
#   环境准备步骤幂等快速通过, 直接进入 inventory 重生成 + 扩容
#
# 职责边界: 节点环境(虚拟机创建/裸金属就绪)由 tools/vm/create-vms.sh 独立准备;
#           cubestack-offline.sh scale 仅负责 K8s 层面扩容, 假设节点环境已存在
#
# ⚠ 安全边界(扩容绝不覆盖已有集群):
#   · 扩容前**必须**能从首个 master 拿到集群节点列表(kubectl get nodes); 拿不到 → 中止,
#     绝不把已有节点当新节点处理(历史: 集群不可达时 fallback 全当新节点, 风险极大)
#   · 只对 diff 出的新节点执行环境准备/装包/join(--limit new_node), 已有节点不触碰
#   · cluster.conf 的 master 必须能命中运行中集群, 否则中止(配置与真实集群脱节)
#   · 本模块不依赖 k8s_deploy 模块(自包含校验集群存在), 防止 --steps 闭包误拉 k8s_deploy 重装集群
#
# 自动检测新节点(无 --only 时):
#   查询运行中集群的节点列表(name + InternalIP + ExternalIP) → 与 cluster.conf 中 worker
#   对比 → 不在集群中的 worker 自动识别为新增节点 → 放入 new_node 组
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

OFFLINE_SCRIPT="${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh"
[ -f "${OFFLINE_SCRIPT}" ] || { err "未找到 ${OFFLINE_SCRIPT}"; exit 1; }

# ── 登录首个 master, 查询运行中集群的节点(名称 + InternalIP + ExternalIP) ──
# 返回: 每行 "hostname|ip|external_ip"; 失败(集群不可达)→ 非 0
# ★ 安全边界: 扩容前必须确认集群真实状态; 集群不可达时宁可不扩, 绝不盲扩
_query_cluster_nodes() {
    local m_ip="" m_user="ubuntu" m_pw=""
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        if [ "${NODE_ROLE}" = "master" ]; then
            m_ip="${NODE_IP}"; m_user="${NODE_USER}"; m_pw="${NODE_PW}"
            break
        fi
    done
    [ -z "${m_ip}" ] && { warn "cluster.conf 中无 master 节点, 无法核对集群" >&2; return 1; }

    local ssh_key="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
    local out=""
    # 密钥优先(BatchMode), 失败回退 sshpass 密码
    if [ -f "${ssh_key}" ]; then
        out=$(ssh -i "${ssh_key}" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
            "${m_user}@${m_ip}" \
            "sudo kubectl get nodes --no-headers -o wide 2>/dev/null | awk '{print \$1\"|\"\$6\"|\"\$7}'" 2>/dev/null || true)
    fi
    if [ -z "${out}" ] && [ -n "${m_pw}" ] && command -v sshpass >/dev/null 2>&1; then
        out=$(env SSHPASS="${m_pw}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            "${m_user}@${m_ip}" \
            "sudo kubectl get nodes --no-headers -o wide 2>/dev/null | awk '{print \$1\"|\"\$6\"|\"\$7}'" 2>/dev/null || true)
    fi
    [ -z "${out}" ] && { warn "无法获取集群节点列表(API Server 不可达或免密未配: ${m_user}@${m_ip})" >&2; return 1; }
    echo "${out}"
}

# ── 自动检测新节点: 登录首个 master 核对集群, 对比 cluster.conf 找出未加入的 worker ──
# 返回: 逗号分隔的新节点 hostname 列表
_auto_detect_new_nodes() {
    local cluster_out
    cluster_out="$(_query_cluster_nodes)" || {
        err "集群节点列表获取失败 —— 扩容前必须确认集群真实状态, 已中止(绝不把已有节点当新节点)"
        err "  请检查: ① cluster.conf 首个 master 的 IP/免密正确(k8s_passwordless 已执行)"
        err "  ② 集群 API Server 正常(kubectl get nodes 在 master 上可执行)"
        return 1
    }

    # 解析集群节点: 名称 + 全部 IP 归入一个集合(hostname 或 IP 命中即视为已入集群)
    local cluster_names="" cluster_ips="" line
    while IFS= read -r line; do
        [ -z "${line}" ] && continue
        IFS='|' read -r name ip eip <<< "${line}"
        [ -n "${name}" ] && cluster_names="${cluster_names} ${name}"
        [ -n "${ip}" ] && cluster_ips="${cluster_ips} ${ip}"
        [ -n "${eip}" ] && cluster_ips="${cluster_ips} ${eip}"
    done <<< "${cluster_out}"

    # ★ 配置校验: cluster.conf 的 master 必须能命中运行中集群(配置与真实集群脱节 → 中止)
    #   (至少一个 master 命中即可; 多 master 配置中个别 master 未部署时 warn 提示)
    local master_hit=0 master_miss=""
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        [ "${NODE_ROLE}" = "master" ] || continue
        if echo "${cluster_names}" | grep -qwF "${NODE_HOSTNAME}" \
            || { [ -n "${NODE_IP}" ] && echo "${cluster_ips}" | grep -qwF "${NODE_IP}"; }; then
            master_hit=1
        else
            master_miss="${master_miss} ${NODE_HOSTNAME}(${NODE_IP})"
        fi
    done
    if [ "${master_hit}" != "1" ]; then
        err "cluster.conf 中的 master 均不在运行中集群节点列表里 —— 配置与真实集群脱节, 已中止"
        err "  cluster.conf master: ${master_miss:-<无>}"
        err "  集群现有节点: ${cluster_names}"
        err "  请核对 cluster.conf 的 NODES(尤其 master IP)后再扩容"
        return 1
    fi
    [ -n "${master_miss}" ] && warn "cluster.conf 中以下 master 不在集群(未部署/IP 变更? 本次不处理):${master_miss}"

    # 对比: cluster.conf 中 worker 的 hostname/IP 不在集群中的 → 新节点
    local new_hosts=""
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        [ "${NODE_ROLE}" != "worker" ] && continue
        [ -z "${NODE_IP}" ] && continue

        if echo "${cluster_names}" | grep -qwF "${NODE_HOSTNAME}" \
            || echo "${cluster_ips}" | grep -qwF "${NODE_IP}"; then
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
    # ★ 同样先核对集群: 所选节点已在集群中 → warn 跳过(不重复 join 已有节点)
    _cluster_out2="$(_query_cluster_nodes 2>/dev/null || true)"
    _cluster_names2=""
    _cluster_ips2=""
    while IFS= read -r _cl2; do
        [ -z "${_cl2}" ] && continue
        IFS='|' read -r _n2 _i2 _e2 <<< "${_cl2}"
        [ -n "${_n2}" ] && _cluster_names2="${_cluster_names2} ${_n2}"
        [ -n "${_i2}" ] && _cluster_ips2="${_cluster_ips2} ${_i2}"
        [ -n "${_e2}" ] && _cluster_ips2="${_cluster_ips2} ${_e2}"
    done <<< "${_cluster_out2}"
    [ -z "${_cluster_out2}" ] && warn "--only 模式: 无法获取集群节点列表, 无法核对所选节点是否已在集群(按用户指定继续)"
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        if node_matches "${NODE_HOSTNAME}"; then
            if echo "${_cluster_names2}" | grep -qwF "${NODE_HOSTNAME}" \
                || { [ -n "${NODE_IP}" ] && echo "${_cluster_ips2}" | grep -qwF "${NODE_IP}"; }; then
                warn "--only ${NODE_HOSTNAME}(${NODE_IP}) 已在集群中, 跳过(无需扩容)"
                continue
            fi
            SELECTED_NODES=$((SELECTED_NODES + 1))
            NEW_NODE_HOSTS="${NEW_NODE_HOSTS},${NODE_HOSTNAME}"
        fi
    done
    NEW_NODE_HOSTS="${NEW_NODE_HOSTS#,}"
    if [ "${SELECTED_NODES}" -eq 0 ]; then
        warn "--only ${ONLY_HOSTS} 未匹配到任何新节点(已在集群中的节点会被跳过), 无需扩容"
        exit 0
    fi
else
    # 自动检测模式: 登录首个 master 核对集群, 找出未加入的 worker
    say "自动检测新节点(登录首个 master 核对集群, 对比 cluster.conf 与运行中集群节点)..."
    NEW_NODE_HOSTS=$(_auto_detect_new_nodes) || { err "自动检测失败"; exit 1; }

    if [ -z "${NEW_NODE_HOSTS}" ]; then
        ok "未检测到新节点 — 所有 worker 已在集群中, 无需扩容"
        exit 0
    fi
    SELECTED_NODES=$(echo "${NEW_NODE_HOSTS}" | tr ',' '\n' | grep -c . || echo 0)
    say "检测到 ${SELECTED_NODES} 个新节点: ${NEW_NODE_HOSTS}"
fi

# ── 1. 环境准备: 仅对【新节点】执行(SSH 免密 + worker 离线装包 + NTP 时间同步) ──
# ★ 通过 ONLY_HOSTS 限定子模块只处理新节点 —— 扩容绝不重复向已有节点上传/装包
#   (k8s_passwordless / k8s_workerbm / k8s_ntp 内部均按 node_matches 过滤)
#   虚拟机创建由 tools/vm/create-vms.sh 独立执行(不经过主程序): 新 VM 请先在
#   tools/vm/vm-nodes.conf 添加并单独执行 sudo ./deployments/scripts/tools/vm/create-vms.sh
say "[1/3] 环境准备(SSH 免密 / worker 离线装包 / NTP, 仅新节点: ${NEW_NODE_HOSTS}) ..."
bash "${SCRIPT_DIR}/modules/01_env/02_vm_sshkey.sh"        # 生成密钥(全局幂等)
export ONLY_HOSTS="${NEW_NODE_HOSTS}"
bash "${SCRIPT_DIR}/modules/02_k8s/01_k8s_passwordless.sh" # 仅新节点注入公钥
bash "${SCRIPT_DIR}/modules/02_k8s/02_k8s_workerbm.sh"     # 仅新 worker 离线装包(版本感知+依赖修复)
bash "${SCRIPT_DIR}/modules/02_k8s/05_k8s_ntp.sh"          # NTP: 首 master chrony 权威(无过滤, 照常配置)+ 新节点同步/校验
unset ONLY_HOSTS
bash "${SCRIPT_DIR}/modules/02_k8s/03_k8s_hosts.sh"        # 宿主机 /etc/hosts 全量收敛(幂等, 默认关)
ok "环境就绪(新节点可 SSH, 时间已同步)"

# ── 1.5 新节点 /etc/hosts + registry certs.d 域名同步(API/registry 域名 → 首 master IP; 幂等) ──
# ★ 2026-09-09(用户要求): 扩容时新增 worker 也必须拿到 k8s-api.cubestack.io /
#   registry.cubestack.io 解析 —— 03_k8s_hosts 只写**部署机** /etc/hosts,
#   节点侧此处补上(与 deploy-registry.sh 同款远端脚本: 先删旧域名行再追加当前 IP,
#   换集群/换 IP 不残留)。API_IP/REGISTRY_IP 由 load_config 派生(nodeport=首 master IP)。
# ★ 2026-09-10(用户要求): 新节点还需 containerd certs.d 信任内置 registry(否则 join 后
#   拉 registry.cubestack.io 镜像 ImagePullBackOff)。与 deploy-registry.sh [2/4] 同款 hosts.toml。
if [ -n "${NEW_NODE_HOSTS}" ] && [ -n "${API_IP:-}" ]; then
    say "[1.5/3] 新节点 /etc/hosts + registry certs.d 同步(${API_DOMAIN} / ${REGISTRY_DOMAIN}) ..."
    # nodeport 模式: 节点侧经 NodePort 直连首个 master; 否则经 REGISTRY_DOMAIN:REGISTRY_PORT(VIP)
    _np_mirror="http://${REGISTRY_DOMAIN}:${REGISTRY_PORT}"
    if [ "${REGISTRY_SERVICE_TYPE:-loadbalancer}" = "nodeport" ] || [ "${SERVICE_EXPOSE_MODE:-nodeport}" = "nodeport" ]; then
        _np_mirror="http://${API_IP}:${REGISTRY_NODEPORT:-31148}"
    fi
    _certs_dir="/etc/containerd/certs.d/${REGISTRY_DOMAIN}:${REGISTRY_PORT}"
    _HOSTS_SCRIPT="$(mktemp)"
    cat > "${_HOSTS_SCRIPT}" <<EOF
#!/bin/bash
set -e
_rd1="\$(echo '${API_DOMAIN}' | sed 's/\\./\\\\\\./g')"
sed -i -E "/[[:space:]]\${_rd1}([[:space:]]|\$)/d" /etc/hosts 2>/dev/null || true
echo "${API_IP} ${API_DOMAIN}" >> /etc/hosts
_rd2="\$(echo '${REGISTRY_DOMAIN}' | sed 's/\\./\\\\\\./g')"
sed -i -E "/[[:space:]]\${_rd2}([[:space:]]|\$)/d" /etc/hosts 2>/dev/null || true
echo "${REGISTRY_IP:-${API_IP}} ${REGISTRY_DOMAIN}" >> /etc/hosts
mkdir -p "${_certs_dir}"
cat > "${_certs_dir}/hosts.toml" <<HT
server = "http://${REGISTRY_DOMAIN}:${REGISTRY_PORT}"
[host."${_np_mirror}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
HT
if [ ! -f /var/lib/containerd/certs.d-stamp ]; then
    systemctl restart containerd 2>/dev/null || true
    touch /var/lib/containerd/certs.d-stamp
    echo "containerd restarted(首次配置 certs.d)"
else
    echo "certs.d 已就绪(无需重启)"
fi
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
                ok "  ${_hn}(${NODE_IP}) /etc/hosts + certs.d 已同步(${API_DOMAIN} / ${REGISTRY_DOMAIN})"
            else
                warn "  ${_hn}(${NODE_IP}) 同步失败(密钥/密码均不可达; 检查 k8s_passwordless)"
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
