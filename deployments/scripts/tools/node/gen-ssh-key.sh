#!/bin/bash
# 生成集群 SSH 密钥对(幂等,已存在则跳过)
# 用法: ./gen-ssh-key.sh [--quiet]
#   --quiet: 只生成/检查密钥, 不打印私钥/公钥路径与公钥内容(部署流程内部调用用)。
# 数据源: config/cluster.conf (SSH_KEY_DIR / SSH_KEY_NAME)
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

SSH_KEY_DIR="${SSH_KEY_DIR:-${HOME}/.ssh}"
SSH_KEY_NAME="${SSH_KEY_NAME:-cubestack_k8s}"
SSH_KEY="${SSH_KEY_DIR}/${SSH_KEY_NAME}"

# ★ 已存在的 key 直接复用(issue #196): 只读挂载($HOME/.ssh:/root/.ssh:ro)下 mkdir/chmod
#   会以 "Read-only file system" 失败并把安装打断 —— 但 key 本身已经完全可用。
#   故先把"是否需要生成"判定放在任何写入/改权限之前; 只有确实要生成时才动目录权限。
if [ -f "${SSH_KEY}" ]; then
    # 目录权限收敛尽力而为: 只读挂载下失败无妨, 可写目录上仍要防止 group/world-writable。
    chmod 700 "${SSH_KEY_DIR}" 2>/dev/null || true
    # 私钥在、公钥缺失时下游 setup-passwordless.sh 会硬失败且重跑也修不好 —— 这里从私钥重建。
    if [ ! -s "${SSH_KEY}.pub" ]; then
        if [ -w "${SSH_KEY_DIR}" ] && ssh-keygen -y -f "${SSH_KEY}" > "${SSH_KEY}.pub" 2>/dev/null; then
            chmod 644 "${SSH_KEY}.pub" 2>/dev/null || true
            [ "${QUIET}" = "0" ] && say "已从私钥重建公钥: ${SSH_KEY}.pub"
        else
            # 只读挂载上 rm 会失败; 清理是 best-effort, 不能让它抢在错误提示前退出(set -e)。
            rm -f "${SSH_KEY}.pub" 2>/dev/null || true
            err "私钥存在但公钥缺失/无法重建: ${SSH_KEY}.pub"
            err "  在宿主机执行: ssh-keygen -y -f ${SSH_KEY} > ${SSH_KEY}.pub, 或挂载可写目录后重跑"
            exit 1
        fi
    fi
    [ "${QUIET}" = "0" ] && ok "密钥已存在: ${SSH_KEY} (跳过生成)"
else
    # 目录不存在则创建; 只读挂载时 mkdir -p 对已存在目录是 no-op, 不会失败。
    if ! mkdir -p "${SSH_KEY_DIR}" 2>/dev/null; then
        err "SSH 密钥目录不存在且无法创建: ${SSH_KEY_DIR}"
        exit 1
    fi
    # chmod 失败不阻断: 只读挂载/非属主时改不了权限, 但目录可写就还能生成 key。
    chmod 700 "${SSH_KEY_DIR}" 2>/dev/null \
        || warn "无法修改 ${SSH_KEY_DIR} 权限(只读挂载?); 继续尝试生成密钥"
    if [ ! -w "${SSH_KEY_DIR}" ]; then
        err "密钥 ${SSH_KEY} 不存在, 且目录 ${SSH_KEY_DIR} 不可写 —— 无法生成"
        err "  修法: 把宿主机可写目录挂进容器(如 -v \$PWD/.ssh:/root/.ssh), 或预先放好密钥"
        err "       并挂载为只读(-v \$HOME/.ssh:/root/.ssh:ro)后重跑"
        exit 1
    fi
    [ "${QUIET}" = "0" ] && say "生成 SSH 密钥对(ed25519, 无口令) ..."
    if ! ssh-keygen -t ed25519 -N "" -C "cubestack-cluster" -f "${SSH_KEY}" >/dev/null 2>&1; then
        err "SSH 密钥生成失败: ${SSH_KEY}"
        err "  目录 ${SSH_KEY_DIR} 是否只读 / 磁盘是否已满? 只读挂载时请预先放好密钥再挂载"
        exit 1
    fi
    chmod 600 "${SSH_KEY}" 2>/dev/null || true
    [ "${QUIET}" = "0" ] && ok "已生成: ${SSH_KEY}"
fi

if [ "${QUIET}" = "0" ]; then
    echo "  私钥: ${SSH_KEY}"
    echo "  公钥: ${SSH_KEY}.pub"
    echo "  公钥内容:"
    cat "${SSH_KEY}.pub"
fi
