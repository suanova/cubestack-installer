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
#   bash ceph-rbd-cleanup.sh --skip-keep-query
#       # 不查询 PV/PVC(集群 API 不可用/覆盖安装 reset 后), 只 unmap **空闲**设备;
#       # 仍逐设备检查 holders/open fd/inflight/挂载, 忙/未知一律跳过
#   bash ceph-rbd-cleanup.sh --skip-keep-query --fail-if-left
#       # 同上, 但清理后仍有映射/状态未知 → 非零退出(kubespray 前守卫用)
#   bash ceph-rbd-cleanup.sh --inventory <hosts.yml> [--skip-keep-query] [--fail-if-left]
#       # 节点/SSH 用户/密钥取自已选 inventory(覆盖安装 reset 后 cluster.conf 不可用时)
#   KEEP_VOLUME=<imageName> bash ...         # 额外保留某卷(逗号分隔)
# 数据源: cluster.conf (NODES / SSH_KEY_NAME / SSH_USER) + kubeconfig 或 --inventory hosts.yml
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config
LIST_ONLY=0
SKIP_KEEP_QUERY=0
FAIL_IF_LEFT=0
INVENTORY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST_ONLY=1; shift ;;
        --skip-keep-query) SKIP_KEEP_QUERY=1; shift ;;
        --fail-if-left) FAIL_IF_LEFT=1; shift ;;
        --inventory) INVENTORY="${2:?--inventory 需要 hosts.yml 路径}"; shift 2 ;;
        -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "未知参数: $1(--help 查看用法)"; exit 1 ;;
    esac
done

SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
# ★ 只有需要查 PV/PVC 时才依赖 cluster.conf 的 master; --skip-keep-query(覆盖安装
#   reset 后)和纯 --list 可以完全由 --inventory 驱动, cluster.conf 缺失也不阻断。
if [ "${SKIP_KEEP_QUERY}" != "1" ]; then
    init_remote_kubectl || { err "init_remote_kubectl 失败(cluster.conf NODES 无 master?)"; exit 1; }
fi

# ---------------- 目标来源: --inventory(hosts.yml) 优先, 否则 cluster.conf NODES ----------------
# 覆盖安装流程里 reset/Kubespray 都以 hosts.yml 为准; cluster.conf 可能缺失或与 inventory
# 不一致。--inventory 从 ansible-inventory 读取每台节点的 ansible_host/user/private_key,
# 清理只作用于安装目标, 不再依赖 cluster.conf NODES。
# 输出数组元素: "<ip>|<ansible_user>|<private_key>"
INVENTORY_TARGETS=()
if [ -n "${INVENTORY}" ]; then
    [ -f "${INVENTORY}" ] || { err "--inventory 文件不存在: ${INVENTORY}"; exit 1; }
    _inv_hosts=""
    if command -v ansible-inventory >/dev/null 2>&1; then
        _inv_hosts="$(ansible-inventory -i "${INVENTORY}" --list 2>/dev/null | python3 -c '
import os, sys, json
try:
    inv = json.load(sys.stdin)
except Exception:
    sys.exit(0)
meta = (inv.get("_meta") or {}).get("hostvars") or {}
seen = set()
seen_groups = set()
def add_group(name):
    # Ansible 2.19 --list: 组内既有直接 hosts, 也有 children 组(列表)。
    # 只看直接 hosts 会漏掉子组里的 worker(且非空输出会跳过 YAML 递归兜底)。
    if name in seen_groups:
        return
    seen_groups.add(name)
    g = inv.get(name)
    if not isinstance(g, dict):
        return
    for h in g.get("hosts") or []:
        if h in seen:
            continue
        seen.add(h)
        hv = meta.get(h) or {}
        ip = hv.get("ansible_host") or h
        user = hv.get("ansible_user") or "ubuntu"
        key = os.path.expanduser(hv.get("ansible_ssh_private_key_file") or "~/.ssh/cubestack_k8s")
        print("%s|%s|%s" % (ip, user, key))
    children = g.get("children") or []
    if isinstance(children, dict):
        children = list(children.keys())
    for child in children:
        add_group(child)
for group in ("kube_node", "kube_control_plane"):
    add_group(group)
' 2>/dev/null || true)"
    fi
    if [ -z "${_inv_hosts}" ] && command -v python3 >/dev/null 2>&1; then
        # 无 ansible-inventory(或输出为空)时按 hosts.yml 结构直接解析。
        # ★ 只解析 kube_node / kube_control_plane 及其子孙组 —— 不能把 inventory 里
        #   所有组都当清理目标(例如单独的 backup 组), 否则 --skip-keep-query 会误清
        #   非 K8s 主机上的空闲 rbd 映射。与 JSON 路径保持同一目标选择。
        _inv_hosts="$(python3 - "${INVENTORY}" <<'PY' 2>/dev/null || true
import os, sys
try:
    import yaml
except Exception:
    sys.exit(0)
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
TARGETS = ("kube_node", "kube_control_plane")
seen = {}
seen_groups = set()
groups = {}
all_vars = (d.get("all") or {}).get("vars") or {}
def register(name, g):
    # 同名组可能先在 children 里以空引用出现; 保留真实(非空)定义。
    if not isinstance(g, dict):
        return
    if not groups.get(name):
        groups[name] = g
    children = g.get("children") or {}
    if isinstance(children, dict):
        for cname, cg in children.items():
            register(cname, cg)
for k, v in d.items():
    register(k, v)
def collect(name, g, inherited, in_target):
    # 只收集 kube_node/kube_control_plane 及其子孙; 同时合并组级 vars
    # (Ansible group vars 向下继承; host vars 覆盖组级值)。
    # ★ 2026-11-23(CodeRabbit): visited 状态按 (组名, 是否在目标范围) 记录 —— 一个组
    #   可能先在 all 的非目标分支被访问(如 worker_pool), 之后才从 kube_node 的孩子
    #   引用进入; 只按组名去重会让后者被误跳过, 漏掉 worker。
    target = in_target or name in TARGETS
    if (name, target) in seen_groups:
        return
    seen_groups.add((name, target))
    # children 里的组可能只是空引用; 解析到它的独立定义。
    if not isinstance(g, dict) or not g:
        g = groups.get(name) or g
    if not isinstance(g, dict):
        return
    merged = dict(inherited)
    gvars = g.get("vars") or {}
    if isinstance(gvars, dict):
        merged.update(gvars)
    if target:
        for h, hv in (g.get("hosts") or {}).items():
            host_vars = dict(merged)
            if isinstance(hv, dict):
                host_vars.update(hv)
            seen.setdefault(h, host_vars)
    children = g.get("children") or {}
    if isinstance(children, dict):
        for cname, cg in children.items():
            collect(cname, cg, merged, target)
# 从 all 走一遍覆盖嵌套组(继承 all.vars 与各层组 vars), 再补顶层独立组。
collect("all", d.get("all") or {}, {}, False)
for k, v in d.items():
    if k == "all":
        continue
    collect(k, v, all_vars, False)
for h, hv in seen.items():
    ip = hv.get("ansible_host") or h
    user = hv.get("ansible_user") or "ubuntu"
    key = os.path.expanduser(hv.get("ansible_ssh_private_key_file") or "~/.ssh/cubestack_k8s")
    print("%s|%s|%s" % (ip, user, key))
PY
)"
    fi
    while IFS='|' read -r _i_ip _i_user _i_key; do
        [ -n "${_i_ip}" ] || continue
        INVENTORY_TARGETS+=("${_i_ip}|${_i_user:-ubuntu}|${_i_key:-${SSH_KEY}}")
    done <<< "${_inv_hosts}"
    unset _inv_hosts _i_ip _i_user _i_key
    [ "${#INVENTORY_TARGETS[@]}" -gt 0 ] \
        || { err "无法从 inventory 解析节点(${INVENTORY}); 需要 kube_control_plane/kube_node hosts"; exit 1; }
    say "目标来源: inventory ${INVENTORY}(${#INVENTORY_TARGETS[@]} 台)"
fi

# 需要保留的卷名(在用): 集群内全部 PV 的 CSI imageName。
KEEP_VOLS="${KEEP_VOLUME:-}"
if [ "${SKIP_KEEP_QUERY}" = "1" ]; then
    # 2026-11-22: 覆盖安装/集群 API 已不可用时, 无法查询 PV。只按设备空闲状态清理
    #   (holders/open fd/inflight/挂载任一命中都跳过), 不依赖 PV 列表。
    _KEEP_QUERY_OK=1
    warn "  --skip-keep-query: 不查询 PV/PVC(API 不可达/覆盖安装 reset 后); 只 unmap 空闲设备"
else
    # kubeconfig(供 kubectl 查 registry-pvc 卷名; 缺失则回退到 master 上 /etc/kubernetes/admin.conf)
    #   本地有 kubeconfig 用本地; 否则经 SSH 用 master 的 /etc/kubernetes/admin.conf(sudo)。
    KC="${KUBECONFIG:-}"
    if [ -z "${KC}" ]; then
        KC="/opt/cubestack-installer/deployments/kubespray/inventory/cubestack-cluster/artifacts/admin.conf"
    fi
    [ -f "${KC}" ] || KC=""
    KC_REMOTE="/etc/kubernetes/admin.conf"   # master 上固定路径(SSH 执行 kubectl 用)
    _KC=""          # 本地 kubectl 前缀(容器/部署机)
    _KC_REMOTE=""   # SSH 远程 kubectl 前缀(master 上, sudo)
    if [ -n "${KC}" ] && [ -f "${KC}" ]; then
        _KC="kubectl --kubeconfig=${KC}"
    fi
    if SSH "test -f ${KC_REMOTE}" 2>/dev/null; then
        _KC_REMOTE="sudo kubectl --kubeconfig=${KC_REMOTE}"
    fi
    _KEEP_QUERY_OK=0
    if [ -n "${_KC}" ]; then
        if _img="$(kubectl --kubeconfig="${KC}" get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeAttributes.imageName} ' 2>/dev/null)"; then
            _KEEP_QUERY_OK=1
            [ -n "${_img}" ] && KEEP_VOLS="${KEEP_VOLS:+${KEEP_VOLS},}${_img}"
        fi
    fi
    if [ "${_KEEP_QUERY_OK}" != "1" ] && [ -n "${_KC_REMOTE}" ]; then
        if _img="$(SSH "${_KC_REMOTE} get pv -o jsonpath={.items[*].spec.csi.volumeAttributes.imageName}" 2>/dev/null)"; then
            _KEEP_QUERY_OK=1
            [ -n "${_img}" ] && KEEP_VOLS="${KEEP_VOLS:+${KEEP_VOLS},}${_img// /,}"
        fi
    fi
    if [ "${_KEEP_QUERY_OK}" != "1" ] && [ "${LIST_ONLY}" != "1" ]; then
        warn "无法读取当前 PV/PVC(集群 API 不可达) —— 无法证明 rbd 映射是孤儿, 跳过清理(避免误 unmap 在用卷造成 D 状态)"
        exit 0
    fi
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
# ⚠ 返回码**透传**(不吞, 2026-10-13 CodeRabbit): 调用侧据此区分"查询失败(rc≠0, 状态未知)"
#   与"无映射(rc 0 且空输出)"—— 不可达节点绝不能被当成"干净"。
list_maps() {   # <ip>
    local ip="$1"
    ssh -i "${CUR_SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${CUR_SSH_USER}@${ip}" \
        "for d in /sys/bus/rbd/devices/*; do [ -e \"\$d\" ] || continue; echo \"\$(basename \$d) \$(cat \$d/name 2>/dev/null) \$(cat \$d/pool 2>/dev/null)\"; done" 2>/dev/null
}

# 0=在用/有在飞 IO(绝不能 unmap); 1=确认空闲; 2=查询失败(保守按忙处理)。
# 旧逻辑只看宿主机 `mount | grep /dev/rbdX`; CSI RBD 卷通常在 pod/CSI nodeplugin 的
# namespace 里被 open, 宿主 mount 看不到 → 对在用卷执行 sysfs remove → 内核写永久 D 态
# (2026-11-11 实机: .190/.36 的 `bash -c echo N > /sys/bus/rbd/remove...` 卡住, dpkg/fuser 被拖死, 只能重启)。
# 这里同时检查 holders / open fd / inflight / host mount; 任意命中都视为忙。
_rbd_device_busy() {   # <ip> <id>
    local ip="$1" id="$2" rc=0
    ssh -n -i "${CUR_SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "${CUR_SSH_USER}@${ip}" \
        "sudo bash -c '
            [ -d /sys/bus/rbd/devices/${id} ] || exit 1
            _h_rc=0
            _h=\$(ls -A /sys/block/rbd${id}/holders 2>/dev/null) || _h_rc=\$?
            [ \${_h_rc} -eq 0 ] || exit 2
            [ -n \"\${_h}\" ] && exit 0
            _fd_rc=0
            _fd_out=\$(timeout 5 ls -l /proc/[0-9]*/fd 2>/dev/null) || _fd_rc=\$?
            [ \${_fd_rc} -eq 0 ] || exit 2
            if printf \"%s\\n\" \"\${_fd_out}\" | grep -qE \"/dev/rbd${id}([^0-9]|\$)\"; then exit 0; fi
            _inf_rc=0
            _inf=\$(cat /sys/block/rbd${id}/inflight 2>/dev/null) || _inf_rc=\$?
            [ \${_inf_rc} -eq 0 ] && [ -n \"\${_inf}\" ] || exit 2
            if ! printf \"%s\\n\" \"\${_inf}\" | grep -qE \"^[[:space:]]*0[[:space:]]+0[[:space:]]*$\"; then exit 0; fi
            _fm_rc=0
            _fm_err=\$(findmnt -rn -S /dev/rbd${id} 2>&1 >/dev/null) || _fm_rc=\$?
            [ \${_fm_rc} -eq 0 ] && exit 0
            [ \${_fm_rc} -eq 1 ] && [ -z \"\${_fm_err}\" ] && exit 1
            exit 2
        '" >/dev/null 2>&1 || rc=$?
    case "${rc}" in
        0) return 0 ;;   # busy
        1) return 1 ;;   # idle
        *) return 2 ;;    # unknown
    esac
}

# 清理单个节点
cleanup_node() {   # <ip>
    local ip="$1" maps line id name pool cleaned=0 mounted _left
    # ★ 2026-10-13(CodeRabbit): 查询失败 ≠ 无映射 —— 不可达节点报"状态未知"并计入总账,
    #   不得落入下方"无 rbd 映射"早退(那会让总报告对未知节点假清零)。
    if ! maps="$(list_maps "${ip}")"; then
        warn "  ${ip}: rbd 映射查询失败(SSH 不可达?) —— 状态未知, 跳过"
        _TOTAL_UNKNOWN=$(( ${_TOTAL_UNKNOWN:-0} + 1 ))
        _UNKNOWN_NODES="${_UNKNOWN_NODES:+${_UNKNOWN_NODES} }${ip}"
        return 0
    fi
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
        # ★ 2026-11-11: 先证明设备空闲; 在用/有在飞 IO 的映射**绝不**写 sysfs。
        _busy_rc=0
        _rbd_device_busy "${ip}" "${id}" || _busy_rc=$?
        if [ "${LIST_ONLY}" = "1" ]; then
            echo "    [映射] ${name}(id=${id}, pool=${pool}, busy=${_busy_rc})"
            continue
        fi
        if [ "${_busy_rc}" -eq 0 ]; then
            warn "    保留 ${name}(id=${id}): 设备在用/有在飞 IO, 跳过 unmap(避免内核 D 状态)"
            continue
        elif [ "${_busy_rc}" -eq 2 ]; then
            warn "    ${name}(id=${id}): 设备忙状态无法确认, 跳过 unmap(保守)"
            continue
        fi
        # 该映射是否有有效挂载(kubelet 引用)
        # ★ 2026-09-24: 原来这条 ssh 被**写了两遍**(先判断、再把同一条命令塞进 `mounted="$(...)"`,
        #   且赋值处在 `A && B` 的末位 —— B 失败时 set -e 会直接结束脚本)。合并成一次取值 + `|| true`。
        mounted="$(ssh -n -i "${CUR_SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${CUR_SSH_USER}@${ip}" \
            "mount | grep -qE '[[:space:]]/dev/rbd${id}[[:space:]]' && echo yes || echo no" 2>/dev/null || true)"
        # 卸载挂载点(仅当 kubelet 挂载引用且设备被占用; 残留挂载点安全卸载)
        if [ "${mounted}" = "yes" ]; then
            # ⚠ 卸载改**惰性(setsid umount -l)且后台化、不等待**(2026-10-10): 后端已死时正规
            #   umount 会卡在"日志回写死设备"(永久 D 态不可杀) —— 与 k8s 清理处同一事故类。
            #   惰性脱挂只做命名空间脱开, 后台进程即便 D 也只是惰性残留; 本步随之立即返回。
            timeout 30 ssh -n -i "${CUR_SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${CUR_SSH_USER}@${ip}" \
                "sudo bash -c 'mount | grep /dev/rbd${id} | while read -r _d _on m _rest; do setsid umount -l \"\$m\" >/dev/null 2>&1 & done' ; echo 卸载已发起（惰性后台, 不等待）" 2>/dev/null || true
            warn "    ${name}(id=${id}): 已发起惰性卸载(后台)"
        fi
        # ★ 2026-11-11: 惰性卸载后再次确认空闲; 仍忙/未知则绝不写 sysfs(否则 D 态)。
        _busy_rc=0
        _rbd_device_busy "${ip}" "${id}" || _busy_rc=$?
        if [ "${_busy_rc}" -ne 1 ]; then
            warn "    ${name}(id=${id}): 卸载后设备仍忙/未知(busy_rc=${_busy_rc}), 跳过 unmap(避免内核 D 状态)"
            continue
        fi
        # unmap(经 sysfs, 设备节点缺失也有效)
        # 两套 sysfs remove 接口均接收设备 ID(rbd0 → 0); 按序尝试。
        #   设备目录已不存在 = 映射本来就没有 → 幂等视为成功。
        # ⚠ 改为**后台不等待 + 有界复核**(2026-10-10 实机): 后端已死时 sysfs remove 的**写调用
        #   本身会永久 D 态**(worker .41 实测, 不可杀) —— 同步等待 = 部署无限挂。后台执行后
        #   有界复核(≤10s): 设备目录消失=成功; 超时=告警放行(残映射仅造成 -13 日志刷屏,
        #   不影响新集群; 择机重启清零)。
        if timeout 30 ssh -n -i "${CUR_SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${CUR_SSH_USER}@${ip}" \
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
            # ★ 2026-11-23(CodeRabbit): 只删**已确认 unmap 成功**的这个 id 的设备节点;
            #   旧实现循环后统一 rm -f /dev/rbd* 会误删 KEEP_VOLUME/PV 保留卷或忙设备的节点,
            #   后续 remount/path-open 会失败。分区节点一并清理(id 已消失, 不应再被引用)。
            ssh -n -i "${CUR_SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${CUR_SSH_USER}@${ip}" \
                "sudo rm -f /dev/rbd${id} /dev/rbd${id}p* 2>/dev/null || true" >/dev/null 2>&1 || true
        else
            warn "    ${name}(id=${id}): unmap 未完成(后端已死时 sysfs 写会阻塞; 已后台化不再等待 —— 残映射无碍新集群, 择机重启清零)"
        fi
    done <<< "${maps}"
    # 清理失效的 kubelet CSI 空挂载目录(只清理模式; --list 必须保持只读)。
    # ⚠ 设备节点已在上面的 unmap 成功分支按 id 精确删除, 这里绝不再用 /dev/rbd* 通配。
    if [ "${LIST_ONLY}" != "1" ]; then
        ssh -n -i "${CUR_SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${CUR_SSH_USER}@${ip}" \
            "sudo find /var/lib/kubelet/pods -path '*kubernetes.io~csi*' -type d -empty -delete 2>/dev/null || true" 2>/dev/null || true
    fi
    # ★ 2026-10-10 收尾阶梯(仅清理模式): 该节点映射清完后尝试**模块级卸载**(连客户端
    #   会话/-13 刷屏一起清); 仍有残留 → 计全局账(总账在 main 末尾的洁净度报告)。
    if [ "${LIST_ONLY}" != "1" ]; then
        # ★ 2026-10-13(CodeRabbit): 空输出 = SSH 失败/查询异常 → **状态未知**, 不得归 0 ——
        #   旧行为把失败归 0 → 该节点被误报"内核态清零"且不计入 _TOTAL_LEFT → 总报告假"全部
        #   清零"。只有**真实读到的 0** 才走模块卸载; 未知单独计数, 报告里明示(不并入 LEFT:
        #   LEFT>0 会触发"硬复位"建议, 对未知节点是错误指引)。
        if _left="$(ssh -n -i "${CUR_SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${CUR_SSH_USER}@${ip}" \
            "ls /sys/bus/rbd/devices 2>/dev/null | wc -l" 2>/dev/null)"; then
            _left="${_left//[!0-9]/}"
        else
            _left=""
        fi
        _TOTAL_CLEANED=$(( ${_TOTAL_CLEANED:-0} + cleaned ))
        if [ -z "${_left}" ]; then
            _TOTAL_UNKNOWN=$(( ${_TOTAL_UNKNOWN:-0} + 1 ))
            _UNKNOWN_NODES="${_UNKNOWN_NODES:+${_UNKNOWN_NODES} }${ip}"
            warn "    ${ip}: 内核 rbd 映射数查询失败(SSH 不可达?) —— 状态未知(未计入清零)"
        elif [ "${_left}" = "0" ]; then
            # ★ 采纳远端建议(用户网页提交 96bc395): 模块卸载后**回来验证**是否真的卸载 ——
            #   旧写法无论结果都报"已卸载"; EBUSY(仍有引用)时给出如实告警。
            if ssh -n -i "${CUR_SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${CUR_SSH_USER}@${ip}" \
                "sudo modprobe -r rbd 2>/dev/null; sudo modprobe -r libceph 2>/dev/null; ! lsmod | grep -qE '^(rbd|libceph) '" >/dev/null 2>&1; then
                ok "    ${ip}: rbd/libceph 模块已卸载(内核态清零)"
            else
                warn "    ${ip}: 映射已清零, 但 rbd/libceph 模块仍加载(EBUSY)"
            fi
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
if [ "${#INVENTORY_TARGETS[@]}" -gt 0 ]; then
    for _target in "${INVENTORY_TARGETS[@]}"; do
        IFS='|' read -r _t_ip CUR_SSH_USER CUR_SSH_KEY <<< "${_target}"
        [ -n "${_t_ip}" ] || continue
        cleanup_node "${_t_ip}"
    done
    unset _target _t_ip
else
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        [ -n "${NODE_IP}" ] || continue
        CUR_SSH_USER="$(ssh_user_for_ip "${NODE_IP}")"
        CUR_SSH_KEY="${SSH_KEY}"
        cleanup_node "${NODE_IP}"
    done
fi
echo "---------------------------------------------"
if [ "${LIST_ONLY}" = "1" ]; then
    say "以上为各节点 rbd 映射(非 --list 时清除 [残留] 标记的映射; 若 -13 仍刷屏且存在 mounted=yes 的残留, 对应节点需重启)"
else
    echo "  ▍内核洁净度报告(阶梯: 惰性脱挂 → sysfs 后台清理 → 模块卸载)"
    echo "     本轮已清映射: ${_TOTAL_CLEANED:-0} 个"
    # ★ 2026-10-13(CodeRabbit): "清零"结论仅当 **LEFT=0 且无未知节点** 时才成立 ——
    #   查询失败的节点状态未知, 不能并入"全部节点已清零"。
    if [ "${_TOTAL_LEFT:-0}" -eq 0 ] 2>/dev/null && [ "${_TOTAL_UNKNOWN:-0}" -eq 0 ]; then
        ok "rbd 残留清理完成: 全部节点内核 rbd 侧已清零(映射=0)"
    else
        if [ "${_TOTAL_LEFT:-0}" -ne 0 ] 2>/dev/null; then
            warn "rbd 残留清理完成, 但**仍有 ${_TOTAL_LEFT:-?} 个内核 rbd 映射**(内核持锁, 物理所限)"
            warn "  影响: 仅致 libceph -13 日志刷屏, 无碍新集群数据面 —— 部署可继续"
            warn "  想彻底清零: 对相应节点**硬复位**后重跑本工具(⚠ 优雅重启会卡在 sync; 用 sysrq-b / reboot -f / virsh reset)"
        fi
        if [ "${_TOTAL_UNKNOWN:-0}" -ne 0 ] 2>/dev/null; then
            warn "另有 ${_TOTAL_UNKNOWN} 个节点内核 rbd 状态**未知**(查询失败, 多为 SSH 不可达): ${_UNKNOWN_NODES:-?}"
            warn "  —— 未计入清零; 节点恢复可达后重跑本工具确认"
        fi
    fi
fi
# 2026-11-22: kubespray 前守卫。仍有映射/未知 → 非零退出, 避免 Ansible hardware
#   facts 的 vgs 扫描旧 rbd 时永久 D 态(实机静默挂起 1 小时)。
if [ "${FAIL_IF_LEFT}" = "1" ] && [ "${LIST_ONLY}" != "1" ]; then
    if [ "${_TOTAL_LEFT:-0}" -ne 0 ] 2>/dev/null || [ "${_TOTAL_UNKNOWN:-0}" -ne 0 ] 2>/dev/null; then
        err "内核 rbd 映射未清零(残留=${_TOTAL_LEFT:-0}, 未知节点=${_TOTAL_UNKNOWN:-0}) → 不能进入 kubespray(vgs 会永久 D 态)"
        exit 1
    fi
fi
exit 0
