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
        # ★ 2026-09-24: 原来这条 ssh 被**写了两遍**(先判断、再把同一条命令塞进 `mounted="$(...)"`,
        #   且赋值处在 `A && B` 的末位 —— B 失败时 set -e 会直接结束脚本)。合并成一次取值 + `|| true`。
        mounted="$(ssh -n -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${ip}" \
            "mount | grep -qE '[[:space:]]/dev/rbd${id}[[:space:]]' && echo yes || echo no" 2>/dev/null || true)"
        if [ "${LIST_ONLY}" = "1" ]; then
            echo "    [残留] ${name}(id=${id}, pool=${pool}, mounted=${mounted:-?})"
            continue
        fi
        # 卸载挂载点(仅当 kubelet 挂载引用且设备被占用; 残留挂载点安全卸载)
        if [ "${mounted}" = "yes" ]; then
            # ⚠ 卸载改**惰性(setsid umount -l)且后台化、不等待**(2026-10-10): 后端已死时正规
            #   umount 会卡在"日志回写死设备"(永久 D 态不可杀) —— 与 k8s 清理处同一事故类。
            #   惰性脱挂只做命名空间脱开, 后台进程即便 D 也只是惰性残留; 本步随之立即返回。
            timeout 30 ssh -n -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${ip}" \
                "sudo bash -c 'mount | grep /dev/rbd${id} | while read -r _d _on m _rest; do setsid umount -l \"\$m\" >/dev/null 2>&1 & done' ; echo 卸载已发起（惰性后台, 不等待）" 2>/dev/null || true
            warn "    ${name}(id=${id}): 已发起惰性卸载(后台)"
        fi
        # unmap(经 sysfs, 设备节点缺失也有效)
        # 两套 sysfs remove 接口均接收设备 ID(rbd0 → 0); 按序尝试。
        #   设备目录已不存在 = 映射本来就没有 → 幂等视为成功。
        # ⚠ 改为**后台不等待 + 有界复核**(2026-10-10 实机): 后端已死时 sysfs remove 的**写调用
        #   本身会永久 D 态**(worker .41 实测, 不可杀) —— 同步等待 = 部署无限挂。后台执行后
        #   有界复核(≤10s): 设备目录消失=成功; 超时=告警放行(残映射仅造成 -13 日志刷屏,
        #   不影响新集群; 择机重启清零)。
        if timeout 30 ssh -n -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${ip}" \
            "sudo bash -c '
                [ -d /sys/bus/rbd/devices/${id} ] || exit 0
                setsid bash -c \"echo ${id} > /sys/bus/rbd/remove_single_major 2>/dev/null || echo ${id} > /sys/bus/rbd/remove 2>/dev/null\" >/dev/null 2>&1 &
                for _i in 1 2 3 4 5 6 7 8 9 10; do
                    [ -d /sys/bus/rbd/devices/${id} ] || exit 0
                    sleep 1
                done
                exit 1' 2>/dev/null" ; then
            ok "    ${name}(id=${id}): 已 unmap"
            cleaned=$((cleaned+1))
        else
            warn "    ${name}(id=${id}): unmap 未完成(后端已死时 sysfs 写会阻塞; 已后台化不再等待 —— 残映射无碍新集群, 择机重启清零)"
        fi
    done <<< "${maps}"
    # 清理失效设备节点文件与空挂载目录(kubelet 残留)
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${ip}" \
        "sudo rm -f /dev/rbd* 2>/dev/null || true; sudo find /var/lib/kubelet/pods -path '*kubernetes.io~csi*' -type d -empty -delete 2>/dev/null || true" 2>/dev/null || true
    # ★ 2026-10-10 收尾阶梯(仅清理模式): 该节点映射清完后尝试**模块级卸载**(连客户端
    #   会话/-13 刷屏一起清); 仍有残留 → 计全局账(总账在 main 末尾的洁净度报告)。
    if [ "${LIST_ONLY}" != "1" ]; then
        _left="$(ssh -n -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${ip}" \
            "ls /sys/bus/rbd/devices 2>/dev/null | wc -l" 2>/dev/null || true)"
        _left="${_left//[!0-9]/}"
        _left="${_left:-0}"
        _TOTAL_CLEANED=$(( ${_TOTAL_CLEANED:-0} + cleaned ))
        if [ "${_left}" = "0" ]; then
            ssh -n -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${ip}" \
                "sudo modprobe -r rbd 2>/dev/null; sudo modprobe -r libceph 2>/dev/null; true" >/dev/null 2>&1 || true
            ok "    ${ip}: rbd/libceph 模块已卸载(内核态清零)"
        else
            _TOTAL_LEFT=$(( ${_TOTAL_LEFT:-0} + _left ))
            warn "    ${ip}: 仍有 ${_left} 个内核 rbd 映射(sysfs 被拒/模块卸载 EBUSY = 内核持锁)"
        fi
    fi
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
    echo "  ▍内核洁净度报告(阶梯: 惰性脱挂 → sysfs 后台清理 → 模块卸载)"
    echo "     本轮已清映射: ${_TOTAL_CLEANED:-0} 个"
    if [ "${_TOTAL_LEFT:-0}" -eq 0 ] 2>/dev/null; then
        ok "rbd 残留清理完成: 全部节点内核 rbd 侧已清零(映射=0)"
    else
        warn "rbd 残留清理完成, 但**仍有 ${_TOTAL_LEFT:-?} 个内核 rbd 映射**(内核持锁, 物理所限)"
        warn "  影响: 仅致 libceph -13 日志刷屏, 无碍新集群数据面 —— 部署可继续"
        warn "  想彻底清零: 对相应节点**硬复位**后重跑本工具(⚠ 优雅重启会卡在 sync; 用 sysrq-b / reboot -f / virsh reset)"
    fi
fi
