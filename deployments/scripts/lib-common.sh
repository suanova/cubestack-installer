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
    # ⚠ || true: 状态文件可能不存在(--fresh 清状态后)或该 key 无记录 → 返回空且退出码 0,
    #   否则 set -euo pipefail 下管道(grep 找不到文件)非零, 裸赋值处脚本静默退出
    #   (曾致 --fresh 时部署在 ceph 预检块无报错中断)。
    grep -F "$1=" "${STATE_FILE}" 2>/dev/null | tail -1 | cut -d= -f2- || true
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
# ⚠ vlog 必须走 stderr —— 它是诊断输出, 而 "$(...)" 命令替换**只捕获 stdout**。
#   历史事故(2026-09-22 实机): kube_vip_resolve_target 内部的 vlog 走了 stdout,
#   于是 api_addr="$(kube_vip_resolve_target)" 抓到 "[DEBUG] …\n<master01>" 两行,
#   该值组进 sed 表达式时换行把表达式截断 → "unterminated `s' command" →
#   k8s_inventory 在写 all.yml 处中断, 整个部署(含 kube-vip)根本没开始。
#   约定: 值函数(返回地址/列表者)的 stdout 只允许出现"值"本身, 出口用 emit_ip 兜底。
vlog() { [ "${LOG_VERBOSE}" = "1" ] && { local m="[DEBUG] $*"; echo -e "\033[90m${m}\033[0m" >&2; _log_file "${m}"; } || true; }

# 值函数出口(与 vlog 同一条约定): 只把一个 IPv4 字面量写进 stdout。
# 用法: emit_ip "${vip}" || return 1
# 双重作用: ① 保证 stdout 干净(无颜色码/无换行); ② 兜底校验 —— 万一将来又有诊断输出
# 混进 stdout, 这里明确报"非 IPv4", 而不是让它流进 sed/YAML 变成静默错配(见 vlog 注释里的事故)。
emit_ip() {
    if [[ ! "${1:-}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        err "内部错误: 期望 IPv4 地址, 实得 '${1:-}'"
        err "  多半是某个函数把诊断输出写进了 stdout 而被 \$(...) 捕获 —— 见本文件 vlog 的注释"
        return 1
    fi
    printf '%s\n' "$1"
}

# ---------------- skopeo 运行时最小 trust policy(/etc/containers/policy.json) ----------------
# 本机(尤其 CLI 容器内)无容器运行时 daemon 配置目录时, skopeo copy/inspect 会因读不到
# policy.json 而 fatal: "Error loading trust policy: open /etc/containers/policy.json: no such file or directory"。
# 所有用 skopeo 的模块(tar 镜像推送: gpu_operator/lws/ceph/... )source 本库后即自动就绪。
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
# gpu_operator / lws / metax-load 曾各自复制同一份 _push_skopeo/_reg_has_tag;
# 集中到本库供新代码复用, 已有 metax/gpu/lws 维持原状避免回归。
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

# ---------------- 共享 skopeo 拉取助手(私服 docker:// → 本地 docker-archive tar) ----------------
# 与 push_image_skopeo 对称: 私服链路(尤其外网 Harbor)的 TLS 握手**间歇性超时**,
#   单次失败在调用方那里会变成"静默降级为本地旧 tar", 且 stderr 被吞掉 → 事后无从排查。
#   故拉取统一走这里: ① 整包 3 次重试; ② 失败原因经全局 SKOPEO_PULL_ERR 回传给调用方写进告警;
#   ③ 先写 <tar>.tmp 再原子 mv —— 拉取失败**绝不动**原有可用 tar
#      (否则回退路径会按 [ -f <tar> ] 把半截包当成"本地可用制品"推出去)。
# 全部为**新符号**, 不改任何现有调用方。

# 取私服上该 tag 的 digest(决定"要不要重下")。结果写全局 SKOPEO_REMOTE_DIGEST, 失败原因写 SKOPEO_PULL_ERR。
# ⚠ 刻意**不用 stdout 回显**: 调用方写成 $(...) 就在子 shell 里跑, 函数设的 SKOPEO_PULL_ERR 传不出来
#   (只剩"私服不可达"却不知道为什么)。调用方按 [ -n "${SKOPEO_REMOTE_DIGEST}" ] 判定"可达且有该 tag"。
# 恒 return 0 —— set -e 下裸调用不会退出模块; 判据一律看 SKOPEO_REMOTE_DIGEST 是否为空。
# 3 次重试很关键: 单次 TLS 超时若被当成"私服没这个镜像", 会静默跳过下载并回退旧 tar。
# 用法: remote_image_digest <src> [额外 skopeo 参数...]
SKOPEO_REMOTE_DIGEST=""
remote_image_digest() {
    local src="$1"; shift
    local d="" n=1 errf="/tmp/skopeo-inspect-err-$$"
    SKOPEO_REMOTE_DIGEST=""; SKOPEO_PULL_ERR=""
    for n in 1 2 3; do
        d="$(skopeo inspect --format '{{.Digest}}' "$@" "docker://${src}" 2>"${errf}" || true)"
        if [ -n "${d}" ]; then SKOPEO_REMOTE_DIGEST="${d}"; rm -f "${errf}"; return 0; fi
        SKOPEO_PULL_ERR="$(tail -1 "${errf}" 2>/dev/null || true)"
        if [ "${n}" -lt 3 ]; then
            warn "  私服 digest 查询失败(第 ${n}/3 次: ${SKOPEO_PULL_ERR:-未知错误}), 3s 后重试..."
            sleep 3
        fi
    done
    rm -f "${errf}"
    SKOPEO_PULL_ERR="${SKOPEO_PULL_ERR:-私服不可达或该 tag 不存在}"
    return 0
}

# 3 次整包重试的 skopeo 拉取(与 push_image_skopeo 同款: 大 blob 连接中断时
# skopeo 的 --retry-times 不覆盖)。错误文件按 PID 隔离(并行安全)。
# 用法: pull_image_skopeo <src> <tar 路径> [额外 skopeo 参数...](参数须在 ref 之前, skopeo 用 Go flag 解析)
pull_image_skopeo() {
    local src="$1" tar="$2"; shift 2
    local tmp="${tar}.tmp" n=1 errf="/tmp/skopeo-pull-err-$$" err=""
    SKOPEO_PULL_ERR=""
    for n in 1 2 3; do
        if skopeo copy --quiet "$@" "docker://${src}" "docker-archive:${tmp}" 2>"${errf}"; then
            mv -f "${tmp}" "${tar}"      # 同目录 rename, 原子替换: 旧 tar 在成功前一直可用
            rm -f "${errf}"
            return 0
        fi
        err="$(tail -1 "${errf}" 2>/dev/null || true)"
        rm -f "${tmp}"                  # 半截包一律不留(回退路径只认完整 tar)
        if [ "${n}" -lt 3 ]; then
            warn "  拉取失败(第 ${n}/3 次: ${err:-未知错误}), 3s 后重试整包..."
            sleep 3
        fi
    done
    SKOPEO_PULL_ERR="${err:-未知错误}"
    rm -f "${errf}"
    return 1
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

# ---------------- Helm chart 离线副本助手(全仓库唯一实现) ----------------
# 规则(见 docs/scripts-development-spec.md §2.4): **每个 helm chart 都必须在
# deployments/cubestack-addon/<组件>/ 下有一份随 git 分发的离线副本**(.tgz 或解包源码目录),
# 且**安装一律用这份本地副本** —— 线上拉到的东西不直接装。缺了它, 私服/上游一抖动就装不上
# (cubepilot 曾经就是这样: 回退代码写好了, 却压根没有可回退的文件)。
#
# 本助手把"本地副本就绪"这件事收敛到一处:
#   online : helm pull 到临时目录 → 取远端 digest, 与 <tgz>.digest 边车比对
#              未变 → 丢弃刚拉的文件, 继续用本地那份(**仓库保持干净**)
#              变了 → 覆盖本地副本 + 更新边车并**提示 commit**(会弄脏工作区, 但这是有意的:
#                      vendored 副本的刷新必须落到版本库里才有意义)
#              拉取失败 → **降级**回退本地副本(告警不中断)
#   offline: 完全不联网, 直接用本地副本
#   两种模式收尾都判一次"本地副本在不在"—— 不在就 err 并给出获取方法。
#
# 用法: helm_chart_ensure <组件名> <本地tgz路径> <版本> <online|offline> <ref> [repoURL]
#         ref : oci://host/proj/chart  或  chart 名(需同时给 repoURL)
#         repoURL 非空 → helm pull <ref> --repo <repoURL> --version <版本>(经典 helm repo)
#       返回 0 = 本地副本就绪(调用方直接 helm install <本地tgz路径>); 1 = 缺失且无法获取
#       ⚠ 本函数进度消息一律走 stderr(与 ensure_registry_nginx 同理), 便于将来在 $(...) 中使用;
#         err() 只打印不退出, 由本函数 return 1 / 调用方 || exit 1 决定是否中断。
# 依赖: load_config 已执行; online 模式另需 helm。digest 边车缺失视为"未知"→ 刷新(安全默认,
#       与镜像 tar 的 <tar>.digest 同一约定)。
helm_chart_ensure() {
    local comp="$1" tgz="$2" version="$3" mode="$4" ref="$5" repo="${6:-}"
    local dgfile="${tgz}.digest" tmpd="" pulled="" rdig="" ldig="" out="" args=()

    case "${mode}" in
        online|offline) ;;
        *) err "helm_chart_ensure: 模式仅支持 online|offline(当前=${mode})"; return 1 ;;
    esac
    mkdir -p "$(dirname "${tgz}")"

    if [ "${mode}" = "online" ]; then
        if ! command -v helm >/dev/null 2>&1; then
            warn "  未找到 helm, 跳过在线校验(改用本地离线副本: $(basename "${tgz}"))" >&2
        else
            tmpd="$(mktemp -d)"
            if [ -n "${repo}" ]; then
                args=( "${ref}" --repo "${repo}" --version "${version}" --destination "${tmpd}" )
            else
                args=( "${ref}" --version "${version}" --destination "${tmpd}" )
            fi
            if out="$(helm pull "${args[@]}" 2>&1)"; then
                pulled="$(ls -1t "${tmpd}"/*.tgz 2>/dev/null | head -1 || true)"
                # helm 各版本把 "Digest:" 写 stdout 还是 stderr 不一致 → 上面已合并捕获
                rdig="$(printf '%s\n' "${out}" | sed -n 's/^Digest:[[:space:]]*//p' | head -1)"
                [ -f "${dgfile}" ] && ldig="$(cat "${dgfile}" 2>/dev/null || true)"
                if [ -n "${pulled}" ] && [ -n "${rdig}" ] && [ -n "${ldig}" ] && [ "${rdig}" = "${ldig}" ]; then
                    ok "  ${comp} chart 远端 digest 未变, 继续用本地离线副本(仓库保持干净)" >&2
                elif [ -n "${pulled}" ]; then
                    mv -f "${pulled}" "${tgz}"
                    # 覆盖原因必须如实区分: "远端确实变了" 与 "没法比对所以按变了处理" 是两回事,
                    # 后者会误伤(把本地那份未经证实的覆盖掉), 混为一谈会让人查不出真相。
                    if [ -z "${rdig}" ]; then
                        warn "  ${comp} chart 未取到远端 digest(无法比对, 按已变更处理) → 已用刚拉取的覆盖 $(basename "${tgz}")" >&2
                    elif [ -z "${ldig}" ]; then
                        warn "  ${comp} chart 本地无边车 $(basename "${dgfile}")(无法比对, 按已变更处理) → 已覆盖 $(basename "${tgz}")" >&2
                    else
                        warn "  ${comp} chart 远端有更新 → 已覆盖离线副本 $(basename "${tgz}")" >&2
                    fi
                    [ -n "${rdig}" ] && printf '%s' "${rdig}" > "${dgfile}"
                    warn "    ⚠ 该文件是仓库内的 vendored 副本, 请 git add/commit 固化; 不提交则下次部署又回到旧版本" >&2
                fi
            else
                printf '%s\n' "${out}" | tail -3 | sed 's/^/    /' >&2
                warn "  ${comp} chart 远端拉取失败, **回退使用本地离线副本** $(basename "${tgz}")" >&2
            fi
            rm -rf "${tmpd}"; unset out
        fi
    fi

    if [ ! -f "${tgz}" ]; then
        err "  ${comp} 离线 chart 缺失: ${tgz}"
        err "    获取: helm pull ${ref}${repo:+ --repo ${repo}} --version ${version} -d $(dirname "${tgz}")"
        err "          然后把产出改名为 $(basename "${tgz}")(并写 <同名>.digest 边车), 提交入库"
        err "    注意: 离线副本**必须随仓库分发**, 只在部署时拉到盘上不算数"
        return 1
    fi
    return 0
}

# ---------------- 共享 nginx 校验镜像助手(verify 模块测试后端共用) ----------------
# verify_metallb / verify_lws / verify_ceph 等的测试后端
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
    # ---------------- Ceph 模式统一归一化(2026-09-07 双模式) ----------------
    # CEPH_MODE ∈ {internal, external}:
    #   · internal(默认) = 集群内 Rook-Ceph, 部署 CephCluster CR(现有行为);
    #   · external       = 不创建集群内 CephCluster, 由 ceph_csi 模块经 ceph-csi-operator
    #                     的 CephConnection 接入外部已有 Ceph 集群。
    # 兼容旧配置: 仅设了 CEPH_EXTERNAL_MONITORS(旧外部模式开关)→ 自动视为 external,
    #   并把 CEPH_EXTERNAL_POOL/USER/KEYRING 迁移到新变量 CEPH_POOL/USER/KEYRING。
    # 统一由本处归一化, 各模块只读 CEPH_MODE/CEPH_MONITORS/CEPH_POOL/CEPH_USER/CEPH_KEYRING。
    if [ "${CEPH_MODE:-internal}" != "external" ]; then
        if [ -n "${CEPH_EXTERNAL_MONITORS:-}" ]; then
            CEPH_MODE="external"
            CEPH_MONITORS="${CEPH_MONITORS:-${CEPH_EXTERNAL_MONITORS}}"
            CEPH_POOL="${CEPH_POOL:-${CEPH_EXTERNAL_POOL:-rbd}}"
            CEPH_USER="${CEPH_USER:-${CEPH_EXTERNAL_USER:-admin}}"
            CEPH_KEYRING="${CEPH_KEYRING:-${CEPH_EXTERNAL_KEYRING:-}}"
        else
            CEPH_MODE="internal"
        fi
    fi
    # external 模式下统一兜底默认值(显式 CEPH_MODE=external 未设 CEPH_POOL/USER 时也生效)
    CEPH_POOL="${CEPH_POOL:-rbd}"
    CEPH_USER="${CEPH_USER:-admin}"
    export CEPH_MODE CEPH_MONITORS CEPH_POOL CEPH_USER CEPH_KEYRING
    # ---------------- local-path / ceph 二选一(互斥, 集中派生) ----------------
    # 单一事实来源 = CEPH_ENABLED **或 CEPH_CSI_ENABLED**(任一 true 即视为 ceph 体系:
    #   internal 自建 CephCluster / external 只接外部 Ceph 都算 ceph 底座):
    #   · ceph 启用(任一 true) → registry 后端强制 ceph-block, 并关闭 local-path(ceph 替代 local-path,
    #     不再安装 local-path-provisioner; addons.yml local_path_provisioner_enabled 同步为 false)。
    #   · 都 false → 保持 local-path 为默认后端(默认)。
    # ⚠ 即使显式写了 REGISTRY_STORAGE_CLASS / LOCAL_PATH_ENABLED 也会被本规则覆盖(二选一, 不并存);
    #   想用 local-path 就设 CEPH_ENABLED=false 且 CEPH_CSI_ENABLED=false。
    # ★ CEPH_FALLBACK_TO_LOCALPATH=true 且检测到 ceph 安装条件不足(manifest/裸盘/lvm2/external 参数
    #   缺失)时, deploy-cluster.sh 预检会把 CEPH_ENABLED 置 false → 此处自然走 local-path 分支,
    #   无需额外逻辑。检测函数见 ceph_installable_check(下方)。
    if [ "${CEPH_ENABLED:-false}" = "true" ] || [ "${CEPH_CSI_ENABLED:-false}" = "true" ]; then
        # 仅当 cluster.conf 显式写了冲突值时提醒(默认值 local-path/true 不算冲突, 避免每次 run 刷屏)
        if grep -qE '^[[:space:]]*REGISTRY_STORAGE_CLASS=.*(local-path)' "${CLUSTER_CONF}" 2>/dev/null; then
            warn "Ceph 已启用(CEPH_ENABLED/CEPH_CSI_ENABLED) → REGISTRY_STORAGE_CLASS 强制 ceph-block(local-path 被替代)"
        fi
        if grep -qE '^[[:space:]]*LOCAL_PATH_ENABLED=(true|1|yes|on)' "${CLUSTER_CONF}" 2>/dev/null; then
            warn "Ceph 已启用(CEPH_ENABLED/CEPH_CSI_ENABLED) → LOCAL_PATH_ENABLED 强制 false(local-path 与 ceph 二选一, 不再安装 local-path)"
        fi
        REGISTRY_STORAGE_CLASS="ceph-block"
        LOCAL_PATH_ENABLED="false"
    fi
    export REGISTRY_STORAGE_CLASS LOCAL_PATH_ENABLED
    # 虚拟机配置(独立于 cluster.conf): source vm-nodes.conf 提供 VM 创建/网络变量
    vm_conf_load
}

# ---------------- Ceph 安装条件检测(供回退判定) ----------------
# 检测当前环境是否**具备安装 Ceph** 的条件, 供 deploy-cluster.sh 预检在
# CEPH_FALLBACK_TO_LOCALPATH=true 时决定是否回退到 local-path 模式。
# 返回 0=具备(可装 ceph), 1=不具备(可回退); 不满足项输出到 stdout 供提示。
# 判定(与 02_ceph.sh / 03_ceph_csi.sh 的前置校验一致):
#   · external: CEPH_MONITORS 与 CEPH_KEYRING 必须非空; CEPH_USER 与 CEPH_KEYRING 必须成对
#     (2026-09-10 Bug B: 只查 keyring 存在不校验 user 会让"用户不存在/key 不匹配"拖到部署后期
#     才以 rados ret=-13 暴露 —— 这里做结构校验; 用户存在性/caps 的真实校验在 ceph_csi 模块
#     的 preflight(见 03_ceph_csi.sh)与提供方 ceph-expose-external.sh status 5 层自检)
#   · internal: rook manifest(operator.yaml/csi-operator.yaml)存在;
#     存储节点数 ≥ CEPH_MIN_NODES; 至少一台节点有裸盘(CEPH_DATA_DISKS 显式 或
#     自动检测到); lvm2 离线包或节点已装 lvm2(仅检查离线包目录, 不 SSH 探测)
ceph_installable_check() {
    local _miss=""
    # external 模式: monitors + keyring(+ user 成对)
    if [ "${CEPH_MODE:-internal}" = "external" ]; then
        [ -n "${CEPH_MONITORS:-}" ] || _miss="${_miss} CEPH_MONITORS"
        [ -n "${CEPH_KEYRING:-}" ] || _miss="${_miss} CEPH_KEYRING"
        [ -n "${CEPH_USER:-}" ] || _miss="${_miss} CEPH_USER"
        # CephFS 启用时 provisioner 凭据成对(node 可回退, 不强制)
        if [ -n "${CEPHFS_FS:-}" ] && { [ -z "${CEPHFS_USER:-}" ] || [ -z "${CEPHFS_KEYRING:-}" ]; }; then
            _miss="${_miss} CEPHFS_USER/CEPHFS_KEYRING(成对)"
        fi
        if [ -n "${_miss}" ]; then
            echo "外部 Ceph 参数缺失/不成对:${_miss}"
            return 1
        fi
        return 0
    fi
    # internal 模式: manifest + 存储节点数 + 裸盘 + lvm2 离线包
    if [ ! -f "${CEPH_ROOK_MANIFEST_DIR:-${REPO_ROOT}/deployments/cubestack-addon/rook}/operator.yaml" ] \
        || [ ! -f "${CEPH_ROOK_MANIFEST_DIR:-${REPO_ROOT}/deployments/cubestack-addon/rook}/csi-operator.yaml" ]; then
        echo "Rook manifest 缺失(${CEPH_ROOK_MANIFEST_DIR:-${REPO_ROOT}/deployments/cubestack-addon/rook})"
        return 1
    fi
    # 存储节点数(与 02_ceph.sh 同源: 统一走 ceph_storage_hosts, 不再各写一遍)
    local _cn
    _cn="$(ceph_storage_host_count)"
    if [ "${_cn}" -lt "${CEPH_MIN_NODES:-3}" ]; then
        echo "存储节点 ${_cn} 台 < CEPH_MIN_NODES=${CEPH_MIN_NODES:-3}"
        return 1
    fi
    # 裸盘(显式 CEPH_DATA_DISKS 非空即视为具备; 自动检测需 SSH, 预检阶段不探测 → 显式才判为具备)
    if [ -z "${CEPH_DATA_DISKS:-}" ]; then
        echo "未显式指定 CEPH_DATA_DISKS(自动检测需节点 SSH, 预检不探测)"
        return 1
    fi
    # lvm2 离线包(仅检查目录, 不 SSH)
    if [ ! -d "${OFFLINE_FILES_DIR:-${REPO_ROOT}/deployments/offline-files/kubespray}/packages" ] \
        || ! ls "${OFFLINE_FILES_DIR:-${REPO_ROOT}/deployments/offline-files/kubespray}/packages"/lvm2_*.deb >/dev/null 2>&1; then
        echo "lvm2 离线包缺失(packages/ 无 lvm2_*.deb)"
        return 1
    fi
    return 0
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

# ---------------- kube-vip: API Server VIP 推导与校验 ----------------
# 详见 docs/kube-vip-api-ha.md。三个关键约束(任一违反都是确定性故障, 故为硬失败):
#   ① 与 HAPROXY_ENABLED / KEEPALIVED_ENABLED 互斥 —— 三者都在争 loadbalancer_apiserver.address 的解释权
#   ② VIP 不得落在 METALLB_POOL 内 —— 否则 MetalLB 可能把同一个 IP 分配给某个 Service, 抢走控制平面入口
#   ③ VIP 不得等于任一节点 IP —— 会与真实网卡地址冲突(ARP 打架)

# <IP> → 退出码 0=落在 METALLB_POOL 内(支持 起止区间 / CIDR / 单地址; 留空视为不冲突)
metallb_pool_contains() {
    local ip="$1" pool="${METALLB_POOL:-}"
    [ -n "${pool}" ] || return 1
    local ipint lo hi
    ipint=$(ip2int "${ip}")
    case "${pool}" in
        *-*)
            lo=$(ip2int "${pool%%-*}"); hi=$(ip2int "${pool##*-}")
            [ "${ipint}" -ge "${lo}" ] && [ "${ipint}" -le "${hi}" ]
            ;;
        */*) cidr_contains "${ip}" "${pool}" ;;
        *)   [ "$(ip2int "${pool}")" -eq "${ipint}" ] ;;
    esac
}

# 由节点主机名反查其 IP(供 SSH/端口探测复用)。
# ⚠ 必须用 IP 而不是主机名去做 SSH: 部署容器里通常没有各节点的 /etc/hosts 解析,
#   用主机名会**静默连不上**(stderr 被丢弃时尤其难查)。09_kube_vip 曾因此误报镜像缺失。
# 用法: ip="$(node_ip_by_hostname mxgpu-1-147)"
node_ip_by_hostname() {
    local want="$1" line
    [ -n "${want}" ] || return 1
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        if [ "${NODE_HOSTNAME}" = "${want}" ] && [ -n "${NODE_IP}" ]; then
            printf '%s' "${NODE_IP}"
            return 0
        fi
    done
    return 1
}

# 收集全部 master 主机名(空格分隔; 供逐台 SSH 探测复用)
# ⚠ 用显式 if 而非 `A && B && printf`: 后者在条件不成立时整条返回 1, 在 set -e 下
# 会让 `X=$(master_hosts)` 这种命令替换**静默中止调用方**(09_kube_vip 曾因此死掉)。
master_hosts() {
    local line
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        if [ "${NODE_ROLE}" = "master" ] && [ -n "${NODE_HOSTNAME}" ]; then
            printf '%s ' "${NODE_HOSTNAME}"
        fi
    done
    return 0
}

# 收集全部节点 IP(空格分隔; 供 VIP 冲突判定复用)
all_node_ips() {
    local line
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        if [ -n "${NODE_IP}" ]; then
            printf '%s ' "${NODE_IP}"
        fi
    done
    return 0
}

# 静态校验(无网络交互): kube-vip 开关与取值的一致性
# 硬失败项直接 err+exit 1; 通过则返回 0
# 用法: kube_vip_validate_config || exit 1   (须已 load_config)
kube_vip_validate_config() {
    [ "${KUBE_VIP_ENABLED:-true}" = "true" ] || return 0

    # ① 互斥
    if [ "${HAPROXY_ENABLED:-false}" = "true" ] || [ "${KEEPALIVED_ENABLED:-false}" = "true" ]; then
        err "KUBE_VIP_ENABLED=true 与 HAPROXY_ENABLED/KEEPALIVED_ENABLED 互斥, 二者都在争 API 入口:"
        err "  kube-vip  : KUBE_VIP_ENABLED=true"
        err "  HAProxy+KA: HAPROXY_ENABLED=${HAPROXY_ENABLED:-false} KEEPALIVED_ENABLED=${KEEPALIVED_ENABLED:-false}"
        err "二者只能留一个(推荐保留 kube-vip, 见 docs/kube-vip-api-ha.md)"
        return 1
    fi

    local vip="${K8S_API_VIP:-}"

    # ② VIP 不在 MetalLB 池内
    if [ -n "${vip}" ] && metallb_pool_contains "${vip}"; then
        err "K8S_API_VIP=${vip} 落在 METALLB_POOL=${METALLB_POOL} 内 —— MetalLB 可能把该地址分配给"
        err "某个 LoadBalancer Service, 直接抢走 API 控制平面入口。请改用池外地址。"
        return 1
    fi

    # ③ VIP 不等于任一节点 IP
    if [ -n "${vip}" ]; then
        local _ips _ip
        _ips="$(all_node_ips)"
        for _ip in ${_ips}; do
            if [ "${_ip}" = "${vip}" ]; then
                err "K8S_API_VIP=${vip} 与节点 IP 冲突(节点 IP 不能同时作 VIP: ARP 会打架)"
                return 1
            fi
        done
    fi

    # ④ master 数量(单 master 无高可用可言, 但不算错误 —— 只提示)
    local _master_count=0 _line
    for _line in "${NODES[@]:-}"; do
        [ -z "${_line}" ] && continue
        node_parse "${_line}"
        [ "${NODE_ROLE}" = "master" ] && _master_count=$((_master_count + 1))
    done
    if [ "${_master_count}" -lt 3 ]; then
        warn "kube-vip 已启用但仅 ${_master_count} 台 master —— VIP 只能在现存 master 之间漂移,"
        warn "少于 3 台时无真正的多数派容错(建议 3 台及以上)"
    fi

    # ⑤ 本地代理(kubespray nginx-proxy): 拦住"以为改了开关就生效"的假修复
    #    kubespray 的 kube_apiserver_endpoint 模板里 `loadbalancer_apiserver is defined` 分支优先,
    #    只要外部 LB 还在, kubelet 永远走 <域名>:6443 —— 本地代理装了也没人用。
    #    这不是"少配一个变量", 是两个互斥的拓扑选择, 所以硬失败而不是警告。
    if bool_is_true "${KUBE_VIP_LOCAL_PROXY:-false}"; then
        err "KUBE_VIP_LOCAL_PROXY=true 与当前拓扑冲突, 单改开关不会生效(本地代理会装上但没流量):"
        err "  原因: kubespray 模板中 loadbalancer_apiserver 分支优先于 localhost 分支,"
        err "        只要 all.yml 里还定义着 loadbalancer_apiserver, kubelet 就始终走域名:6443"
        err "  二选一:"
        err "    · 路线1(推荐, 保留域名/VIP 对外入口): 待支持后由脚本显式声明 kubelet 端点"
        err "    · 路线2(全集群改用本地代理): 摘掉 all.yml 的 loadbalancer_apiserver 块"
        err "        代价: 对外稳定入口丢失(除非另有外部 LB), kube-vip 的价值也随之消失"
        err "  当前建议: 保持 KUBE_VIP_LOCAL_PROXY=false, 走 kube-vip 单一路径"
        return 1
    fi
    return 0
}

# 读取 inventory 中当前已生效的 API 入口地址(all.yml 的 loadbalancer_apiserver.address)
# 用途: 让 VIP 在多次运行间保持稳定 —— 一旦写进库存就不再重新推导(否则每次跑都可能漂到别的地址,
# 导致 kube_vip_address 与 loadbalancer_apiserver.address 失配、证书 SAN 反复重签)。
# 用法: cur="$(kube_vip_current_entry)"   (无库存/读不到时输出空串)
kube_vip_current_entry() {
    local all_yml="${KUBESPRAY_INV_DIR:-${REPO_ROOT}/deployments/kubespray/inventory/cubestack-cluster}/group_vars/all/all.yml"
    [ -f "${all_yml}" ] || return 0
    awk '/^loadbalancer_apiserver:/{f=1; next} f && /^[[:space:]]+address:/{print $2; exit}' "${all_yml}" 2>/dev/null
}

# 读取 inventory 里记录的 kube-vip VIP(addons.yml 的 kube_vip_address)
# 用途: 关闭态清理时的"阶段二"判定 —— 若 API 入口仍指向这个地址, 就绝不能删 manifest。
# ⚠ 这个键与 kube_vip_enabled 开关**无关**(它只喂 apiserver 证书 SAN), 所以关闭态下它依然在,
#   正好可以当"这台集群的 VIP 是哪个"的记录来用。
# 用法: vip="$(kube_vip_recorded_address)"   (无库存/读不到时输出空串)
kube_vip_recorded_address() {
    local addons="${KUBESPRAY_INV_DIR:-${REPO_ROOT}/deployments/kubespray/inventory/cubestack-cluster}/group_vars/k8s_cluster/addons.yml"
    [ -f "${addons}" ] || return 0
    awk '/^kube_vip_address:/{print $2; exit}' "${addons}" 2>/dev/null
}

# VIp 是否是一个"可以当 VIP 用"的候选(排掉节点自身 IP 与 MetalLB 池内地址)
# 用法: kube_vip_is_viable_candidate <ip>
kube_vip_is_viable_candidate() {
    local ip="$1" _ip
    [ -n "${ip}" ] || return 1
    for _ip in $(all_node_ips); do [ "${_ip}" = "${ip}" ] && return 1; done
    metallb_pool_contains "${ip}" && return 1
    return 0
}

# VIP 自动推导: 在各 master 上探测, 找同网段的空闲地址
# 判定"空闲" = ICMP 无应答(地址真的没被占) 且 6443 端口连不上(不是别的集群的 API VIP)
# ⚠ 探测必须在各 master 上经 SSH 执行 —— 部署机不一定有到节点网段的路由, 从部署机探测会把
#   "路由不通"误判成"地址空闲", 这比不探测更危险(会把别人的 IP 当 VIP 用)。
# 推导顺序(确保幂等): 已写入 all.yml 的地址 > K8S_API_VIP / APISERVER_ADDRESS 显式值 > 从 .210 起探测
# ⚠ "复用 all.yml 现值"有个陷阱: 存量集群首跑时现值是 master01 —— 那是**节点 IP**, 不是 VIP。
#   若照抄会得到"VIP = master01"这种自相矛盾的配置(等于让 kube-vip 去抢一个真实节点地址),
#   且阶段判定会短路成"已切换"。故复用时必须过 kube_vip_is_viable_candidate 校验。
# 用法: vip="$(kube_vip_derive)" || exit 1     (输出推导出的 VIP; 失败 err 并返回 1)
kube_vip_derive() {
    local node_ips; node_ips="$(all_node_ips)"
    local m1; m1="$(first_master_ip)" || { err "无 master 节点, 无法推导 VIP"; return 1; }
    local base="${m1%.*}" ssh_key="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
    local _user="${SSH_USER:-ubuntu}"

    # 探测器(在目标机上执行): 0 = 该地址空闲
    #   -c1 -W1   : ICMP 一次, 最多等 1s
    #   /dev/tcp  : bash 内建 TCP 连接, 1s 超时(节点上不保证装了 nc)
    local probe='
        ip="__IP__"
        ping -c1 -W1 "$ip" >/dev/null 2>&1 && exit 1
        timeout 1 bash -c "echo > /dev/tcp/$ip/6443" 2>/dev/null && exit 1
        exit 0'

    # 候选地址是否可用(排除节点 IP / MetalLB 池 / 被占用)
    _kube_vip_candidate_free() {
        local ip="$1" _ip
        for _ip in ${node_ips}; do [ "${_ip}" = "${ip}" ] && return 1; done
        metallb_pool_contains "${ip}" && return 1
        local _host
        for _host in $(master_hosts); do
            ssh -i "${ssh_key}" -o BatchMode=yes -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
                "${_user}@${_host}" "${probe//__IP__/${ip}}" >/dev/null 2>&1 || return 1
        done
        return 0
    }

    # 1) 显式指定优先(cluster.conf K8S_API_VIP; APISERVER_ADDRESS 仅作兼容兜底)
    local seed="${K8S_API_VIP:-}"
    [ -n "${seed}" ] || seed="$(nonnumeric_entry "${KUBESPRAY_INV_DIR:-${REPO_ROOT}/deployments/kubespray/inventory/cubestack-cluster}/group_vars/all/all.yml" 2>/dev/null || true)"
    if [ -z "${seed}" ] && [ "${KUBE_VIP_SWITCH_CONFIRMED:-0}" != "1" ]; then
        # 阶段一里 APISERVER_ADDRESS 常被显式设成第一个 master(用于固定入口)—— 那不是 VIP, 不能当种子
        seed=""
    fi
    if [ -n "${seed}" ]; then emit_ip "${seed}" || return 1; return 0; fi

    # 2) 库存里已有**可当 VIP 用**的地址 —— 直接复用(保证幂等, 不因重跑而漂移)
    #    例外: KUBE_VIP_SWITCH_CONFIRMED=1(用户已在倒计时窗口确认切换)时跳过复用, 重新推导
    local cur; cur="$(kube_vip_current_entry)"
    if [ -n "${cur}" ] && [ "${KUBE_VIP_SWITCH_CONFIRMED:-0}" != "1" ]; then
        if kube_vip_is_viable_candidate "${cur}"; then
            vlog "沿用已生效的 API 入口地址: ${cur}"
            emit_ip "${cur}" || return 1; return 0
        fi
        vlog "当前入口 ${cur} 不是可用 VIP(节点 IP 或落在 MetalLB 池内)→ 重新推导"
    fi

    # 3) 自动探测: 从 K8S_API_VIP_START(默认 210)到 .254
    local start="${K8S_API_VIP_START:-210}"
    # ⚠ >&2: 本函数是值函数(返回值走 stdout), 进度提示绝不能混进 $(...) 的捕获结果
    say "推导 API VIP(起于 ${base}.${start}, 逐个探测直至 .254)..." >&2
    local i ip
    for i in $(seq "${start}" 254); do
        ip="${base}.${i}"
        if _kube_vip_candidate_free "${ip}"; then
            vlog "VIP 候选 ${ip} 空闲(已排除节点 IP 与 MetalLB 池)"
            emit_ip "${ip}" || return 1; return 0
        fi
    done

    err "在 ${base}.${start}-${base}.254 范围内未找到空闲 VIP(全部被占用/被排除)"
    err "请在 ${CLUSTER_CONF} 显式指定 K8S_API_VIP=<同网段空闲地址>"
    return 1
}

# 探测: 集群是否已经在运行(首个 master 上能列出 Node)。
# 用途: kube_vip 模块的前置自检 —— 它需要一个已存在的集群才能动手(VIP 是给 API 用的)。
# 用法: if is_cluster_live; then ... fi     (探测失败一律视为"未运行")
is_cluster_live() {
    local m1; m1="$(first_master_ip)" || return 1
    local _user="${SSH_USER:-ubuntu}" ssh_key="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
    ssh -i "${ssh_key}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${_user}@${m1}" \
        "command -v kubectl >/dev/null 2>&1 && sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o name 2>/dev/null | head -1" \
        2>/dev/null | grep -q .
}

# 探测: VIP 是否已真实绑定在某台 master 的网卡上(kube-vip 已就位)。
# ⚠ 必须经 SSH 在各 master 上探测: 部署机不一定有到节点网段的路由, 从部署机探测会把"路由不通"
#   误判成"VIP 未就绪" —— 而对存量集群来说, 这个误判会让切换被无谓拦停(fail-closed 方向是对的,
#   但会一直卡住)。用路由表查法(ip route get)而非 ping: 不需要 ICMP 可达, 只看本机是否持有该地址。
# 用法: if kube_vip_is_bound "<VIP>"; then ... fi
kube_vip_is_bound() {
    local vip="${1:-}"
    [ -n "${vip}" ] || return 1
    local _user="${SSH_USER:-ubuntu}" ssh_key="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
    local _host
    for _host in $(master_hosts); do
        if ssh -i "${ssh_key}" -o BatchMode=yes -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${_user}@${_host}" \
               "ip route get '${vip}' 2>/dev/null | grep -q 'local ${vip} '" 2>/dev/null; then
            vlog "VIP ${vip} 已绑定在 ${_host}"
            return 0
        fi
    done
    return 1
}

# 阶段判定: 决定本次运行 API 入口地址取什么值(两阶段切换的核心, 见 docs/kube-vip-api-ha.md 第 7 节)
# 输出: 要写入 all.yml 的 loadbalancer_apiserver.address; 同时设置 API_ENTRY_PHASE(1/2)
#
#   与"集群是不是新建"无关, 只看一件事: **VIP 此刻是否已经真的绑上了**。
#   原因是 kubespray 的时序: 写 /etc/hosts 的 0090-etchosts.yml 在 **preinstall 角色**里,
#   而拉起 kube-vip 的 kubernetes/node 角色排在 **etcd 安装之后** —— 两者差一个 etcd 安装的时间。
#   所以无论新建还是存量, 只要 VIP 还没绑, 把入口指向 VIP 就等于指向一个不存在的地址。
#
#   VIP 未绑 → 阶段一: 写 master01(既有行为, 零风险); 本轮的唯一产出是让 kube-vip 就位
#   VIP 已绑 → 阶段二: 写 VIP(切换入口)
#
# 用法: api_addr="$(kube_vip_resolve_target)" && api_phase="${API_ENTRY_PHASE}"
kube_vip_resolve_target() {
    API_ENTRY_PHASE=1

    # kube-vip 未启用 → 维持既有行为(第一个 master), 不引入任何新路径
    if [ "${KUBE_VIP_ENABLED:-true}" != "true" ]; then
        API_ENTRY_PHASE=0
        local _m; _m="$(first_master_ip)" || return 1
        emit_ip "${_m}" || return 1; return 0
    fi

    local vip; vip="$(kube_vip_derive)" || return 1
    local master01; master01="$(first_master_ip)" || return 1

    if [ "${vip}" = "${master01}" ]; then
        API_ENTRY_PHASE=0
        emit_ip "${master01}" || return 1; return 0
    fi

    if kube_vip_is_bound "${vip}"; then
        API_ENTRY_PHASE=2
        emit_ip "${vip}" || return 1; return 0
    fi

    vlog "VIP ${vip} 尚未绑定 → 阶段一(本轮仅就位 VIP, API 入口保持 ${master01})"
    emit_ip "${master01}" || return 1; return 0
}

# 布尔归一化(cluster.conf 里 true/1/yes/on 都算开) —— 与 sync-kubespray-config.sh 的 _bool 同语义
bool_is_true() { case "${1:-0}" in 1|true|yes|on) return 0;; *) return 1;; esac; }

# all.yml 里"非数值的 API 入口地址"(如 kube-vip 启用后的 VIP 走的是 Jinja 表达式)。
# 现有的 sed 同步只认 [0-9.]+ 字面量, 这类值不会被误覆盖; 但仍需在写入前确认,
# 否则一次误改就会把真正生效的表达式抹掉。
# 用法: nonnumeric_entry "<all.yml 路径>" → 输出该值(无则空)
nonnumeric_entry() {
    local f="$1" v
    v="$(awk '/^loadbalancer_apiserver:/{f=1; next} f && /^[[:space:]]+address:/{print $2; exit}' "${f}" 2>/dev/null)"
    case "${v}" in
        ""|*[!0-9.]*) printf '%s' "${v}" ;;   # 含非数字/点字符 → 不是字面 IP
        *) printf '' ;;
    esac
}

# 重写 addons.yml 的 kube-vip 配置块(幂等)
# 以 "# Kube VIP" 行为锚点: 丢弃旧块(锚点行 + 紧随其后的注释行 + 其后连续的 kube_vip_*/loadbalancer_apiserver 行),
# 再按当前配置重写。用 awk 脚本文件而非内联程序 —— 内联的复杂引号规则经 shell 传递易被破坏。
# 用法: update_kube_vip_addons_yml "<addons.yml 路径>" "<VIP>"
#
# ⚠ **单一写入者契约**: 本函数写入的 kube_vip_enabled **恒为 false**, 与 KUBE_VIP_ENABLED 无关。
#   含义不是"kube-vip 没启用", 而是"不要让 kubespray 写这个静态 Pod" —— 静态 Pod 由
#   02_k8s/09_kube_vip.sh 独占。原因是两边的渲染结果**必然不同**: kubespray 对**首台** master
#   会把 manifest 的 hostPath 渲染成 super-admin.conf
#   (roles/kubernetes/node/tasks/loadbalancer/kube-vip.yml:26-31 的 set_fact), 而我们的渲染器
#   恒用 admin.conf → 每次全量运行该文件被改写两次 → kube-vip pod 跟着重启两次。
#   把 kubespray 侧关掉之后, 它对本集群 kube-vip 的唯一贡献就只剩 "把 VIP 写进证书 SAN"。
#   详见 docs/kube-vip-api-ha.md 第 18 节。
update_kube_vip_addons_yml() {
    local f="$1" vip="${2:-}"
    [ -f "${f}" ] || { warn "未找到 ${f}, 跳过 kube-vip 同步"; return 1; }
    grep -q '^# Kube VIP' "${f}" || { warn "${f} 中未找到 '# Kube VIP' 锚点行, 跳过 kube-vip 同步"; return 1; }

    local tmp; tmp="$(mktemp)"
    awk '
        function is_block_line(s) {
            return (s ~ /^[[:space:]]*#/ || s ~ /^[[:space:]]*kube_vip_/ ||
                    s ~ /^[[:space:]]*loadbalancer_apiserver:/ || s ~ /^[[:space:]]*address:/ ||
                    s ~ /^[[:space:]]*port:/)
        }
        /^# Kube VIP/ { dropping = 1; next }
        dropping && is_block_line($0) { next }
        dropping { dropping = 0 }
        { print }
    ' "${f}" > "${tmp}"

    {
        echo "# Kube VIP"
        # ⚠ 恒为 false, 且**不跟随 KUBE_VIP_ENABLED** —— 含义是"kubespray 不要插手这个静态 Pod",
        #   静态 Pod 由 02_k8s/09_kube_vip.sh 独占(单一写入者)。理由见本函数头注释。
        echo "kube_vip_enabled: false"
        # kube_vip_address 与上面的开关**无关**: 它只喂 apiserver 证书 SAN
        # (control-plane/tasks/kubeadm-setup.yml:48 的 sans_kube_vip_address, 只看它是否定义,
        #  不看 kube_vip_enabled)。**KUBE_VIP_ENABLED=false 时也保留它** → 关掉 kube-vip 后再开回来
        #  不必重签证书(阶段二切换的主要代价之一就是证书 SAN 重签, 能省则省)。
        [ -n "${vip}" ] && echo "kube_vip_address: ${vip}"
        # 以下键在 kube_vip_enabled: false 下**全部不生效**(kubespray 的 kube-vip 任务整个被跳过),
        # 保留它们纯粹是逃生口: 万一手工把上面的开关翻成 true, kubespray 渲染出来的仍是这套策略
        # (ARP + 控制面 + cp_detect + 不开服务 LB), 而不是一份 arp 全关的坏 manifest。
        echo "kube_vip_arp_enabled: true"
        echo "kube_vip_controlplane_enabled: true"
        # apiserver 进程级故障检测: 开启后 kube-vip 探本机 apiserver /healthz, 探失败即把
        # 自身健康置假 → 不再续租 → 约 5s(租约时长)后 VIP 漂走。这是"节点活着但 apiserver
        # 死了"这一场景唯一的快速切换手段(关闭时只能等租约自然过期, 与节点宕机同速)。
        # 默认开(与 kubespray 的 false 不同): 该场景在真实运维中比整机宕机更常见。
        echo "kube_vip_cp_detect: $(bool_is_true "${KUBE_VIP_CP_DETECT:-true}" && echo true || echo false)"
        # 服务 LB 归 MetalLB —— 两者都实现 LoadBalancer 语义, 同时开会让 kube-vip 抢走
        # MetalLB 的地址分配权(实机已验证的分工, 见 docs/kube-vip-api-ha.md 决策 D1)
        echo "kube_vip_services_enabled: false"
        # 不开控制面负载均衡(决策 D4)。⚠ 不是"收益有限"那么含糊 —— 是 kube_vip_lb_fwdmethod
        # 的默认值 local 在内核里等于 ip_vs_null_xmit(包原样交回本机栈, 根本不转发),
        # 开了也只会得到一个"后端登记了但不用"的 IPVS 表; 要真 LB 得换 masquerade, 那又要
        # privileged + kube-vip-iptables 镜像 + kube-proxy excludeCIDRs 与 VIP 同步。
        # 详见 docs/kube-vip-api-ha.md 决策 D4 与 docs/troubleshooting.md 三.11。
        echo "kube_vip_lb_enable: false"
        [ -n "${KUBE_VIP_INTERFACE:-}" ] && echo "kube_vip_interface: ${KUBE_VIP_INTERFACE}"
    } >> "${tmp}"

    cat "${tmp}" > "${f}"
    rm -f "${tmp}"

    if bool_is_true "${KUBE_VIP_ENABLED:-true}"; then
        [ -n "${vip}" ] || { err "kube-vip 已启用但 VIP 为空 —— 不能写入 kube_vip_address"; return 1; }
    fi
    if [ -n "${vip}" ]; then
        local wrote; wrote="$(awk '/^kube_vip_address:/{print $2; exit}' "${f}")"
        [ "${wrote}" = "${vip}" ] || { err "kube_vip_address 写入校验失败(期望 ${vip}, 实际 ${wrote})"; return 1; }
    fi
    # 单一写入者契约的写入校验: 这一行必须恒为 false, 否则 kubespray 会回来写 manifest
    local _en; _en="$(awk '/^kube_vip_enabled:/{print $2; exit}' "${f}")"
    [ "${_en}" = "false" ] || { err "kube_vip_enabled 应为 false(静态 Pod 由 09_kube_vip 独占), 实际 '${_en}'"; return 1; }
    return 0
}

# 把 k8s-cluster.yml 的 advertise-address 修为"按节点各写各的"(幂等修复, 非同步)
# 原实现统一写死第一个 master IP → 三个 apiserver 都对外宣告同一地址 →
# kubernetes Service 的 EndpointSlice 只有一条 → 集群内经 Service 访问 API 同样单点。
# ⚠ 这是独立于 kube-vip 的一处单点修复, 详见 docs/kube-vip-api-ha.md 2.5 节。
#   值必须保持 Jinja 表达式, 改成具体 IP 会直接抵消本修复。
# 用法: update_advertise_address_yml "<k8s-cluster.yml 路径>"
update_advertise_address_yml() {
    local f="$1" want='  advertise-address: "{{ kube_apiserver_address }}"'
    [ -f "${f}" ] || { warn "未找到 ${f}, 跳过 advertise-address 同步"; return 1; }

    if grep -qE '^[[:space:]]+advertise-address:[[:space:]]*' "${f}"; then
        grep -qF "${want}" "${f}" && return 0    # 已是目标值 → 幂等跳过
        sed -i -E 's|^([[:space:]]+advertise-address:).*|\1 "{{ kube_apiserver_address }}"|' "${f}"
        say "  advertise-address 已修正为按节点取值(原为固定 IP, 会造成 kubernetes Service 单点)"
    else
        sed -i -E "/^kube_apiserver_extra_args:/a\\${want}" "${f}"
    fi
    grep -qF "${want}" "${f}" || { err "advertise-address 写入校验失败"; return 1; }
    return 0
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
    # ⚠ 显式 return 0: 本函数是纯解析器, 上面的 if 分支未命中时退出码会是 1。
    # 调用方(set -e 下的模块)若写成 `X=$(...)` 就会**静默退出** —— 曾致 09_kube_vip
    # 在遍历到 worker 节点时无任何报错直接死掉(排查花掉很久)。解析成功就该返回 0。
    return 0
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

# ---------------- Ceph 存储节点选择(唯一实现) ----------------
# ⚠ 这段逻辑**曾在本仓库散落 5 处各写一遍**(02_ceph.sh / lib-common 的预检 / deploy-cluster.sh
#   两处 / ceph-cleanup.sh), 改一处漏一处就会出现"预检说 3 台、真装却装到别的节点"这类不一致。
#   统一收敛到这里, 所有消费方都调本函数。
#
# 选择规则(优先级从上到下):
#   ① CEPH_NODES 非空      → 显式列表优先(hostname, 逗号分隔), 不做任何过滤
#   ② CEPH_NODE_ROLE=all   → NODES 全量(2026-09-18 之前的旧默认行为)
#   ③ 其它                 → 只取 NODES 中 role == CEPH_NODE_ROLE 的节点
#                            (**默认 master**: 即"ceph 默认只装在 master 节点")
# 输出: hostname 每行一个(调用方用 mapfile/while read 接)。
# ⚠ 在**命令替换**中调用($(...)), 内部 node_parse 设的全局变量不会污染调用方 —— 这是有意的,
#   避免把 NODE_* 全局态留在调用者的 shell 里。
ceph_storage_hosts() {
    local _h _line _role="${CEPH_NODE_ROLE:-master}"
    if [ -n "${CEPH_NODES:-}" ]; then
        for _h in ${CEPH_NODES//,/ }; do
            [ -n "${_h}" ] && echo "${_h}"
        done
        return 0
    fi
    for _line in "${NODES[@]:-}"; do
        [ -z "${_line}" ] && continue
        node_parse "${_line}"
        [ -n "${NODE_HOSTNAME}" ] || continue
        if [ "${_role}" = "all" ] || [ "${NODE_ROLE}" = "${_role}" ]; then
            echo "${NODE_HOSTNAME}"
        fi
    done
    return 0
}

# Ceph 存储节点数量(复用上面的选择规则; 供预检/提示用)
ceph_storage_host_count() {
    local n
    n="$(ceph_storage_hosts | grep -c . || true)"
    echo "${n:-0}"
}

# ---------------- 共用 MetalLB VIP 的约定(多服务共用一个 IP、不同端口) ----------------
# 默认关闭: 共用 VIP 需要**每个共用方**都带同一个 sharing key 注解, MetalLB 才肯把同一地址
# 分给多个 Service。约定集中在这里, 是因为它必须**三处完全一致**, 分散写必有一处漂移:
#   ① tools/k8s/sync-kubespray-config.sh —— 写进 registry 的 kubespray manifest(registry_service_annotations)
#   ② 将来若要再让某个 Service 与 registry 共用 VIP(如统一网关数据面), 复用同一组变量即可
# ⚠ 注解键名随 MetalLB 版本演进: v0.13.x 用 metallb.universe.tf/allow-shared-ip,
#   新版(v0.14+)改 metallb.io/allow-shared-ip。本集群实测 v0.13.9 → 用前者(可用变量覆盖)。
# ⚠ 共用的硬前提(缺一不可): 端口不重叠 / externalTrafficPolicy 一致(都 Cluster) /
#   两边都显式请求同一 IP(spec.loadBalancerIP)。
SHARED_VIP_ANNOTATION="${SHARED_VIP_ANNOTATION:-metallb.universe.tf/allow-shared-ip}"
SHARED_VIP_KEY="${SHARED_VIP_KEY:-cubestack-shared-vip}"

# ---------------- 规律 NodePort 分配(共享, 供各类 *-external/NodePort 服务复用) ----------------
# 让"连续规律端口"(mon a/b/c → 30100/30101/30102)与"自动分配"统一走一个入口,
# 其他模块回调本函数即可得到同样的端口序列(base 连续 + 上限校验)。
# 用法: nodeport_alloc <base> <count> <max> [off]
#   base  = 起始端口; 空/0 → 自动分配(输出空字符串, 由 kube-apiserver 随机)
#   count = 需要的端口个数(用于 base+0..base+count-1 的总上限校验)
#   max   = 硬上限(一般 = kube-apiserver --service-node-port-range 上限; 扩 range 时调大)
#   off   = (可选)本次要第几个偏移量(0 起); 输出 base+off; 省略 → 输出 base+count-1(即最后一个, 便于校验)
# ⚠ 校验: base..base+count-1 全部 ≤ max, 且 base >= 30000(K8s 默认下限), 超则 err + exit 1。
# 示例:
#   nodeport_alloc 30100 3 32767        # → 30102(校验 base..base+2 ≤ 32767 后打印最后一个)
#   nodeport_alloc 30100 3 32767 1      # → 30101
#   nodeport_alloc "" 3 32767 0         # → (空)
nodeport_alloc() {
    local base="$1" count="$2" max="$3" off="$4" np
    if [ -z "${base}" ]; then
        echo ""; return 0
    fi
    # 校验: base..base+count-1 全部 ≤ max, 且 base ≥ 30000(默认下限)
    if [ -n "${count}" ] && [ "${count}" -gt 0 ] 2>/dev/null \
       && [ "$(( base + count - 1 ))" -gt "${max}" ] 2>/dev/null; then
        err "规律 NodePort 超上限: base=${base} count=${count} 末端口=$(( base + count - 1 )) > max=${max}; 需先扩 apiserver service-node-port-range, 或调小 base/count"; exit 1
    fi
    [ "${base}" -lt 30000 ] 2>/dev/null \
        && err "规律 NodePort base=${base} < 30000(K8s 默认 service-node-port-range 下限); 请用 30000-40000 区间" && exit 1
    if [ -z "${off}" ]; then
        echo "$(( base + count - 1 ))"     # 省略 off: 打印区间末端口(base+count-1)
    else
        echo "$(( base + off ))"           # 指定 off: 打印 base+off
    fi
}

# ---------------- CRD Established 等待(共享, 防 apply 竞态) ----------------
# CRD 同批 apply 后 API server 需要时间注册 group/version(Established), 期间 apply
# 依赖该 CRD 的资源会报 "no matches for kind" / "server doesn't have a resource type"
# (discovery 未刷新)。所有"先 apply CRD manifest、后建 CR 资源"的模块统一用本函数
# 等待: ① CRD 对象 Established; ② discovery 已能看到该资源(plural 验证)。
# 前置: 已调用 init_remote_kubectl(需要 SSH/K)。
# 用法: wait_crd_established <crd名> <plural资源名> [重试次数=24(每次5s)] → 退出码 0=就绪
wait_crd_established() {
    local crd="$1" plural="$2" tries="${3:-24}" t ok=0
    for t in $(seq 1 "${tries}"); do
        # ① CRD Established(对象可见 + 条件就绪)
        if SSH "${K} wait --for condition=Established crd/${crd} --timeout=5s >/dev/null 2>&1"; then
            # ② discovery 可见该资源(kubectl 缓存/聚合层可能瞬时未刷新, 单独验证)
            if SSH "${K} get ${plural} -A >/dev/null 2>&1"; then
                ok=1; break
            fi
        fi
        [ "${t}" -lt "${tries}" ] && sleep 5
    done
    [ "${ok}" = "1" ] || { warn "  CRD ${crd} 在 $((tries * 5))s 内未就绪(Established/discovery); 用 kubectl get crd ${crd} 复查"; return 1; }
    return 0
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
# 所有连 API 的模块(gpu_operator/gpu_lws/ceph_*/...)统一复用本函数, 不各自复制。
# 用法: sync_kubeconfig → 退出码 0=宿主机可访问集群
sync_kubeconfig() {
    local tmp newctx
    tmp="$(mktemp)"
    local fm="${FIRST_MASTER:-$(first_master_ip)}"
    [ -n "${fm}" ] || { rm -f "${tmp}"; err "未找到 master 节点(无法下载 admin.conf)"; return 1; }
    # admin.conf 属 root(600), scp 会 Permission denied → 用 ssh + sudo cat 读取
    # BatchMode=yes: 密钥失败立即返回(不读 tty 密码提示; 交互终端下读 tty 会 SIGTTIN
    #   永久卡死, 见 ceph-detect-disks.sh 2026-09-09 注释)
    ssh -i "${SSH_KEY:-${HOME}/.ssh/cubestack_k8s}" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
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
    #   注意: K/_ctx/_cl 必须 local —— 各 addon 模块(gpu_operator/lws/ceph_*)顶层也有同名
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

# ---------------- 远端 kubectl 统一初始化(幂等) ----------------
# ★ 所有需要 SSH 到 master 执行 kubectl 的模块/脚本**必须**调用本函数获取:
#   FIRST_MASTER / SSH_KEY / SSH() 函数 / K(远端 kubectl 简写)。
#   禁止在模块内重复定义这四个 —— 历史上 metallb/ceph 等模块各自定义, 新模块少复制
#   一行就踩 set -u 的 "K: unbound variable"(05_k8s_registry 曾致部署成功后崩溃)。
# 用法: init_remote_kubectl || exit 1   (失败已 err 说明, 调用方直接退出即可)
# 注意: 本函数依赖 first_master_ip, 调用前须已 load_config(NODES)。
init_remote_kubectl() {
    [ "${_INIT_REMOTE_KUBECTL:-0}" = "1" ] && return 0   # 幂等: 同一进程只初始化一次
    FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点(cluster.conf NODES 无 role=master)"; return 1; }
    SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
    SSH() { ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
               "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "$@"; }
    # 字符串式(伪代码/单行命令场景, 如 addon_stub 步骤数组): ssh ... ${SSH_USER:-ubuntu}@${FIRST_MASTER}
    SSH_CMD="ssh -i ${SSH_KEY} -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 ${SSH_USER:-ubuntu}@${FIRST_MASTER}"
    K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"
    _INIT_REMOTE_KUBECTL=1
    return 0
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