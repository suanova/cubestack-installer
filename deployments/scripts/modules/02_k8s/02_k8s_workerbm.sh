#!/bin/bash
# ============================================================
# MODULE: k8s_workerbm
# DESC: worker 节点离线包安装(默认关, WORKER_PKGS_ENABLED=true 启用)
# PHASE: k8s
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: WORKER_PKGS_ENABLED
# REQUIRES: k8s_passwordless pre_install_check
# 说明: 主程序不判断虚拟机/裸金属 — 对 cluster.conf NODES 中全部 worker 执行:
#       免密连通检测(已在 k8s_passwordless 注入公钥)→ 离线系统包安装(幂等)
#   · **默认关闭(2026-11-18)**: 节点前置包由 OS 黄金镜像/运维预装, installer 不安装
#     OS 包。默认的 SSH/sudo/资源检查由 pre_install_check 覆盖。
#   · 启用三选一: cluster.conf 置 WORKER_PKGS_ENABLED=true / --enable k8s_workerbm /
#     --steps k8s_workerbm。启用后从 offline-files/os/packages 取 .deb 安装。
#   · 开关在模块内自检(而非只靠调度): k8s_scale 扩容时会**直接调用本脚本**给新 worker
#     装包, 也必须受同一开关控制。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# 开关自检(含 k8s_scale 直接调用的路径; --steps/--enable 会由 deploy-cluster 导出 true)
case "$(printf '%s' "${WORKER_PKGS_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) ;;
    *) say "WORKER_PKGS_ENABLED=false, 跳过 worker 离线装包(需要时置 true 或 --steps k8s_workerbm)"; exit 0 ;;
esac

say "worker 节点连通性检查 + 离线包安装(全部 worker, 不区分虚拟机/裸金属) ..."
PKG_FAIL=0
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    [ "${NODE_ROLE}" = "worker" ] || continue
    node_matches "${NODE_HOSTNAME}" || continue

    # 免密连通检测(公钥已在 k8s_passwordless 注入; 失败则提示)
    SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
    if ! ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes -o ConnectTimeout=8 "${NODE_USER}@${NODE_IP}" 'true' >/dev/null 2>&1; then
        if [ -z "${NODE_PW}" ]; then
            warn "worker ${NODE_HOSTNAME}(${NODE_IP}) 免密不可达且未配置密码, 跳过(检查 k8s_passwordless 与 SSH_DEFAULT_PASSWORD/节点独立密码)"
            continue
        fi
        if ! SSHPASS="${NODE_PW}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=8 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            "${NODE_USER}@${NODE_IP}" 'hostname' >/dev/null 2>&1; then
            warn "worker ${NODE_HOSTNAME}(${NODE_IP}) 免密/密码均不可达, 跳过(检查网络与密码)"
            continue
        fi
        warn "worker ${NODE_HOSTNAME}(${NODE_IP}) 免密不可达但密码连通(公钥未注入?), 继续尝试装包"
    fi
    ok "worker ${NODE_HOSTNAME}(${NODE_IP}) 连通(user=${NODE_USER})"

    # sudo 前置: install-worker-packages.sh 只用 `ssh ... sudo`(没有密码回退); 非 root
    # 且无 NOPASSWD 时会在 dpkg 阶段才报 "sudo: a password is required", 容易误判成包问题。
    if [ "${NODE_USER}" != "root" ] && ! ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes -o ConnectTimeout=8 "${NODE_USER}@${NODE_IP}" 'sudo -n true' >/dev/null 2>&1; then
        warn "worker ${NODE_HOSTNAME}(${NODE_IP}) sudo 不可用(user=${NODE_USER}) —— 请设 SSH_USER=root,"
        warn "  或在节点配置 sudoers: echo '${NODE_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-cubestack"
        PKG_FAIL=1
        continue
    fi

    # 安装离线包
    say "安装离线包到 worker ${NODE_HOSTNAME}(${NODE_IP}) ..."
    if ! bash "${SCRIPT_DIR}/tools/node/install-worker-packages.sh" "${NODE_IP}" "${NODE_USER}"; then
        warn "离线包安装失败: worker ${NODE_HOSTNAME}(${NODE_IP})"
        PKG_FAIL=1
    fi
done
if [ "${PKG_FAIL}" -ne 0 ]; then
    err "worker 离线包安装存在失败节点; 修复后重跑 --steps k8s_workerbm"
fi
ok "worker 节点离线包安装完成"
