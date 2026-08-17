#!/bin/bash
# ============================================================
# CubeStack 公共库: 统一配置加载 + 通用工具函数
# 所有 scripts/*.sh 在 set -euo pipefail 之后 source 本文件
# 配置统一来源: config/cluster.conf (同时驱动虚拟机创建与 kubespray inventory 生成)
# 优先级: 环境变量 > 配置文件 > 内置默认值(内置默认值在配置文件中声明)
# 说明: 本库不执行任何宿主修改,仅供各脚本复用
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_CONF="${CLUSTER_CONF:-${REPO_ROOT}/config/cluster.conf}"

# ---------------- 输出函数 ----------------
say()  { echo -e "\033[36m→  $*\033[0m"; }
ok()   { echo -e "\033[32m✅ $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m"; }
err()  { echo -e "\033[31m【错误】$*\033[0m" >&2; }

# ---------------- 统一配置加载 ----------------
# 环境变量优先: 配置文件内使用 ${VAR:-default},已导出的环境变量不会被覆盖
load_config() {
    if [ -f "${CLUSTER_CONF}" ]; then
        # shellcheck disable=SC1090
        source "${CLUSTER_CONF}"
    else
        warn "未找到配置文件 ${CLUSTER_CONF},使用内置默认值"
        warn "建议: cp ${REPO_ROOT}/config/cluster.conf.example ${CLUSTER_CONF}"
    fi
}

# ---------------- IP / CIDR 工具 ----------------
ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a<<24) + (b<<16) + (c<<8) + d )); }
int2ip() { local n=$1; echo "$(( (n>>24)&255 )).$(( (n>>16)&255 )).$(( (n>>8)&255 )).$(( n&255 ))"; }
mask2int() { local n=0 p; for p in $(echo "$1" | tr '.' ' '); do n=$(( (n<<8) | p )); done; echo $(( n & 0xFFFFFFFF )); }
# <IP> <CIDR> → 退出码 0=在网段内
cidr_contains() {
    local net="${2%%/*}" prefix="${2#*/}" ip_int net_int mask
    ip_int=$(ip2int "$1"); net_int=$(ip2int "$net")
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    [ $(( ip_int & mask )) -eq $(( net_int & mask )) ]
}

# ---------------- MAC 生成 ----------------
# 未显式指定 MAC 时,按主机名确定性生成(幂等,重复部署 MAC 不变)
# <hostname> → 52:54:00:xx:xx:xx
mac_from_name() {
    local hex
    hex="$(printf '%s' "$1" | md5sum | cut -c1-6)"
    echo "52:54:00:${hex:0:2}:${hex:2:2}:${hex:4:2}"
}

# ---------------- 节点解析 ----------------
# 解析 NODES 配置行为字段,输出以 IFS=, 分隔的字段
# 格式: role,hostname,ip,mac,mem_g,cpu,disk_g,ssh_user,ssh_password
# mac: 显式或 "-"(自动生成); ssh_password: 显式或 "-"(用角色默认)
node_password() { # <role> <password>
    [ "$1" = "worker" ] && { [ -n "$2" ] && [ "$2" != "-" ] && echo "$2" || echo "${WORKER_SSH_PASSWORD:-}"; } \
                      || { [ -n "$2" ] && [ "$2" != "-" ] && echo "$2" || echo "${SSH_DEFAULT_PASSWORD:-}"; }
}

# 获取根目录(供其它脚本引用路径)
repo_root() { echo "${REPO_ROOT}"; }

# ---------------- 节点注册到 cluster.conf ----------------
# 将节点信息写入 config/cluster.conf 的 NODES 数组(幂等)
# 用法: register_node_to_conf <role> <hostname> <ip> <mac> <mem> <cpu> <disk> <user> <password>
register_node_to_conf() {
    local role="$1" hostname="$2" ip="$3" mac="$4" mem="$5" cpu="$6" disk="$7" user="$8" pw="$9"
    local conf_file="${CLUSTER_CONF:-${REPO_ROOT}/config/cluster.conf}"

    [ -f "${conf_file}" ] || { warn "cluster.conf 不存在: ${conf_file}, 跳过注册 ${hostname}"; return 0; }
    [ -w "${conf_file}" ] || { warn "cluster.conf 不可写: ${conf_file}, 跳过注册 ${hostname}"; return 0; }

    # 已存在则跳过(幂等)
    if grep -qF "${hostname}," "${conf_file}" 2>/dev/null; then
        echo -e "\033[33m⚠ ${hostname} 已在 ${conf_file} 中注册,跳过\033[0m"
        return 0
    fi

    local new_entry="\"${role},${hostname},${ip},${mac},${mem},${cpu},${disk},${user},${pw}\""
    echo -e "\033[36m→ 注册节点到 ${conf_file}: ${new_entry}\033[0m"

    # 在 NODES=( 区块的结尾 ) 前插入新条目(awk 实现, 可靠)
    awk -v entry="  ${new_entry}" '
        /^NODES=\(/ { in_nodes=1 }
        in_nodes && /^\)/ {
            print entry
            in_nodes=0
        }
        { print }
    ' "${conf_file}" > "${conf_file}.tmp" && mv "${conf_file}.tmp" "${conf_file}"

    echo -e "\033[32m✅ ${hostname} 已注册到 cluster.conf\033[0m"
}
