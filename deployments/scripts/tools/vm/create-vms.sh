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

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

ONLY=""
[ "${1:-}" = "--only" ] && ONLY="${2:-}"

# vm-nodes.conf 缺失 → 无虚拟机需要创建(裸金属集群), 幂等跳过
if [ ! -f "${VM_NODES_CONF}" ]; then
    say "未找到 VM 配置 ${VM_NODES_CONF}, 无虚拟机需要创建(纯裸金属集群)"
    exit 0
fi
[ -s "${VM_NODES_CONF}" ] || { say "VM 配置为空, 无虚拟机需要创建"; exit 0; }

say "按 ${VM_NODES_CONF} 创建/启动虚拟机 ..."
BOOTED_VMS=()
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

    # 自动注入 5 字段到 cluster.conf(幂等; create-libvirt-vm.sh 已注册新 VM, 这里兜底补已存在 VM)
    register_node_to_conf "${NODE_ROLE}" "${NODE_HOSTNAME}" "${NODE_IP}" "${NODE_USER}" "${NODE_PW}"
done

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
