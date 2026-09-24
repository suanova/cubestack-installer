#!/bin/bash
# ============================================================
# TOOL: ceph-cleanup
# DESC: 幂等卸载 Ceph + 清理"被判为 Ceph 占用"的磁盘(标准 Ceph 卸载流程: 优雅移除 OSD → 物理擦除 → 软件残留清理)
# 背景/参考:
#   · 标准流程: ① ceph osd out/purge(集群可达) ② 停止进程 + 解除 LVM/dm-mapper + wipefs/sgdisk/dd
#     ③ 清理 /var/lib/ceph /etc/ceph 等 ④ 重装。本工具自动化上述, 幂等可重复执行。
#   · Rook 场景: 删除 CephCluster(cleanupPolicy yes-really-destroy-data)由 Rook 擦盘;
#     若 Rook/operator 已不在(k8s 重装中)→ 直接跳到物理擦除(第二阶段)。
#   · 为什么清盘要用官方 zap(2026-09-24 修正): 旧版认为"ceph 工具宿主机上没有 → 只能自己 dd",
#     而手写 dd 的偏移(头/尾/size÷20/size÷2)与 Ceph v20 实际的 label 副本位置
#     (**10/100/1000GiB**, 见 ceph-bluestore-tool show-label 的 locations)对不上 →
#     副本残留 → 新集群 0 OSD。现改为: 用节点 containerd 里**预加载的 ceph 镜像**经 ctr 跑
#     `ceph-bluestore-tool zap-device`(读 label 自带 locations, 版本无关) + 候选偏移 dd 兜底
#     + 逐处校验, 实现见 lib-common.sh 的 bluestore_wipe_remote_lib(模块 02_ceph.sh 复用同一份)。
#     停止进程 → lvremove/vgremove → dmsetup remove → 这套编排仍在 wipe_node 里保留。
# ★ 选盘只依据 tools/k8s/ceph-disk-classify.py 的分类(强证据), 挂载中/非 ceph 文件系统/
#   非 ceph 的 LVM/系统盘一律不碰; 混合盘(同盘既有 Ceph 物证又有别的数据)只报告不自动清。
#   旧版 --all 只挑"空闲裸盘", 结果上次 Ceph 占用的分区/LVM 盘一块都不清(清理空转, 重装时
#   那几台节点还显示"未检测到可用裸盘")—— 本版按分类清, 正是修这个。
# 支持场景:
#   · 场景① 重装 K8s+Ceph: k8s 重装时 rook ns 已清 → --all 直接按分类清盘即可;
#   · 场景② 只重装 Ceph(K8s 保留): --all 先删 CephCluster(operator 擦盘)再逐节点清盘。
# 用法(部署机/容器内, 需 SSH 密钥): 见 --help
# 数据源: cluster.conf (NODES / CEPH_NODES / CEPH_NODE_ROLE / CEPH_NAMESPACE / SSH_USER /
#                       CEPH_DETECT_EXCLUDE)
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
    # ★ 2026-09-24 修复: 只删 **Bound** 的 ceph PVC, 且永不删 kube-system/registry-pvc。
    #   本步目的是"删掉有后端卷的 PVC, 逼 CSI 先 unmap"; 而**没有后端卷的 PVC(Pending)删掉
    #   只是丢声明, 一个卷也 unmap 不到** —— registry-pvc 恰是这一种: 它由 kubespray 在 k8s
    #   阶段创建(roles/kubernetes-apps/registry), 之后没有任何 addon 模块会重建它。
    #   删了它 → 模块 05_k8s_registry 一直等 "registry-pvc Bound"(等一个不存在的对象)
    #   → 600s 超时 → 整轮部署在 ceph 修好之后**又**挂在 registry 上。
    #   已 Bound 的 registry-pvc 同样保护: 删了 registry 就失去存储声明(镜像数据本就随
    #   OSD 清盘没了, 要重建 registry 请人工删声明 + 重跑 k8s 阶段)。
    SSH "${K} get pvc -A -o json 2>/dev/null" | python3 -c '
import sys, json
PROTECT = {("kube-system", "registry-pvc")}      # kubespray 建的 registry 声明: 删了不会自愈
try:
    d = json.load(sys.stdin)
    for pvc in d.get("items", []):
        sc = pvc.get("spec", {}).get("storageClassName", "")
        if "ceph" not in sc:
            continue
        ns, name = pvc["metadata"]["namespace"], pvc["metadata"]["name"]
        if (ns, name) in PROTECT:
            print("KEEP %s/%s (registry 存储声明, 受保护)" % (ns, name))
            continue
        if pvc.get("status", {}).get("phase") != "Bound":
            print("KEEP %s/%s (未 Bound, 无后端卷可 unmap)" % (ns, name))
            continue
        print("DEL %s/%s" % (ns, name))
except Exception:
    pass
' | while read -r _act _pvc _why; do
        [ -n "${_pvc:-}" ] || continue
        case "${_act}" in
            DEL)  say "     删除 PVC ${_pvc}(数据将销毁)..."
                  SSH "${K} -n ${_pvc%/*} delete pvc ${_pvc#*/} --wait=false >/dev/null 2>&1" || true ;;
            KEEP) say "     保留 PVC ${_pvc} ${_why:-}" ;;
        esac
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
wipe_node() {   # <ip> <disks: "/dev/vdb,/dev/vdc"> [user]
    local ip="$1" disks="$2" user="${3:-${SSH_USER:-ubuntu}}"
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
# 2) 解除 **目标盘上** 的 LVM —— 只动这些盘上的 PV 所属 VG。
#    ★ 不按名字正则扫全节点(`lvs | grep ceph` / `vgs | grep ceph|rbd`): 那会误伤
#      "名字里恰好带 ceph" 的无关卷(如 data-vg/cephbackup、手工建的 ceph-backup VG),
#      与"不覆盖其他使用方式的磁盘"直接冲突; 本脚本的 7a 让这段跑在**默认部署流程**里,
#      影响面比人工执行 --all 时大得多, 必须按盘收敛。
_TARGET_VGS=""
for dev in __DISKS__; do
    [ -b "$dev" ] || continue
    for pv in $(pvs --noheadings -o pv_name 2>/dev/null | tr -d ' '); do
        case "$pv" in
            "$dev"|"$dev"p[0-9]*|"$dev"[0-9]*) ;;      # 盘本身 或 它的分区(nvme0n1p1 / sdb1)
            *) continue ;;
        esac
        _vg="$(pvs --noheadings -o vg_name "$pv" 2>/dev/null | tr -d ' ')"
        [ -n "${_vg}" ] && _TARGET_VGS="${_TARGET_VGS} ${_vg}"
    done
done
for vg in $(printf '%s\n' ${_TARGET_VGS} | sort -u); do
    for lv in $(lvs --noheadings -o lv_path "$vg" 2>/dev/null | tr -d ' '); do
        lvremove -f "$lv" 2>/dev/null || true
    done
    vgremove -f "$vg" 2>/dev/null || true
done
# 3) 解除 device-mapper 映射: 只拆**目标盘之上**的 dm/crypt 层(这些盘已被判定为 Ceph 占用,
#    其上的 dm 随盘一起清掉)。**不用 `dmsetup remove_all`** —— 那会拆掉本节点**所有** dm 映射
#    (未打开的业务 LV、多路径、dm-crypt 都会被映断; 数据虽不毁, 但超出"只清这些盘"的范围)。
for dev in __DISKS__; do
    [ -b "$dev" ] || continue
    for dm in $(lsblk -n -o NAME,TYPE "$dev" 2>/dev/null | awk '$2=="dm" || $2=="crypt" {print $1}'); do
        dmsetup remove -f "$dm" 2>/dev/null || true
    done
done
# 4) 擦除磁盘签名 + 分区表 + bluestore 标签(**全部 label 副本**, 见 lib-common.sh 的
#    bluestore_wipe_remote_lib)。★ 2026-09-24 事故修复: 旧版这里手写 dd 只擦
#    头/尾/size÷20/size÷2, 漏掉 Ceph v20 在 **10/100/1000GiB** 的 label 副本
#    → `ceph-volume raw list` 仍认得出旧 OSD → Rook osd-prepare 判 "already prepared"
#    → 新集群 0 OSD。现在: 官方 zap-device(读 label 自带 locations) + 候选偏移 dd + 校验,
#    校验不过就非 0 退出, 不再假装成功。
_BSTORE_FAIL=0
for dev in __DISKS__; do
    [ -b "$dev" ] || continue
    if bluestore_wipe_dev "$dev"; then
        echo "   ${dev}: bluestore 已擦净(label 副本 + 头/分区表/尾)"
    else
        echo "    !! ${dev} 未通过 bluestore 擦除校验(残留偏移见上) —— 该盘作 OSD 会被 Rook 判 already prepared"
        _BSTORE_FAIL=1
    fi
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
echo "--- 验证完成(FSTYPE 列应全空; bluestore label 副本另由 bluestore_wipe_dev 逐处校验) ---"
# ★ bluestore label 没擦净 → 非 0 退出: 调用方必须看见, 否则盘会带着旧 OSD 身份进 CR,
#   新集群 OSD 数为 0(2026-09-24 事故的静默形态)。
[ "${_BSTORE_FAIL:-0}" = "1" ] && exit 1
exit 0
WIPESCRIPT
)"
    script="${script//__DISKS__/${disks//,/ }}"
    # ★ 节点端 bluestore 擦除函数(wipescript 里直接调用)由 lib-common 提供, 避免两处各写一份
    #   (另一处: 模块 03_addon/02_ceph.sh 的 7a-② 逐盘兜底)。
    { bluestore_wipe_remote_lib; printf '\n%s\n' "${script}"; } | node_cmd "${ip}" "${user}" "sudo bash -s" \
        && ok "  ${ip} 磁盘已恢复原始状态" \
        || { warn "  ${ip} 磁盘清理失败(见上方输出; 常见: 盘被占用 lsof /dev/sdX 找进程 kill 后重试)"; return 1; }
}

# ---------------- 磁盘分类(选盘唯一依据) ----------------
# 分类实现全在 tools/k8s/ceph-disk-classify.py(经 ceph-detect-disks.sh --classify 调用),
# 与部署模块/预检复用同一份判定 —— 避免"清理判一套、部署判另一套"导致清了不该清的盘
# 或者该清的盘没清(旧版 --all 只挑"空闲裸盘", 结果上次 Ceph 占用的分区/LVM 盘一个都不碰,
# 重装时那几台节点显示"未检测到可用裸盘", 清理等于空转)。
DETECT_SH="${SCRIPT_DIR}/tools/k8s/ceph-detect-disks.sh"

classify_all_hosts() {   # stdout = TSV: <host>\t<设备>\t<分类>\t<证据>
    local args=() _h
    while IFS= read -r _h; do
        [ -n "${_h}" ] && args+=(--node "${_h}")
    done < <(ceph_storage_hosts)
    bash "${DETECT_SH}" "${args[@]}" -m --classify
}

# TSV 里取某主机某分类的设备(逗号分隔)
_tsv_devices() {   # <tsv> <host> <分类...>
    local tsv="$1" host="$2"; shift 2
    local -a want=("$@") w out=""
    for w in "${want[@]}"; do
        out="${out}$(awk -F'\t' -v h="${host}" -v c="${w}" '$1==h && $3==c {printf "%s,", $2}' <<< "${tsv}")"
    done
    printf '%s' "${out%,}"
}

# 分类结果人工可读打印(红底强调"不碰"的盘, 避免用户以为清理没跑全)
print_classified() {   # <tsv>
    local tsv="$1" _h _d _c _e
    while IFS=$'\t' read -r _h _d _c _e; do
        [ -n "${_h}" ] || continue
        case "${_c}" in
            ceph)  echo -e "\033[36m  ♻  ${_h} ${_d} — 上次 Ceph 占用, 将清理: ${_e}\033[0m" ;;
            free)  echo -e "     ${_h} ${_d} — 空闲(无需清理)" ;;
            mixed) echo -e "\033[41m\033[97m  ⚠  ${_h} ${_d} — 混合盘, 不自动清理(需人工判断): ${_e}\033[0m" ;;
            *)     echo -e "     ${_h} ${_d} — 在用盘, 不触碰: ${_e}" ;;
        esac
    done <<< "${tsv}"
}

# 解析主机名 → IP/用户名到 _HOST_IP/_HOST_USER(NODES 里查)
_resolve_host() {   # <hostname>
    _HOST_IP=""; _HOST_USER="${SSH_USER:-ubuntu}"
    local _line
    for _line in "${NODES[@]:-}"; do
        [ -z "${_line}" ] && continue
        node_parse "${_line}"
        [ "${NODE_HOSTNAME}" = "$1" ] && { _HOST_IP="${NODE_IP}"; _HOST_USER="${NODE_USER}"; return 0; }
    done
    return 1
}

# IP → hostname(cleanup 按 IP 操作, 分类结果按 hostname 索引)
_hostname_of_ip() {   # <ip> → stdout=hostname(空=不在 NODES 里)
    local _line
    for _line in "${NODES[@]:-}"; do
        [ -z "${_line}" ] && continue
        node_parse "${_line}"
        [ "${NODE_IP}" = "$1" ] && { printf '%s' "${NODE_HOSTNAME}"; return 0; }
    done
    return 1
}

# ---------------- ③ 只列出清理计划, 不动任何盘 ----------------
list_plan() {
    say "扫描各存储节点磁盘(只读, 不会修改任何磁盘)..."
    local tsv
    tsv="$(classify_all_hosts)" || { err "磁盘分类失败(节点 SSH 不可达?)"; exit 1; }
    [ -n "${tsv}" ] || { err "未获得任何节点的磁盘分类(检查 NODES / SSH 可达性)"; exit 1; }
    print_classified "${tsv}"
    echo ""
    say "图例: ♻ = 会被 --all 清理(标准 Ceph 清除步骤); 空闲盘无需清理;"
    say "      在用盘(挂载中/非 ceph 文件系统/非 ceph LVM/系统盘)与混合盘一律不动"
    say "如需强制清理某块盘: $0 --wipe-node <ip> --disks \"/dev/xxx\" [--force]"
}

# ---------------- ④ 全流程: 删集群 + 清理判为 Ceph 占用的盘 ----------------
cleanup_all() {
    delete_cluster || true
    wipe_ceph_disks_all_nodes
}

# 分类各存储节点 → 只清被判为 Ceph 占用的盘(在用/混合盘一律不动)。
# 被 --all 与部署模块的覆盖安装路径(02_ceph.sh 7a)共用 —— 两处走同一份判定与同一套清除步骤。
wipe_ceph_disks_all_nodes() {
    say "分类各存储节点磁盘(只清被判为上次 Ceph 占用的盘; 在用/混合盘一律不动)..."
    local tsv
    tsv="$(classify_all_hosts)" || { err "磁盘分类失败(节点 SSH 不可达?)"; exit 1; }
    [ -n "${tsv}" ] || { err "未获得任何节点的磁盘分类(检查 NODES / SSH 可达性)"; exit 1; }
    print_classified "${tsv}"
    echo ""
    # 按节点聚合 -- 一台节点一次 SSH 跑一遍标准清除步骤(LVM/VG 解绑只需做一次), 多盘一起擦
    local _h _ip _user _disks _n
    _n=0
    while IFS= read -r _h; do
        [ -n "${_h}" ] || continue
        _disks="$(_tsv_devices "${tsv}" "${_h}" ceph)"
        [ -n "${_disks}" ] || continue
        _resolve_host "${_h}" || { warn "  ${_h}: NODES 中找不到该节点, 跳过"; continue; }
        [ -n "${_HOST_IP}" ] || { warn "  ${_h}: 无 IP, 跳过"; continue; }
        _ip="${_HOST_IP}"; _user="${_HOST_USER}"
        say "  节点 ${_h}(${_ip}): 清理 ${_disks}"
        wipe_node "${_ip}" "${_disks}" "${_user}" && _n=$((_n + 1)) || true
    done < <(ceph_storage_hosts)
    if [ "${_n}" -eq 0 ]; then
        warn "没有节点需要清理(未检出任何 Ceph 占用盘; 若确认有旧 OSD 盘, 见上方分类说明)"
    fi
    ok "Ceph 磁盘清理完成(可重新安装)"
}

# ---------------- ⑤ 显式清指定节点的指定盘(带分类护栏) ----------------
# 直接落实"不覆盖其他使用方式的磁盘": 擦盘前逐块查分类, 判为 inuse/mixed/未知的一律拒擦,
# 要用 --force 才越过(此时会先把证据打印出来, 让人看清楚自己越过了什么)。
wipe_node_guarded() {   # <ip> <disks>
    local ip="$1" disks="$2" hn tsv _d _cls _ev
    local allowed=() refused=() unknown=()

    hn="$(_hostname_of_ip "${ip}" || true)"
    if [ -z "${hn}" ]; then
        warn "  ${ip} 不在 cluster.conf NODES 里 → 无法分类, 需 --force 才擦"
        for _d in ${disks//,/ }; do unknown+=("/dev/${_d#/dev/}"); done
    else
        tsv="$(classify_all_hosts)" || { err "磁盘分类失败(SSH 不可达?)"; exit 1; }
        for _d in ${disks//,/ }; do
            _d="/dev/${_d#/dev/}"
            _cls="$(awk -F'\t' -v h="${hn}" -v dev="${_d}" '$1==h && $2==dev {print $3}' <<< "${tsv}")"
            _ev="$(awk -F'\t' -v h="${hn}" -v dev="${_d}" '$1==h && $2==dev {print $4}' <<< "${tsv}")"
            case "${_cls}" in
                ceph) allowed+=("${_d}");  say "  ♻  ${_d} — 上次 Ceph 占用, 允许清理(${_ev})" ;;
                free) allowed+=("${_d}");  say "  ✅ ${_d} — 空闲盘(清理无害)" ;;
                "")   unknown+=("${_d}");  warn "  ⚠  ${_d} — 未在 lsblk 中找到该设备(盘名写错/节点不可达?)" ;;
                *)    refused+=("${_d}");  warn "  ⛔ ${_d} — 判为 ${_cls}, 拒绝清理: ${_ev}" ;;
            esac
        done
    fi

    if [ "${#refused[@]}" -gt 0 ] || [ "${#unknown[@]}" -gt 0 ]; then
        echo ""
        warn "以下磁盘未被清理(分类显示它们不像是 Ceph 盘, 或无法确认):"
        local _r
        for _r in "${refused[@]:-}" "${unknown[@]:-}"; do [ -n "${_r}" ] && warn "    ${_r}"; done
        if [ "${FORCE}" = "1" ]; then
            warn "--force 已指定 → 连同上述磁盘一并清理"
            for _r in "${refused[@]:-}" "${unknown[@]:-}"; do [ -n "${_r}" ] && allowed+=("${_r}"); done
        else
            # fail-fast: 一块盘不放行就整批不动 —— 破坏性操作用"部分执行"会让现场更难判断
            warn "本次未清理任何磁盘。确认要销毁上述盘上数据请加 --force 重跑本命令"
            return 1
        fi
    fi

    [ "${#allowed[@]}" -gt 0 ] || { warn "  无可清理的磁盘"; return 1; }
    local _joined _user="${SSH_USER:-ubuntu}"
    _joined="$(IFS=,; printf '%s' "${allowed[*]}")"
    # 用户按 NODES 第4字段每节点不同时, 这里必须用该节点自己的用户(否则认证失败)
    if [ -n "${hn}" ] && _resolve_host "${hn}"; then
        _user="${_HOST_USER}"
    fi
    wipe_node "${ip}" "${_joined}" "${_user}"
}

# ---------------- main ----------------
ACTION=""
WIPE_IP=""
WIPE_DISKS=""
FORCE=0
usage() {
    cat <<'USAGE'
用法:
  ceph-cleanup.sh --list                               # 只列出清理计划(只读, 不动盘)
  ceph-cleanup.sh --delete-cluster                     # 仅删除 CephCluster CR(等 Rook 擦盘, 最长 300s)
  ceph-cleanup.sh --wipe-disks                         # 只清理判为 Ceph 占用的盘(不删集群)
  ceph-cleanup.sh --all                                # 全流程: 删集群(若在) + 清理判为 Ceph 占用的盘
  ceph-cleanup.sh --wipe-node <ip> --disks "/dev/vdb,/dev/vdc" [--force]
                                                       # 显式清指定盘(默认拒绝清在用/混合盘)
说明: 判定"哪些盘是 Ceph 盘"由 ceph-disk-classify.py 统一给出(强证据: bluestore 签名 /
      ceph 分区 GUID 或分区名 / ceph-* LVM 卷); 挂载中、非 ceph 文件系统、非 ceph LVM、
      系统盘一律不碰。混合盘(同盘既有 Ceph 又有别的数据)只报告, 需人工处理。
USAGE
}
while [ $# -gt 0 ]; do
    case "$1" in
        --list)           ACTION=list; shift ;;
        --delete-cluster) ACTION=delete-cluster; shift ;;
        --wipe-disks)     ACTION=wipe-disks; shift ;;
        --all)            ACTION=all; shift ;;
        --wipe-node)      ACTION=wipe-node; WIPE_IP="${2:-}"; shift 2 ;;
        --disks)          WIPE_DISKS="${2:-}"; shift 2 ;;
        --force)          FORCE=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) err "未知参数: $1"; usage; exit 1 ;;
    esac
done

case "${ACTION}" in
    list)           list_plan ;;
    delete-cluster) delete_cluster ;;
    wipe-disks)     wipe_ceph_disks_all_nodes ;;
    all)            cleanup_all ;;
    wipe-node)
        [ -n "${WIPE_IP}" ] && [ -n "${WIPE_DISKS}" ] \
            || { err "用法: $0 --wipe-node <ip> --disks \"/dev/vdb,/dev/vdc\" [--force]"; exit 1; }
        wipe_node_guarded "${WIPE_IP}" "${WIPE_DISKS}" ;;
    *) usage; exit 1 ;;
esac
