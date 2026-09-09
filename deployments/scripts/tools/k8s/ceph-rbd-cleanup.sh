#!/bin/bash
# ============================================================
# TOOL: ceph-rbd-cleanup
# DESC: 清理节点上残留的内核 rbd 映射(集群重建/删除 ns 后遗留)
# 背景: 集群重建(fsid 变化)后, 旧集群的 CSI RBD 卷映射仍留在内核
#   (/sys/bus/rbd/devices/*), 但: ① 设备节点文件可能缺失(之前误删)
#   → kubelet 挂载点失效; ② 内核用旧集群 keyring 持续认证新集群
#   → 内核日志刷屏 "libceph: auth protocol 'cephx' authorization to
#   osd failed: -13"。挂载点仍在但对应 pod/PVC 早已删除 = 纯残留。
# 修复: 安全 unmap 全部残留 rbd 映射(保留在用卷, 如 registry-pvc),
#   清理失效 kubelet 挂载点残留。
# 用法(部署机/容器内, 需 SSH 密钥):
#   bash ceph-rbd-cleanup.sh                 # 清理全部节点残留 rbd 映射
#   bash ceph-rbd-cleanup.sh --list          # 只列出各节点 rbd 映射(不清理)
#   KEEP_VOLUME=<imageName> bash ...         # 额外保留某卷(逗号分隔)
# 数据源: cluster.conf (NODES / SSH_KEY_NAME / SSH_USER) + kubeconfig
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config
# ★ 统一远端初始化(幂等): 定义 FIRST_MASTER / SSH_KEY / SSH() / K
init_remote_kubectl || { err "init_remote_kubectl 失败(cluster.conf NODES 无 master?)"; exit 1; }

LIST_ONLY=0
[ "${1:-}" = "--list" ] && LIST_ONLY=1

# kubeconfig(供 kubectl 查 registry-pvc 卷名; 缺失则回退到 master 上 /etc/kubernetes/admin.conf)
KC="${KUBECONFIG:-}"
if [ -z "${KC}" ]; then
    KC="/opt/cubestack-installer/deployments/kubespray/inventory/cubestack-cluster/artifacts/admin.conf"
fi
[ -f "${KC}" ] || KC=""
KC_REMOTE="/etc/kubernetes/admin.conf"   # master 上固定路径(SSH 执行 kubectl 用)

# 需要保留的卷名(在用): 集群内全部 PV 的 CSI imageName。
#   本地有 kubeconfig 用本地; 否则经 SSH 用 master 的 /etc/kubernetes/admin.conf(sudo)。
KEEP_VOLS="${KEEP_VOLUME:-}"
_KC=""          # 本地 kubectl 前缀(容器/部署机)
_KC_REMOTE=""   # SSH 远程 kubectl 前缀(master 上, sudo)
if [ -n "${KC}" ] && [ -f "${KC}" ]; then
    _KC="kubectl --kubeconfig=${KC}"
fi
if SSH "test -f ${KC_REMOTE}" 2>/dev/null; then
    _KC_REMOTE="sudo kubectl --kubeconfig=${KC_REMOTE}"
fi
if [ -n "${_KC}" ]; then
    _img="$( (kubectl --kubeconfig="${KC}" get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeAttributes.imageName} ' 2>/dev/null || true) )"
    [ -n "${_img}" ] && KEEP_VOLS="${KEEP_VOLS:+${KEEP_VOLS},}${_img}"
fi
if [ -z "${KEEP_VOLS}" ] && [ -n "${_KC_REMOTE}" ]; then
    _img="$( (SSH "${_KC_REMOTE} get pv -o jsonpath={.items[*].spec.csi.volumeAttributes.imageName} 2>/dev/null" || true) )"
    [ -n "${_img}" ] && KEEP_VOLS="${KEEP_VOLS:+${KEEP_VOLS},}${_img// /,}"
fi
say "需保留的卷: ${KEEP_VOLS:-<无(将清理全部 rbd 映射)>}"
[ -n "${KEEP_VOLS}" ] && say "  (可用 KEEP_VOLUME=xxx,yyy 额外保留)"

keep_vol() {   # <imageName> → 0=保留
    local v="$1" k
    for k in ${KEEP_VOLS//,/ }; do
        [ "${k}" = "${v}" ] && return 0
    done
    return 1
}

# 列出某节点全部 rbd 映射: "id name pool"(逐行)
list_maps() {   # <ip>
    local ip="$1"
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${ip}" \
        "for d in /sys/bus/rbd/devices/*; do [ -e \"\$d\" ] || continue; echo \"\$(basename \$d) \$(cat \$d/name 2>/dev/null) \$(cat \$d/pool 2>/dev/null)\"; done" 2>/dev/null || true
}

# 清理单个节点
cleanup_node() {   # <ip>
    local ip="$1" maps line id name pool cleaned=0 mounted
    maps="$(list_maps "${ip}")"
    [ -n "${maps}" ] || { ok "  ${ip}: 无 rbd 映射"; return 0; }
    echo "  ${ip}:"
    while IFS= read -r line; do
        [ -z "${line}" ] && continue
        set -- ${line}
        id="$1"; name="$2"; pool="$3"
        # 保留在用卷
        if keep_vol "${name}"; then
            ok "    保留 ${name}(在用卷, id=${id})"
            continue
        fi
        # 该映射是否有有效挂载(kubelet 引用)
        mounted=""
        ssh -n -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${ip}" \
            "mount | grep -qE '[[:space:]]/dev/rbd${id}[[:space:]]' && echo yes || echo no" 2>/dev/null \
            && mounted="$(ssh -n -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${ip}" "mount | grep -qE '[[:space:]]/dev/rbd${id}[[:space:]]' && echo yes || echo no" 2>/dev/null)"
        if [ "${LIST_ONLY}" = "1" ]; then
            echo "    [残留] ${name}(id=${id}, pool=${pool}, mounted=${mounted:-?})"
            continue
        fi
        # 卸载挂载点(仅当 kubelet 挂载引用且设备被占用; 残留挂载点安全卸载)
        if [ "${mounted}" = "yes" ]; then
            ssh -n -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${ip}" \
                "sudo umount /dev/rbd${id} 2>/dev/null || true; for m in \$(mount | grep -E '[[:space:]]/dev/rbd${id}[[:space:]]' | awk '{print \$3}'); do sudo umount \"\$m\" 2>/dev/null || true; done; echo 卸载完成" 2>/dev/null || true
            warn "    ${name}(id=${id}): 已卸载挂载点"
        fi
        # unmap(经 sysfs, 设备节点缺失也有效)
        if ssh -n -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${ip}" \
            "sudo bash -c 'echo ${id} > /sys/bus/rbd/remove' 2>/dev/null" ; then
            ok "    ${name}(id=${id}): 已 unmap"
            cleaned=$((cleaned+1))
        else
            warn "    ${name}(id=${id}): unmap 失败(可能被内核占用, 可重启节点清除)"
        fi
    done <<< "${maps}"
    # 清理失效设备节点文件与空挂载目录(kubelet 残留)
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${ip}" \
        "sudo rm -f /dev/rbd* 2>/dev/null || true; sudo find /var/lib/kubelet/pods -path '*kubernetes.io~csi*' -type d -empty -delete 2>/dev/null || true" 2>/dev/null || true
    [ "${cleaned}" -gt 0 ] && ok "  ${ip}: 清理 ${cleaned} 个残留 rbd 映射" || true
}

# ---------------- main ----------------
if [ "${LIST_ONLY}" = "1" ]; then
    say "==== 各节点 rbd 映射清单 ===="
else
    say "==== 清理各节点残留 rbd 映射(保留在用卷) ===="
fi
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    [ -n "${NODE_IP}" ] || continue
    cleanup_node "${NODE_IP}"
done
echo "---------------------------------------------"
if [ "${LIST_ONLY}" = "1" ]; then
    say "以上为各节点 rbd 映射(非 --list 时清除 [残留] 标记的映射; 若 -13 仍刷屏且存在 mounted=yes 的残留, 对应节点需重启)"
else
    ok "rbd 残留清理完成(若 -13 仍在刷屏, 可能有个别映射被内核占用, 可重启对应节点)"
fi
