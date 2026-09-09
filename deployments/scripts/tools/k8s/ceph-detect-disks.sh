#!/bin/bash
# ============================================================
# ceph-detect-disks.sh — 自动检测各节点的"未使用裸盘"(供 Ceph/Rook OSD 用)
# 判定"未使用裸盘": 整块 disk 未被分区/格式化/挂载/作 LVM PV, 且非系统盘
#   (系统盘 = 持有 / 、/boot*、swap、LVM 的盘; 绝不被选中)。
# 输出: 每节点一行 `hostname:/dev/vdb,/dev/vdc`(可 -m 仅机器可读);
#       供 modules/03_addon/02_ceph.sh 生成 CephCluster CR(按节点精确 devices, 防误选)。
# 用法: sudo ./ceph-detect-disks.sh [--node <hostname|ip> ...] [-m]
# 数据源: cluster.conf (NODES / SSH_KEY_NAME / CEPH_DETECT_EXCLUDE)
# 前置: 节点 SSH 免密(部署 k8s_passwordless 后)。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# 人工可读诊断(say/warn)一律走 stderr: -m 机器可读模式下 stdout 只留 "hostname:/dev/x"
# 机器行供上层模块(02_ceph.sh / k8s_deploy 预检)捕获 —— 否则模块捕获 stdout 时会把
# "SSH 失败/无裸盘"等提示吞掉(屏幕上只剩 Python traceback, 不知为何失败)。
say()  { printf '\033[36m→  %s\033[0m\n' "$*" >&2; }
warn() { printf '\033[33m⚠  %s\033[0m\n' "$*" >&2; }

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
# ★ 2026-09-07: 密钥缺失不再硬失败 —— 密码回退可完成检测(全新环境 k8s_passwordless 未跑 /
#   容器未挂载密钥时); 密钥与节点密码都不可用才在逐节点处提示失败。
[ -f "${SSH_KEY}" ] \
    || warn "SSH 密钥不存在: ${SSH_KEY}(将尝试节点密码认证; 均失败请先 gen-ssh-key.sh + k8s_passwordless)"

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
    NODE_SELECT+=("${NODE_HOSTNAME}|${NODE_IP}|${NODE_USER}|${NODE_PW}")
done
[ "${#NODE_SELECT[@]}" -gt 0 ] || { err "未匹配到任何节点(检查 NODES / --node)"; exit 1; }

parse_remote() {   # stdin=lsblk -J JSON → 输出未使用裸盘名(空格分隔, 已排除系统盘/EXCLUDE)
    # ★ 用 python3 -c 而非 heredoc: heredoc 会吃掉 stdin(set -euo pipefail + $( ) 下
    #   stdin 被 /dev/null 占用), json.load 读到空输入 → JSONDecodeError(traceback)。
    #   -c 把程序放参数, stdin 留给数据, 容器/宿主机均可用。
    python3 -c "$_PRG" "${CEPH_DETECT_EXCLUDE}"
}
_PRG='import json, sys, re
excl = re.compile(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1] else None
data = json.load(sys.stdin)
blocks = data.get("blockdevices", [])

def walk(b, parent=None):
    top = parent if parent else b["name"]
    yield (b["name"], b.get("type"), b.get("fstype"), b.get("mountpoint"), b.get("children"), top)
    for c in b.get("children", []) or []:
        yield from walk(c, parent=top if b.get("type") == "disk" else parent)

flat = [r for b in blocks for r in walk(b)]
system = set()
for (name, typ, fstype, mnt, kids, top) in flat:
    # ★ 任何有挂载点的盘一律视为"在用"(无论挂载在 /、/boot、swap 还是 /mnt/data0、
    #   /data 等数据路径)—— 已挂载 = 可能含数据, 绝不可作为裸盘(防覆盖用户数据)。
    #   lvm/raid 子卷所在盘同样排除。
    if mnt:
        if top: system.add(top)
    if typ in ("lvm", "raid") and top: system.add(top)

cands = []
for b in blocks:
    if b.get("type") != "disk":
        continue
    name = b["name"]
    # 盘名泛化: sda/sdb(裸金属 SATA/SAS)、nvme0n1/nvme1n1(裸金属 NVMe)、
    # vda/vdb(云/VM 虚拟盘)一律纳入候选; 排除 loop/ram/zram/sr 伪设备 与 rbd(N 设备。
    if name.startswith(("loop", "ram", "zram", "sr", "rbd")):
        continue
    if name in system:
        continue
    if excl and excl.search(name):
        continue
    kids = b.get("children")
    if kids:            # 已分区/已有子设备 → 在用, 排除
        continue
    # fstype 判定: 普通在用盘(ext4/xfs/... )排除; **ceph_bluestore** = 旧 Rook OSD 盘
    # (上一轮部署的 OSD 残留签名), 可被 Rook 重新认领(同 fsid 恢复)或需清理后复用 ——
    # 作为候选输出, 由 ceph 模块决定"恢复/复用"还是"清理", 避免重装时误判为在用盘而漏选。
    ft = b.get("fstype")
    if ft and ft != "ceph_bluestore":
        continue
    if b.get("mountpoint"):  # 兜底: 顶层直接挂载(无分区) → 排除
        continue
    cands.append("/dev/%s" % name)
for c in sorted(cands):
    print(c)
'

# 节点 SSH 取 lsblk JSON: 密钥优先, 失败回退密码(与 setup-passwordless.sh 同款 SSHPASS 模式)。
# ★ 2026-09-07 修复: 全新环境(k8s_passwordless 尚未分发密钥)/容器未挂载密钥时,
#   `ssh -i` 在全部节点失败 → 检测全空(表现为"裸盘: <未检测到>")。
#   节点密码来自 NODES 第5字段(NODE_PW, node_parse 已归一为 SSH_DEFAULT_PASSWORD)。
# ★ 2026-09-09 修复(卡死根因): 密钥分支必须 `BatchMode=yes` + `</dev/null` ——
#   交互终端下 timeout 会给命令新开进程组(后台), 若公钥认证瞬间失败(如 kubespray
#   刚收尾时 authorized_keys 未就绪), ssh 回退密码提示会读 /dev/tty → SIGTTIN →
#   进程永久 T(stopped), timeout 的 SIGTERM 杀不死它 → 部署无限卡死。
#   BatchMode 让密钥失败立即返回(不提示、不读 tty), 自然落到下方 sshpass 密码分支
#   (sshpass 自带 pty, 不碰部署终端, 无此问题)。
node_lsblk_json() {   # <user> <ip> <pw> → stdout=lsblk JSON(空=均失败)
    local user="$1" ip="$2" pw="$3" out=""
    if [ -f "${SSH_KEY}" ]; then
        out="$(timeout 15 ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
            "${user}@${ip}" "lsblk -J -o NAME,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null" </dev/null 2>/dev/null || true)"
    fi
    if [ -z "${out}" ] && [ -n "${pw}" ] && command -v sshpass >/dev/null 2>&1; then
        out="$(timeout 15 env SSHPASS="${pw}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=8 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            "${user}@${ip}" "lsblk -J -o NAME,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null" 2>/dev/null || true)"
    fi
    printf '%s' "${out}"
}

say "检测节点裸盘(排除系统盘; EXCLUDE=${CEPH_DETECT_EXCLUDE})..."
for entry in "${NODE_SELECT[@]}"; do
    hn="${entry%%|*}"; rest="${entry#*|}"; ip="${rest%%|*}"
    rest="${rest#*|}"; user="${rest%%|*}"; pw="${rest#*|}"
    JSON="$(node_lsblk_json "${user}" "${ip}" "${pw}")"
    [ -n "${JSON}" ] || { warn "  ${hn}(${ip}) 无法读取 lsblk(SSH 密钥/密码均失败), 跳过"; continue; }
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
