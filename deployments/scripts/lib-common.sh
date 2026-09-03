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

# ---------------- 共享 skopeo 推送助手(tar → 集群内置 registry) ----------------
# gpu_operator / lws / envoy(09/10) / metax-load 曾各自复制同一份 _push_skopeo/_reg_has_tag;
# 集中到本库供新代码复用(envoy 家族 + 独立 load 脚本), 已有 metax/gpu/lws 维持原状避免回归。
# 全部为**新符号**, 不改任何现有调用方。

# 前置检查: 缺失 skopeo 时给明确指引(而非 3 次重试后误报"未找到镜像")
# 用法: skopeo_require <组件名>
skopeo_require() {
    command -v skopeo >/dev/null 2>&1 && return 0
    err "未找到 skopeo(推送镜像到集群内置 registry 必需)。请安装 skopeo, 或使用项目 CLI 镜像"
    err "  (tools/docker/build-cli-context.sh 内置 skopeo-1.16.1-amd64)"
    exit 1
}

# 3 次整包重试的 skopeo copy(大 blob 连接中断时 skopeo 的 --retry-times 不覆盖)
# 错误文件按 PID 隔离(并行安全)。用法: push_image_skopeo <src> <dst>
push_image_skopeo() {
    local src="$1" dst="$2" n=1 errf="/tmp/skopeo-err-$$" err
    for n in 1 2 3; do
        if skopeo copy --quiet --src-tls-verify=false --dest-tls-verify=false \
            --dest-no-creds "${src}" "${dst}" 2>"${errf}"; then
            rm -f "${errf}"; return 0
        fi
        err="$(tail -1 "${errf}" 2>/dev/null || true)"
        if [ "${n}" -lt 3 ]; then
            warn "  推送失败(第 ${n}/3 次: ${err}), 3s 后重试整包..."
            sleep 3
        fi
    done
    rm -f "${errf}"; return 1
}

# 幂等检查: registry 是否已有 <repo>:<tag>(优先 skopeo inspect, 缺失时 curl tags/list)
# 需调用方先设置 REGISTRY_BASE(各模块/load 脚本在 load_config 后派生)。
# 用法: reg_has_tag <push_registry> <repo> <tag>
reg_has_tag() {
    # 注意: path 依赖 pr, 须与 pr 分行 local —— bash 同一 local 语句的 RHS 按旧作用域
    # 展开(set -u 下引用同语句未赋值变量会报 unbound variable, 如: local pr="$1" ... path="${pr#*/}")
    local pr="$1" repo="$2" ver="$3"
    local path="${pr#*/}"
    if command -v skopeo >/dev/null 2>&1; then
        skopeo inspect --tls-verify=false --no-creds "docker://${pr}/${repo}:${ver}" >/dev/null 2>&1 && return 0
    fi
    curl -s -m 6 "http://${REGISTRY_DIRECT:-${REGISTRY_BASE}}/v2/${path}/${repo}/tags/list" 2>/dev/null | grep -q "\"${ver}\""
}

# 离线 tar 内容识别: 文件名 glob 快路径 + tar_first_image_tag 内容校验; glob 未命中时
# 扫描全部 *.tar 按内容兜底(兼容改名/异常命名)。读不出内容时**信任 glob 不否决**,
# 仅明确不匹配才跳过并告警。用法: find_offline_tar <ref后缀> <文件名glob> <dir...>
#   ref 后缀带前导 /(如 /gateway:v1.9.1), 防 /foo/gateway:v1.9.1 误匹配
find_offline_tar() {
    local suffix="$1" glob="$2"; shift 2
    local d t src
    for d in "$@"; do
        [ -d "${d}" ] || continue
        # 快路径: 文件名 glob 候选 + 内容校验
        # 注意: ${glob} 不能加引号(引号会抑制路径展开, 快路径永远匹配不到文件, 只剩内容兜底)
        for t in "${d}"/${glob}; do
            [ -f "${t}" ] || continue
            src="$(tar_first_image_tag "${t}")"
            if [ -z "${src}" ]; then
                echo "${t}"; return 0
            fi
            case "${src}" in
                *"${suffix}") echo "${t}"; return 0 ;;
                # 告警走 stderr: 调用方可能在 $(...) 里调本函数(如 load 脚本), stdout 会被吞
                *) warn "  $(basename "${t}") 内容为 ${src}, 非 ${suffix}, 跳过" >&2 ;;
            esac
        done
        # 兜底: 无 glob 命中时扫描全部 *.tar 按内容匹配
        for t in "${d}"/*.tar; do
            [ -f "${t}" ] || continue
            case "$(tar_first_image_tag "${t}")" in
                *"${suffix}") echo "${t}"; return 0 ;;
            esac
        done
    done
    return 1
}

# ---------------- 共享 nginx 校验镜像助手(verify 模块测试后端共用) ----------------
# verify_metallb / verify_envoy_gateway / verify_envoy_ai_gateway / verify-lws 的测试后端
# 统一用 **nginx**(测试 HTTP 后端, 静态页/JSON mock 皆可), 曾用 busybox httpd(依赖节点
# containerd 预加载, 漏预加载即 Pending)。统一收敛到本助手:
# 幂等确保 nginx 已推送进集群内置 registry, echo 出 **K8s 可见镜像 ref**(调用方在 $(...) 捕获,
# 故本函数进度消息一律走 stderr, 与 find_offline_tar 的 warn >&2 同理), pod 直接走集群 registry
# 拉取(离线可用, 不依赖节点状态)。
# 来源: ① 本地 docker daemon → ② 离线 tar(deployments/offline-files/nginx/nginx.tar 优先,
#       也兼容 LOCAL_REPO_DIR/images) → ③ 在线(仅 VERIFY_IMAGE_ONLINE=true, 离线部署默认禁止)。
# 用法: TEST_IMAGE="$(ensure_registry_nginx)" || exit 1   # 默认 tag=latest; 可 ensure_registry_nginx <tag>
# 依赖: load_config 已执行(REGISTRY_* / LOCAL_REPO_DIR / OFFLINE_FILES_DIR / REPO_ROOT); 推送需 skopeo。
ensure_registry_nginx() {
    local tag="${1:-latest}"
    # 推送走 IP 直连(REGISTRY_DIRECT: metallb→VIP:PORT / nodeport→master:REGISTRY_NODEPORT, 无 DNS 依赖);
    # 返回的 ref 用 REGISTRY_DOMAIN(K8s 节点可解析)
    local pr="${REGISTRY_DIRECT}/verify"
    local ref="${REGISTRY_DOMAIN:-${REGISTRY_IP}}:${REGISTRY_PORT}/verify/nginx:${tag}"
    # reg_has_tag 的 curl 兜底(无 skopeo 时)依赖 REGISTRY_BASE, 先确保已派生(set -u 下未赋值即报错)
    REGISTRY_BASE="${REGISTRY_BASE:-${REGISTRY_DOMAIN:-${REGISTRY_IP}}:${REGISTRY_PORT}}"
    # 幂等: registry 已有直接返回(无需 skopeo)
    reg_has_tag "${pr}" "nginx" "${tag}" && { echo "${ref}"; return 0; }
    skopeo_require "verify"
    local src="" _tmp="" _t
    # ① 本地 docker daemon(nginx 常被手工 pull 过, 快路径)
    src="$(sudo docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '(/|^)nginx:(latest|[0-9.]+)$' | head -1 || true)"
    if [ -n "${src}" ]; then
        echo "  [nginx] 从本地 docker 推送: ${src}" >&2
        _tmp="$(mktemp)"
        if sudo docker save "${src}" -o "${_tmp}" >/dev/null 2>&1 \
           && push_image_skopeo "docker-archive:${_tmp}" "docker://${pr}/nginx:${tag}" >/dev/null 2>&1; then
            rm -f "${_tmp}"; echo "${ref}"; return 0
        fi
        rm -f "${_tmp}"; echo "  [nginx] 本地 docker 推送失败, 尝试离线 tar..." >&2
    fi
    # ② 离线 tar: suffix 用 "nginx:latest"(无前导 /——find_offline_tar 的前导 / 约定只匹配带
    # registry 前缀的全格式, 库镜像短格式如 "nginx:latest" 会漏; glob nginx*.tar 已限定候选)。
    # find_offline_tar 是 endswith 语义, 版本化 tag(nginx:1.31.4)不命中, 下方按内容兜底。
    _t="$(find_offline_tar "nginx:latest" "nginx*.tar" \
            "${REPO_ROOT}/deployments/offline-files/nginx" \
            "${LOCAL_REPO_DIR}/images" \
            "${OFFLINE_FILES_DIR:-${REPO_ROOT}/deployments/offline-files/kubespray}/${CLUSTER_NAME:-cubestack-cluster}/images")" || _t=""
    if [ -z "${_t}" ]; then
        # 兜底: 版本化 tag(如 nginx:1.31.4)按内容匹配(含 "nginx:" 即接受)
        for _d in "${REPO_ROOT}/deployments/offline-files/nginx" \
                  "${LOCAL_REPO_DIR}/images" \
                  "${OFFLINE_FILES_DIR:-${REPO_ROOT}/deployments/offline-files/kubespray}/${CLUSTER_NAME:-cubestack-cluster}/images"; do
            [ -d "${_d}" ] || continue
            for _f in "${_d}"/nginx*.tar; do
                [ -f "${_f}" ] || continue
                case "$(tar_first_image_tag "${_f}")" in
                    *"nginx:"*) _t="${_f}"; break 2 ;;
                esac
            done
        done
    fi
    if [ -n "${_t}" ]; then
        echo "  [nginx] 从离线 tar 推送: $(basename "${_t}")" >&2
        if push_image_skopeo "docker-archive:${_t}" "docker://${pr}/nginx:${tag}" >/dev/null 2>&1; then
            echo "${ref}"; return 0
        fi
        echo "  [nginx] 离线 tar 推送失败" >&2
    fi
    # ③ 在线(仅显式允许; 离线部署默认禁止, 给明确指引)
    if [ "${VERIFY_IMAGE_ONLINE:-false}" = "true" ]; then
        echo "  [nginx] 在线拉取并推送(VERIFY_IMAGE_ONLINE=true)..." >&2
        if push_image_skopeo "docker://docker.io/library/nginx:latest" "docker://${pr}/nginx:${tag}" >/dev/null 2>&1; then
            echo "${ref}"; return 0
        fi
        echo "  [nginx] 在线拉取失败" >&2
    fi
    err "集群 registry 无 nginx(${ref}), 测试后端无法拉起。请任选其一:"
    err "  ① 准备离线 nginx 镜像 tar 放到 ${REPO_ROOT}/deployments/offline-files/nginx/nginx.tar(联网机: sudo docker pull nginx:latest && sudo docker save nginx:latest -o .../nginx.tar, 拷到部署机);"
    err "  ② 部署机本地 docker 有 nginx:latest(sudo docker pull nginx:latest);"
    err "  ③ 允许在线拉取: VERIFY_IMAGE_ONLINE=true 重跑"
    return 1
}

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
    #   API_DOMAIN   API Server 域名(跨网段统一入口), 默认 k8s-api.cubestack.io
    API_IP="${API_IP:-${APISERVER_ADDRESS:-}}"
    API_DOMAIN="${API_DOMAIN:-${APISERVER_DOMAIN:-k8s-api.cubestack.io}}"
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
        # 按暴露模式决定默认入口(二选一):
        #   nodeport(默认) → 集群第一个 master IP —— 节点 containerd 经 hosts.toml 直连该 IP 的
        #     REGISTRY_NODEPORT 拉取, 宿主机经 deploy-registry.sh 的 DNAT 访问, 均无需手动配置;
        #   metallb         → METALLB_POOL 池内首地址作为 LoadBalancer VIP(registry 固定 VIP)。
        _EXPOSE="$(echo "${SERVICE_EXPOSE_MODE:-nodeport}" | tr '[:upper:]' '[:lower:]')"
        if [ "${_EXPOSE}" = "nodeport" ]; then
            REGISTRY_IP="$(first_master_ip)" || REGISTRY_IP="$(first_pool_addr "${METALLB_POOL:-}")"
            vlog "REGISTRY_IP 留空, nodeport 模式取首个 master IP → ${REGISTRY_IP}"
        else
            REGISTRY_IP="$(first_pool_addr "${METALLB_POOL:-}")"
            vlog "REGISTRY_IP 留空, 自动取 METALLB_POOL=${METALLB_POOL:-} 首地址 → ${REGISTRY_IP}"
        fi
        unset _EXPOSE
        export REGISTRY_IP
    else
        export REGISTRY_IP_EXPLICIT=1
    fi
    # 服务暴露方式归一化: SERVICE_EXPOSE_MODE ∈ {metallb, nodeport}
    # 大小写不敏感: 判断前先 tr 转小写, 任何大小写组合(nodeport/NodePort/nodePort/NODEPORT...)均接受
    #   nodeport           → nodeport(默认, 测试环境, NodePort 经 kube-proxy 路由, 不依赖 MetalLB)
    #   metallb/loadbalancer/其它 → metallb(生产, MetalLB LoadBalancer VIP)
    # 下游 sync-addons-config / sync-kubespray-config / verify / 部署汇总统一按此分支。
    _EXPOSE_MODE="$(echo "${SERVICE_EXPOSE_MODE:-nodeport}" | tr '[:upper:]' '[:lower:]')"
    case "${_EXPOSE_MODE}" in
        nodeport) SERVICE_EXPOSE_MODE="nodeport" ;;
        *)        SERVICE_EXPOSE_MODE="metallb" ;;
    esac
    unset _EXPOSE_MODE
    export SERVICE_EXPOSE_MODE
    # registry 暴露方式: 留空 → 按全局模式派生; 显式设置(loadbalancer|nodeport|clusterip)则覆盖。
    # cluster.conf 留空 + 各脚本里 ":-loadbalancer" 兜底的默认值统一收敛到本处, 保证所有消费者拿到同一值。
    if [ -z "${REGISTRY_SERVICE_TYPE:-}" ]; then
        [ "${SERVICE_EXPOSE_MODE}" = "nodeport" ] && REGISTRY_SERVICE_TYPE="nodeport" || REGISTRY_SERVICE_TYPE="loadbalancer"
        export REGISTRY_SERVICE_TYPE
        vlog "REGISTRY_SERVICE_TYPE 留空, 按 SERVICE_EXPOSE_MODE=${SERVICE_EXPOSE_MODE} 派生 → ${REGISTRY_SERVICE_TYPE}"
    fi
    # registry 宿主侧直连端点(预检 curl / skopeo push 用), 与镜像名 DOMAIN:PORT 解耦:
    #   nodeport → 首个 master:REGISTRY_NODEPORT(无 VIP, 直连 NodePort; 容器/裸机均可达);
    #   metallb   → REGISTRY_IP:REGISTRY_PORT(MetalLB VIP)。
    # 镜像名统一 registry.cubestack.io:5000(节点经 containerd hosts.toml 改写连接), 端口无需统一;
    # 显式设 REGISTRY_DIRECT 可覆盖(如经代理/别名推送)。
    # ⚠ nodeport 分支复用 REGISTRY_IP 而非直接 first_master_ip:
    #   create-vms.sh 等场景 load_config 时 NODES 可能已被清空 → first_master_ip 返回 1,
    #   在 set -euo pipefail 下命令替换失败会传导给赋值 → load_config 静默退出, 卡死 VM 创建。
    #   REGISTRY_IP 自带 first_master_ip || first_pool_addr 兜底(见上), 此处直接复用其值。
    if [ "${SERVICE_EXPOSE_MODE}" = "nodeport" ]; then
        REGISTRY_DIRECT="${REGISTRY_DIRECT:-${REGISTRY_IP}:${REGISTRY_NODEPORT:-31148}}"
    else
        REGISTRY_DIRECT="${REGISTRY_DIRECT:-${REGISTRY_IP}:${REGISTRY_PORT:-5000}}"
    fi
    export REGISTRY_DIRECT
    # ---------------- local-path / ceph 二选一(互斥, 集中派生) ----------------
    # 单一事实来源 = CEPH_ENABLED:
    #   · CEPH_ENABLED=true  → registry 后端强制 ceph-block, 并关闭 local-path(ceph 替代 local-path,
    #     不再安装 local-path-provisioner; addons.yml local_path_provisioner_enabled 同步为 false)。
    #   · CEPH_ENABLED=false → 保持 local-path 为默认后端(默认)。
    # ⚠ 即使显式写了 REGISTRY_STORAGE_CLASS / LOCAL_PATH_ENABLED 也会被本规则覆盖(二选一, 不并存);
    #   想用 local-path 就设 CEPH_ENABLED=false。
    if [ "${CEPH_ENABLED:-false}" = "true" ]; then
        # 仅当 cluster.conf 显式写了冲突值时提醒(默认值 local-path/true 不算冲突, 避免每次 run 刷屏)
        if grep -qE '^[[:space:]]*REGISTRY_STORAGE_CLASS=.*(local-path)' "${CLUSTER_CONF}" 2>/dev/null; then
            warn "CEPH_ENABLED=true → REGISTRY_STORAGE_CLASS 强制 ceph-block(local-path 被替代)"
        fi
        if grep -qE '^[[:space:]]*LOCAL_PATH_ENABLED=(true|1|yes|on)' "${CLUSTER_CONF}" 2>/dev/null; then
            warn "CEPH_ENABLED=true → LOCAL_PATH_ENABLED 强制 false(local-path 与 ceph 二选一, 不再安装 local-path)"
        fi
        REGISTRY_STORAGE_CLASS="ceph-block"
        LOCAL_PATH_ENABLED="false"
    fi
    export REGISTRY_STORAGE_CLASS LOCAL_PATH_ENABLED
    # 虚拟机配置(独立于 cluster.conf): source vm-nodes.conf 提供 VM 创建/网络变量
    vm_conf_load
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

# 默认密码: 全节点默认一致(SSH_DEFAULT_PASSWORD); 节点独立密码在 NODES 第5字段显式填写
# 用法: node_default_pw [role] → 默认密码(可空; role 仅保留签名兼容旧调用)
node_default_pw() {
    echo "${SSH_DEFAULT_PASSWORD:-}"
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

# ---------------- 宿主机 /etc/hosts 收敛(共享, 防多集群残留 + 防重复行) ----------------
# 多套集群/换环境时, 同一域名(registry.cubestack.io / k8s-api.cubestack.io / 节点主机名)会在
# /etc/hosts 残留多个旧 IP 行; getent 命中旧 IP → push/helm/kubectl 打到旧集群 → 误报失败。
# 固定套路: 【先无条件删除该域名所有旧行, 再追加当前 IP 一行】。
# ⚠ 不要加 "grep 已匹配则跳过" 的幂等守卫: 守卫会因第一行旧 IP 已匹配而跳过追加,
#   新 IP 永远写不进去 —— 正是多行残留累积的根因(历史 _ensure_hosts 的 bug)。
# 用法: ensure_hosts_entry <ip> <domain>; 非 root 时静默失败, 调用方用 grep 校验 + warn。
#
# ★ bind-mount 安全: 不能用 sed -i / awk -i inplace(它们=写临时文件再 rename 覆盖)。
#   容器(cli 镜像/installer)内 /etc/hosts 是 docker bind-mount, rename 会
#   "Device or resource busy" 失败 → 旧行删不掉、只剩追加 → 同一域名多行残留(历史根因)。
#   【优先用】sed '/<域名>/d' /etc/hosts | sponge /etc/hosts(moreutils, CLI 镜像已预装)
#   做"删旧行→原地覆盖写"; 非容器环境(宿主机/节点, 未必有 sponge)回退
#   "sed 过滤 → 临时文件 + cat 覆盖写"(同样不 rename, bind-mount 与普通 FS 都安全)。
#   两种分支都是先删该域名【所有】旧行, 再追加当前 IP 一行。
ensure_hosts_entry() {
    local ip="$1" dom="$2"
    [ -n "${ip}" ] && [ -n "${dom}" ] || return 0
    local t="/etc/hosts.$$"
    if command -v sponge >/dev/null 2>&1; then
        sed "/${dom}/d" /etc/hosts | sponge /etc/hosts 2>/dev/null || return 0
    else
        sed "/${dom}/d" /etc/hosts > "${t}" 2>/dev/null || return 0
        cat "${t}" > /etc/hosts 2>/dev/null || { rm -f "${t}"; return 0; }
        rm -f "${t}"
    fi
    printf '%s %s\n' "${ip}" "${dom}" >> /etc/hosts 2>/dev/null || true
}

# 幂等追加【整块】宿主机 hosts 条目(与 ensure_hosts_entry 同套防重复理念, 适用于多行块):
#   · 命中任意主机名(含 k8s-api.cubestack.io / k8s-api.nova.local / nova-k8s-* / mxgpu-* 旧版裸条目)即视为已有该块,
#     【先删除旧块标记段 + 匹配主机名的裸行, 再追加新块】, 主机名→IP 永不重复。
#   · 块标记仅保留一段, 重复追加(历史版本多次写入)也会被收敛成一段。
#   · bind-mount 安全(同 ensure_hosts_entry): 过滤→sponge 或临时文件+cat 覆盖写。
# 用法: ensure_hosts_block <块首注释> <块尾注释> <<< 块内容(以 EOF 结尾)
ensure_hosts_block() {
    local start="$1" end="$2" content
    content="$(cat)"
    [ -n "${content}" ] || return 0
    local t="/etc/hosts.$$"
    if command -v sponge >/dev/null 2>&1; then
        sed -e "/${start}/,/${end}/d" \
            -e '/nova-k8s-\(master\|node\)/d' \
            -e '/mxgpu-[0-9]/d' \
            -e '/k8s-api\.\(nova\.local\|cubestack\.io\)/d' \
            /etc/hosts | sponge /etc/hosts 2>/dev/null || return 0
    else
        sed -e "/${start}/,/${end}/d" \
            -e '/nova-k8s-\(master\|node\)/d' \
            -e '/mxgpu-[0-9]/d' \
            -e '/k8s-api\.\(nova\.local\|cubestack\.io\)/d' \
            /etc/hosts > "${t}" 2>/dev/null || return 0
        cat "${t}" > /etc/hosts 2>/dev/null || { rm -f "${t}"; return 0; }
        rm -f "${t}"
    fi
    printf '%s\n' "${content}" >> /etc/hosts 2>/dev/null || true
}

# ---------------- 宿主机 kubectl/helm 访问集群(共享, 防 TLS/DNAT 坑) ----------------
# 从第一个 master 下载 /etc/kubernetes/admin.conf 并同步到 ~/.kube/config, 同时:
#   ① server 改写为证书 SAN 内的 API_DOMAIN(k8s-api.cubestack.io) —— admin.conf 默认
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
    API_DOMAIN="${API_DOMAIN:-k8s-api.cubestack.io}"
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
    ensure_hosts_entry "${API_IP}" "${API_DOMAIN}"
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
# source vm-nodes.conf(虚拟机创建 + 虚拟网络变量 + VM_NODES 10字段数组):
#   · 集中 VM 专属配置(BASE_IMG/VM_DISK_DIR/VM_SSH_USERS/VM_SUBNET/BRIDGE/NET_MODE/NAT_*/PHYS_WORKER_NET),
#     与 cluster.conf 解耦; 所有引用这些变量的脚本(tools/vm/*, tools/net/*, 01_vm_network)统一经 lib-common 拿到。
#   · 无 VM 的纯裸金属集群: 文件不存在则跳过(变量回退到各自默认值)。
vm_conf_load() {
    [ -f "${VM_NODES_CONF}" ] || return 0
    # 容错: 文件不合法不阻断(变量回退默认)
    source "${VM_NODES_CONF}" 2>/dev/null || true
}
vm_conf_entries() {   # 输出 VM_NODES 数组中 10 字段节点行(定义于 vm-nodes.conf)
    local i
    # 直接遍历 VM_NODES 数组(需已 source vm-nodes.conf); 未 source 时回退 sed 解析
    if declare -p VM_NODES >/dev/null 2>&1; then
        for i in "${VM_NODES[@]:-}"; do echo "${i}"; done
        return 0
    fi
    sed -n 's/^[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "${VM_NODES_CONF}" 2>/dev/null
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

# 返回第一个节点 IP(NODES 顺序首位; NodePort 暴露模式的访问入口)
# 用法: NODE_IP="$(first_node_ip)" || { err "未找到节点"; exit 1; }
first_node_ip() {
    local line
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        [ -n "${NODE_IP}" ] && { echo "${NODE_IP}"; return 0; }
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