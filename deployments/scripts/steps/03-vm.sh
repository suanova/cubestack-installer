#!/bin/bash
# ============================================================
# 部署模块: 03-vm — 创建虚拟机并确保 running
# 对 NODES 中 node_type=vm 的节点: 已存在则启动, 缺失则 create-libvirt-vm.sh 创建(自带自动启动)
# 新启动/创建的 VM 会等待 SSH 就绪(最长 180s/台), 避免后续模块连不上
# 支持 --only 过滤(ONLY_HOSTS 环境变量)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib-common.sh"
load_config

say "创建/启动集群虚拟机(vm 节点) ..."
BOOTED_VMS=()
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    IFS=, read -r role hostname ip mac mem cpu disk user pw node_type <<<"${line}"
    node_is_vm "${role}" "${mac}" "${mem}" "${node_type:-}" || continue   # bm/裸金属 → worker_bm 模块
    node_matches "${hostname}" || continue
    [ "${mac}" = "-" ] && mac="$(mac_from_name "${hostname}")"

    if virsh list --all | grep -qw "${hostname}"; then
        if virsh domstate "${hostname}" 2>/dev/null | grep -qi "running"; then
            ok "VM ${hostname} 已在运行"
        else
            say "启动 VM ${hostname} (当前: $(virsh domstate "${hostname}" 2>/dev/null)) ..."
            virsh start "${hostname}" >/dev/null 2>&1 && { ok "VM ${hostname} 已启动"; BOOTED_VMS+=("${ip}"); } \
                || warn "VM ${hostname} 启动失败,请检查(virsh list --all / virsh start ${hostname})"
        fi
        # 确保设置开机自启(宿主机重启后自动启动)
        virsh autostart "${hostname}" >/dev/null 2>&1 \
            && ok "VM ${hostname} 已设置开机自启" \
            || warn "VM ${hostname} 设置开机自启失败(virsh autostart ${hostname})"
    else
        say "创建 VM ${hostname} (${mem}G/${cpu}C/${disk}G, ${ip}, ${mac}) ..."
        AUTO_REGISTER_CLUSTER=1 bash "${SCRIPT_DIR}/create-libvirt-vm.sh" "${hostname}" "${mem}" "${cpu}" "${disk}" "${mac}" "${ip}"
        BOOTED_VMS+=("${ip}")
    fi
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

ok "虚拟机模块完成"
