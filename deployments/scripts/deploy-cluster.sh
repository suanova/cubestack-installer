#!/bin/bash
# ============================================================
# CubeStack 一键部署编排(CLI)
# 数据源: config/cluster.conf(单集群) 或 config/cluster-${CLUSTER_NAME}.conf(多集群)
# 流程:   宿主网络 → SSH密钥 → master虚拟机+免密 → worker连通性 → /etc/hosts → inventory → (可选)k8s
# 多集群: --cluster <name> 指定集群名(默认 cubestack-cluster, 环境变量 CUBESTACK_CLUSTER 也可)
# 断点续跑: 每阶段完成后自动保存状态;下次启动从断点继续; --fresh 清状态重新执行
# 用法:
#   sudo ./deploy-cluster.sh                              # 全流程
#   sudo ./deploy-cluster.sh --cluster mycluster          # 指定集群
#   sudo ./deploy-cluster.sh --skip-net                   # 跳过宿主网络初始化
#   sudo ./deploy-cluster.sh --only <host>                # 仅处理指定节点(可多次)
#   sudo ./deploy-cluster.sh --with-k8s                   # 完成后执行 kubespray offline 部署
#   sudo ./deploy-cluster.sh --list                       # 仅打印集群规划
#   sudo ./deploy-cluster.sh --fresh                      # 清状态重新执行
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"

# ---------------- 参数解析 ----------------
SKIP_NET=0; WITH_K8S=0; LIST=0; FRESH=0; ONLY=()
while [ $# -gt 0 ]; do
    case "$1" in
        --cluster)    CLUSTER_NAME="${2:?--cluster 需要集群名}"; export CLUSTER_NAME; shift 2 ;;
        --skip-net)   SKIP_NET=1; shift ;;
        --with-k8s)   WITH_K8S=1; shift ;;
        --only)       ONLY+=("${2:?--only 需要节点名}"); shift 2 ;;
        --list)       LIST=1; shift ;;
        --fresh)      FRESH=1; shift ;;
        *)            err "未知参数: $1"; exit 1 ;;
    esac
done

# 重新加载配置(CLUSTER_NAME 已更新,lib-common 的 CLUSTER_CONF 基于新 CLUSTER_NAME 重算)
CLUSTER_CONF="${CLUSTER_CONF:-${REPO_ROOT}/config/cluster.conf}"
CONF_BY_CLUSTER="${REPO_ROOT}/config/cluster-${CLUSTER_NAME}.conf"
[ -f "${CONF_BY_CLUSTER}" ] && CLUSTER_CONF="${CONF_BY_CLUSTER}"
load_config

# 清状态
[ "${FRESH}" = "1" ] && clear_state

need_root() { [ "$(id -u)" -eq 0 ] || { err "需要 root 权限,请执行: sudo $0"; exit 1; }; }

# 指定节点过滤: 无 --only 时全部处理
node_matches() {
    [ "${#ONLY[@]}" -eq 0 ] && return 0
    local h; for h in "${ONLY[@]}"; do [ "$h" = "$1" ] && return 0; done
    return 1
}

# SSH 端口探测(免认证,仅确认就绪)
ssh_port_open() { timeout 3 bash -c "echo > /dev/tcp/$1/22" 2>/dev/null; }

# ---------------- 断点续跑: 检查阶段是否已完成 ----------------
PHASE_NAMES=("phase_net" "phase_ssh" "phase_master" "phase_worker" "phase_hosts" "phase_inventory" "phase_k8s")
phase_done() { [ "$(get_state "$1")" = "done" ]; }
skip_if_done() {
    if phase_done "$1"; then
        say "[$1] 已完成,跳过(--fresh 清状态可重跑)"
        return 0
    fi
    return 1
}

# ---------------- 集群规划打印 ----------------
print_plan() {
    say "==== 集群规划(集群: ${CLUSTER_NAME}, 配置: ${CLUSTER_CONF}) ===="
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

# 断点续跑: 打印已完成阶段
DONE_LIST=""
for p in "${PHASE_NAMES[@]}"; do
    phase_done "$p" && DONE_LIST="${DONE_LIST} ${p}"
done
[ -n "${DONE_LIST}" ] && say "检测到已完成阶段:${DONE_LIST}, 将跳过(--fresh 清状态可重跑)"

# ============ Phase 1: 宿主网络 ============
if ! skip_if_done "phase_net"; then
    if [ "${SKIP_NET}" = "1" ]; then
        say "[1/7] 跳过宿主网络初始化(--skip-net)"
    else
        say "[1/7] 初始化宿主网络 (NET_MODE=${NET_MODE:-bridge}) ..."
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
    save_state "phase_net" "done"
fi

# ============ Phase 2: SSH 密钥 ============
if ! skip_if_done "phase_ssh"; then
    say "[2/7] SSH 密钥对(幂等) ..."
    bash "${SCRIPT_DIR}/gen-ssh-key.sh"
    save_state "phase_ssh" "done"
fi

# ============ Phase 3: master 虚拟机 + 免密 ============
if ! skip_if_done "phase_master"; then
    say "[3/7] master 虚拟机部署 + 免密登录 ..."
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
            AUTO_REGISTER_CLUSTER=1 bash "${SCRIPT_DIR}/create-libvirt-vm.sh" "${hostname}" "${mem}" "${cpu}" "${disk}" "${mac}" "${ip}"
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
    save_state "phase_master" "done"
fi

# ============ Phase 4: worker(裸金属) 连通性 + 离线包安装 ============
if ! skip_if_done "phase_worker"; then
    say "[4/7] worker(裸金属) 连通性检查 + 离线包安装 ..."
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
                # 注入 SSH 公钥(免密)
                say "注入 SSH 公钥到 worker ${hostname}(${ip}) ..."
                SSH_KEY_DIR="${SSH_KEY_DIR:-${HOME}/.ssh}"
                SSH_KEY_NAME="${SSH_KEY_NAME:-cubestack_k8s}"
                KEY_PUB="${SSH_KEY_DIR}/${SSH_KEY_NAME}.pub"
                if [ -f "${KEY_PUB}" ]; then
                    PUBKEY="$(cat "${KEY_PUB}")"
                    SSHPASS="${pw}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                        -o ConnectTimeout=10 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                        "${user}@${ip}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '${PUBKEY}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" 2>/dev/null || true
                    ok "SSH 公钥已注入 ${hostname}"
                fi
                # 安装离线包
                say "安装离线包到 worker ${hostname}(${ip}) ..."
                bash "${SCRIPT_DIR}/install-worker-packages.sh" "${ip}" "${user}" || warn "离线包安装失败,可稍后手动执行"
            else
                warn "worker ${hostname}(${ip}) 密码连接失败(检查 WORKER_SSH_PASSWORD 或节点第9字段)"
            fi
        else
            warn "worker ${hostname}(${ip}) 未配置密码,跳过连通性检查(可稍后补 config 后重跑)"
        fi
    done
    save_state "phase_worker" "done"
fi

# ============ Phase 5: 更新 /etc/hosts ============
if ! skip_if_done "phase_hosts"; then
    if [ "${UPDATE_ETC_HOSTS:-0}" = "1" ]; then
        say "[5/7] 更新 /etc/hosts(节点主机名解析) ..."
        for line in "${NODES[@]:-}"; do
            [ -z "${line}" ] && continue
            IFS=, read -r role hostname ip mac mem cpu disk user pw <<<"${line}"
            if ! grep -qE "[[:space:]]${hostname}([[:space:]]|\$)" /etc/hosts; then
                echo "${ip} ${hostname}" >> /etc/hosts
                ok "已添加 /etc/hosts: ${ip} ${hostname}"
            fi
        done
    else
        say "[5/7] 跳过 /etc/hosts 更新(配置 UPDATE_ETC_HOSTS=1 可启用)"
    fi
    save_state "phase_hosts" "done"
fi

# ============ Phase 6: 生成 inventory ============
if ! skip_if_done "phase_inventory"; then
    say "[6/7] 生成 kubespray 兼容 inventory ..."
    bash "${SCRIPT_DIR}/gen-inventory.sh"
    save_state "phase_inventory" "done"
fi

# ============ Phase 7: (可选) kubespray 离线部署 ============
if ! skip_if_done "phase_k8s"; then
    if [ "${WITH_K8S}" = "1" ]; then
        OFFLINE_SCRIPT="${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh"
        if [ -f "${OFFLINE_SCRIPT}" ]; then
            say "执行 kubespray 离线部署 (via cubestack-offline.sh) ..."
            CUBESTACK_CLUSTER="${CLUSTER_NAME}" \
            CUBESTACK_KUBESPRAY_DIR="${KUBESPRAY_DIR}" \
            CUBESTACK_INVENTORY_DIR="${KUBESPRAY_INV_DIR}" \
            CUBESTACK_LOCAL_REPO_DIR="${LOCAL_REPO_DIR}" \
                bash "${OFFLINE_SCRIPT}" install
            save_state "phase_k8s" "done"
        else
            warn "未找到 ${OFFLINE_SCRIPT}, 跳过 kubespray 部署"
        fi
    fi
fi

# ============ 汇总 ============
echo "============================================="
echo -e "\033[32m✅ 一键部署流程完成(集群: ${CLUSTER_NAME})\033[0m"
echo "  配置: ${CLUSTER_CONF}"
echo "  状态: $(is_state_completed "${PHASE_NAMES[@]}" && echo '全部完成' || echo '部分完成,可加 --fresh 重跑')"
echo "  下一步:"
echo "    1. deployments/scripts/verify-vm-network.sh          # 验证宿主网络"
echo "    2. sudo ./deployments/scripts/deploy-cluster.sh --with-k8s  # 执行 kubespray 部署"
echo "============================================="