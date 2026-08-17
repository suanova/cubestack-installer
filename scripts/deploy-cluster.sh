#!/bin/bash
# ============================================================
# CubeStack 一键部署编排(CLI)
# 数据源: config/cluster.conf —— 虚拟机创建与 kubespray inventory 均读此配置
# 流程:   宿主网络 → SSH密钥 → master虚拟机+免密 → worker连通性 → /etc/hosts → inventory → (可选)k8s
# 用法:
#   sudo ./deploy-cluster.sh                # 全流程
#   sudo ./deploy-cluster.sh --skip-net     # 跳过宿主网络初始化
#   sudo ./deploy-cluster.sh --only <host>  # 仅处理指定节点(可多次)
#   sudo ./deploy-cluster.sh --with-k8s     # 完成后执行 kubespray cluster.yml
#   sudo ./deploy-cluster.sh --list         # 仅打印集群规划
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"
load_config

# ---------------- 参数解析 ----------------
SKIP_NET=0; WITH_K8S=0; LIST=0; ONLY=()
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-net)   SKIP_NET=1; shift ;;
        --with-k8s)   WITH_K8S=1; shift ;;
        --only)       ONLY+=("${2:?--only 需要节点名}"); shift 2 ;;
        --list)       LIST=1; shift ;;
        *)            err "未知参数: $1"; exit 1 ;;
    esac
done

need_root() { [ "$(id -u)" -eq 0 ] || { err "需要 root 权限,请执行: sudo $0"; exit 1; }; }

# 指定节点过滤: 无 --only 时全部处理
node_matches() {
    [ "${#ONLY[@]}" -eq 0 ] && return 0
    local h; for h in "${ONLY[@]}"; do [ "$h" = "$1" ] && return 0; done
    return 1
}

# SSH 端口探测(免认证,仅确认就绪)
ssh_port_open() { timeout 3 bash -c "echo > /dev/tcp/$1/22" 2>/dev/null; }

# ---------------- 集群规划打印 ----------------
print_plan() {
    say "==== 集群规划(来源: ${CLUSTER_CONF}) ===="
    echo "  网络模式: ${NET_MODE:-bridge}   虚拟机网段: ${VM_SUBNET:-10.244.0.0/16}   物理Worker: ${PHYS_WORKER_NET:-10.66.1.0/24}"
    echo "  SSH密钥: ${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}   默认密码: ${SSH_DEFAULT_PASSWORD:-<未配置>}"
    echo "  控制平面(master虚拟机) / 工作节点(worker裸金属):"
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        IFS=, read -r role hostname ip mac mem cpu disk user pw <<<"${line}"
        if [ "${role}" = "master" ]; then
            echo "    [master] ${hostname}  ${ip}  (${mem}G/${cpu}C/${disk}G, user=${user})"
        else
            echo "    [worker] ${hostname}  ${ip}  (user=${user})"
        fi
    done
    echo "---------------------------------------------"
}

[ "${LIST}" = "1" ] && { print_plan; exit 0; }
need_root
say "==== 开始一键部署 ===="
print_plan

# ============ Phase 1: 宿主网络 ============
if [ "${SKIP_NET}" = "1" ]; then
    say "[1/6] 跳过宿主网络初始化(--skip-net)"
else
    say "[1/6] 初始化宿主网络 (NET_MODE=${NET_MODE:-bridge}) ..."
    case "${NET_MODE:-bridge}" in
        bridge)
            bash "${SCRIPT_DIR}/setup-vm-network.sh"
            bash "${SCRIPT_DIR}/verify-vm-network.sh" || true
            ;;
        nat)
            bash "${SCRIPT_DIR}/setup-libvirt-nat.sh" "${NAT_NET_NAME:-cubestack-nat}"
            ;;
        *) err "未知 NET_MODE: ${NET_MODE}"; exit 1 ;;
    esac
fi

# ============ Phase 2: SSH 密钥 ============
say "[2/6] SSH 密钥对(幂等) ..."
bash "${SCRIPT_DIR}/gen-ssh-key.sh"

# ============ Phase 3: master 虚拟机 + 免密 ============
say "[3/6] master 虚拟机部署 + 免密登录 ..."
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    IFS=, read -r role hostname ip mac mem cpu disk user pw <<<"${line}"
    [ "${role}" = "master" ] || continue
    node_matches "${hostname}" || continue
    [ "${mac}" = "-" ] && mac="$(mac_from_name "${hostname}")"
    pw="$(node_password master "${pw}")"

    if virsh list --all | grep -qw "${hostname}"; then
        ok "VM ${hostname} 已存在,跳过创建; 确保运行中 ..."
        virsh start "${hostname}" >/dev/null 2>&1 || true
    else
        say "创建 VM ${hostname} (${mem}G/${cpu}C/${disk}G, ${ip}, ${mac}) ..."
        bash "${SCRIPT_DIR}/create-libvirt-vm.sh" "${hostname}" "${mem}" "${cpu}" "${disk}" "${mac}" "${ip}"
    fi

    # 等待 SSH 就绪(最长120s)
    say "等待 ${hostname}(${ip}) SSH 就绪 ..."
    READY=0
    for i in $(seq 1 12); do
        ssh_port_open "${ip}" && { READY=1; break; }
        [ "${i}" -eq 12 ] && break
        sleep 10
    done
    if [ "${READY}" = "1" ]; then
        SSH_DEFAULT_PASSWORD="${pw}" bash "${SCRIPT_DIR}/setup-passwordless.sh" "${ip}" ${VM_SSH_USERS:-root ubuntu}
    else
        warn "${hostname}(${ip}) SSH 120s 内未就绪,跳过免密配置(稍后可手动执行 setup-passwordless.sh)"
    fi
done

# ============ Phase 4: worker(裸金属) 连通性 ============
say "[4/6] worker(裸金属) 连通性检查(仅读,不修改) ..."
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    IFS=, read -r role hostname ip mac mem cpu disk user pw <<<"${line}"
    [ "${role}" = "worker" ] || continue
    node_matches "${hostname}" || continue
    pw="$(node_password worker "${pw}")"
    if [ -n "${pw}" ]; then
        if SSHPASS="${pw}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=8 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            "${user}@${ip}" 'hostname' >/dev/null 2>&1; then
            ok "worker ${hostname}(${ip}) 连通(user=${user}, 密码认证OK)"
        else
            warn "worker ${hostname}(${ip}) 密码连接失败(检查 WORKER_SSH_PASSWORD 或节点第9字段)"
        fi
    else
        warn "worker ${hostname}(${ip}) 未配置密码,跳过连通性检查(可稍后补 config 后重跑)"
    fi
done

# ============ Phase 5: 更新 /etc/hosts ============
if [ "${UPDATE_ETC_HOSTS:-0}" = "1" ]; then
    say "[5/6] 更新 /etc/hosts(节点主机名解析) ..."
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        IFS=, read -r role hostname ip mac mem cpu disk user pw <<<"${line}"
        if ! grep -qE "[[:space:]]${hostname}([[:space:]]|\$)" /etc/hosts; then
            echo "${ip} ${hostname}" >> /etc/hosts
            ok "已添加 /etc/hosts: ${ip} ${hostname}"
        fi
    done
else
    say "[5/6] 跳过 /etc/hosts 更新(配置 UPDATE_ETC_HOSTS=1 可启用)"
fi

# ============ Phase 6: 生成 inventory ============
say "[6/6] 生成 kubespray 兼容 inventory ..."
bash "${SCRIPT_DIR}/gen-inventory.sh"

# ============ Phase 7: (可选) kubespray 部署 ============
if [ "${WITH_K8S}" = "1" ]; then
    say "执行 kubespray 部署 ..."
    if command -v ansible-playbook >/dev/null 2>&1 && [ -d "${KUBESPRAY_DIR:-}" ]; then
        INV="${KUBESPRAY_INV_DIR:-${REPO_ROOT}/deployments/kubespray/inventory/cubestack-cluster}"
        ( cd "${KUBESPRAY_DIR}" && ansible-playbook -i "${INV}/hosts.yml" cluster.yml )
    else
        warn "缺少 ansible-playbook 或 KUBESPRAY_DIR=${KUBESPRAY_DIR:-<未配置>},跳过 kubespray 部署"
    fi
fi

# ============ 汇总 ============
echo "============================================="
echo -e "\033[32m✅ 一键部署流程完成\033[0m"
echo "  下一步:"
echo "    1. sudo ./scripts/verify-vm-network.sh          # 验证宿主网络"
echo "    2. sudo ./scripts/deploy-cluster.sh --with-k8s  # 执行 kubespray 部署"
echo "============================================="
