#!/bin/bash
# ============================================================
# MODULE: k8s_passwordless
# DESC: 配置节点 SSH 免密(对所有节点注入公钥, 幂等; 不区分虚拟机/裸金属)
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# 说明: 主程序不判断虚拟机/裸金属 — 对 cluster.conf NODES 中全部节点执行公钥注入
#       (密码 = 节点独立密码或默认 SSH_DEFAULT_PASSWORD); 支持 --only 过滤
#       节点用户为 root 时附 sudo 存在性预检(root 安装模式; 缺 sudo 明确报错并给指引)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

say "配置节点 SSH 免密(全部节点, 不区分虚拟机/裸金属) ..."
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
FAILED=0
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    node_matches "${NODE_HOSTNAME}" || continue

    # 不再按"是否配置密码"预先跳过: 工具会先验证密钥是否**已经可用**(幂等重跑常见),
    # 只有密钥不通时才回退密码; 密码为空且密钥不通时同样给出明确错误。
    say "  ${NODE_HOSTNAME}(${NODE_IP}, user=${NODE_USER}) 注入公钥 ..."
    if ! SSH_DEFAULT_PASSWORD="${NODE_PW}" \
        bash "${SCRIPT_DIR}/tools/node/setup-passwordless.sh" "${NODE_IP}" "${NODE_USER}"; then
        err "  ${NODE_HOSTNAME}(${NODE_IP}) SSH 免密配置失败(原因见上)"
        FAILED=1
        continue
    fi

    # root 用户预检(2026-10-15, SSH_USER=root 支持): root 登录时, 远端命令仍大量经 sudo 提权
    # (root 执行 sudo 免密) —— 节点缺 sudo 会让后续部署在各种远端命令处零散失败, 报错点离真因远。
    # 仅在此节点**免密已可用**时检查(密钥不通已在上面的失败分支覆盖, 不误报到 sudo 上)。
    if [ "${NODE_USER}" = "root" ] \
       && ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${NODE_USER}@${NODE_IP}" 'true' 2>/dev/null; then
        if ! ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
               "${NODE_USER}@${NODE_IP}" 'command -v sudo >/dev/null 2>&1' 2>/dev/null; then
            err "  ${NODE_HOSTNAME}(${NODE_IP}) 未安装 sudo —— root 模式下部署的远端管理命令仍经 sudo 提权"
            err "  修复(二选一): ① 节点安装 sudo(apt-get install -y sudo / yum install -y sudo)后重跑;"
            err "                ② 改用 sudo SSH_USER=ubuntu ./deploy-cluster.sh(或 cluster.conf 改 SSH_USER)"
            exit 1
        fi
        vlog "  ${NODE_HOSTNAME} root 预检通过(sudo 可用)"
    fi
done
if [ "${FAILED}" -ne 0 ]; then
    err "SSH 免密未全部就绪 —— 后续模块都依赖免密 SSH, 已中止部署"
    err "  处置: 核对 cluster.conf 的 SSH_DEFAULT_PASSWORD(或 NODES 行节点密码)与目标 sshd 密码登录开关;"
    err "        修正后可单跑复核: sudo ./deploy-cluster.sh --steps k8s_passwordless"
    exit 1
fi
ok "SSH 免密配置完成"
