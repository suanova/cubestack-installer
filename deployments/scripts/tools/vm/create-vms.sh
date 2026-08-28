#!/bin/bash
# ============================================================
# create-vms.sh — 按 vm-nodes.conf 批量创建/启动虚拟机, 并自动注入 cluster.conf
# 用途: 所有创建虚拟机的脚本统一在本目录(tools/vm/); 本脚本是入口:
#   1. 读取 tools/vm/vm-nodes.conf(10字段: role,hostname,ip,mac,mem,cpu,disk,user,pw,node_type)
#   2. 对每台 VM: 已存在 → 启动+开机自启; 缺失 → create-libvirt-vm.sh 创建
#   3. 每台确认 running 后, **自动把 5 字段信息注入 cluster.conf 的 NODES**
#      (role,hostname,ip,ssh_user,ssh_password; 密码为 "-" 用默认), 幂等
#   4. 等待新启动 VM 的 SSH 就绪(最长 180s/台)
# 用法: sudo ./create-vms.sh [--only <hostname>]
# 数据源: tools/vm/vm-nodes.conf + cluster.conf(网络/镜像/默认密码)
# ============================================================
set -euo pipefail

# ============ 先恢复 cluster.conf(在任何 source/load_config 之前) ============
# create-vms.sh 每次执行都把 cluster.conf 重建为"可 source"的完整配置:
#   1. 无条件用 cluster.conf.example 覆盖 cluster.conf(备份旧文件到 .bak);
#   2. 覆盖后 NODES 先清空(保留 NODES=() 空数组);
#   3. 之后在本脚本每台 VM 创建完毕时, 用 vm-nodes.conf 全部 VM 整体覆盖 NODES。
#   4. 最后校验 cluster.conf 是否合法(bash -n), 不合法即终止。
# 这避免了 load_config source 到损坏(截断/括号未闭合)的旧 cluster.conf 而报
# "unexpected EOF" —— 必须在 source lib-common 抛错前就把配置恢复好。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"   # tools/vm → tools → scripts → deployments → 仓库根(4级)
CLUSTER_CONF="${CLUSTER_CONF:-${REPO_ROOT}/deployments/config/cluster.conf}"
CONF_TEMPLATE="${CLUSTER_CONF}.example"
[ -f "${CONF_TEMPLATE}" ] || { echo "【错误】模板不存在: ${CONF_TEMPLATE}"; exit 1; }
[ -f "${CLUSTER_CONF}" ] && cp "${CLUSTER_CONF}" "${CLUSTER_CONF}.bak" 2>/dev/null || true
cp "${CONF_TEMPLATE}" "${CLUSTER_CONF}" || { echo "【错误】恢复 ${CONF_TEMPLATE} → ${CLUSTER_CONF} 失败"; exit 1; }
# NODES 清空(保留 NODES=() 空数组): 让 bin-cluster.conf 成为 VM 覆盖的唯一来源
awk '
    /^NODES=\(/ { in_nodes=1; print; next }
    in_nodes && /^\)/ { print; in_nodes=0; next }
    in_nodes { next }
    { print }
' "${CLUSTER_CONF}" > "${CLUSTER_CONF}.tmp" && mv "${CLUSTER_CONF}.tmp" "${CLUSTER_CONF}"
echo "→ 已用模板重建 cluster.conf: cp ${CONF_TEMPLATE} ${CLUSTER_CONF}"
echo "→ 更新完 NODES 后会自动校验 cluster.conf 合法性。"

# ============ 再加载公共库 + 配置(此时 cluster.conf 已完整可 source) ============
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ============ 校验 cluster.conf 合法性(重建/更新 NODES 后调用) ============
# 任何对 cluster.conf 的写入完成后, 都 bash -n 校验; 不合法立即终止, 避免下游部署
# source 到损坏配置而报 "unexpected EOF"。
assert_conf_valid() {
    if ! bash -n "${CLUSTER_CONF}" 2>/dev/null; then
        err "cluster.conf 语法不合法(括号未闭合/格式错误): ${CLUSTER_CONF}"; exit 1
    fi
    ok "cluster.conf 语法校验通过: ${CLUSTER_CONF}"
}

ONLY=""
[ "${1:-}" = "--only" ] && ONLY="${2:-}"

# vm-nodes.conf 缺失 → 无虚拟机需要创建(裸金属集群), 幂等跳过
if [ ! -f "${VM_NODES_CONF}" ]; then
    say "未找到 VM 配置 ${VM_NODES_CONF}, 无虚拟机需要创建(纯裸金属集群)"
    exit 0
fi
[ -s "${VM_NODES_CONF}" ] || { say "VM 配置为空, 无虚拟机需要创建"; exit 0; }

# ============ 宿主网络初始化(bridge/nat) ============
# 有 VM 要创建才需要宿主网络(网桥/SNAT/NAT); 已从 deploy-cluster.sh 默认序列移出,
# 改在这里、创建 VM 之前自动执行。不重复执行: 已存在的网桥/网络由 setup 脚本幂等跳过。
say "初始化宿主网络 (NET_MODE=${NET_MODE:-bridge}) ..."
case "${NET_MODE:-bridge}" in
    bridge)
        bash "${SCRIPT_DIR}/tools/net/setup-vm-network.sh"
        ;;
    nat)
        bash "${SCRIPT_DIR}/tools/net/setup-libvirt-nat.sh" "${NAT_NET_NAME:-cubestack-nat}"
        ;;
    *) err "未知 NET_MODE: ${NET_MODE}"; exit 1 ;;
esac
ok "宿主网络就绪"

say "按 ${VM_NODES_CONF} 创建/启动虚拟机 ..."
BOOTED_VMS=()
# 收集 vm-nodes.conf 全部 VM 的 5 字段条目(密码归一化后), 结束后整体覆盖 cluster.conf NODES
VM_ENTRIES_IFS=""
for line in $(vm_conf_entries); do
    [ -z "${line}" ] && continue
    node_parse "${line}"    # 10字段 → NODE_* (NODE_TYPE=vm)
    [ -n "${NODE_HOSTNAME}" ] || continue
    # 过滤: 命令行 --only 或框架 --only(ONLY_HOSTS, 由 deploy-cluster.sh 导出)
    [ -z "${ONLY}" ] || [ "${NODE_HOSTNAME}" = "${ONLY}" ] || continue
    node_matches "${NODE_HOSTNAME}" || continue
    [ "${NODE_TYPE:-vm}" = "vm" ] || { warn "跳过非 vm 节点: ${NODE_HOSTNAME}(${NODE_TYPE})"; continue; }
    # 旧格式兼容: MAC 为 "-" 时按主机名确定性生成(幂等)
    [ "${NODE_MAC}" = "-" ] && NODE_MAC="$(mac_from_name "${NODE_HOSTNAME}")"

    if virsh list --all | grep -qw "${NODE_HOSTNAME}"; then
        if virsh domstate "${NODE_HOSTNAME}" 2>/dev/null | grep -qi "running"; then
            ok "VM ${NODE_HOSTNAME} 已在运行"
        else
            say "启动 VM ${NODE_HOSTNAME} (当前: $(virsh domstate "${NODE_HOSTNAME}" 2>/dev/null)) ..."
            virsh start "${NODE_HOSTNAME}" >/dev/null 2>&1 && { ok "VM ${NODE_HOSTNAME} 已启动"; BOOTED_VMS+=("${NODE_IP}"); } \
                || warn "VM ${NODE_HOSTNAME} 启动失败,请检查(virsh list --all / virsh start ${NODE_HOSTNAME})"
        fi
        virsh autostart "${NODE_HOSTNAME}" >/dev/null 2>&1 \
            && ok "VM ${NODE_HOSTNAME} 已设置开机自启" \
            || warn "VM ${NODE_HOSTNAME} 设置开机自启失败(virsh autostart ${NODE_HOSTNAME})"
    else
        say "创建 VM ${NODE_HOSTNAME} (${NODE_MEM}G/${NODE_CPU}C/${NODE_DISK}G, ${NODE_IP}, ${NODE_MAC}) ..."
        AUTO_REGISTER_CLUSTER=1 bash "${SCRIPT_DIR}/tools/vm/create-libvirt-vm.sh" \
            "${NODE_HOSTNAME}" "${NODE_MEM}" "${NODE_CPU}" "${NODE_DISK}" "${NODE_MAC}" "${NODE_IP}"
        BOOTED_VMS+=("${NODE_IP}")
    fi

    # 密码归一化("-"/空→默认密码), 收集该 VM 5 字段条目(供最终整体替换 NODES)
    if [ -z "${NODE_PW}" ] || [ "${NODE_PW}" = "-" ]; then
        NODE_PW="$(node_default_pw "${NODE_ROLE}")"
    fi
    VM_ENTRIES_IFS="${VM_ENTRIES_IFS}"$'\n'"${NODE_ROLE},${NODE_HOSTNAME},${NODE_IP},${NODE_USER},${NODE_PW}"
    # 记录一个 VM IP 用于后续自动推导 METALLB_POOL
    [ -n "${NODE_IP}" ] && VM_IP_FIRST="${VM_IP_FIRST:-${NODE_IP}}"
done

# ============ 自动推导 METALLB_POOL(与 VM 同网段) ============
# MetalLB Layer2 要求池内 IP 与节点同二层网络; 虚拟机集群的节点在 VM 网段,
# 因此创建虚拟机后把 METALLB_POOL 改为与 VM 同网段的一段空闲地址。
# 生成规则: 取第一个 VM IP 的网段, 池起点 = 该网段后半段(如 .200-.209), 避免与 VM 静态 IP 冲突。
if [ -n "${VM_IP_FIRST:-}" ]; then
    NEW_POOL="$(python3 - "${VM_IP_FIRST}" << 'PY'
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
# 用 /24 网段计算: 起点 = 网段 .200, 终点 = 网段 .209
net = ipaddress.ip_network(str(ip) + "/24", strict=False)
base = int(net.network_address)
start = base + 200
end   = base + 209
print(f"{ipaddress.ip_address(start)}-{ipaddress.ip_address(end)}")
PY
)"
    # 用 sed 更新 cluster.conf 的 METALLB_POOL(写**实际值**, 而非 ${VAR} 模板字面量)
    # 否则 load_config source 时 NEW_POOL 未定义 → 回退旧默认(如 10.66.1.130-139), 部署仍用旧 IP。
    sed -i -E "s|^(METALLB_POOL=).*|METALLB_POOL=\"${NEW_POOL}\"   # 由 create-vms.sh 自动推导(与 VM 网段同段)|" "${CLUSTER_CONF}"
    ok "自动更新 METALLB_POOL → ${NEW_POOL}(与 VM 网段同为 ${VM_IP_FIRST}.0/24, 池 .200-.209 避开 VM 静态 IP)"
fi

# 用 vm-nodes.conf 全部 VM 整体替换 cluster.conf NODES(而非逐条幂等追加)
if [ -n "${VM_ENTRIES_IFS}" ]; then
    REPLACE_NODES_IFS="${VM_ENTRIES_IFS#?}" replace_nodes_to_conf "${CLUSTER_CONF}"
fi

# 最终校验 cluster.conf 合法性(括号闭合/格式正确); 不合法立即终止, 避免下游 source 失败
assert_conf_valid

# 等待本次启动/创建的 VM SSH 就绪(端口探测, 免认证)
if [ "${#BOOTED_VMS[@]}" -gt 0 ]; then
    say "等待 ${#BOOTED_VMS[@]} 台 VM 的 SSH 就绪(最长 180s/台) ..."
    for boot_ip in "${BOOTED_VMS[@]}"; do
        READY=0
        for i in $(seq 1 18); do
            ssh_port_open "${boot_ip}" && { READY=1; break; }
            [ "${i}" -eq 18 ] && break
            sleep 10
        done
        [ "${READY}" = "1" ] && ok "  ${boot_ip} SSH 就绪" || warn "  ${boot_ip} 180s 内 SSH 未就绪,可能仍需等待"
    done
fi

ok "虚拟机创建/启动完成(已注入 cluster.conf NODES)"
