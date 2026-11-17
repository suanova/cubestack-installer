#!/bin/bash
# ============================================================
# 批量准备物理 GPU worker 节点(master VM 外的裸金属)
# 对每台 worker:
#   1. 用节点密码(NODES 第5字段显式密码或默认 SSH_DEFAULT_PASSWORD)注入 SSH 公钥(免密)
#   2. 检查节点前置包是否存在(不安装; 由 OS 镜像/运维预装)
#   3. 推送 /etc/hosts 节点解析(k8s-api.cubestack.io + 全节点)
# 用法: sudo ./prepare-workers.sh [--only <hostname>]
# 数据源: deployments/config/cluster.conf
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

ONLY=""
[ "${1:-}" = "--only" ] && ONLY="${2:-}"

# SSH 密钥: 优先 root 默认 id_rsa(物理 worker 已预配 root 免密), 回退当前选中密钥(SSH_KEY_NAME)
SSH_KEY_DIR="${SSH_KEY_DIR:-${REAL_HOME}/.ssh}"
SSH_KEY_NAME="${SSH_KEY_NAME:-cubestack_k8s}"
# 当前选中密钥(由 ensure_node_ssh_access / cluster.conf 决定; id_rsa 复用路径下为 id_rsa,
# kubespray inventory 也用同一把 —— 见 gen-inventory.sh 的 ansible_ssh_private_key_file)
SEL_KEY="${SSH_KEY_DIR}/${SSH_KEY_NAME}"
SEL_SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    case "${SEL_KEY}" in /root/*) SEL_SUDO="sudo" ;; esac
fi
if [ -f /root/.ssh/id_rsa ]; then
    PRIMARY_KEY="/root/.ssh/id_rsa"
    PRIMARY_SUDO="sudo"    # 读 root 密钥需 sudo
    vlog "worker 登录密钥: /root/.ssh/id_rsa (root)"
else
    PRIMARY_KEY="${SEL_KEY}"
    PRIMARY_SUDO="${SEL_SUDO}"
fi
SSH_KEY="${PRIMARY_KEY}"
SSH_SUDO="${PRIMARY_SUDO}"
KEY_PUB="${SSH_KEY}.pub"
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

[ -f "${SSH_KEY}" ] || { err "SSH 密钥不存在: ${SSH_KEY}, 先运行 gen-ssh-key.sh"; exit 1; }

# 宿主机解析块(与 sync-hosts.sh 一致)
# API_DOMAIN 的解析地址 = api_entry_ip()(kube-vip 已绑 → VIP, 未绑 → 首个 master),
# 不是 API_IP(那是"能通 NodePort 的节点 IP"语义, 见 lib-common 该函数说明)。
API_ENTRY_IP="$(api_entry_ip)" || exit 1
HOSTS_BLOCK="# >>> cubestack-cluster
${API_ENTRY_IP}          ${API_DOMAIN}"
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    HOSTS_BLOCK="${HOSTS_BLOCK}
${NODE_IP}     ${NODE_HOSTNAME}"
done
HOSTS_BLOCK="${HOSTS_BLOCK}
# <<< cubestack-cluster"

say "准备物理 GPU worker 节点(登录密钥: ${SSH_KEY}) ..."
COUNT=0
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    [ "${NODE_ROLE}" = "worker" ] || continue
    [ -z "${ONLY}" ] || [ "${NODE_HOSTNAME}" = "${ONLY}" ] || continue

    COUNT=$((COUNT + 1))
    say "── [${NODE_HOSTNAME}](${NODE_IP}) ──"
    # 每节点复位为主登录密钥(上个节点可能临时切到过选中密钥)
    SSH_KEY="${PRIMARY_KEY}"
    SSH_SUDO="${PRIMARY_SUDO}"
    SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

    # 1. 免密检测(root id_rsa / 当前选中密钥) → 并确保选中密钥公钥已在 authorized_keys
    if ${SSH_SUDO} timeout 5 ssh ${SSH_OPTS} -o BatchMode=yes "${NODE_USER}@${NODE_IP}" 'true' >/dev/null 2>&1; then
        ok "root id_rsa 免密登录 OK"
    elif [ "${SEL_KEY}" != "${SSH_KEY}" ] && [ -f "${SEL_KEY}" ] \
         && ${SEL_SUDO} timeout 5 ssh -i "${SEL_KEY}" -o BatchMode=yes \
                -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
                "${NODE_USER}@${NODE_IP}" 'true' >/dev/null 2>&1; then
        # 节点只授权了选中密钥(id_rsa / 自定义) → 切到该密钥, 不再走密码回退
        SSH_KEY="${SEL_KEY}"
        SSH_SUDO="${SEL_SUDO}"
        SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        ok "选中密钥 ${SSH_KEY_NAME} 免密登录 OK"
    else
        # root id_rsa 免密失败: 尝试密码注入 root id_rsa 公钥
        PWD="${NODE_PW:-}"
        [ -n "${PWD}" ] || { warn "免密失败且无密码,跳过 ${NODE_HOSTNAME}"; continue; }
        say "注入公钥(密码认证 ${NODE_USER}@${NODE_IP})..."
        # `|| true` + 空值护栏: 本机没有 root 公钥时 cat 非 0 → set -e 结束整个脚本(以前是
        # 静默死), 而现在会明确告知"没公钥可选、跳过这台"。
        PUBKEY="$(sudo cat /root/.ssh/id_rsa.pub 2>/dev/null || true)"
        [ -n "${PUBKEY}" ] || { warn "本机 /root/.ssh/id_rsa.pub 不存在, 无法注入公钥, 跳过 ${NODE_HOSTNAME}"; continue; }
        SSHPASS="${PWD}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            "${NODE_USER}@${NODE_IP}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '${PUBKEY}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" 2>/dev/null \
            && ok "root 公钥已注入" || { warn "公钥注入失败,跳过 ${NODE_HOSTNAME}"; continue; }
    fi

    # 1b. 确保**当前选中密钥**(SSH_KEY_NAME; 默认 cubestack_k8s, id_rsa 复用路径下为 id_rsa)
    #     已在 authorized_keys(kubespray inventory 用同一把密钥连接)。
    #     · 选中密钥已能免密登录 → 无需注入(它本就被 ensure_node_ssh_access 验证过);
    #     · .pub 缺失时从私钥导出(ssh-keygen -y), 不再因"只授权了 id_rsa/没有 id_rsa.pub"而中止。
    if [ -f "${SEL_KEY}" ] && ${SEL_SUDO} timeout 5 ssh -i "${SEL_KEY}" \
            -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 "${NODE_USER}@${NODE_IP}" 'true' >/dev/null 2>&1; then
        ok "${SSH_KEY_NAME} 免密已可用, 跳过公钥注入"
    else
        CSPUBKEY="$(${SEL_SUDO} cat "${SEL_KEY}.pub" 2>/dev/null \
            || ${SEL_SUDO} ssh-keygen -y -f "${SEL_KEY}" 2>/dev/null || true)"
        [ -n "${CSPUBKEY}" ] || { err "无法读取/导出选中密钥公钥: ${SEL_KEY}(先跑 gen-ssh-key/vm_sshkey)"; exit 1; }
        say "注入 ${SSH_KEY_NAME} 公钥(幂等)..."
        ${SSH_SUDO} ssh ${SSH_OPTS} -o BatchMode=yes "${NODE_USER}@${NODE_IP}" \
            "sed -i '/cubestack-cluster/d' ~/.ssh/authorized_keys 2>/dev/null; echo '${CSPUBKEY}' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys" 2>/dev/null \
            && ok "${SSH_KEY_NAME} 公钥已就绪" || warn "${SSH_KEY_NAME} 公钥注入失败"
    fi

    # 2. 节点前置包检查(不安装; 缺包由运维按清单处理)
    say "检查节点前置包..."
    bash "${SCRIPT_DIR}/tools/online/check-os-packages.sh" \
        --baseline "${REPO_ROOT}/versions/base.yaml" \
        --hosts "${NODE_USER}@${NODE_IP}" --key "${SSH_KEY}" --warn-only || true

    # 3. 推送 /etc/hosts
    say "更新 /etc/hosts ..."
    # 先删旧块 + 旧裸条目(nova-k8s-*/node-*/k8s-api.nova.local / k8s-api.cubestack.io), 再追加新块 → 主机名不重复
    ${SSH_SUDO} timeout 30 ssh ${SSH_OPTS} "${NODE_USER}@${NODE_IP}" "sudo bash -c '
        sed -i \"/# >>> cubestack-cluster/,/# <<< cubestack-cluster/d\" /etc/hosts
        sed -i -E \"/nova-k8s-(master|node)/d; /node-[0-9]/d; /k8s-api\\\\.(nova\\\\.local|cubestack\\\\.io)/d\" /etc/hosts
        echo \"${HOSTS_BLOCK}\" >> /etc/hosts
    '" 2>&1 && ok "hosts 已更新" || warn "hosts 更新失败"
    vlog "  校验: ${NODE_USER}@${NODE_IP} hostname = $(${SSH_SUDO} ssh ${SSH_OPTS} -o BatchMode=yes "${NODE_USER}@${NODE_IP}" 'hostname' 2>/dev/null)"
done

[ "${COUNT}" -eq 0 ] && { warn "未处理任何 worker 节点"; exit 1; }
ok "物理 worker 准备完成: ${COUNT} 台"