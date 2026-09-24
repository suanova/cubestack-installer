#!/bin/bash
# ============================================================
# ceph-detect-disks.sh — 逐节点分类块设备: 上次 Ceph 占用 / 空闲 / 在用 / 混合
#
# 判定实现在同目录 ceph-disk-classify.py(纯函数, 可离线单测), 本脚本只做 SSH 取数 + 渲染。
#   · free  = 未使用裸盘(整盘无分区/无文件系统/无挂载, 非系统盘) → 可直接作新 OSD
#   · ceph  = 被上次 Ceph 占用(bluestore 签名 / ceph 分区 GUID 或分区名 / ceph-* LVM 卷)
#             → 覆盖安装时清空复用; 也是"重装时检测不到存量盘"的根因所在
#   · inuse = 被别的方式占用(挂载中/非 ceph 文件系统/非 ceph 的 VG·LV/系统盘) → 绝不触碰
#   · mixed = 同盘既有 Ceph 物证又有别的数据 → 调用方必须跳过, 交人工判断
# ★ 只认可复核的强证据, 不做"有分区+未挂载就是 OSD 盘"这类启发式猜测(会误伤业务数据盘)。
#
# 输出:
#   默认          → 人工可读(按分类分组 + 证据串)
#   -m            → 每节点一行 `hostname:/dev/vdb,/dev/vdc` = 可作为 OSD 的盘(free + ceph)
#                   (旧格式不变; 语义等价于旧版"候选裸盘", 并补上旧版漏掉的 分区/LVM 型 OSD 盘)
#   -m --classify → 每行 `<hostname>\t<设备>\t<分类>\t<证据>`(cleanup/预检据此选盘与展示)
# 用法: sudo ./ceph-detect-disks.sh [--node <hostname|ip> ...] [-m] [--classify]
# 数据源: cluster.conf (NODES / SSH_KEY_NAME / CEPH_DETECT_EXCLUDE)
# 前置: 节点 SSH 免密(部署 k8s_passwordless 后); 未免密时自动回退节点密码。
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
CLASSIFY=0
NODE_FILTER=()
while [ $# -gt 0 ]; do
    case "$1" in
        --node) NODE_FILTER+=("$2"); shift 2 ;;
        -m|--machine) MACHINE=1; shift ;;
        --classify) CLASSIFY=1; shift ;;
        *) err "未知参数: $1(用法: --node <hostname|ip>...  / -m / --classify)"; exit 1 ;;
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

# ---------------- 分类器(唯一判定实现) ----------------
# 分类逻辑全在 ceph-disk-classify.py(纯 stdin/stdout, 可离线单测), 本脚本只负责:
#   SSH 取数 → 组装 → 渲染。cleanup / 部署模块 / 预检 都复用同一份判定, 避免"三处各写一份、改一处漏两处"。
CLASSIFY_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ceph-disk-classify.py"
[ -f "${CLASSIFY_PY}" ] || { err "分类器缺失: ${CLASSIFY_PY}"; exit 1; }

# 节点执行一条远端命令: 密钥优先, 失败回退密码(与 setup-passwordless.sh 同款 SSHPASS 模式)。
# ★ 2026-09-07 修复: 全新环境(k8s_passwordless 尚未分发密钥)/容器未挂载密钥时,
#   `ssh -i` 在全部节点失败 → 检测全空(表现为"裸盘: <未检测到>")。
#   节点密码来自 NODES 第5字段(NODE_PW, node_parse 已归一为 SSH_DEFAULT_PASSWORD)。
# ★ 2026-09-09 修复(卡死根因): 密钥分支必须 `BatchMode=yes` + `</dev/null` ——
#   交互终端下 timeout 会给命令新开进程组(后台), 若公钥认证瞬间失败(如 kubespray
#   刚收尾时 authorized_keys 未就绪), ssh 回退密码提示会读 /dev/tty → SIGTTIN →
#   进程永久 T(stopped), timeout 的 SIGTERM 杀不死它 → 部署无限卡死。
#   BatchMode 让密钥失败立即返回(不提示、不读 tty), 自然落到下方 sshpass 密码分支
#   (sshpass 自带 pty, 不碰部署终端, 无此问题)。
node_run() {   # <user> <ip> <pw> <remote-cmd> → stdout(空=两种认证均失败)
    local user="$1" ip="$2" pw="$3" cmd="$4" out=""
    if [ -f "${SSH_KEY}" ]; then
        out="$(timeout 25 ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
            "${user}@${ip}" "${cmd}" </dev/null 2>/dev/null || true)"
    fi
    if [ -z "${out}" ] && [ -n "${pw}" ] && command -v sshpass >/dev/null 2>&1; then
        out="$(timeout 25 env SSHPASS="${pw}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=8 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            "${user}@${ip}" "${cmd}" 2>/dev/null || true)"
    fi
    printf '%s' "${out}"
}

# lsblk 字段: 分类器靠 PARTTYPE(分区类型 GUID)/PARTLABEL(分区名)判定 Ceph 物证, 缺一不可。
LSBLK_CMD="lsblk -J -o NAME,TYPE,FSTYPE,MOUNTPOINT,PARTTYPE,PARTLABEL,PKNAME 2>/dev/null"
# LVM 佐证(可选): VG 名 ceph-* / VG·LV 的 ceph.* 标签。`sudo -n` = 不可交互,
# 需要密码时立即失败而不是挂在密码提示上(与上方 SIGTTIN 同类风险); 取不到只少一条证据。
LVM_CMD="sudo -n pvs --noheadings -o pv_name,vg_name,vg_tags 2>/dev/null; echo '##LVS##'; sudo -n lvs --noheadings -o lv_name,vg_name,lv_tags 2>/dev/null"
# BlueStore label **副本**探针(可选佐证): Ceph v20 把 bdev label 复制到固定偏移
# 10GiB / 100GiB / 1000GiB, 而 lsblk/blkid **只看 offset 0** —— 于是"头被擦过、副本还在"的盘
# 会被判成"空闲"。这正是 2026-09-24 的 0 OSD 事故成因: 这种盘进 CR → Rook 判
# "Raw device ... is already prepared" → 认领失败被跳过 → 新集群 0 OSD。
# 这里逐盘读 3 处各 4KB 找 label magic("ceph osd volume"), 命中就打盘名。
# 无 sudo/无盘 → 空输出, 只少一条证据(绝不当成命中)。
# 偏移换算: 10/100/1000 GiB ÷ 4096B = 2621440 / 26214400 / 262144000。
LABEL_PROBE_CMD='for D in /sys/block/*; do N=${D##*/}; case "$N" in loop*|ram*|zram*|sr*|dm-*|md*|nbd*|rbd*) continue;; esac; B=/dev/$N; [ -b "$B" ] || continue; for O in 2621440 26214400 262144000; do if sudo -n dd if=$B bs=4096 skip=$O count=1 status=none 2>/dev/null | grep -qa "ceph osd volume"; then echo "$N"; break; fi; done; done'

# 单节点分类: stdout = 分类器 TSV(<设备>\t<分类>\t<证据>); 诊断信息走 stderr。
# 返回 0=成功; 1=lsblk 取数失败(SSH/认证问题)。
classify_node() {   # <hostname> <ip> <user> <pw>
    local hn="$1" ip="$2" user="$3" pw="$4" json pvs="" lvs="" lvm_out probed=""
    json="$(node_run "${user}" "${ip}" "${pw}" "${LSBLK_CMD}")"
    if [ -z "${json}" ]; then
        warn "  ${hn}(${ip}) 无法读取 lsblk(SSH 密钥/密码均失败), 跳过" >&2
        return 1
    fi
    # 只有树里真的出现 LVM 才去取 LVM 佐证(省一次 SSH + 一次 sudo)
    if printf '%s' "${json}" | grep -q 'LVM2_member\|"lvm"'; then
        lvm_out="$(node_run "${user}" "${ip}" "${pw}" "${LVM_CMD}")"
        if [ -n "${lvm_out}" ]; then
            pvs="${lvm_out%%##LVS##*}"
            lvs="${lvm_out##*##LVS##}"
            [ "${lvs}" = "${lvm_out}" ] && lvs=""       # 无分隔符 = 整条命令失败
        fi
        if [ -z "${pvs}${lvs}" ]; then
            warn "  ${hn}: LVM 佐证不可得(sudo -n 失败/无 lvm 工具) → 仅按分区与文件系统物证判定" >&2
        fi
    fi
    # BlueStore label 副本佐证(可选): 每盘 3×4KB 读, 成本可忽略, 故无条件探测;
    # 取不到 → 空串, 分类器只会"少一条证据", 绝不因此判 ceph。
    probed="$(node_run "${user}" "${ip}" "${pw}" "${LABEL_PROBE_CMD}")"
    printf '%s' "${json}" | python3 "${CLASSIFY_PY}" "${CEPH_DETECT_EXCLUDE}" "${pvs}" "${lvs}" "${probed}" \
        || { warn "  ${hn}: 分类器执行失败(见上方错误)" >&2; return 1; }
}

# 人工可读渲染: 按分类分组打印某节点的一类磁盘(+ 证据串)。
classify_show() {   # <分类 TSV> <分类> <前缀>
    local tsv="$1" want="$2" prefix="$3" d c e
    while IFS=$'\t' read -r d c e; do
        [ -n "${d}" ] || continue
        [ "${c}" = "${want}" ] || continue
        printf '    %s %s\n' "${prefix}" "${d}"
        printf '        %s\n' "${e}"
    done <<< "${tsv}"
}

say "检测节点磁盘(EXCLUDE=${CEPH_DETECT_EXCLUDE})..."
say "  分类: ceph=上次 Ceph 占用(覆盖安装会清空复用) / free=空闲(可作新 OSD) / inuse=在用(不触碰) / mixed=混合(需人工判断)"
for entry in "${NODE_SELECT[@]}"; do
    hn="${entry%%|*}"; rest="${entry#*|}"; ip="${rest%%|*}"
    rest="${rest#*|}"; user="${rest%%|*}"; pw="${rest#*|}"
    TSV="$(classify_node "${hn}" "${ip}" "${user}" "${pw}")" || continue

    if [ "${MACHINE}" = "1" ]; then
        if [ "${CLASSIFY}" = "1" ]; then
            # 全分类 TSV: <host>\t<设备>\t<分类>\t<证据>(供 cleanup / 预检解析)
            while IFS=$'\t' read -r _d _c _e; do
                [ -n "${_d}" ] && printf '%s\t%s\t%s\t%s\n' "${hn}" "${_d}" "${_c}" "${_e}"
            done <<< "${TSV}"
        else
            # 兼容旧格式 <host>:<盘,盘> —— 语义 = 可作为 OSD 的盘 = 空闲 + 上次 Ceph 占用的盘
            # (旧版把未分区的整盘 ceph_bluestore 也算候选; 这里保持等价, 并补上旧版漏掉的
            #  分区/LVM 型 OSD 盘 —— 正是"重装时检测不到存量 Ceph 盘"的根因)。
            _osd=""
            while IFS=$'\t' read -r _d _c _e; do
                case "${_c}" in free|ceph) _osd="${_osd:+${_osd},}${_d}" ;; esac
            done <<< "${TSV}"
            [ -n "${_osd}" ] && echo "${hn}:${_osd}"
        fi
    else
        echo "  ${hn}(${ip}):"
        classify_show "${TSV}" free  "✅ 空闲(可作新 OSD):"
        classify_show "${TSV}" ceph  "♻  上次 Ceph 占用(覆盖安装将清空复用):"
        classify_show "${TSV}" mixed "⚠  混合盘(需人工判断, 不会自动清理):"
        classify_show "${TSV}" inuse "⛔ 在用盘(不会触碰):"
    fi

    # 无任何可作 OSD 的盘(空闲 + Ceph 残留)时明确告警 —— 否则上层会拿着空列表继续跑
    if ! grep -qE $'\t(free|ceph)\t' <<< "${TSV}"; then
        warn "  ${hn}(${ip}): 未检测到可用裸盘(既无空闲盘也无上次 Ceph 占用盘)"
        warn "     VM 集群请确认 VM_DATA_DISKS>0 且已附加数据盘; 裸金属请挂新盘; 或用 CEPH_DATA_DISKS 显式指定"
    fi
done
say "检测完成(Ceph 盘已单独标出; 部署/清理前请人工核对盘名, 避免覆盖系统盘/在用盘)"
