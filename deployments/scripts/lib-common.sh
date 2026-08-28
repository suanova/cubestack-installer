#!/bin/bash
# ============================================================
# CubeStack 公共库: 统一配置加载 + 通用工具函数
# 所有 deployments/scripts/*.sh 在 set -euo pipefail 之后 source 本文件
# 配置统一来源: deployments/config/cluster.conf
# 优先级: 环境变量 > 配置文件 > 内置默认值(内置默认值在配置文件中声明)
# 说明: 本库不执行任何宿主修改,仅供各脚本复用
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"          # deployments/scripts/ → 根目录

# 真实用户 home(sudo bash 下 HOME=/root 会出错, 用 SUDO_USER 定位真实用户)
REAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
REAL_HOME="$(getent passwd "${REAL_USER}" 2>/dev/null | cut -d: -f6)"
[ -n "${REAL_HOME}" ] || REAL_HOME="${HOME}"
export REAL_HOME REAL_USER
# 统一 HOME 为真实用户(sudo bash 下 HOME=/root, 会导致配置里 ${HOME}/.ssh 等解析错误)
[ -n "${REAL_HOME}" ] && export HOME="${REAL_HOME}"

# ---------------- 配置文件: 统一读取 cluster.conf ----------------
CLUSTER_CONF="${CLUSTER_CONF:-${REPO_ROOT}/deployments/config/cluster.conf}"
export CLUSTER_CONF

# ---------------- 集群名(固定默认, 单集群) ----------------
# 默认集群名 cubestack-cluster, 用于 inventory/offline-files 目录与日志命名; 环境变量可覆盖
CLUSTER_NAME="${CLUSTER_NAME:-cubestack-cluster}"
export CLUSTER_NAME

# ---------------- 宿主机物理 IP 自动检测 ----------------
# 不 hardcode: 自动检测宿主机物理网卡 IP(排除虚拟网桥 docker0/privbr0/virbr0 等)
detect_host_ip() {
    local ip=""
    # 方法1: 默认路由出口源 IP(最可靠)
    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    [ -n "${ip}" ] && echo "${ip}" && return 0
    # 方法2: hostname -I 过滤虚拟网桥/保留地址
    ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^(10\.244\.|10\.245\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.122\.|127\.|169\.254\.)' | head -1)"
    [ -n "${ip}" ] && echo "${ip}" && return 0
    # 方法3: 枚举物理网卡 IP
    ip="$(ip -4 addr show 2>/dev/null | grep -oP 'inet \K[0-9.]+' | grep -vE '^(10\.244\.|10\.245\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.122\.|127\.|169\.254\.)' | head -1)"
    [ -n "${ip}" ] && echo "${ip}" || echo "127.0.0.1"
}

# 从地址池取首个可用地址(供 REGISTRY_IP 自动派生): 支持 起止区间 / CIDR / 单地址
# 区间/单地址 → 首地址本身; CIDR → 网络首地址 +1(首个可用)
# 用法: first_pool_addr "<METALLB_POOL>" → 首个可用地址
first_pool_addr() {
    python3 - "${1:-}" << 'PY'
import ipaddress, sys
p = (sys.argv[1] or "").strip()
if not p:
    sys.exit(0)
if "/" in p:
    try:
        net = ipaddress.ip_network(p, strict=False)
        print(str(net.network_address + 1)); sys.exit(0)
    except Exception:
        pass
if "-" in p:
    print(p.split("-", 1)[0].strip()); sys.exit(0)
print(p)
PY
}

# 读 docker-save tar 的源镜像名(manifest.json RepoTags[0]); 无则输出空
# 用法: tar_first_image_tag <tar文件> → 源镜像 ref(如 cr.metax-tech.com/cloud/gpu-label:0.15.3)
# 供 tar 离线加载模式推导目标 repo/tag(与 docker save 生成的 tar 兼容)
tar_first_image_tag() {
    python3 - "${1:-}" << 'PY'
import json, sys, tarfile
p = sys.argv[1]
try:
    tags = []
    with tarfile.open(p, "r") as t:
        try:
            m = t.extractfile("manifest.json")
            tags = (json.load(m) or [{}])[0].get("RepoTags") or []
        except (KeyError, TypeError, IndexError, json.JSONDecodeError):
            pass
    # 优先取带冒号 tag、非 digest 引用的条目
    for tag in tags:
        if tag and ":" in tag and "@sha256" not in tag:
            print(tag); sys.exit(0)
    if tags:
        print(tags[0]); sys.exit(0)
except Exception:
    sys.exit(0)
PY
}

# ---------------- 断点续跑: 状态文件 ----------------
# 统一的状态文件,记录已完成的任务阶段
# 用法: save_state <phase> <value>; get_state <phase>; clear_state
STATE_FILE="${REPO_ROOT}/deployments/config/.deploy.state"
save_state() {
    local key="$1" val="$2"
    # 移除旧记录再写入(避免重复)
    grep -vF "${key}=" "${STATE_FILE}" 2>/dev/null > "${STATE_FILE}.tmp" || true
    echo "${key}=${val}" >> "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "${STATE_FILE}"
}
get_state() {
    grep -F "$1=" "${STATE_FILE}" 2>/dev/null | tail -1 | cut -d= -f2-
}
clear_state() {
    rm -f "${STATE_FILE}"
}
# 检查是否所有 phases 都已完成 → 上次部署成功
is_state_completed() {
    local phases=("$@")
    for p in "${phases[@]}"; do
        [ "$(get_state "$p")" = "done" ] || return 1
    done
    return 0
}

# ---------------- 输出函数(同时写入日志文件) ----------------
# 日志文件路径: 设置 LOG_FILE 后, 所有输出同时写入该文件
# 用法: export LOG_FILE=/tmp/deploy.log; sudo ./deploy-cluster.sh ...
# 日志开关: LOG_VERBOSE=1 显示详细日志(默认) / 0 仅显示关键信息
LOG_VERBOSE="${LOG_VERBOSE:-1}"
_log_file() { [ -n "${LOG_FILE:-}" ] && echo -e "$*" >> "${LOG_FILE}" 2>/dev/null || true; }
say()  { local m="→  $*"; echo -e "\033[36m${m}\033[0m"; _log_file "${m}"; }
ok()   { local m="✅ $*"; echo -e "\033[32m${m}\033[0m"; _log_file "${m}"; }
warn() { local m="⚠  $*"; echo -e "\033[33m${m}\033[0m"; _log_file "${m}"; }
err()  { local m="【错误】$*"; echo -e "\033[31m${m}\033[0m" >&2; _log_file "${m}"; }
vlog() { [ "${LOG_VERBOSE}" = "1" ] && { local m="[DEBUG] $*"; echo -e "\033[90m${m}\033[0m"; _log_file "${m}"; } || true; }

# ---------------- skopeo 运行时最小 trust policy(/etc/containers/policy.json) ----------------
# 本机(尤其 CLI 容器内)无容器运行时 daemon 配置目录时, skopeo copy/inspect 会因读不到
# policy.json 而 fatal: "Error loading trust policy: open /etc/containers/policy.json: no such file or directory"。
# 所有用 skopeo 的模块(tar 镜像推送: gpu_operator/lws/envoy/... )source 本库后即自动就绪。
# 幂等: 已存在则不覆盖。insecureAcceptAnything 与本仓库离线内网 registry(--tls-verify=false)语义一致。
ensure_skopeo_policy() {
    [ -f "/etc/containers/policy.json" ] && return 0
    if ! mkdir -p /etc/containers 2>/dev/null; then
        warn "无法创建 /etc/containers(无写权限): skopeo 推送可能因缺 policy.json 失败(容器需 root / 可写 /etc)"
        return 1
    fi
    cat > /etc/containers/policy.json <<'POLICY_EOF'
{
    "default": [
        {
            "type": "insecureAcceptAnything"
        }
    ],
    "transports": {}
}
POLICY_EOF
    ok "已生成 skopeo 最小 trust policy: /etc/containers/policy.json"
}
ensure_skopeo_policy

# ---------------- 统一配置加载 ----------------
# 环境变量优先: 配置文件内使用 ${VAR:-default},已导出的环境变量不会被覆盖
load_config() {
    if [ -f "${CLUSTER_CONF}" ]; then
        # shellcheck disable=SC1090
        source "${CLUSTER_CONF}"
    else
        warn "未找到配置文件 ${CLUSTER_CONF},使用内置默认值"
        warn "建议: cp ${REPO_ROOT}/deployments/config/cluster.conf.example ${CLUSTER_CONF}"
    fi
    # 宿主机物理 IP 自动检测(不 hardcode): 仅当未显式设置或仍是占位符时覆盖
    if [ -z "${HOST_PHYS_IP:-}" ] || [ "${HOST_PHYS_IP}" = "CHANGE_ME" ]; then
        HOST_PHYS_IP="$(detect_host_ip)"
        export HOST_PHYS_IP
        vlog "自动检测宿主机物理 IP: ${HOST_PHYS_IP}"
    fi
    # API 入口地址默认取第一个 master IP(VM 与裸金属统一, 不再使用宿主机物理 IP):
    # 宿主机/节点都直接连第一个 master 的 6443 —— 桥接模式宿主可达 VM 网段, NAT 模式宿主经
    # libvirt 可达, 裸金属同网段直连, 均无需把 API 入口指向宿主机再做 DNAT。
    # 显式设置 APISERVER_ADDRESS(如 HAProxy)时保留。
    if [ -z "${APISERVER_ADDRESS:-}" ]; then
        for line in "${NODES[@]:-}"; do
            [ -z "${line}" ] && continue
            node_parse "${line}"
            [ "${NODE_ROLE}" = "master" ] && [ -n "${NODE_IP}" ] && { APISERVER_ADDRESS="${NODE_IP}"; export APISERVER_ADDRESS; vlog "API 入口=第一个 master: ${NODE_IP}"; break; }
        done
    fi
    # 全局派生变量(由 cluster.conf 变量派生, 各脚本直接引用, 不各自设置本地变量):
    #   API_IP       API 入口地址 = APISERVER_ADDRESS(默认第一个 master IP; 显式设置时保留)
    #   API_DOMAIN   API Server 域名(跨网段统一入口), 默认 k8s-api.nova.local
    API_IP="${API_IP:-${APISERVER_ADDRESS:-}}"
    API_DOMAIN="${API_DOMAIN:-${APISERVER_DOMAIN:-k8s-api.nova.local}}"
    export API_IP API_DOMAIN
    # 全局派生变量(续): 离线文件路径
    #   OFFLINE_FILES_DIR  离线文件根目录(二进制/镜像/离线包), 全局唯一可切换点
    #                      默认 ${REPO_ROOT}/deployments/offline-files/kubespray
    #   LOCAL_REPO_DIR     当前集群离线资源目录 = ${OFFLINE_FILES_DIR}/${CLUSTER_NAME}
    #                      (若显式设置了 LOCAL_REPO_DIR, 保留不覆盖; 否则统一收敛到 OFFLINE_FILES_DIR)
    OFFLINE_FILES_DIR="${OFFLINE_FILES_DIR:-${REPO_ROOT}/deployments/offline-files/kubespray}"
    if [ -z "${LOCAL_REPO_DIR:-}" ]; then
        LOCAL_REPO_DIR="${OFFLINE_FILES_DIR}/${CLUSTER_NAME:-cubestack-cluster}"
    fi
    export OFFLINE_FILES_DIR LOCAL_REPO_DIR
    # 全局派生变量(续): REGISTRY_IP 留空时从 METALLB_POOL 自动取池内首地址作为 LoadBalancer VIP
    # (cluster.conf 约定 "留空 = 自动派生", 与 sync-kubespray-config.sh 写入 addons.yml 的规则一致;
    #  centralized 于此, 让 deploy-registry.sh / setup-registry-expose.sh 等所有消费者拿到同一值)
    # 标记是否显式指定(供 deploy-registry.sh 冲突检测: 显式设置不再提示)
    export REGISTRY_IP_EXPLICIT="${REGISTRY_IP_EXPLICIT:-0}"
    if [ -z "${REGISTRY_IP:-}" ]; then
        REGISTRY_IP="$(first_pool_addr "${METALLB_POOL:-}")"
        export REGISTRY_IP
        vlog "REGISTRY_IP 留空, 自动取 METALLB_POOL=${METALLB_POOL:-} 首地址 → ${REGISTRY_IP}"
    else
        export REGISTRY_IP_EXPLICIT=1
    fi
}

# ---------------- 指定节点过滤(--only) ----------------
# 仅在 ONLY_HOSTS(逗号分隔, 由 deploy-cluster.sh --only 收集)非空时过滤
# --only 过滤: 支持全名精确匹配或短名后缀匹配
# (如 --only worker02 可匹配 cubestack-k8s-worker02)
node_matches() {
    [ -z "${ONLY_HOSTS:-}" ] && return 0
    local h
    for h in ${ONLY_HOSTS//,/ }; do
        [ "$h" = "$1" ] && return 0
        case "$1" in
            *"-${h}") return 0 ;;   # 短名后缀: cubestack-k8s-worker02 匹配 worker02
        esac
    done
    return 1
}

# SSH 端口探测(免认证,仅确认就绪)
ssh_port_open() { timeout 3 bash -c "echo > /dev/tcp/$1/22" 2>/dev/null; }

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

# ---------------- 节点解析(统一, 兼容新5字段/旧10字段) ----------------
# cluster.conf NODES 新格式(5字段, 不区分 vm/bm): role,hostname,ip,ssh_user,ssh_password
#   · ssh_password 为 "-" 或空 → 用默认密码 SSH_DEFAULT_PASSWORD(全节点默认一致)
#   · ssh_password 为显式值   → 该节点用此密码(支持裸金属不同密码场景)
# 旧格式(10字段, 向后兼容): role,hostname,ip,mac,mem_g,cpu,disk_g,ssh_user,ssh_password,node_type
# 用法: node_parse <NODES行> → 设置全局变量:
#   NODE_ROLE / NODE_HOSTNAME / NODE_IP / NODE_USER / NODE_PW(已归一为真实密码)
#   NODE_MAC / NODE_MEM / NODE_CPU / NODE_DISK / NODE_TYPE(仅旧格式/VM 配置行有值)
node_parse() {
    local line="$1" f4 f5
    NODE_ROLE=""; NODE_HOSTNAME=""; NODE_IP=""; NODE_USER=""; NODE_PW=""
    NODE_MAC=""; NODE_MEM=""; NODE_CPU=""; NODE_DISK=""; NODE_TYPE=""
    IFS=, read -r NODE_ROLE NODE_HOSTNAME NODE_IP f4 f5 _f6 _f7 _f8 _f9 _f10 <<<"${line}"
    # 格式判定: 旧10字段第4位=MAC(或 "-" 且存在第8位用户); 新5字段第4位=SSH 用户名
    if [[ "${f4}" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || { [ "${f4}" = "-" ] && [ -n "${_f8}" ]; }; then
        NODE_MAC="${f4}"; NODE_MEM="${f5}"; NODE_CPU="${_f6}"; NODE_DISK="${_f7}"
        NODE_USER="${_f8}"; NODE_PW="${_f9}"; NODE_TYPE="${_f10:-}"
    else
        NODE_USER="${f4}"; NODE_PW="${f5}"
    fi
    # 密码归一: 显式密码优先; "-"/空 → 默认密码(全节点默认一致)
    if [ -z "${NODE_PW}" ] || [ "${NODE_PW}" = "-" ]; then
        NODE_PW="$(node_default_pw "${NODE_ROLE}")"
    fi
}

# 默认密码: 全节点默认一致(SSH_DEFAULT_PASSWORD); 兼容旧 WORKER_SSH_PASSWORD(仅默认未设时回退)
# 用法: node_default_pw <role> → 默认密码(可空)
node_default_pw() {
    if [ -n "${SSH_DEFAULT_PASSWORD:-}" ]; then
        echo "${SSH_DEFAULT_PASSWORD}"
    elif [ "$1" = "worker" ] && [ -n "${WORKER_SSH_PASSWORD:-}" ]; then
        echo "${WORKER_SSH_PASSWORD}"
    fi
}

# 旧接口(向后兼容): node_password <role> <explicit_pw> → 解析后密码
#   explicit_pw 非 "-" 且非空 → 原样返回(节点独立密码); 否则 → 默认密码
node_password() {
    local pw="$2"
    if [ -n "${pw}" ] && [ "${pw}" != "-" ]; then echo "${pw}"; else node_default_pw "$1"; fi
}

# ---------------- 集群内置 registry 就绪等待(共享, 防 MetalLB 竞态) ----------------
# MetalLB Layer2 VIP 出现后, speaker ARP 通告与 kube-proxy DNAT 规则需时间才生效;
# kubespray 刚部署完时 speaker 冷启动可能被 liveness 误杀重启, registry pod 可能仍在拉镜像,
# → 所有连 registry 的模块统一用本函数重试(默认 90s, 每 2s), 避免误报不可达。
# 注: 不能用 ping VIP 判活(ICMP 无 DNAT 规则必回 "port unreachable"), 只能 curl 服务端口。
# 用法: wait_registry_ready <url> [重试次数=45] → 退出码 0=可达
wait_registry_ready() {
    local url="$1" tries="${2:-45}" t
    for t in $(seq 1 "${tries}"); do
        curl -s -m 8 "${url}" >/dev/null 2>&1 && return 0
        [ "${t}" -lt "${tries}" ] && { say "  ${url} 未就绪, 等待第 ${t}/${tries} 次(MetalLB 数据面/registry pod 初始化) ..."; sleep 2; }
    done
    return 1
}

# ---------------- 宿主机 kubectl/helm 访问集群(共享, 防 TLS/DNAT 坑) ----------------
# 从第一个 master 下载 /etc/kubernetes/admin.conf 并同步到 ~/.kube/config, 同时:
#   ① server 改写为证书 SAN 内的 API_DOMAIN(k8s-api.nova.local) —— admin.conf 默认
#      直连 master IP, 证书 SAN 常不含该 IP → 宿主机 kubectl 会 TLS x509 校验失败;
#   ② 调用 tools/lb/setup-api-expose.sh 幂等配置宿主机 6443→first master 的 DNAT
#      (PREROUTING + OUTPUT), 让 API_DOMAIN 从宿主机可访问。
# 所有连 API 的模块(gpu_operator/gpu_lws/envoy_*/...)统一复用本函数, 不各自复制。
# 用法: sync_kubeconfig → 退出码 0=宿主机可访问集群
sync_kubeconfig() {
    local tmp newctx
    tmp="$(mktemp)"
    local fm="${FIRST_MASTER:-$(first_master_ip)}"
    [ -n "${fm}" ] || { rm -f "${tmp}"; err "未找到 master 节点(无法下载 admin.conf)"; return 1; }
    # admin.conf 属 root(600), scp 会 Permission denied → 用 ssh + sudo cat 读取
    ssh -i "${SSH_KEY:-${HOME}/.ssh/cubestack_k8s}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "${SSH_USER:-ubuntu}@${fm}" "sudo cat /etc/kubernetes/admin.conf" > "${tmp}" 2>/dev/null \
        || { rm -f "${tmp}"; return 1; }
    [ -s "${tmp}" ] || { rm -f "${tmp}"; return 1; }
    # ★ server 改写为证书 SAN 内的 API_DOMAIN(直连 master IP 不在 SAN → TLS 校验失败)
    API_DOMAIN="${API_DOMAIN:-k8s-api.nova.local}"
    sed -i -E "s|(server:[[:space:]]*https?://)[^:/]+(:[0-9]+)|\1${API_DOMAIN}\2|" "${tmp}"
    mkdir -p "${HOME}/.kube"
    newctx="$(grep -E '^[[:space:]]*current-context:' "${tmp}" | head -1 | awk '{print $2}')"
    if [ -f "${HOME}/.kube/config" ]; then
        # 合并(新 admin.conf 在前, 同名校则新集群优先); 合并失败则直接覆盖
        KUBECONFIG="${tmp}:${HOME}/.kube/config" kubectl config view --flatten > "${tmp}.merged" 2>/dev/null \
            && mv "${tmp}.merged" "${HOME}/.kube/config" || cp "${tmp}" "${HOME}/.kube/config"
    else
        cp "${tmp}" "${HOME}/.kube/config"
    fi
    [ -n "${newctx}" ] && KUBECONFIG="${HOME}/.kube/config" kubectl config use-context "${newctx}" >/dev/null 2>&1 || true
    # ★ 强制收敛: 合并可能保留旧集群残留(如 lb.k8s.local / 直连 master IP, 不在证书 SAN → TLS 失败)。
    #   只把当前 context 对应 cluster 的 server 改写为 SAN 内 API_DOMAIN(保留证书校验), 不动其它集群。
    #   注意: K/_ctx/_cl 必须 local —— 各 addon 模块(gpu_operator/lws/envoy_*)顶层也有同名
    #   全局 K(远端 kubectl), 若此处用全局并 unset 会把调用方的 K 冲掉 → set -u 报 unbound。
    local K _ctx _cl
    K="KUBECONFIG=${HOME}/.kube/config kubectl"
    _ctx="$(${K} config current-context 2>/dev/null || echo "${newctx}")"
    _cl="$(${K} config view -o jsonpath="{.contexts[?(@.name==\"${_ctx}\")].context.cluster}" 2>/dev/null | head -1)"
    if [ -n "${_cl}" ]; then
        ${K} config set-cluster "${_cl}" --server="https://${API_DOMAIN}:6443" >/dev/null 2>&1 || true
    fi
    chmod 600 "${HOME}/.kube/config"
    rm -f "${tmp}"
    # ★ 宿主机 /etc/hosts 收敛 API_DOMAIN(换环境旧 IP 残留会让 getent 命中旧集群 → 误报失败):
    #   先删该域名所有旧行, 再写当前 API_IP 一行(与 setup-api-expose.sh 逻辑一致, 双保险)。
    _api_re="$(echo "${API_DOMAIN}" | sed 's/\./\\./g')"
    sed -i -E "/[[:space:]]${_api_re}([[:space:]]|$)/d" /etc/hosts 2>/dev/null || true
    grep -qE "^${API_IP}[[:space:]]+${API_DOMAIN}([[:space:]]|$)" /etc/hosts 2>/dev/null \
        || echo "${API_IP} ${API_DOMAIN}" >> /etc/hosts 2>/dev/null || true
    unset _api_re
    # 宿主机 DNAT(6443→first master): 让 API_DOMAIN 从宿主机可达(幂等)
    bash "${SCRIPT_DIR}/tools/lb/setup-api-expose.sh" >/dev/null 2>&1 || \
        sudo bash "${SCRIPT_DIR}/tools/lb/setup-api-expose.sh" >/dev/null 2>&1 || true
    # 校验: 经 API_DOMAIN 访问集群
    KUBECONFIG="${HOME}/.kube/config" timeout 15 kubectl get nodes --no-headers >/dev/null 2>&1
}

# 节点类型判断(vm=虚拟机 / bm=裸金属): 仅对含类型信息的行(旧格式 / VM 配置文件)有效
# 用法: node_is_vm <role> <mac> <mem_g> <node_type> → 退出码 0=是虚拟机
node_is_vm() {
    local role="$1" mac="$2" mem="$3" ntype="$4"
    case "${ntype}" in
        vm) return 0 ;;
        bm) return 1 ;;
    esac
    # 未显式指定类型: 回退推断
    [ "${role}" = "master" ] && return 0
    [ -n "${mac}" ] && [ "${mac}" != "-" ] && [ "${mem:-0}" -gt 0 ]
}

# ---------------- VM 创建配置(独立于 cluster.conf, 集中管理虚拟机规格) ----------------
# cluster.conf 的 NODES 不区分 vm/bm(5字段); 需要创建虚拟机的节点统一在
#   deployments/scripts/tools/vm/vm-nodes.conf 中定义(10字段格式, 见该文件头部注释)。
# 创建虚拟机的脚本(tools/vm/*)读取本配置; 创建成功后自动把 5 字段信息注入 cluster.conf。
VM_NODES_CONF="${VM_NODES_CONF:-${SCRIPT_DIR}/tools/vm/vm-nodes.conf}"
vm_conf_entries() {   # 输出 vm-nodes.conf 中引号包裹的 NODES 行(10字段)
    [ -f "${VM_NODES_CONF}" ] || return 0
    sed -n 's/^[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "${VM_NODES_CONF}"
}
vm_conf_has_nodes() {   # 是否有 VM 定义(供"含 VM 集群 / 全裸金属"判断)
    [ -n "$(vm_conf_entries)" ]
}
vm_conf_has_node() {    # <hostname> → 退出码 0=该节点在 VM 配置中(是虚拟机)
    local h="$1" line
    for line in $(vm_conf_entries); do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        [ "${NODE_HOSTNAME}" = "${h}" ] && return 0
    done
    return 1
}

# 获取根目录(供其它脚本引用路径)
repo_root() { echo "${REPO_ROOT}"; }

# ---------------- 节点注册到 cluster.conf ----------------
# 将节点信息写入 config/cluster.conf 的 NODES 数组(新5字段格式, 幂等)
# 用法: register_node_to_conf <role> <hostname> <ip> <user> <password>
#   password 为 "-" 表示用默认(SSH_DEFAULT_PASSWORD)
#   (向后兼容: 传 9 参数旧格式时取 role/hostname/ip/user=8/pw=9, 忽略 mac/mem/cpu/disk)
register_node_to_conf() {
    local role="$1" hostname="$2" ip="$3" user pw
    if [ $# -ge 9 ]; then
        user="$8"; pw="$9"     # 旧 9 参数调用(含 mac/mem/cpu/disk)
    else
        user="$4"; pw="$5"
    fi
    local conf_file="${CLUSTER_CONF:-${REPO_ROOT}/config/cluster.conf}"

    [ -f "${conf_file}" ] || { warn "cluster.conf 不存在: ${conf_file}, 跳过注册 ${hostname}"; return 0; }
    [ -w "${conf_file}" ] || { warn "cluster.conf 不可写: ${conf_file}, 跳过注册 ${hostname}"; return 0; }

    # 已存在则跳过(幂等)
    if grep -qF "${hostname}," "${conf_file}" 2>/dev/null; then
        echo -e "\033[33m⚠ ${hostname} 已在 ${conf_file} 中注册,跳过\033[0m"
        return 0
    fi

    local new_entry="\"${role},${hostname},${ip},${user},${pw}\""
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

# ---------------- 用 VM 集合整体替换 cluster.conf NODES ----------------
# 创建虚拟机会话结束时, 将 vm-nodes.conf 决定的**全部** 5 字段 VM 条目作为
# cluster.conf NODES 的唯一内容(整体替换 NODES 区块, 非追加)。cluster.conf
# 不再区分 vm/bm: 纯虚拟机集群由本函数重建 NODES = 全部 VM; 裸金属集群不跑
# 创建脚本, 由用户在 cluster.conf 手动维护 5 字段节点。
# 用法: replace_nodes_to_conf <conf_file> <entry> [<entry> ...]
#   entry = "role,hostname,ip,ssh_user,ssh_password" (5字段, 密码 "-"=默认)
#   或通过环境变量 REPLACE_NODES_IFS 传入(条目以换行分隔, 便于带空格密码)。
replace_nodes_to_conf() {
    local conf_file="$1"; shift
    [ -f "${conf_file}" ] || { warn "cluster.conf 不存在: ${conf_file}, 跳过覆盖 NODES"; return 0; }
    [ -w "${conf_file}" ] || { warn "cluster.conf 不可写: ${conf_file}, 跳过覆盖 NODES"; return 0; }

    local entries=()
    while [ $# -gt 0 ]; do [ -n "${1}" ] && entries+=("${1}"); shift; done
    if [ -n "${REPLACE_NODES_IFS:-}" ]; then
        while IFS= read -r e; do [ -n "${e}" ] && entries+=("${e}"); done <<<"${REPLACE_NODES_IFS}"
    fi

    # 拼出 NODES 区块新内容(两空格缩进 + 双引号包裹, 换行分隔), 用 awk 整体替换旧条目。
    local _body=""
    local e
    for e in "${entries[@]:-}"; do _body="${_body}  \"${e}\"\n"; done
    awk -v body="$(printf '%b' "${_body}")" '
        /^NODES=\(/ { print; in_nodes=1; next }
        in_nodes && /^\)/ { printf "%s", body; print ")"; in_nodes=0; next }
        in_nodes { next }               # 丢弃旧的 NODES 条目行
        { print }
    ' "${conf_file}" > "${conf_file}.tmp" && mv "${conf_file}.tmp" "${conf_file}"

    ok "已用 ${#entries[@]} 个 VM 节点覆盖 cluster.conf NODES"
}

# ---------------- 离线文件就绪检查(醒目提示, 不阻断) ----------------
# 部署依赖离线 binary 与镜像(deployments/offline-files); 缺失时给出醒目提示与准备指引。
# 用法: check_offline_files   # 在 deploy-cluster.sh / 各模块开头调用
check_offline_files() {
    if [ ! -d "${OFFLINE_FILES_DIR:-}" ] || [ -z "$(ls -A "${OFFLINE_FILES_DIR:-/nonexistent}" 2>/dev/null)" ]; then
        echo ""
        echo -e "\033[41m\033[97m================================================================\033[0m"
        echo -e "\033[41m\033[97m ⚠⚠⚠  离线文件缺失: ${OFFLINE_FILES_DIR:-<未配置>} 为空或不存在  ⚠⚠⚠\033[0m"
        echo -e "\033[41m\033[97m  离线安装需要 binary 与镜像, 请先准备离线文件:                     \033[0m"
        echo -e "\033[41m\033[97m   ① 内网/联网机从 MinIO 下载:                                    \033[0m"
        echo -e "\033[41m\033[97m      sudo ./deployments/scripts/tools/offline/fetch-offline-files.sh\033[0m"
        echo -e "\033[41m\033[97m   ② 或手工拷贝离线文件到 ${OFFLINE_FILES_DIR:-deployments/offline-files}/   \033[0m"
        echo -e "\033[41m\033[97m   ③ kubespray 离线资源位于 ${LOCAL_REPO_DIR:-offline-files/kubespray}/    \033[0m"
        echo -e "\033[41m\033[97m      (镜像 images/ + 二进制 + packages/ 系统包)                    \033[0m"
        echo -e "\033[41m\033[97m================================================================\033[0m"
        echo ""
    fi
}

# ---------------- 附加组件通用工具 ----------------

# 返回第一个 master 节点 IP(附加组件执行 kubectl 的入口)
# 用法: FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
first_master_ip() {
    local line
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        if [ "${NODE_ROLE}" = "master" ] && [ -n "${NODE_IP}" ]; then
            echo "${NODE_IP}"
            return 0
        fi
    done
    return 1
}

# 伪代码占位执行框架: 用于尚未实现真实逻辑的附加组件模块。
# 用法: addon_stub <模块key> <步骤数组名>
#   步骤数组格式: "步骤描述|要执行的命令(伪代码)" 每行一项
# 行为:
#   · ADDON_STUB_EXEC=1 时: 真实执行伪代码命令(用于实现验证/模拟)
#   · 否则: 仅打印伪代码步骤(占位, 不执行), 返回 0 表示"流程可继续"
#   · DEPLOY_MODE=sim 时额外 sleep 模拟耗时
addon_stub() {
    local key="$1" arr_name="$2"
    local -n _steps="${arr_name}"  # bash 4.3+ nameref
    local _desc _cmd _i=0
    say "▶ [${key}] 伪代码占位实现(尚未接入真实逻辑, ADDON_STUB_EXEC=1 可试执行)..."
    for _line in "${_steps[@]:-}"; do
        [ -z "${_line}" ] && continue
        _i=$((_i + 1))
        _desc="${_line%%|*}"
        _cmd="${_line#*|}"
        say "  ${_i}. ${_desc}"
        say "     \$ ${_cmd}"
        if [ "${ADDON_STUB_EXEC:-0}" = "1" ]; then
            # 试执行模式: 忽略失败继续
            bash -c "${_cmd}" 2>/dev/null || warn "     [占位试执行失败,忽略]"
        elif [ "${DEPLOY_MODE:-auto}" = "sim" ]; then
            sleep 0.5
        fi
    done
    say "◼ [${key}] 占位流程执行完毕(如需真实安装, 请按 TODO 实现模块逻辑)"
    return 0
}