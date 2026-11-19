#!/bin/bash
# ============================================================
# MODULE: k8s_hosts
# DESC: 同步节点侧 /etc/hosts(NODES hostname → IP, 供 hostNetwork Pod 解析对端) + 可选部署机 /etc/hosts
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# REQUIRES: k8s_passwordless
# 说明:
#   · **节点侧**(所有 NODES): 无条件执行 —— 把每个 NODES hostname→IP 以及当前 API/registry
#     域名(issue #187)写入每台节点的 /etc/hosts, 幂等(先删旧行再追加), 不碰 /etc/hostname;
#     失败即非 0(列出节点)。
#     背景(2026-10-23): NODES hostname 是 K8s 节点名, 但节点上没有解析; hostNetwork Pod 的
#     MCCL/RoCE 多机通信按 hostname 找对端失败 → 回退 127.0.0.1 → 通信失败。
#     背景(issue #187): kubeadm join / bootstrap token 在节点上执行, 节点缺 API_DOMAIN 会
#     `lookup k8s-api.cubestack.io: no such host`; 容器安装时只写部署机不够(容器私有 hosts)。
#   · **部署机** /etc/hosts: UPDATE_ETC_HOSTS=auto(默认)时, 仅当部署机本身在 NODES 里
#     (单节点 / 在 master 上就地部署)才写; 1=强制写, 0=强制不写(尊重运维显式管理)。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ★ 节点侧 hostname 解析必须先于/独立于部署机 hosts 开关: hostNetwork Pod 在节点上运行,
#   部署机 /etc/hosts 对它们没有意义(2026-10-23 MCCL 实机根因)。
say "同步节点侧 /etc/hosts(NODES hostname → IP, 供 hostNetwork Pod 解析对端)..."
sync_nodes_hosts_remote || exit 1

# 部署机 /etc/hosts 开关(issue #187):
#   auto(默认) = 部署机本身在 NODES 里时写(单节点/在 master 上就地部署), 否则跳过;
#   1/0        = 强制写 / 强制不写(尊重运维对 /etc/hosts 的显式管理)。
# 注意: 节点侧(含单节点的那台节点)的 API/registry 域名已由上面的 sync_nodes_hosts_remote
#   远端写入 —— 即使这里跳过(显式 0 或容器安装), kubeadm 在节点上也能解析域名。
_DO_UPDATE=0
case "$(printf '%s' "${UPDATE_ETC_HOSTS:-auto}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) _DO_UPDATE=1 ;;
    0|false|no|off) _DO_UPDATE=0; say "UPDATE_ETC_HOSTS=0: 跳过部署机 /etc/hosts 更新(节点侧域名已同步)" ;;
    auto|"")
        if deploy_host_is_node; then
            _DO_UPDATE=1
            say "部署机本身是 NODES 中的节点 → 更新部署机 /etc/hosts(API/registry 域名)"
        else
            say "跳过部署机 /etc/hosts 更新(部署机不是 NODES 节点; UPDATE_ETC_HOSTS=1 可强制启用)"
        fi ;;
    *)
        warn "UPDATE_ETC_HOSTS=${UPDATE_ETC_HOSTS} 非法(只接受 auto|1|0), 按 auto 处理"
        deploy_host_is_node && _DO_UPDATE=1 || true ;;
esac
if [ "${_DO_UPDATE}" != "1" ]; then
    exit 0
fi

say "更新部署机 /etc/hosts(API/registry 域名 + 节点主机名解析收敛) ..."
# 先删旧行再写当前行(ensure_hosts_entry), 多套集群/换 IP 不再残留同一域名的旧 IP 行
# API_DOMAIN 的解析地址用 api_entry_addr(): 外部 LB(API_EXTERNAL_ADDR) / 已绑 VIP / 首个 master,
# 与节点侧同步和 10_api_local_lb / 07_k8s_scale 的口径一致。
# ⚠ 不能用 API_IP —— 它是"能通 NodePort 的节点 IP"语义(registry mirror/DNAT 判定用), 见其说明。
_API_ENTRY="$(api_entry_addr)" || exit 1
say "  ${API_DOMAIN} → ${_API_ENTRY}"
ensure_hosts_entry "${_API_ENTRY}" "${API_DOMAIN}"
ensure_hosts_entry "${REGISTRY_IP}" "${REGISTRY_DOMAIN}"
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    ensure_hosts_entry "${NODE_IP}" "${NODE_HOSTNAME}"
    ok "已收敛 /etc/hosts: ${NODE_IP} ${NODE_HOSTNAME}"
done
ok "/etc/hosts 更新完成(${API_DOMAIN}/${REGISTRY_DOMAIN} + ${#NODES[@]} 节点)"

# 写后校验(issue #187): ensure_hosts_entry 在非 root / 只读挂载时静默失败, 不能只看返回码。
# API_DOMAIN 解析不到 → kubespray 在 kubeadm 之后创建 bootstrap token 时必然失败;
# 解析到别的 IP(旧集群残留行 / 外部 DNS 优先)同样会让安装打到错误地址。
# 用 resolve_host_ipv4: 外部 DNS 有 AAAA 时 getent hosts 可能先返回 IPv6, 会误判我们的 IPv4 映射。
_API_RESOLVED="$(resolve_host_ipv4 "${API_DOMAIN}")"
if [ -z "${_API_RESOLVED}" ]; then
    err "部署机 /etc/hosts 已更新, 但 ${API_DOMAIN} 仍无法解析"
    err "  修法: 用 root 运行(或容器加 --network host), 或手工写入: ${_API_ENTRY} ${API_DOMAIN}"
    exit 1
fi
if [ "${_API_RESOLVED}" != "${_API_ENTRY}" ]; then
    err "部署机解析 ${API_DOMAIN} → ${_API_RESOLVED}, 期望 ${_API_ENTRY}(旧行残留或外部 DNS 优先)"
    err "  修法: 检查 /etc/hosts 中 ${API_DOMAIN} 的行; 需要时手工写成: ${_API_ENTRY} ${API_DOMAIN}"
    exit 1
fi
unset _API_RESOLVED
ok "部署机解析校验通过: ${API_DOMAIN} → ${_API_ENTRY}"
