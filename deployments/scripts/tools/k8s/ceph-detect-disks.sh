#!/bin/bash
# ============================================================
# ceph-detect-disks.sh — 自动检测各节点的"未使用裸盘"(供 Ceph/Rook OSD 用)
# 判定"未使用裸盘": 整块 disk 未被分区/格式化/挂载/作 LVM PV, 且非系统盘
#   (系统盘 = 持有 / 、/boot*、swap、LVM 的盘; 绝不被选中)。
# 输出: 每节点一行 `hostname:/dev/vdb,/dev/vdc`(可 -m 仅机器可读);
#       供 modules/03_addon/07_ceph.sh 生成 CephCluster CR(按节点精确 devices, 防误选)。
# 用法: sudo ./ceph-detect-disks.sh [--node <hostname|ip> ...] [-m]
# 数据源: cluster.conf (NODES / SSH_KEY_NAME / CEPH_DETECT_EXCLUDE)
# 前置: 节点 SSH 免密(部署 k8s_passwordless 后)。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

MACHINE=0
NODE_FILTER=()
while [ $# -gt 0 ]; do
    case "$1" in
        --node) NODE_FILTER+=("$2"); shift 2 ;;
        -m|--machine) MACHINE=1; shift ;;
        *) err "未知参数: $1(用法: --node <hostname|ip>...  / -m)"; exit 1 ;;
    esac
done

CEPH_DETECT_EXCLUDE="${CEPH_DETECT_EXCLUDE:-^(sda|sr0|vda)$}"
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
[ -f "${SSH_KEY}" ] || { err "SSH 密钥不存在: ${SSH_KEY}(先 gen-ssh-key.sh + k8s_passwordless)"; exit 1; }

# 远端 lsblk 仅需读权限; 名称取相对名(vdb), 避免 /dev/mapper 等路径干扰
NODE_SELECT=()
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    if [ "${#NODE_FILTER[@]}" -gt 0 ]; then
        _hit=0
        for _f in "${NODE_FILTER[@]}"; do
            { [ "${NODE_HOSTNAME}" = "${_f}" ] || [ "${NODE_IP}" = "${_f}" ]; } && _hit=1
        done
        [ "${_hit}" = "1" ] || continue
    fi
    NODE_SELECT+=("${NODE_HOSTNAME}|${NODE_IP}|${NODE_USER}")
done
[ "${#NODE_SELECT[@]}" -gt 0 ] || { err "未匹配到任何节点(检查 NODES / --node)"; exit 1; }

parse_remote() {   # stdin=lsblk -J JSON → 输出未使用裸盘名(空格分隔, 已排除系统盘/EXCLUDE)
    python3 - "${CEPH_DETECT_EXCLUDE}" <<'PY'
import json, sys, re
excl = re.compile(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1] else None
data = json.load(sys.stdin)
blocks = data.get('blockdevices', [])

# 1) 收集系统盘: 持有 /、/boot*、[SWAP] 挂载点的设备, 向上回溯到顶层 disk;
#    以及含 LVM 子卷(child 中 type=lvm)的 disk。
def walk(b, parent=None):
    """yield (name, type, fstype, mount, children, parent_disk)"""
    top = parent if parent else b['name']
    yield (b['name'], b.get('type'), b.get('fstype'), b.get('mountpoint'), b.get('children'), top if b.get('type')=='disk' else None)
    for c in b.get('children', []) or []:
        # children 的父盘 = 顶层盘名(若父是分区链, 保持祖先 disk)
        yield from walk(c, parent=top if b.get('type')=='disk' else parent)

flat = [r for b in blocks for r in walk(b)]
system = set()
for (name, typ, fstype, mnt, kids, top) in flat:
    if mnt and (mnt == '/' or mnt == '[SWAP]' or str(mnt).startswith('/boot')):
        if top: system.add(top)
    if typ == 'lvm' and top: system.add(top)

# 2) 未使用裸盘: 顶层 disk, 非系统盘, 无任何子设备(children 不存在/为空 → 整盘未分区),
#    FSTYPE 为空, 未被 EXCLUDE 命中, 且不是 loop/ram/zram。
cands = []
for b in blocks:
    if b.get('type') != 'disk':
        continue
    name = b['name']
    if name.startswith(('loop', 'ram', 'zram', 'sr')):
        continue
    if name in system:
        continue
    if excl and excl.search(name):
        continue
    kids = b.get('children')
    # 有子设备(分区/LVM/raid) → 已有布局, 不算"裸盘"
    if kids:
        continue
    if b.get('fstype'):      # 整盘直接被格式化(如 mkfs.xfs /dev/vdb)
        continue
    cands.append(f"/dev/{name}")
for c in sorted(cands):
    print(c)
PY
}

say "检测节点裸盘(排除系统盘; EXCLUDE=${CEPH_DETECT_EXCLUDE})..."
for entry in "${NODE_SELECT[@]}"; do
    hn="${entry%%|*}"; rest="${entry#*|}"; ip="${rest%%|*}"; user="${rest#*|}"
    JSON="$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "${user}@${ip}" "lsblk -J -o NAME,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null" 2>/dev/null || echo '')"
    [ -n "${JSON}" ] || { warn "  ${hn}(${ip}) 无法读取 lsblk(SSH/权限), 跳过"; continue; }
    DISKS="$(parse_remote <<< "${JSON}" | tr '\n' ',')"; DISKS="${DISKS%,}"
    if [ -n "${DISKS}" ]; then
        if [ "${MACHINE}" = "1" ]; then
            echo "${hn}:${DISKS}"
        else
            echo "  ${hn}(${ip}): ${DISKS}"
        fi
    else
        warn "  ${hn}(${ip}): 未检测到可用裸盘(请确认 VM 附加了数据盘: VM_DATA_DISKS>0 或裸金属已挂新盘)"
    fi
done
say "检测完成(裸盘候选如上; 部署 ceph 前请人工核对盘名, 避免覆盖系统盘/在用盘)"
