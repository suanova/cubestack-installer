#!/bin/bash
# ============================================================
# TOOL: ceph-cleanup
# DESC: 幂等卸载 Ceph + 磁盘恢复原始状态(标准 Ceph 卸载流程: 优雅移除 OSD → 物理擦除 → 软件残留清理)
# 背景/参考:
#   · 标准流程: ① ceph osd out/purge(集群可达) ② 停止进程 + 解除 LVM/dm-mapper + wipefs/sgdisk/dd
#     ③ 清理 /var/lib/ceph /etc/ceph 等 ④ 重装。本工具自动化上述, 幂等可重复执行。
#   · Rook 场景: 删除 CephCluster(cleanupPolicy yes-really-destroy-data)由 Rook 擦盘;
#     若 Rook/operator 已不在(k8s 重装中)→ 直接跳到物理擦除(第二阶段)。
# 支持场景:
#   · 场景① 重装 K8s+Ceph: k8s 重装时 rook ns 已清 → --wipe-node 强制清盘即可;
#   · 场景② 只重装 Ceph(K8s 保留): --all 先删 CephCluster(operator 擦盘)再逐节点清盘。
# 用法(部署机/容器内, 需 SSH 密钥):
#   ceph-cleanup.sh --delete-cluster                    # 仅删除 CephCluster CR(等 Rook 擦盘, 最长 300s)
#   ceph-cleanup.sh --wipe-node <ip> --disks "/dev/vdb,/dev/vdc"   # 清理单个节点磁盘(LVM/dm/签名/分区表)
#   ceph-cleanup.sh --all                               # 全流程: 删集群(若在) + 全部存储节点清盘
# 数据源: cluster.conf (NODES / CEPH_NODES / CEPH_NAMESPACE / SSH_USER)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config
init_remote_kubectl || { err "init_remote_kubectl 失败(cluster.conf NODES 无 master?)"; exit 1; }

CEPH_NAMESPACE="${CEPH_NAMESPACE:-rook-ceph}"

# ---------------- 工具: 节点 SSH ----------------
node_cmd() {   # <ip> <user> <cmd...>
    local ip="$1" user="$2"; shift 2
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
        "${user}@${ip}" "$@"
}

# ---------------- ① 删除现有 CephCluster(Rook 擦盘) ----------------
delete_cluster() {
    say "删除现有 CephCluster(cleanupPolicy yes-really-destroy-data, Rook 擦盘)..."
    # 幂等: 无集群直接成功
    _exists="$( (SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster --no-headers 2>/dev/null" || true) )"
    [ -z "${_exists}" ] && { ok "  无现有 CephCluster, 跳过"; return 0; }
    # ★ 2026-09-05 事故预防: 删除集群前先清 ceph-block PVC 并删 rbd nodeplugin DaemonSet。
    #   若直接删 CephCluster, nodeplugin 随之被删 → 节点上内核 rbd 映射无人 unmap →
    #   [rbd0-tasks] 内核线程持锁残留 → sysfs remove 被拒(EACCES) → libceph cephx -13
    #   刷屏, 只能重启节点。正确顺序: 先让 CSI 正常 unmap 卷, 再删集群。
    say "  ① 删除使用 ceph-block 的 PVC(触发 CSI unmap)..."
    SSH "${K} get pvc -A -o json 2>/dev/null" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    for pvc in d.get("items", []):
        sc = pvc.get("spec", {}).get("storageClassName", "")
        if "ceph" in sc:
            ns, name = pvc["metadata"]["namespace"], pvc["metadata"]["name"]
            print(f"{ns}/{name}")
except Exception:
    pass
' | while read -r pvc; do
        [ -z "${pvc}" ] && continue
        say "     删除 PVC ${pvc}(数据将销毁)..."
        SSH "${K} -n ${pvc%/*} delete pvc ${pvc#*/} --wait=false >/dev/null 2>&1" || true
    done
    say "  ② 删除 rbd csi nodeplugin DaemonSet(各节点执行内核 rbd unmap)..."
    SSH "${K} -n ${CEPH_NAMESPACE} delete ds rook-ceph.rbd.csi.ceph.com-nodeplugin --wait=false >/dev/null 2>&1" || true
    sleep 5
    SSH "${K} -n ${CEPH_NAMESPACE} patch cephcluster rook-ceph --type merge \
        -p '{"spec":{"cleanupPolicy":{"confirmation":"yes-really-destroy-data"}}}' >/dev/null 2>&1" || true
    SSH "${K} -n ${CEPH_NAMESPACE} delete cephblockpool --all --wait=false >/dev/null 2>&1" || true
    SSH "${K} -n ${CEPH_NAMESPACE} delete cephcluster rook-ceph --wait=false >/dev/null 2>&1" || true
    _gone=0
    for _i in $(seq 1 60); do
        _still="$( (SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster --no-headers 2>/dev/null" || true) )"
        [ -z "${_still}" ] && { _gone=1; break; }
        sleep 5
    done
    if [ "${_gone}" = "1" ]; then
        ok "  CephCluster 已删除(Rook 已擦盘)"
        return 0
    fi
    warn "  CephCluster 删除超时(300s, Rook operator 可能不在 → 需物理擦除兜底)"
    return 1
}

# ---------------- ② 清理单个节点磁盘(物理擦除, 幂等) ----------------
wipe_node() {   # <ip> <disks: "/dev/vdb,/dev/vdc">
    local ip="$1" disks="$2" user="${SSH_USER:-ubuntu}"
    [ -n "${disks}" ] || { warn "  ${ip}: 无盘列表, 跳过"; return 1; }
    say "  清理 ${ip} 磁盘到原始状态(LVM/dm-mapper/签名/分区表/bluestore 标签)..."
    local script
    script="$(cat <<'WIPESCRIPT'
set -e
# 1) 停止可能占用磁盘的 ceph 残留进程
pkill -f "ceph-osd" 2>/dev/null || true
pkill -f "ceph-mon" 2>/dev/null || true
pkill -f "ceph-mgr" 2>/dev/null || true
pkill -f "ceph-volume" 2>/dev/null || true
sleep 1
# 2) 解除 LVM(残留 ceph VG/LV)
for lv in $(lvs --noheadings -o lv_path 2>/dev/null | grep -i ceph | tr -d ' '); do
    lvremove -f "$lv" 2>/dev/null || true
done
for vg in $(vgs --noheadings -o vg_name 2>/dev/null | grep -iE 'ceph|rbd'); do
    vgremove -f "$vg" 2>/dev/null || true
done
# 3) 解除 device-mapper 映射
for dm in $(dmsetup ls 2>/dev/null | awk '{print $1}' | grep -iE 'ceph|rbd'); do
    dmsetup remove -f "$dm" 2>/dev/null || true
done
dmsetup remove_all -f 2>/dev/null || true
# 4) 擦除磁盘签名 + 分区表 + bluestore 标签(头/尾 + label 双位置)
for dev in __DISKS__; do
    [ -b "$dev" ] || continue
    wipefs -a -f "$dev" 2>/dev/null || true
    sgdisk --zap-all "$dev" 2>/dev/null || true
    dd if=/dev/zero of="$dev" bs=1M count=100 conv=fsync status=none 2>/dev/null || true
    SZ=$(lsblk -b -o SIZE "$dev" 2>/dev/null | tail -1); SM=$((SZ/1048576))
    if [ -n "${SM:-}" ] && [ "$SM" -gt 200 ]; then
        dd if=/dev/zero of="$dev" bs=1M seek=$((SM-100)) count=100 conv=fsync status=none 2>/dev/null || true
        dd if=/dev/zero of="$dev" bs=1M seek=$((SM/20)) count=64 conv=fsync status=none 2>/dev/null || true
        dd if=/dev/zero of="$dev" bs=1M seek=$((SM/2)) count=64 conv=fsync status=none 2>/dev/null || true
    fi
    partprobe "$dev" 2>/dev/null || true
done
# 5) 清理 Rook/Ceph 数据目录 + 残留 rbd 设备
rm -rf /var/lib/rook /var/lib/ceph /etc/ceph /run/ceph 2>/dev/null || true
rm -f /dev/rbd* 2>/dev/null || true
udevadm settle 2>/dev/null || true
# 6) ★ 内核 rbd 映射残留检测(2026-09-05 事故预防): 即使磁盘清空, 内核 rbd 映射
#    ([rbd0-tasks] 线程持锁)仍在时, sysfs remove 会被 EACCES 拒绝, 且 libceph 持续
#    cephx -13 刷屏, 只能重启节点清除。此处检测并明确提示, 不再静默继续。
echo "--- 内核 rbd 映射检测 ---"
RBD_N=0
for d in /sys/bus/rbd/devices/*; do
    [ -d "$d" ] || continue
    RBD_N=$((RBD_N+1))
    echo "残留 rbd 映射: $(cat $d/name 2>/dev/null) (pool=$(cat $d/pool 2>/dev/null))"
done
if [ "$RBD_N" -gt 0 ]; then
    echo "!! 检测到 $RBD_N 个内核 rbd 映射残留: sysfs remove 被持锁拒绝, 必须重启本节点清除"
    echo "!! (否则 libceph 持续 cephx 认证失败刷屏; 重启后重跑本清理即可)"
    exit 9
fi
echo "--- 验证目标盘 FSTYPE/挂载(应全空) ---"
for dev in __DISKS__; do
    [ -b "$dev" ] || continue
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT "$dev" 2>/dev/null | tail -1
done
echo "--- 验证完成(上述 FSTYPE 列应均为空; 若 ceph_bluestore 残留说明 dd 未覆盖 label 位置, 手工 dd 头/尾) ---"
WIPESCRIPT
)"
    script="${script//__DISKS__/${disks//,/ }}"
    node_cmd "${ip}" "${user}" "sudo bash -s" <<< "${script}" \
        && ok "  ${ip} 磁盘已恢复原始状态" \
        || { warn "  ${ip} 磁盘清理失败(见上方输出; 常见: 盘被占用 lsof /dev/sdX 找进程 kill 后重试)"; return 1; }
}

# ---------------- ③ 全流程: 删集群 + 全部存储节点清盘 ----------------
cleanup_all() {
    delete_cluster || true
    # 收集存储节点(CEPH_NODES 显式 或 全部 NODES)
    local hosts=() _h
    if [ -n "${CEPH_NODES:-}" ]; then
        for _h in ${CEPH_NODES//,/ }; do hosts+=("${_h}"); done
    else
        for line in "${NODES[@]:-}"; do
            [ -z "${line}" ] && continue
            node_parse "${line}"
            hosts+=("${NODE_HOSTNAME}")
        done
    fi
    for _h in "${hosts[@]:-}"; do
        local _ip="" _user="${SSH_USER:-ubuntu}"
        for line in "${NODES[@]:-}"; do
            [ -z "${line}" ] && continue
            node_parse "${line}"
            [ "${NODE_HOSTNAME}" = "${_h}" ] && { _ip="${NODE_IP}"; _user="${NODE_USER}"; break; }
        done
        [ -n "${_ip}" ] || continue
        # 自动检测该节点裸盘(排除系统盘)
        _disks="$(bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ceph-detect-disks.sh" --node "${_h}" -m 2>/dev/null | sed -n "s/^${_h}://p" )"
        wipe_node "${_ip}" "${_disks%,}" || true
    done
    ok "Ceph 卸载 + 磁盘清理完成(可重新安装)"
}

# ---------------- main ----------------
ACTION="${1:-}"
case "${ACTION}" in
    --delete-cluster) delete_cluster ;;
    --wipe-node)      WIPE_IP="${2:-}"; WIPE_DISKS="${4:-}"; [ -n "${WIPE_IP}" ] && [ -n "${WIPE_DISKS}" ] \
                        && wipe_node "${WIPE_IP}" "${WIPE_DISKS}" || { err "用法: ceph-cleanup.sh --wipe-node <ip> --disks \"/dev/vdb,/dev/vdc\""; exit 1; } ;;
    --all)            cleanup_all ;;
    *) echo "用法: $0 {--delete-cluster | --wipe-node <ip> --disks \"...\" | --all}"; exit 1 ;;
esac
