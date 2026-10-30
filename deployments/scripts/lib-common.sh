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

# 高级/默认值层配置(2026-10-15 拆分, 唯一配置源的**默认值半边**):
#   cluster.conf         = 必改项 + 组件启停开关 + 高频变量(用户日常编辑; gitignored)
#   cluster.defaults.conf = 高级/自定义变量(随仓库分发; 全部 ${VAR:-default} 自默认写法)
# 加载顺序(**cluster.conf 先, defaults 后**)⇒ 优先级: 环境变量 > cluster.conf > cluster.defaults.conf。
CLUSTER_DEFAULTS_CONF="${CLUSTER_DEFAULTS_CONF:-${REPO_ROOT}/deployments/config/cluster.defaults.conf}"
export CLUSTER_DEFAULTS_CONF

# ---------------- 配置漂移门禁工具(2026-10-26) ----------------
# k8s_deploy 在启动时一次性 load_config; 若用户在 30s 倒计时/长时间 kubespray 运行期间
# 修改 cluster.conf, 后续 addon 模块会重新 load_config 看到新值, 而 addons.yml 仍是旧值
# (实机: nodeport→metallb, addons metallb_enabled=false → metallb 模块失败).
# 这两个 helper 供 k8s_deploy/metallb 门禁复用; 只读, 不修改配置.
config_fingerprint() {
    local conf="${CLUSTER_CONF:-${REPO_ROOT}/deployments/config/cluster.conf}"
    [ -f "${conf}" ] || { printf 'missing\n'; return 0; }
    # 只对"生效行"取指纹: 注释/空行变化不算配置漂移, 避免无谓中止.
    command grep -vE '^[[:space:]]*(#|$)' "${conf}" 2>/dev/null \
        | sha256sum | awk '{print $1}' || true
}
addons_metallb_enabled() {
    local yml="${1:-${KUBESPRAY_INV_DIR:-${REPO_ROOT}/deployments/kubespray/inventory/${CLUSTER_NAME}}/group_vars/k8s_cluster/addons.yml}"
    [ -f "${yml}" ] || { printf 'missing\n'; return 0; }
    awk -F':[[:space:]]*' '
        /^[[:space:]]*metallb_enabled:/ {
            v=$2; gsub(/["[:space:]]/, "", v); print v; found=1; exit
        }
        END { if (!found) print "missing" }
    ' "${yml}"
}

# ---------------- 集群名(固定默认, 单集群) ----------------
# 默认集群名 cubestack-cluster, 用于 inventory/offline-files 目录与日志命名; 环境变量可覆盖
CLUSTER_NAME="${CLUSTER_NAME:-cubestack-cluster}"
export CLUSTER_NAME

# ---------------- 宿主机物理 IP 自动检测 ----------------
# 不 hardcode: 自动检测宿主机物理网卡 IP(排除虚拟网桥 docker0/privbr0/virbr0 等)
# ★ 方法 2/3 的管道必须带 `|| true`: 本仓库脚本普遍 `set -euo pipefail`, 而"所有 IP 都被
#   过滤掉"时 grep 退出码非 0 → `ip="$(...)"` 这个**赋值**也非 0 → set -e 直接把调用方
#   (整轮部署)带走。语义上这里只该表示"这个方法没找到", 交给下一个方法 / 兜底 127.0.0.1。
detect_host_ip() {
    local ip=""
    # 方法1: 默认路由出口源 IP(最可靠)
    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    [ -n "${ip}" ] && echo "${ip}" && return 0
    # 方法2: hostname -I 过滤虚拟网桥/保留地址
    ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^(10\.244\.|10\.245\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.122\.|127\.|169\.254\.)' | head -1 || true)"
    [ -n "${ip}" ] && echo "${ip}" && return 0
    # 方法3: 枚举物理网卡 IP
    ip="$(ip -4 addr show 2>/dev/null | grep -oP 'inet \K[0-9.]+' | grep -vE '^(10\.244\.|10\.245\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.122\.|127\.|169\.254\.)' | head -1 || true)"
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
# ★ 2026-10-12: .tar / .tar.gz 均可 —— python tarfile "r" 模式自动识别压缩
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

# ---------------- 优雅覆盖: 安装登记(写集群内 ConfigMap) ----------------
# 设计: docs/graceful-overwrite/design.md(方案 A)。--fresh 等覆盖场景由 cluster-teardown.sh
# 读这份登记 → 按**首装序**反序调用各模块卸载段(模块头部 `# UNINSTALL: 1`)。
# 写失败**绝不阻断部署**(warn 即可; 覆盖时自会走探测降级路径)。
# 用法: record_installed_component <key>   (模块在安装成功点调用; 需已 init_remote_kubectl)
RECORD_CM_NS="kube-system"
RECORD_CM_NAME="cubestack-install-record"

# 纯函数: stdin=当前 record JSON(可空/可坏) → stdout=合并后的新 record JSON
#   · 新组件: seq = 现存 max+1(首装序 —— 反序卸载的排序键);
#   · 已存在: seq 保留(REPEAT:1 模块重跑不改变首装序), 只更新 lastSeenAt/status。
_record_merge_json() {
    local key="$1" status="${2:-done}"
    KEY="${key}" STATUS="${status}" CLUSTER_NAME="${CLUSTER_NAME:-unknown}" python3 -c '
import json, os, sys
from datetime import datetime, timezone
key = os.environ["KEY"]
try:
    rec = json.load(sys.stdin)
    if not isinstance(rec.get("components"), list):
        rec = {"schema": 1, "components": []}
except Exception:
    rec = {"schema": 1, "components": []}
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
hit = None
for c in rec["components"]:
    if isinstance(c, dict) and c.get("key") == key:
        hit = c; break
if hit is None:
    seqs = [c.get("seq", 0) for c in rec["components"] if isinstance(c, dict)]
    hit = {"key": key, "seq": (max(seqs) if seqs else 0) + 1, "firstInstalledAt": now}
    rec["components"].append(hit)
hit["lastSeenAt"] = now
hit["status"] = os.environ["STATUS"]
rec["schema"] = rec.get("schema", 1)
rec.setdefault("cluster", os.environ.get("CLUSTER_NAME", "unknown"))
print(json.dumps(rec, ensure_ascii=False))
'
}

# record JSON → 完整 ConfigMap JSON(apply 用)
_record_cm_json() {
    CM_NAME="${RECORD_CM_NAME}" CM_NS="${RECORD_CM_NS}" python3 -c '
import json, os, sys
rec = json.load(sys.stdin)
cm = {"apiVersion": "v1", "kind": "ConfigMap",
      "metadata": {"name": os.environ["CM_NAME"], "namespace": os.environ["CM_NS"],
                   "labels": {"app.kubernetes.io/managed-by": "cubestack-installer"}},
      "data": {"record.json": json.dumps(rec, ensure_ascii=False)}}
print(json.dumps(cm, ensure_ascii=False))
'
}

record_installed_component() {   # <key>
    local key="$1" cur merged
    [ -n "${key}" ] || return 0
    if [ "${_INIT_REMOTE_KUBECTL:-0}" != "1" ]; then
        warn "登记跳过(远端 kubectl 未初始化): ${key}"
        return 0
    fi
    # 读现有登记(CM 不存在/读失败 → 空登记起步)
    cur="$( (SSH "${K} -n ${RECORD_CM_NS} get cm ${RECORD_CM_NAME} -o json 2>/dev/null") || true)"
    if [ -n "${cur}" ]; then
        cur="$(printf '%s' "${cur}" | python3 -c 'import json,sys
try: print(json.loads(sys.stdin.read()).get("data",{}).get("record.json") or "{}")
except Exception: print("{}")')"
    fi
    merged="$(printf '%s' "${cur:-{\}}" | _record_merge_json "${key}" done)" \
        || { warn "登记合并失败: ${key}(不影响部署)"; return 0; }
    printf '%s' "${merged}" | _record_cm_json | SSH "${K} apply -f -" >/dev/null 2>&1 \
        || warn "登记写入失败: ${key}(不影响部署; 覆盖时将走探测降级路径)"
    return 0
}

# ---------------- 输出函数(同时写入日志文件) ----------------
# 日志文件路径: 设置 LOG_FILE 后, 所有输出同时写入该文件
# 用法: sudo env LOG_FILE=/tmp/deploy.log ./deploy-cluster.sh ...
#   (变量经 env 传给 root: sudo 默认 env_reset 会清掉 export/前置赋值)
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
# 所有用 skopeo 的模块(tar 镜像推送: gpu_operator/ceph/... )source 本库后即自动就绪。
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
# gpu_operator / metax-load 曾各自复制同一份 _push_skopeo/_reg_has_tag;
# 集中到本库供新代码复用, 已有 metax/gpu 维持原状避免回归。
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
# 额外参数原样透传(如 --image-parallel-copies / --dest-precompute-digests)。
# 错误文件按 **BASHPID** 隔离(并行安全): 子 shell 的 $$ 仍是父 PID, 用 $$ 会让并行 worker
# 互相覆盖错误文件(大镜像并行化后实测必要)。
# 用法: push_image_skopeo <src> <dst> [extra skopeo copy args...]
push_image_skopeo() {
    local src="$1" dst="$2"; shift 2
    local -a extra=("$@")
    local n=1 errf="/tmp/skopeo-err-$$-${BASHPID:-$$}" err
    for n in 1 2 3; do
        if skopeo copy --quiet --src-tls-verify=false --dest-tls-verify=false \
            --dest-no-creds ${extra[@]+"${extra[@]}"} "${src}" "${dst}" 2>"${errf}"; then
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

# 大镜像 push 额外参数(36_dev_lab / 37_model_images 使用; 其他模块保持原行为):
#   IMAGE_PUSH_PARALLEL_LAYERS    单镜像内并发层数(1=串行; 默认 4)
#   IMAGE_PUSH_PRECOMPUTE_DIGESTS 跳过 registry 已有层(默认 true)
#   IMAGE_PUSH_RETRY_TIMES        skopeo 内部重试次数(默认 5; 0=不传)
# 结果写入全局数组 IMAGE_PUSH_ARGS, 由调用方透传给 push_image_skopeo。
# 注意: skopeo 1.16.1 的 --dest-compress-level/--dest-compress-format 在 docker:// 推送中
#   不生效(实测目标仍为默认 gzip), 因此这里不暴露压缩参数; 加速靠层/镜像并行 + precompute。
# 用法: image_push_args_init; push_image_skopeo src dst "${IMAGE_PUSH_ARGS[@]}"
image_push_args_init() {
    IMAGE_PUSH_ARGS=()
    local n="${IMAGE_PUSH_PARALLEL_LAYERS:-4}" r="${IMAGE_PUSH_RETRY_TIMES:-5}"
    case "${n}" in ''|*[!0-9]*) n=1 ;; *) n=$((10#${n})) ;; esac
    [ "${n}" -gt 1 ] 2>/dev/null && IMAGE_PUSH_ARGS+=(--image-parallel-copies "${n}")
    case "${IMAGE_PUSH_PRECOMPUTE_DIGESTS:-true}" in
        true|1|yes|on) IMAGE_PUSH_ARGS+=(--dest-precompute-digests) ;;
    esac
    case "${r}" in ''|*[!0-9]*) r=0 ;; *) r=$((10#${r})) ;; esac
    [ "${r}" -gt 0 ] 2>/dev/null && IMAGE_PUSH_ARGS+=(--retry-times "${r}")
    return 0
}

# 有界并行: 对每个参数启动一个后台函数(在子 shell 执行), 同时最多 <max> 个。
# 调用方负责汇总结果(父 shell 变量不会被 worker 回写; worker 应写结果文件)。
# 用途: 大镜像并行推送(36/37)等。
# 用法: parallel_run <max> <func> <arg>...
parallel_run() {
    local max="$1" func="$2"; shift 2
    case "${max}" in ''|*[!0-9]*|0) max=1 ;; *) max=$((10#${max})) ;; esac
    local task
    for task in "$@"; do
        while [ "$(jobs -rp | wc -l)" -ge "${max}" ]; do sleep 0.5; done
        "${func}" "${task}" &
    done
    wait || true
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
# 镜像 digest(规范化比对用): 多架构 index → 取 amd64/linux 条目 digest; 单架构清单 → 清单字节 sha256。
# ⚠ skopeo **不支持 --override-arch**(CLI 镜像 1.16.1 实测): index 上 {{.Digest}} 是 index 自身摘要,
#   与"推过去的单架构镜像"不可比 —— 故自解析 --raw。取不到输出空(调用方保守: 不相等即走推送)。
# 用法: d="$(image_digest_raw docker://ref)"   或   d="$(image_digest_raw docker-archive:/path.tar)"
image_digest_raw() {   # <docker://ref | docker-archive:path>
    local ref="$1" raw=""
    raw="$(skopeo inspect --raw --tls-verify=false "${ref}" 2>/dev/null || true)"
    [ -n "${raw}" ] || return 0
    printf '%s' "${raw}" | python3 -c '
import hashlib, json, sys
raw = sys.stdin.buffer.read()
try:
    d = json.loads(raw)
except Exception:
    sys.exit(0)
ms = d.get("manifests")
if isinstance(ms, list):                 # 多架构 index → amd64/linux 条目
    for m in ms:
        p = m.get("platform") or {}
        if p.get("architecture") == "amd64" and p.get("os") == "linux":
            print(m.get("digest", "")); break
else:                                     # 单架构清单 → 字节 sha256 = 它自己的 digest
    print("sha256:" + hashlib.sha256(raw).hexdigest())
' 2>/dev/null || true
}

# 镜像内容身份(config digest): 比 manifest digest 更适合**幂等判断** ——
#   docker-archive → registry 的 push 会重新压缩层(实测 skopeo 1.16.1: 源层 81MB→31.8MB),
#   manifest/layer digest 会变; 但 config blob 的 digest 不变(源/目标一致)。
#   多架构 index 无法在此单层取 config digest → 输出空, 调用方回退 manifest digest/直接推送。
# 用法: c="$(image_config_digest_raw docker-archive:/path.tar)"  或  docker://ref
image_config_digest_raw() {   # <docker://ref | docker-archive:path>
    local ref="$1" raw=""
    raw="$(skopeo inspect --raw --tls-verify=false "${ref}" 2>/dev/null || true)"
    [ -n "${raw}" ] || return 0
    printf '%s' "${raw}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d.get("manifests"), list):
    sys.exit(0)          # 多架构 index: 调用方回退
print((d.get("config") or {}).get("digest", ""))
' 2>/dev/null || true
}

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
        # ★ 2026-10-12: .tar.gz 支持(大件就地 gzip 省盘)—— **文件名匹配, 不做内容检查**:
        #   · gzip 不可反向寻址, 而 docker-archive 的 manifest.json 在**归档末尾**
        #     ⇒ 任何内容检查 = 整卷解压(11G 级 ~90s/次, 逐镜像调用不可承受; 实测);
        #   · tar 文件名是权威(上游 ref 的 /,: → _; 同 25_cubestack_operator 的实践),
        #     内容校验由生产侧(harbor-save)与 plain .tar 路径(可随机寻址, 毫秒级)承担。
        #   文件名形如 <域>_<路径(段内 _)>_<tag>.tar.gz —— 归一化 suffix 后做尾部匹配。
        _ns="$(printf '%s' "${suffix}" | tr '/:' '__')"
        for t in "${d}"/*.tar.gz; do
            [ -f "${t}" ] || continue
            case "$(basename "${t}")" in
                *"_${_ns}.tar.gz") echo "${t}"; return 0 ;;
            esac
        done
    done
    return 1
}

# ---------------- Helm chart 离线副本助手(全仓库唯一实现) ----------------
# 规则(见 docs/scripts-development-spec.md §2.4): **每个 helm chart 都必须在
# deployments/cubestack-addon/<组件>/ 下有一份随 git 分发的离线副本**(.tgz 或解包源码目录),
# 且**安装一律用这份本地副本** —— 线上拉到的东西不直接装。缺了它, 私服/上游一抖动就装不上
# (曾有模块就是这样: 回退代码写好了, 却压根没有可回退的文件)。
# 窄例外: cubestack-operator 的 chart 随离线包分发(offline-files/cubestack-operator/charts/*.tgz),
#   tgz/digest 不入 git, 由内网同步机上传播; 本助手通过传入路径自然支持, 不另开分支。
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
    local dgfile="${tgz}.digest" tmpd="" pulled="" rdig="" ldig="" out="" args=() _coll=""

    case "${mode}" in
        online|offline) ;;
        *) err "helm_chart_ensure: 模式仅支持 online|offline(当前=${mode})"; return 1 ;;
    esac

    if [ "${mode}" = "online" ]; then
        # 只在真的要落盘时建目录: offline 模式下拼错的显式路径不应凭空多出一个空目录。
        mkdir -p "$(dirname "${tgz}")"
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
                    case "${tgz}" in
                        */deployments/offline-files/*)
                            warn "    ⚠ 已更新离线包本地副本(该 tgz 不入 git); 请在内网同步机执行" >&2
                            warn "      cubestack-platform-sync.sh --collection cubestack-operator --no-pull-state" >&2
                            warn "      (或 sync-to-minio.sh)上传 MinIO, 否则其他部署机拿不到" >&2 ;;
                        *)
                            warn "    ⚠ 该文件是仓库内的 vendored 副本, 请 git add/commit 固化; 不提交则下次部署又回到旧版本" >&2 ;;
                    esac
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
        case "${tgz}" in
            */deployments/offline-files/*)
                # chart 在 <collection>/charts/ 下; --sub 需要的是 collection 名, 不是 charts
                _coll="$(basename "$(dirname "$(dirname "${tgz}")")")"
                err "    获取(离线包): ./deployments/scripts/tools/offline/fetch-offline-from-minio.sh --sub ${_coll}" ;;
            */offline-files/*)
                err "    获取(发布版本): ./deployments/scripts/tools/offline/fetch-offline-from-minio.sh --release ${CUBESTACK_RELEASE:-<版本>} --dest <本地桶根>" ;;
        esac
        err "    获取(在线/手工): helm pull ${ref}${repo:+ --repo ${repo}} --version ${version} -d $(dirname "${tgz}")"
        err "          并把 helm 输出的 Digest: 写入 $(basename "${tgz}").digest(不要用 sha256sum); tgz 不入 git"
        return 1
    fi
    return 0
}

# ---------------- operator 镜像 tag 决策(helm 用) ----------------
# 原则(2026-10-22 用户口径): 默认**完全跟随 chart / operator 自带版本**;
#   installer 只保留一个显式逃生口, 且**只覆盖 cubestack-operator 自身的镜像 tag**,
#   绝不覆盖 operator 内 catalog 定义的其他组件(平台 operator/服务)版本。
#   - 未设 CUBESTACK_OPERATOR_IMAGE_TAG_OVERRIDE → 输出空 → helm 用 chart 自带
#     (Chart.yaml appVersion / values.image.tag);
#   - 设了 override → 只传 --set image.tag=<tag> 给 operator chart。
# CUBESTACK_OPERATOR_IMAGE_TAG 仅用于镜像清单/发布树登记, 不参与 helm 覆盖。
operator_image_tag_for_helm() {
    # ⚠ 必须恒返回 0: 调用方是 `x="$(operator_image_tag_for_helm ...)"` + set -e,
    #   空 override 时若返回 1 会让整个模块静默退出(2026-10-22 实机)。
    if [ -n "${1:-}" ]; then
        printf '%s\n' "$1"
    fi
    return 0
}

# ---------------- CubeStack operator chart 定位(release 版本无关) ----------------
# 在目录中定位 operator chart, 不要求 installer 预先写死版本:
#   ① <name>-<desired>.tgz 存在 → 用它(desired 可空)
#   ② release 模式(<release> 非空): 优先 <name>-<release>.tgz; 否则扫描 <name>-*.tgz,
#      读取 Chart.yaml version, 匹配 <release> 或 <desired>; 唯一命中即用
#   ③ 目录中只有一个 <name>-*.tgz → 用它(版本以 chart 自身为准)
#   ④ 否则返回 1(调用方列出候选并报错)
# 输出(stdout): "<tgz路径>\t<chart版本>"
# 说明: 只读 tar, 不联网; 供 25_cubestack_operator.sh / release-publish.sh 共用。
operator_chart_version() {
    local _tgz="$1" _y
    _y="$(tar -tzf "${_tgz}" 2>/dev/null | command grep -E '/Chart.yaml$' | head -1 || true)"
    [ -n "${_y}" ] || return 0
    tar -xOf "${_tgz}" "${_y}" 2>/dev/null | awk '/^[[:space:]]*version:[[:space:]]*/{print $2; exit}'
}

resolve_operator_chart_tgz() {   # <dir> <chart-name> [desired-version] [release-version]
    local _dir="$1" _name="$2" _desired="${3:-}" _release="${4:-}"
    local _files=() _f _v _hit="" _ver="" _ng=0
    [ -d "${_dir}" ] || return 1
    shopt -q nullglob && _ng=1
    shopt -s nullglob
    _files=("${_dir}/${_name}-"*.tgz)
    [ "${_ng}" = "1" ] || shopt -u nullglob
    [ "${#_files[@]}" -gt 0 ] || return 1

    # release 模式优先按发布版本定位(即使默认的 desired=1.0.0-latest 仍在, 也不能抢跑)
    if [ -n "${_release}" ] && [ -f "${_dir}/${_name}-${_release}.tgz" ]; then
        _hit="${_dir}/${_name}-${_release}.tgz"
    elif [ -n "${_desired}" ] && [ -f "${_dir}/${_name}-${_desired}.tgz" ]; then
        _hit="${_dir}/${_name}-${_desired}.tgz"
    elif [ -n "${_release}" ]; then
        for _f in "${_files[@]}"; do
            _v="$(operator_chart_version "${_f}")"
            if [ "${_v}" = "${_release}" ] || { [ -n "${_desired}" ] && [ "${_v}" = "${_desired}" ]; }; then
                _hit="${_f}"; break
            fi
        done
    fi
    if [ -z "${_hit}" ] && [ "${#_files[@]}" -eq 1 ]; then
        _hit="${_files[0]}"
    fi
    [ -n "${_hit}" ] || return 1

    _ver="$(operator_chart_version "${_hit}")"
    if [ -z "${_ver}" ]; then
        _ver="$(basename "${_hit}")"
        _ver="${_ver#${_name}-}"
        _ver="${_ver%.tgz}"
    fi
    printf '%s\t%s\n' "${_hit}" "${_ver}"
}

# release 树的 charts/ 只允许当前版本 operator chart: 增量刷新/--resume staging 会
# 留下旧版本 tgz, 不清掉会被一并上传并写进 SHA256SUMS. extras 每行输出一个多余文件名.
operator_chart_dir_extras() {   # <charts-dir> <chart-name> <keep-tgz-basename>
    local _dir="$1" _name="$2" _keep="$3" _f _b _ng=0
    [ -d "${_dir}" ] || return 0
    shopt -q nullglob && _ng=1
    shopt -s nullglob
    local -a _files=("${_dir}/${_name}-"*.tgz "${_dir}/${_name}-"*.tgz.digest)
    [ "${_ng}" = "1" ] || shopt -u nullglob
    for _f in "${_files[@]}"; do
        _b="${_f##*/}"
        case "${_b}" in "${_keep}"|"${_keep}.digest") continue ;; esac
        printf '%s\n' "${_b}"
    done
}

prune_operator_chart_dir() {   # <charts-dir> <chart-name> <keep-tgz-basename>; 输出删除个数
    local _dir="$1" _b _n=0
    # 只清理 staging 内真实目录, 避免符号链接把删除带到别处.
    if [ -L "${_dir}" ]; then
        printf '拒绝清理符号链接 charts 目录: %s\n' "${_dir}" >&2
        return 1
    fi
    while IFS= read -r _b; do
        [ -n "${_b}" ] || continue
        rm -f "${_dir}/${_b}" || { printf '删除旧 chart 失败: %s\n' "${_dir}/${_b}" >&2; return 1; }
        _n=$((_n + 1))
    done < <(operator_chart_dir_extras "$@")
    printf '%s' "${_n}"
}

# ---------------- 共享 nginx 校验镜像助手(verify 模块测试后端共用) ----------------
# verify_metallb / verify_ceph 等的测试后端
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
    # 离线 tar 搜索目录: release 模式**只用发布树** —— 绝不回落到 dev/latest offline-files,
    # 否则 2.0 验证可能拿到 latest 的 nginx(违反"release 与 latest 互不影响")。
    local -a _nginx_dirs=()
    if [ -n "${CUBESTACK_RELEASE:-}" ]; then
        _nginx_dirs=("${OFFLINE_FILES_ROOT}/nginx" "${LOCAL_REPO_DIR}/images")
    else
        _nginx_dirs=("${REPO_ROOT}/deployments/offline-files/nginx" \
                     "${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}/nginx" \
                     "${LOCAL_REPO_DIR}/images")
    fi
    # ① 本地 docker daemon(仅 dev 模式快路径; release 模式必须走发布树, 避免掩盖缺失的离线件)
    if [ -z "${CUBESTACK_RELEASE:-}" ]; then
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
    fi
    # ② 离线 tar: suffix 用 "nginx:latest"(无前导 /——find_offline_tar 的前导 / 约定只匹配带
    # registry 前缀的全格式, 库镜像短格式如 "nginx:latest" 会漏; glob nginx*.tar 已限定候选)。
    # find_offline_tar 是 endswith 语义, 版本化 tag(nginx:1.31.4)不命中, 下方按内容兜底。
    _t="$(find_offline_tar "nginx:latest" "nginx*.tar" "${_nginx_dirs[@]}")" || _t=""
    if [ -z "${_t}" ]; then
        # 兜底: 版本化 tag(如 nginx:1.31.4)按内容匹配(含 "nginx:" 即接受)
        for _d in "${_nginx_dirs[@]}"; do
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
    err "     release 模式请放到 ${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}/nginx/nginx.tar;"
    err "  ② 部署机本地 docker 有 nginx:latest(sudo docker pull nginx:latest);"
    err "  ③ 允许在线拉取: VERIFY_IMAGE_ONLINE=true 重跑"
    return 1
}

# 仓库当前 kubespray 树版本(带 v 前缀; 取不到输出空) —— 供 KUBESPRAY_VERSION 默认值机械派生
# (不写死版本号: 换树后自动跟随; 见 docs/kubespray-versioning/design.md §4.1)
kubespray_tree_version() {
    local galaxy="${REPO_ROOT}/deployments/kubespray/kubespray/galaxy.yml"
    [ -f "${galaxy}" ] || return 0
    awk '/^version:/{print "v"$2; exit}' "${galaxy}"
}

# 默认部署版本 = **最新版本** = max(仓库树版本, **有入库档案**的版本目录)
#   · 只认"有入库档案"的版本: 档案是版本面变量的接管凭证; 没有档案 ⇒ 钉子仍按 cluster.conf,
#     拿别的版本的资产配本版本的钉子 = 静默错配(设计 §3.2 要防的正是这个)
#     ⇒ 本地临时版本(有 LOCAL_ONLY / 无档案)不进默认, 必须显式 --profile / KUBESPRAY_VERSION
#   · 用户口径(2026-09-30): 不指定 --profile 时默认部署最新版本; 原部署模式(默认全量、参数语义)不变
kubespray_latest_version() {
    local prof_dir="${REPO_ROOT}/deployments/config/profiles"
    {
        kubespray_tree_version
        if [ -d "${prof_dir}" ]; then
            local f
            for f in "${prof_dir}"/*.profile; do
                [ -f "${f}" ] || continue
                sed -nE 's/^[[:space:]]*KUBESPRAY_VERSION=([^[:space:]#]+).*/\1/p' "${f}" | head -1
            done
        fi
    } | sed '/^$/d' | sort -V | tail -1
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
    # 高级/默认值层(2026-10-15): **必须在 cluster.conf 之后**(见文件头 CLUSTER_DEFAULTS_CONF 注释
    # 的优先级: 环境变量 > cluster.conf > defaults)。全文件 ${VAR:-default} 自默认写法,
    # 只补未定义变量 ⇒ 用户在 cluster.conf 写的同名覆盖项天然生效。
    if [ -f "${CLUSTER_DEFAULTS_CONF}" ]; then
        # shellcheck disable=SC1090
        source "${CLUSTER_DEFAULTS_CONF}"
    else
        warn "未找到高级默认值层 ${CLUSTER_DEFAULTS_CONF}(部分高级变量将回退内置兜底; 该文件应随仓库分发)"
    fi
    # 节点 SSH 用户(2026-10-15): 全局安装用户单一旋钮(root|ubuntu, 默认 ubuntu)——
    # 决定免密注入 / 即席 SSH / kubespray ansible_user 的口径。
    #   · NODES 每行第4字段写 "-"(或留空) → 跟随本值(node_parse 归一);
    #   · 显式写用户名 → 该节点覆盖(进阶场景; 与全局不一致时 deploy-cluster.sh 会点名告警)。
    # ⚠ sudo 默认清掉未列入 env_keep 的环境变量: 想用环境变量传参要写 `sudo SSH_USER=root ./deploy-cluster.sh`
    #   (赋值放在 sudo **之后**)或直接写进 cluster.conf(推荐)。
    SSH_USER="${SSH_USER:-ubuntu}"
    export SSH_USER
    # ---- release 模式(2026-10-21): 版本目录 + release.env ----
    # 本地桶根与 MinIO 同构: <root>/<版本>/{offline-files,cubestack-installer-cli-v<版本>.tar}
    # release.env 提供版本变量, 必须在 kubespray 版本档案块之前加载(才能接管 KUBESPRAY_VERSION)。
    OFFLINE_FILES_ROOT="${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}"
    # 自动检测(2026-10-26): flat offline 根存在 release.env 时, 直接以它为准进入 release
    # 模式, 不需要 cluster.conf 再写 CUBESTACK_RELEASE / LAYOUT; 版本也取自 release.env。
    _auto_rel_env="${OFFLINE_FILES_ROOT}/release.env"
    if [ "${CUBESTACK_RELEASE_AUTO:-true}" = "true" ] \
       && [ -z "${CUBESTACK_RELEASE:-}" ] && [ -f "${_auto_rel_env}" ]; then
        _auto_ver="$(sed -nE 's/^RELEASE_VERSION=([^[:space:]#]+).*/\1/p' "${_auto_rel_env}" | head -1)"
        [ -n "${_auto_ver}" ] || { err "自动检测到 ${_auto_rel_env}, 但缺少 RELEASE_VERSION"; exit 1; }
        CUBESTACK_RELEASE="${_auto_ver}"
        [ -n "${CUBESTACK_RELEASE_LAYOUT:-}" ] || CUBESTACK_RELEASE_LAYOUT="flat"
        vlog "自动检测 release.env: ${_auto_rel_env} → release=${CUBESTACK_RELEASE} layout=${CUBESTACK_RELEASE_LAYOUT}"
    fi
    if [ -n "${CUBESTACK_RELEASE:-}" ]; then
        # 版本名参与路径(<root>/<版本>/offline-files)并 source 其中的 release.env:
        # 只允许字母数字开头 + 字母数字/点/下划线/连字符, 拒绝 ../、绝对路径、空白与
        # shell 元字符 —— 防止 --release / cluster.conf 的值把 source 引到发布根之外
        # (路径穿越 + 任意脚本执行; 2026-10-23 CodeRabbit)。
        if ! [[ "${CUBESTACK_RELEASE}" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
            err "CUBESTACK_RELEASE 格式非法: '${CUBESTACK_RELEASE}'(只允许字母数字开头, 后接字母数字/点/下划线/连字符)"
            exit 1
        fi
        # 未显式指定 layout: 有版本树(root 非空且存在)用 tree; 否则 flat offline 有 release.env
        # 用 flat; 都没有用 tree(保持旧报错路径, 提示取件)。
        if [ -z "${CUBESTACK_RELEASE_LAYOUT:-}" ]; then
            if [ -n "${CUBESTACK_RELEASE_ROOT:-}" ] \
               && [ -f "${CUBESTACK_RELEASE_ROOT}/${CUBESTACK_RELEASE}/offline-files/release.env" ]; then
                CUBESTACK_RELEASE_LAYOUT="tree"
            elif [ -f "${OFFLINE_FILES_ROOT}/release.env" ]; then
                CUBESTACK_RELEASE_LAYOUT="flat"
            else
                CUBESTACK_RELEASE_LAYOUT="tree"
            fi
        fi
        _layout="${CUBESTACK_RELEASE_LAYOUT}"
        CUBESTACK_RELEASE_ROOT="${CUBESTACK_RELEASE_ROOT:-${REPO_ROOT}/offline-releases}"
        case "${_layout}" in
            tree)
                _rel_root="${CUBESTACK_RELEASE_ROOT}/${CUBESTACK_RELEASE}/offline-files"
                if [ ! -f "${_rel_root}/release.env" ]; then
                    err "未找到发布版本 ${CUBESTACK_RELEASE}: ${_rel_root}/release.env"
                    err "  先取件: ./deployments/scripts/tools/offline/fetch-offline-from-minio.sh --release ${CUBESTACK_RELEASE} --dest ${CUBESTACK_RELEASE_ROOT}"
                    exit 1
                fi
                ;;
            flat)
                # flat: 资产平铺在 OFFLINE_FILES_ROOT; 优先用其中的 release.env(用户口径:
                # 部署以 release.env 为主), 没有时回退仓库内发布定义。
                if [ -f "${OFFLINE_FILES_ROOT}/release.env" ]; then
                    _rel_root="${OFFLINE_FILES_ROOT}"
                else
                    _rel_root="${REPO_ROOT}/deployments/releases/${CUBESTACK_RELEASE}"
                fi
                if [ ! -f "${_rel_root}/release.env" ]; then
                    err "未找到 release.env: ${OFFLINE_FILES_ROOT}/release.env 或 ${REPO_ROOT}/deployments/releases/${CUBESTACK_RELEASE}/release.env(flat 模式)"
                    exit 1
                fi
                CUBESTACK_RELEASE_ROOT=""
                ;;
            *)
                err "CUBESTACK_RELEASE_LAYOUT 仅支持 tree|flat(当前=${_layout})"
                exit 1
                ;;
        esac
        # shellcheck disable=SC1090
        source "${_rel_root}/release.env"
        if [ "${RELEASE_VERSION:-}" != "${CUBESTACK_RELEASE}" ]; then
            err "release.env 版本不符: RELEASE_VERSION=${RELEASE_VERSION:-<空>} CUBESTACK_RELEASE=${CUBESTACK_RELEASE}"
            exit 1
        fi
        if [ -z "${KUBESPRAY_VERSION:-}" ]; then
            err "release.env 缺少 KUBESPRAY_VERSION(${_rel_root}/release.env)"
            exit 1
        fi
        if [ "${_layout}" = "flat" ]; then
            OFFLINE_FILES_ROOT="${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}"
        else
            OFFLINE_FILES_ROOT="${_rel_root}"
        fi
        # 这些变量默认写死指向 dev offline-files; release 模式统一重定向到发布根。
        METAX_OFFLINE_DIR="${OFFLINE_FILES_ROOT}/metax-gpu"
        METAX_PKG_DIR="${METAX_OFFLINE_DIR}"
        CUBESTACK_OPERATOR_OFFLINE_DIR="${OFFLINE_FILES_ROOT}/cubestack-operator"
        MULTUS_SAVE_DIR="${OFFLINE_FILES_ROOT}/multus"
        NVIDIA_GPU_OPERATOR_OFFLINE_DIR="${OFFLINE_FILES_ROOT}/nvidia-gpu-operator"
        RDMA_SAVE_DIR="${OFFLINE_FILES_ROOT}/rdma"
        NETSHOOT_SAVE_DIR="${OFFLINE_FILES_ROOT}/netshoot"
        NETSHOOT_BASE_TAR="${OFFLINE_FILES_ROOT}/os/netshoot.tar"
        DEV_LAB_SAVE_DIR="${OFFLINE_FILES_ROOT}/dev-lab"
        MODEL_IMAGES_SAVE_DIR="${OFFLINE_FILES_ROOT}/model-collection"
        CEPH_IMAGE_DIR="${OFFLINE_FILES_ROOT}/kubespray/${KUBESPRAY_VERSION}/images"
        export CUBESTACK_RELEASE_LAYOUT CUBESTACK_RELEASE_ROOT METAX_OFFLINE_DIR METAX_PKG_DIR \
               CUBESTACK_OPERATOR_OFFLINE_DIR MULTUS_SAVE_DIR \
               NVIDIA_GPU_OPERATOR_OFFLINE_DIR RDMA_SAVE_DIR \
               NETSHOOT_SAVE_DIR NETSHOOT_BASE_TAR DEV_LAB_SAVE_DIR \
               MODEL_IMAGES_SAVE_DIR CEPH_IMAGE_DIR
        vlog "release 模式生效: ${CUBESTACK_RELEASE} layout=${_layout}(OFFLINE_FILES_ROOT=${OFFLINE_FILES_ROOT})"
        unset _rel_root _layout _auto_rel_env _auto_ver
    fi
    # 版本档案接管(2026-09-30): 选定 KUBESPRAY_PROFILE 后, 该版本的**版本面变量**以档案为准
    # (档案 > cluster.conf > cluster.defaults.conf; 见 docs/kubespray-versioning/design.md §3.2 —— 否则 --profile v2.28.0
    #  会静默变成"v2.28 的资产 + v1.35.8 的钉子")
    #   显式选择(明写了 KUBESPRAY_PROFILE, 或明写了 KUBESPRAY_VERSION)且档案缺失 → 硬失败:
    #     绝不静默退化成"别的版本的钉子"。err() 只打印不退出, 故这里显式 exit 1
    #     (133 处调用点全是裸 load_config, 顶层退出即停住整个脚本)
    #   隐式默认(版本靠树派生)→ 档案缺失只 warn: 换树/首次升级时不该把每个脚本都卡死
    #   none → 不用档案(全部按 cluster.conf, 等价历史行为)
    # 有效版本与档案名:
    #   ① 先捕获"显式性"(必须在下面填默认值**之前**): 明写了 KUBESPRAY_VERSION 或 KUBESPRAY_PROFILE
    #      ⇒ 档案缺失要**硬失败**(绝不静默退化成"别的版本的钉子")
    #   ② 有效版本: 显式 KUBESPRAY_VERSION > **最新版本**(用户口径 2026-09-30: 不指定 --profile 时
    #      默认部署最新版本; 默认仍是完整全量流程, 原部署模式不变)
    #   ③ 档案名: 显式 KUBESPRAY_PROFILE > 跟随有效版本; 该版本无档案时, 显式选才报错, 隐式默认只告警
    _prof_explicit=0
    [ -n "${KUBESPRAY_PROFILE:-}" ] && _prof_explicit=1
    [ -n "${KUBESPRAY_VERSION:-}" ] && _prof_explicit=1
    if [ -z "${KUBESPRAY_VERSION:-}" ]; then
        KUBESPRAY_VERSION="$(kubespray_latest_version)"
        vlog "未指定版本 → 采用最新版本: ${KUBESPRAY_VERSION}(可用 KUBESPRAY_VERSION/--profile 指定)"
    fi
    _prof_name="${KUBESPRAY_PROFILE:-${KUBESPRAY_VERSION}}"
    if [ -n "${_prof_name}" ] && [ "${_prof_name}" != "none" ]; then
        _prof_file="${REPO_ROOT}/deployments/config/profiles/${_prof_name}.profile"
        # 回退: 版本目录**自带的** VERSION.profile(设计 §3.2 的"自包含副本")——
        #   本地临时版本按 D4 **不入库档案**, 但也必须能显式部署(v2.28 本地验证路径);
        #   在库版本两份应当一致(check-modules ⑱ 逐键断言), 故回退不引入歧义。
        _prof_dir_copy="${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}/kubespray/${_prof_name}/VERSION.profile"
        if [ -f "${_prof_file}" ]; then
            # shellcheck disable=SC1090
            source "${_prof_file}"
            vlog "版本档案生效: ${_prof_file}"
        elif [ -f "${_prof_dir_copy}" ]; then
            # shellcheck disable=SC1090
            source "${_prof_dir_copy}"
            vlog "版本档案生效(版本目录自带副本): ${_prof_dir_copy}"
        elif [ "${_prof_explicit}" = "1" ]; then
            err "版本档案不存在: ${_prof_file}(也没有版本目录副本 ${_prof_dir_copy}; KUBESPRAY_PROFILE=${_prof_name}; 用 KUBESPRAY_PROFILE=none 可禁用档案)"
            exit 1
        else
            warn "未找到版本档案 ${_prof_file}(也没有版本目录副本), 按 cluster.conf 继续(当前版本 ${_prof_name})"
        fi
        unset _prof_file _prof_dir_copy
    fi
    KUBESPRAY_PROFILE="${_prof_name}"
    unset _prof_name _prof_explicit

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
    #                ⚠ "能通 NodePort 的节点 IP"语义 —— registry mirror 与 DNAT 判定依赖它。
    #                要写 API_DOMAIN 的域名解析时**别用它**, 用 api_entry_ip()(见该函数说明)。
    #   API_DOMAIN   API Server 域名(跨网段统一入口), 默认 k8s-api.cubestack.io
    #                (其解析地址 = api_entry_ip(): kube-vip 已绑 → VIP, 否则首个 master)
    API_IP="${API_IP:-${APISERVER_ADDRESS:-}}"
    API_DOMAIN="${API_DOMAIN:-${APISERVER_DOMAIN:-k8s-api.cubestack.io}}"
    export API_IP API_DOMAIN
    # 全局派生变量(续): 离线文件路径 —— 2026-09-30 起按**版本目录**组织
    # (设计: docs/kubespray-versioning/design.md §4; 目录名 = 上游 tag 全名, 决策 D8)
    #   OFFLINE_FILES_ROOT  offline-files **真根**(各组件目录的共同父目录)
    #   KUBESPRAY_VERSION   kubespray 版本开关(单一入口); 默认 = 仓库当前树版本(galaxy.yml 派生)
    #   OFFLINE_FILES_DIR   k8s **资产目录** = <root>/kubespray/<版本>(裸二进制 + images/ + packages/)
    #   LOCAL_REPO_DIR      = OFFLINE_FILES_DIR —— 交给 kubespray 当 local_release_dir,
    #                       ⚠ 必须恰好是"裸二进制 + images/ + packages/"的那一层(树内 dest 全按扁平名读)
    #   KUBESPRAY_BASE_DIR  运行根(交给 cubestack-offline.sh 当 BASE_DIR)
    #   ⚠ 显式设置的值一律保留(运维脚本/容器挂载按显式值走), 不回写
    OFFLINE_FILES_ROOT="${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}"
    if [ -z "${KUBESPRAY_VERSION:-}" ]; then
        KUBESPRAY_VERSION="$(kubespray_latest_version)"
    fi
    OFFLINE_FILES_DIR="${OFFLINE_FILES_DIR:-${OFFLINE_FILES_ROOT}/kubespray/${KUBESPRAY_VERSION}}"
    if [ -z "${LOCAL_REPO_DIR:-}" ]; then
        LOCAL_REPO_DIR="${OFFLINE_FILES_DIR}"
    fi
    if [ -z "${KUBESPRAY_BASE_DIR:-}" ]; then
        if [ "${KUBESPRAY_VERSION}" = "$(kubespray_tree_version)" ]; then
            KUBESPRAY_BASE_DIR="${REPO_ROOT}/deployments/kubespray"
        else
            KUBESPRAY_BASE_DIR="${REPO_ROOT}/deployments/kubespray/versions/${KUBESPRAY_VERSION}"
        fi
    fi
    export OFFLINE_FILES_ROOT KUBESPRAY_VERSION OFFLINE_FILES_DIR LOCAL_REPO_DIR KUBESPRAY_BASE_DIR
    # 全局派生变量(续): REGISTRY_IP 留空时从 METALLB_POOL 自动取池内首地址作为 LoadBalancer VIP
    # (cluster.conf 约定 "留空 = 自动派生", 与 sync-kubespray-config.sh 写入 addons.yml 的规则一致;
    #  centralized 于此, 让 deploy-registry.sh / setup-registry-expose.sh 等所有消费者拿到同一值)
    # 标记是否显式指定(供 deploy-registry.sh 冲突检测: 显式设置不再提示)
    export REGISTRY_IP_EXPLICIT="${REGISTRY_IP_EXPLICIT:-0}"
    # 服务暴露方式归一化: SERVICE_EXPOSE_MODE ∈ {metallb, nodeport}
    # 默认 **metallb**(生产); nodeport 仅作显式降级。
    # 大小写不敏感: 判断前先 tr 转小写, 任何大小写组合(nodeport/NodePort/nodePort/NODEPORT...)均接受
    # 下游 sync-addons-config / sync-kubespray-config / verify / 部署汇总统一按此分支。
    _EXPOSE_MODE="$(echo "${SERVICE_EXPOSE_MODE:-metallb}" | tr '[:upper:]' '[:lower:]')"
    case "${_EXPOSE_MODE}" in
        nodeport) SERVICE_EXPOSE_MODE="nodeport" ;;
        *)        SERVICE_EXPOSE_MODE="metallb" ;;
    esac
    unset _EXPOSE_MODE
    export SERVICE_EXPOSE_MODE
    # registry 暴露方式: **默认 nodeport, 与 SERVICE_EXPOSE_MODE 解耦**
    #   - 显式 REGISTRY_SERVICE_TYPE=loadbalancer|nodeport|clusterip 时尊重显式值
    #   - 即使全局是 metallb, registry 默认仍走 NodePort(直连首个 master, 不占 MetalLB VIP)
    if [ -z "${REGISTRY_SERVICE_TYPE:-}" ]; then
        REGISTRY_SERVICE_TYPE="nodeport"
        export REGISTRY_SERVICE_TYPE
        vlog "REGISTRY_SERVICE_TYPE 留空, 默认 nodeport(与 SERVICE_EXPOSE_MODE=${SERVICE_EXPOSE_MODE} 解耦)"
    fi
    # REGISTRY_IP: 与 registry Service 类型保持一致
    #   nodeport     → 首个 master IP(NodePort 入口)
    #   loadbalancer → METALLB_POOL 池内首地址(固定 VIP)
    if [ -z "${REGISTRY_IP:-}" ]; then
        if [ "${REGISTRY_SERVICE_TYPE}" = "nodeport" ]; then
            REGISTRY_IP="$(first_master_ip)" || REGISTRY_IP="$(first_pool_addr "${METALLB_POOL:-}")"
            vlog "REGISTRY_IP 留空, registry=nodeport → 首个 master IP ${REGISTRY_IP}"
        else
            REGISTRY_IP="$(first_pool_addr "${METALLB_POOL:-}")"
            vlog "REGISTRY_IP 留空, registry=${REGISTRY_SERVICE_TYPE} → METALLB_POOL 首地址 ${REGISTRY_IP}"
        fi
        export REGISTRY_IP
    else
        export REGISTRY_IP_EXPLICIT=1
    fi
    # registry 宿主侧直连端点(预检 curl / skopeo push 用), 与镜像名 DOMAIN:PORT 解耦:
    #   nodeport     → REGISTRY_IP:REGISTRY_NODEPORT
    #   loadbalancer → REGISTRY_IP:REGISTRY_PORT
    # 镜像名统一 registry.cubestack.io:5000(节点经 containerd hosts.toml 改写连接), 端口无需统一;
    # 显式设 REGISTRY_DIRECT 可覆盖(如经代理/别名推送)。
    # ⚠ nodeport 分支复用 REGISTRY_IP 而非直接 first_master_ip:
    #   create-vms.sh 等场景 load_config 时 NODES 可能已被清空 → first_master_ip 返回 1,
    #   在 set -euo pipefail 下命令替换失败会传导给赋值 → load_config 静默退出, 卡死 VM 创建。
    #   REGISTRY_IP 自带 first_master_ip || first_pool_addr 兜底(见上), 此处直接复用其值。
    if [ "${REGISTRY_SERVICE_TYPE}" = "nodeport" ]; then
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
# 详见 docs/kube-vip-api-ha.md。关键约束(任一违反都是确定性故障, 故为硬失败):
#   (原 ① HAPROXY_ENABLED/KEEPALIVED_ENABLED 互斥已随该方案整块移除, 2026-10-14)
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
# 用法: ip="$(node_ip_by_hostname node-1-147)"
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

# 收集全部 master 的 **IP**(空格分隔; 供逐台 SSH 探测复用)
#
# ⚠ 与 master_hosts 的分工(2026-09-28 实机事故, 别再混用):
#   · master_hosts 给的是**主机名** —— 只可用于"要名字"的场合(如 vip_nodename);
#   · **凡是要 SSH 的场合必须用本函数(IP)** —— 部署容器里通常没有节点名的 /etc/hosts 解析
#     (`getent hosts node-3-28` 实测失败), 拿主机名 SSH 会**静默连不上**, 而调用方常把
#     "连不上"当成"条件不成立": kube_vip_is_bound 曾因此恒判"VIP 未绑定" ⇒ api_entry_ip()
#     永远回落首个 master ⇒ 宿主机与全部节点的 k8s-api.cubestack.io 都指向单点 Master,
#     kube-vip 白装(实机: VIP 192.0.2.240 明明已绑在 node-3-28, 判定却说"未绑定")。
#   08/09 两个 kube-vip 模块早就是这么做的(node_ip_by_hostname 转 IP 再 SSH), 这里补齐。
master_ips() {
    local line
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        if [ "${NODE_ROLE}" = "master" ] && [ -n "${NODE_IP}" ]; then
            printf '%s ' "${NODE_IP}"
        fi
    done
    return 0
}

# CubeStack operator HA 拓扑(2026-10-27 用户口径):
#   master >= 3 → "<n> 2 true"  (operator replicas=2; CubeStackCluster.spec.global.ha.enabled=true)
#   master < 3  → "<n> 1 false" (单 master/两 master 一律 non-HA; replicas=1)
# 输出 "<master_count> <replicas> <ha_enabled>"。
# ⚠ node_parse/master_ips 会写 NODE_* 全局量 —— 本函数内部在命令替换子 shell 中统计, 不污染调用方。
cubestack_operator_ha_profile() {
    local _n
    _n="$(master_ips | wc -w | tr -d '[:space:]')"
    case "${_n}" in ''|*[!0-9]*) _n=0 ;; esac
    if [ "${_n}" -ge 3 ]; then
        printf '%s 2 true\n' "${_n}"
    else
        printf '%s 1 false\n' "${_n}"
    fi
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
    # 入口来源互斥(external ↔ kube-vip / HAProxy+KA / 非法 IPv4)先行 —— 放在早退**之前**,
    # 否则 KUBE_VIP_ENABLED≠true 时直接 return 0, external 的几项就永远验不到。
    api_entry_validate_config || return 1

    # ⚠ 2026-09-28 rebase 取舍: 这里的兜底默认取 main 的 `false`(9832975 已把 kube-vip 默认
    #   翻成关, 全仓 11 处一起翻); api-ha 分支那版 `:-true` 是翻之前的写法, 不能照搬。
    [ "${KUBE_VIP_ENABLED:-false}" = "true" ] || return 0

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

    # ⑤ 本地代理: 旧开关 KUBE_VIP_LOCAL_PROXY 已并入 API_LOCAL_LB_ENABLED, 本方案起**真正生效**
    #    (实现路径 = 摘掉 all.yml 的 loadbalancer_apiserver 块, 让上游按 localhost 分支分派,
    #     见 docs/api-ha/04-decision.md §2 与 sync-kubespray-config.sh 的模式分派)
    if bool_is_true "${KUBE_VIP_LOCAL_PROXY:-false}" && [ -n "${API_LOCAL_LB_ENABLED:-}" ] \
       && ! bool_is_true "${API_LOCAL_LB_ENABLED}"; then
        err "KUBE_VIP_LOCAL_PROXY=true 但 API_LOCAL_LB_ENABLED=false —— 两个开关冲突, 请只留一个"
        return 1
    fi
    return 0
}

# 读取 all.yml 里当前已生效的 API 入口地址(loadbalancer_apiserver.address) —— **只读库存事实, 不回退**。
# 用途: 让 VIP 在多次运行间保持稳定(复用逻辑在 kube_vip_derive 第 2 步)。
# ⚠ 语义必须保持**窄**(读不到就输出空串): 另两个消费者把它当"库存里当前生效的入口"用,
#   一旦它在读不到时伪造出一个值, 这两处安全判定都会 fail-open —— 要回退请下沉到 kube_vip_derive:
#     · modules/02_k8s/09_kube_vip.sh#kube_vip_cleanup 清理护栏: 入口"非空且非节点 IP"即拒绝清理,
#       伪造值会让"明明没有入口"的集群永远清不掉 kube-vip(而它给的解法在本地代理模式下也走不通)
#     · modules/02_k8s/06_k8s_deploy.sh 阶段二切换确认门: _KV_OLD==_KV_VIP 会**静默跳过**红底倒计时
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
        local _host _u
        # ★ IP 而非主机名(同上): 容器解析不了节点名 ⇒ 拿主机名 SSH 恒失败 ⇒ 会把每个候选地址
        #   都误判成"被占用" ⇒ VIP 自动推导失效(显式 K8S_API_VIP 不受影响)
        for _host in $(master_ips); do
            _u="$(ssh_user_for_ip "${_host}")"
            ssh -i "${ssh_key}" -o BatchMode=yes -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
                "${_u}@${_host}" "${probe//__IP__/${ip}}" >/dev/null 2>&1 || return 1
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
    #    ⚠ 不再因 KUBE_VIP_SWITCH_CONFIRMED=1 跳过复用: 那会退回第 3 步的逐地址探测, 而
    #      **当前已绑定的 VIP 在探测口径里恰恰是"被占用"** → 每确认一次就换一个地址(VIP 漂移, 见 R8)。
    #      "要换地址"的诉求由第 1 步的显式 K8S_API_VIP 承担, 不需要在这里重新推导。
    local cur; cur="$(kube_vip_current_entry)"
    # 本地代理模式下 all.yml 的 loadbalancer_apiserver 块保持注释 → 回退到 addons.yml 记录值,
    # 让 VIP 在多次运行间保持稳定(不因重跑漂移)。⚠ **只在这一步回退**:
    # kube_vip_current_entry 的其它消费者(清理护栏/切换确认门)需要它保持"all.yml 事实"的窄语义。
    [ -n "${cur}" ] || cur="$(kube_vip_recorded_address)"
    if [ -n "${cur}" ]; then
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
    local ssh_key="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
    local _user; _user="$(ssh_user_for_ip "${m1}")"
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
    local ssh_key="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
    local _host _user
    # ★ 用 master_ips() 而非 master_hosts(): 部署容器解析不了节点名, 拿主机名 SSH 会静默失败
    #   —— 那时本函数**恒返回 1("VIP 未绑定")**, 哪怕 VIP 明明已绑(2026-09-28 实机, 见 master_ips 注释)
    for _host in $(master_ips); do
        _user="$(ssh_user_for_ip "${_host}")"
        if ssh -i "${ssh_key}" -o BatchMode=yes -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${_user}@${_host}" \
               "ip route get '${vip}' 2>/dev/null | grep -q 'local ${vip} '" 2>/dev/null; then
            vlog "VIP ${vip} 已绑定在 ${_host}"
            return 0
        fi
    done
    return 1
}

# API 入口地址(**域名解析专用**)= kube-vip 已绑 → VIP; 否则第一个 master。
#
# ⚠ 与 API_IP 的分工, 二者**不可互换**:
#   API_IP        = "一个能通 NodePort 的**节点** IP", 恒为首个 master。registry 的 containerd
#                   mirror(`http://${REGISTRY_IP:-${API_IP}}:${REGISTRY_NODEPORT}`; REGISTRY_IP
#                   显式指定时按配置, 缺省回退该节点 IP)与 setup-api-expose 的 DNAT 判定都依赖
#                   "这是一台真实节点"。若用 VIP 会坏两处:
#                     ① VIP 不代理 NodePort → 扩容的新节点拉不到 registry 镜像;
#                     ② 宿主机被装一条 `DNAT VIP:6443 → master01:6443`, 把 kube-vip 的高可用打回单点。
#   API_ENTRY_IP  = "集群 API 该从哪个地址进" —— /etc/hosts 里 API_DOMAIN 的解析、kubeconfig 用。
#                   本函数只服务后者; 写域名的调用点用它, 其余一律继续用 API_IP。
#
# 判据与两阶段切换同款(见 kube_vip_resolve_target): **VIP 此刻是否真的绑上了**。
#   VIP 已绑 → 用 VIP(域名真正指向高可用入口)
#   VIP 未绑 → 首个 master —— 全新集群首次部署时 kube-vip 还没起来(k8s_hosts 早于 k8s_deploy),
#              此时指向 VIP 等于指向一个空地址, 会把首次部署自己搞挂。
#
# 成本: kube_vip_is_bound 要 SSH 逐台 master 探测, 故本函数**不进 load_config 热路径**,
#   由调用方按需调用 + 一次运行内缓存。且只对"已知的 VIP"(K8S_API_VIP 或库存记录)探测 ——
#   不做候选地址扫描(那是 kube_vip_derive 的活, 代价高, 属安装期行为)。
# 用法: API_ENTRY_IP="$(api_entry_ip)" || exit 1
api_entry_ip() {
    [ -n "${API_ENTRY_IP_CACHE:-}" ] && { printf '%s' "${API_ENTRY_IP_CACHE}"; return 0; }
    local m1; m1="$(first_master_ip)" || return 1
    local entry="${API_ENTRY_IP:-}"          # cluster.conf 显式设置优先

    if [ -z "${entry}" ] && bool_is_true "${KUBE_VIP_ENABLED:-false}"; then
        local vip="${K8S_API_VIP:-}"
        [ -n "${vip}" ] || vip="$(kube_vip_recorded_address)"
        # 排除自相矛盾的配置(VIP 实为节点 IP / 落在 MetalLB 池内)后才值得去探测
        if [ -n "${vip}" ] && [ "${vip}" != "${m1}" ] \
           && kube_vip_is_viable_candidate "${vip}" \
           && kube_vip_is_bound "${vip}"; then
            entry="${vip}"
        elif [ -n "${vip}" ]; then
            vlog "API 域名: VIP ${vip} 未绑定 → 仍指向首个 master ${m1}(未绑定时指向 VIP 等于指向空地址)"
        fi
    fi

    API_ENTRY_IP_CACHE="${entry:-${m1}}"
    printf '%s' "${API_ENTRY_IP_CACHE}"
}

# 阶段判定: 决定本次运行 API 入口地址取什么值(两阶段切换的核心, 见 docs/kube-vip-api-ha.md 第 7 节)
# 输出: 要写入 all.yml 的 loadbalancer_apiserver.address; 同时设置 API_ENTRY_PHASE(0/1/2)
#
#   与"集群是不是新建"无关, 只看一件事: **VIP 此刻是否已经真的绑上了**。
#   原因是 kubespray 的时序: 写 /etc/hosts 的任务(历史: preinstall 角色的 0090-etchosts.yml ——
#   **v2.32 树已删除该任务**, 现由本仓库 modules/02_k8s/03_k8s_hosts.sh 写)与拉起 kube-vip 的
#   kubernetes/node 角色之间隔着 etcd 安装;收编后 kube-vip 清单更早落盘、但**绑定完成**仍晚于 hosts 写入。
#   所以无论新建还是存量, 只要 VIP 还没绑, 把入口指向 VIP 就等于指向一个不存在的地址。
#
#   VIP 未绑 → 阶段一: 写 master01(既有行为, 零风险); 本轮的唯一产出是让 kube-vip 就位
#   VIP 已绑 → 阶段二: 写 VIP(切换入口)
#
# ★ 阶段怎么取(2026-09-24 修): 调用方通常写成 `api_addr="$(kube_vip_resolve_target)"` —— 而
#   **命令替换是子 shell**: 函数里 `API_ENTRY_PHASE=` 的赋值**回不到调用方**(2026-09-22 已知未修)。
#   后果不是"少个变量", 而是**"切到 VIP 需人工确认"那道 fail-closed 护栏静默失效**(阶段恒为
#   未设 → 护栏与"阶段二"分支永不成立), 地址却照样按 VIP 写下去。
#   所以阶段同时**落盘**, 调用方一律用 `api_entry_phase()` 回读:
#     api_addr="$(kube_vip_resolve_target)" || exit 1
#     phase="$(api_entry_phase)"          # ← 必须紧跟其后回读(别用丢失的 $API_ENTRY_PHASE)
API_ENTRY_PHASE_FILE="${API_ENTRY_PHASE_FILE:-${TMPDIR:-/tmp}/.cubestack-api-entry-phase}"

_api_entry_phase_set() {   # <0|1|2> 记录阶段(全局 + 落盘, 后者供子 shell 调用方回读)
    API_ENTRY_PHASE="$1"
    printf '%s' "$1" > "${API_ENTRY_PHASE_FILE}" 2>/dev/null || true
}

api_entry_phase() {        # → 回读最近一次 kube_vip_resolve_target 判定的阶段(取不到=0)
    local f="${API_ENTRY_PHASE_FILE}"
    if [ -s "${f}" ]; then cat "${f}"; else echo 0; fi
}

kube_vip_resolve_target() {
    _api_entry_phase_set 1

    # kube-vip 未启用 → 维持既有行为(第一个 master), 不引入任何新路径
    if [ "${KUBE_VIP_ENABLED:-false}" != "true" ]; then
        _api_entry_phase_set 0
        local _m; _m="$(first_master_ip)" || return 1
        emit_ip "${_m}" || return 1; return 0
    fi

    local vip; vip="$(kube_vip_derive)" || return 1
    local master01; master01="$(first_master_ip)" || return 1

    if [ "${vip}" = "${master01}" ]; then
        _api_entry_phase_set 0
        emit_ip "${master01}" || return 1; return 0
    fi

    if kube_vip_is_bound "${vip}"; then
        _api_entry_phase_set 2
        emit_ip "${vip}" || return 1; return 0
    fi

    vlog "VIP ${vip} 尚未绑定 → 阶段一(本轮仅就位 VIP, API 入口保持 ${master01})"
    emit_ip "${master01}" || return 1; return 0
}

# 布尔归一化(cluster.conf 里 true/1/yes/on 都算开) —— 与 sync-kubespray-config.sh 的 _bool 同语义
bool_is_true() { case "${1:-0}" in 1|true|yes|on) return 0;; *) return 1;; esac; }

# ---------------- API 入口: 模式判定与地址解析(见 docs/api-ha/04-decision.md §2) ----------------

# 节点侧本地代理(kubespray nginx-proxy 静态 Pod)是否启用。
# 兼容别名: 旧开关 KUBE_VIP_LOCAL_PROXY(新方案起并入本开关, 见 cluster.conf 注释)。
# 用法: api_local_lb_enabled && echo 开
api_local_lb_enabled() {
    if [ -n "${API_LOCAL_LB_ENABLED:-}" ]; then
        bool_is_true "${API_LOCAL_LB_ENABLED}"
    else
        bool_is_true "${KUBE_VIP_LOCAL_PROXY:-false}"
    fi
}

# 入口模式三选一(优先级: external > vip > node)。纯函数, 只读开关。
# 用法: mode="$(api_entry_mode)"
api_entry_mode() {
    if [ -n "${API_EXTERNAL_ADDR:-}" ]; then printf 'external\n'; return 0; fi
    if bool_is_true "${KUBE_VIP_ENABLED:-false}"; then printf 'vip\n'; return 0; fi
    printf 'node\n'; return 0
}

# 当前生效的 API 入口地址(全部返回值都是 IPv4 字面量, 供 /etc/hosts、kubeconfig 等消费)。
#   external → API_EXTERNAL_ADDR
#   vip      → kube_vip_resolve_target(内含两阶段: 未绑=首 master / 已绑=VIP)
#   node     → 第一个 master IP(无 HA —— 不拦停, 但 api_entry_validate_config 会**显式 warn**)
# 用法: addr="$(api_entry_addr)" || exit 1
api_entry_addr() {
    # ⚠ 2026-09-28 rebase 合并: 原先 vip/node 两条各调 kube_vip_resolve_target / first_master_ip,
    #   与 api_entry_ip 是**两套并行机制**(它们不认显式 API_ENTRY_IP, 也不做 VIP 可用性体检)。
    #   现在只留一条: external 走外部入口, 其余一律委托 api_entry_ip。
    if [ "$(api_entry_mode)" = "external" ]; then
        emit_ip "${API_EXTERNAL_ADDR}" || return 1
        return 0
    fi
    api_entry_ip
}

# 入口配置的硬校验(互斥 + 取值合法性 + node 模式的"无 HA"提示)。失败即 err 并 return 1。
# 用法: api_entry_validate_config || exit 1   (须已 load_config)
#
# ⚠ **调用点必须是语句上下文, 不得写成 `x="$(api_entry_validate_config)"`** ——
#   本函数在 node 模式下会 warn, 而 say/ok/warn 写的是 **stdout**(只有 vlog/err 走 stderr),
#   被 `$(...)` 捕获就会把提示文字混进返回值(与 vlog 写 stdout 那次部署中断同源, 见本文件顶部注释)。
#   全仓库调用点(2026-09-28 核查, 两个生产调用点均为语句上下文, 无捕获):
#     · `kube_vip_validate_config()` 内(紧随本函数定义之后)   `api_entry_validate_config || return 1`
#     · `tools/k8s/sync-kubespray-config.sh` 顶部              `api_entry_validate_config || exit 1`
#     · 测试桩 `tools/tests/test-api-entry-mode.sh` **有意**在 `$(...)` 里捕获(为了断言"node 模式确实
#       打印了提示")—— 那是观察手段, 捕获到的提示**不是**被消费的返回值
#   ⚠ **可见性**: sync-kubespray-config.sh 的 stdout 在 `06_k8s_deploy.sh` 里被 `>/dev/null 2>&1` 吞掉
#     (两处调用皆如此), 那条路径**看不到**本提示; 但 `gen-inventory.sh` 调用它时**不重定向**
#     (06_k8s_deploy.sh 第一步就会跑它), 所以正常全量部署里这条 warn 是**可见**的。
api_entry_validate_config() {
    if [ -n "${API_EXTERNAL_ADDR:-}" ]; then
        if bool_is_true "${KUBE_VIP_ENABLED:-false}"; then
            err "API_EXTERNAL_ADDR=${API_EXTERNAL_ADDR} 与 KUBE_VIP_ENABLED=true 互斥 —— 入口只能有一个来源:"
            err "  复用环境已有 LB/VIP → 请设 KUBE_VIP_ENABLED=false"
            err "  由本方案自带 VIP → 请清空 API_EXTERNAL_ADDR"
            return 1
        fi
        emit_ip "${API_EXTERNAL_ADDR}" >/dev/null 2>&1 || {
            err "API_EXTERNAL_ADDR 不是合法 IPv4 字面量: ${API_EXTERNAL_ADDR}"
            return 1
        }
    fi
    if bool_is_true "${KUBE_VIP_LOCAL_PROXY:-false}" && [ -n "${API_LOCAL_LB_ENABLED:-}" ] \
       && ! bool_is_true "${API_LOCAL_LB_ENABLED}"; then
        err "KUBE_VIP_LOCAL_PROXY=true 与 API_LOCAL_LB_ENABLED=false 冲突:"
        err "  KUBE_VIP_LOCAL_PROXY 已是 API_LOCAL_LB_ENABLED 的兼容别名, 只保留其中一个"
        return 1
    fi

    # ⑤ node 模式(既无 kube-vip VIP, 也无 API_EXTERNAL_ADDR) → 外部/管理入口回退第一个 master。
    #   这**正是本方案要消灭的静默单点**(D5 / §2.2 判定图, docs/api-ha/04-decision.md) ——
    #   不拦停(无 VIP 是可接受的现场条件), 但绝不允许悄无声息: 否则运维会以为拿到了高可用入口。
    #   放这里的原因: 本函数是全部部署路径共同的静态入口关(sync / 09_kube_vip / 06_k8s_deploy 都经过);
    #   只把它放进某一个模块, 别的入口(如单独跑 sync)就漏掉了。
    #   ⚠ 去重: 同一进程内只提示一次 —— 单次部署会经过本函数 2~4 次(见上方调用点), 刷屏只会让人无视它。
    #     去重是**进程内**的: 各脚本是独立进程, 因此"可见的那次"不会被隐藏的那次吞掉(06 里 sync 两次重定向,
    #     gen-inventory 那次不重定向 → 提示仍可见)。
    if [ "$(api_entry_mode)" = "node" ] && [ "${_API_ENTRY_NODE_WARNED:-0}" != "1" ]; then
        _API_ENTRY_NODE_WARNED=1
        local _fm=""; _fm="$(first_master_ip)" || _fm="<第一个 master>"
        warn "API 入口模式 = node: 外部/管理入口回退到第一个 master(${_fm}) —— **无 HA**"
        warn "  该 master 宕机 ⇒ kubectl/CI/外部系统失联(节点侧不受影响, 仍走各节点本地代理)"
        warn "  如需外部入口高可用: 设 KUBE_VIP_ENABLED=true(自带浮动 VIP), 或 API_EXTERNAL_ADDR=<环境已有 LB/VIP>"
    fi
    return 0
}

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
# ⚠ **2026-09-28 收编(本函数的语义已反转)**: 写入的 kube_vip_enabled **跟随 KUBE_VIP_ENABLED** ——
#   静态 Pod 清单改由 **kubespray 自己**在 "Install Kubernetes nodes" 里渲染
#   (roles/kubernetes/node/tasks/loadbalancer/kube-vip.yml), 我们不再代劳。
#   历史(2026-09-22 ~ 09-28): 该键曾**恒写 false**("单一写入者契约", 静态 Pod 由 09_kube_vip.sh 独占),
#   起因是**双写者**并存 —— 上游对**首台** master 把 hostPath 渲染成 super-admin.conf、其余 admin.conf,
#   而我们的渲染器恒用 admin.conf ⇒ 同一路径被两方轮流改写、每次全量运行清单改两次、Pod 重启两次。
#   收编后写入者只剩上游一家, 那份分叉本身是**稳定**的 ⇒ 契约不需要, 自持渲染器已删除(见
#   docs/api-ha/07-kube-vip-upstream-assessment.md)。上游做不到的部分仍由我们兜:
#   VIP 推导 / 入口与 hosts / 关闭清理 / 验证(模块 09 / 03 / 10 / 08 / 11)。
update_kube_vip_addons_yml() {
    local f="$1" vip="${2:-}"
    [ -f "${f}" ] || { warn "未找到 ${f}, 跳过 kube-vip 同步"; return 1; }
    grep -q '^# Kube VIP' "${f}" || { warn "${f} 中未找到 '# Kube VIP' 锚点行, 跳过 kube-vip 同步"; return 1; }

    local kv_on; bool_is_true "${KUBE_VIP_ENABLED:-false}" && kv_on=true || kv_on=false
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
        # 跟随开关键: kubespray 据此决定是否渲染 kube-vip 静态 Pod(node/tasks/main.yml:19-24)
        echo "kube_vip_enabled: ${kv_on}"
        # kube_vip_address 与开关**无关**: 它只喂 apiserver 证书 SAN
        # (control-plane/tasks/kubeadm-setup.yml:49 的 sans_kube_vip_address, 只看它是否定义,
        #  不看 kube_vip_enabled)。**KUBE_VIP_ENABLED=false 时也保留它** → 关掉 kube-vip 后再开回来
        #  不必重签证书(阶段二切换的主要代价之一就是证书 SAN 重签, 能省则省)。
        [ -n "${vip}" ] && echo "kube_vip_address: ${vip}"
        # 以下键 = 收编前自持渲染器钉死的策略(render-kube-vip-manifest.py:90-116), 现把同样的策略
        # 喂给上游渲染器, 使上游渲染结果与收编前逐项等价。上游这些键的默认值与本策略**不同**,
        # 缺一项就会渲染出行为不同的清单, 故必须显式写:
        echo "kube_vip_arp_enabled: true"          # 上游默认 false; 且 kube_vip_leader_election_enabled 由它派生(不写=选举关闭)
        echo "kube_vip_controlplane_enabled: true" # 上游默认 false; 不写就没有控制面 VIP
        # apiserver 进程级故障检测: 开启后 kube-vip 探本机 apiserver /healthz, 探失败即把自身健康置假
        # → 不再续租 → 约 5s(租约时长)后 VIP 漂走。这是"节点活着但 apiserver 死了"这一场景唯一的
        # 快速切换手段(关闭时只能等租约自然过期, 与节点宕机同速)。
        echo "kube_vip_cp_detect: $(bool_is_true "${KUBE_VIP_CP_DETECT:-false}" && echo true || echo false)"
        # 服务 LB 归 MetalLB —— 两者都实现 LoadBalancer 语义, 同时开会让 kube-vip 抢走 MetalLB 的
        # 地址分配权(实机已验证的分工, 见 docs/kube-vip-api-ha.md 决策 D1)。显式写 false 作护栏。
        echo "kube_vip_services_enabled: false"
        # 不开控制面负载均衡(决策 D4)。⚠ 不是"收益有限"那么含糊 —— kube_vip_lb_fwdmethod 的默认值
        # local 在内核里等于 ip_vs_null_xmit(包原样交回本机栈, 根本不转发); 要真 LB 得换 masquerade,
        # 那又要 privileged + kube-vip-iptables 镜像 + kube-proxy excludeCIDRs 与 VIP 同步。
        # 详见 docs/kube-vip-api-ha.md 决策 D4 与 docs/troubleshooting.md 三.11。
        echo "kube_vip_lb_enable: false"
        [ -n "${KUBE_VIP_INTERFACE:-}" ] && echo "kube_vip_interface: ${KUBE_VIP_INTERFACE}"
    } >> "${tmp}"

    cat "${tmp}" > "${f}"
    rm -f "${tmp}"

    if [ "${kv_on}" = "true" ]; then
        [ -n "${vip}" ] || { err "kube-vip 已启用但 VIP 为空 —— 不能写入 kube_vip_address"; return 1; }
    fi
    if [ -n "${vip}" ]; then
        local wrote; wrote="$(awk '/^kube_vip_address:/{print $2; exit}' "${f}")"
        [ "${wrote}" = "${vip}" ] || { err "kube_vip_address 写入校验失败(期望 ${vip}, 实际 ${wrote})"; return 1; }
    fi
    # 收编后的写入校验: 开关值必须与 KUBE_VIP_ENABLED 一致(上游据此渲染/不渲染静态 Pod)
    local _en; _en="$(awk '/^kube_vip_enabled:/{print $2; exit}' "${f}")"
    [ "${_en}" = "${kv_on}" ] || { err "kube_vip_enabled 写入校验失败(期望 ${kv_on}, 实际 '${_en}')"; return 1; }
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
    # ssh_user 为 "-"/空 → 跟随全局 SSH_USER(root|ubuntu 单一旋钮; 见 load_config 注释)。
    # 显式写了用户名 = 该节点覆盖(逐行覆盖优先)。
    if [ -z "${NODE_USER}" ] || [ "${NODE_USER}" = "-" ]; then
        NODE_USER="${SSH_USER:-ubuntu}"
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

# 校验显式 Ceph 节点/裸盘配置(CEPH_NODES / CEPH_DATA_DISKS)。
# 目的: 防止 "node0:/dev/vdb,node1:/dev/vdb,node2:/dev/vdb" 这种**节点间用逗号**的写法
# 被解析器静默当成 node0 的三块盘(2026-10-26 实机: 三块盘全显示在第一个节点, 另外两台
# <未检测到>)。必须用分号分隔节点, 逗号只分隔同一节点的多块盘。
# 返回: 0=通过; 1=格式/节点名非法(err 已打印原因)。
ceph_validate_explicit_config() {
    local _line _h _g _grp _hn _ds _d _ncolon
    local -a _hosts=() _grps=()
    # 合法节点名来自 NODES; node_parse 放子 shell, 避免污染调用方 NODE_* 全局态。
    while IFS= read -r _h; do
        [ -n "${_h}" ] && _hosts+=("${_h}")
    done < <(for _line in "${NODES[@]:-}"; do
        [ -z "${_line}" ] && continue
        node_parse "${_line}"
        [ -n "${NODE_HOSTNAME}" ] && printf '%s\n' "${NODE_HOSTNAME}"
    done)

    # CEPH_NODES: 裸 hostname 逗号分隔, 不允许 role 前缀/未知节点。
    if [ -n "${CEPH_NODES:-}" ]; then
        for _h in ${CEPH_NODES//,/ }; do
            [ -n "${_h}" ] || continue
            if ! printf '%s\n' "${_hosts[@]:-}" | command grep -qxF -- "${_h}"; then
                err "CEPH_NODES 含未知节点: ${_h}(NODES 中不存在; 只写 hostname, 不要写 master/worker 角色前缀)"
                return 1
            fi
        done
    fi

    # CEPH_DATA_DISKS: 节点之间用 ;, 同一节点多盘用 ,
    if [ -n "${CEPH_DATA_DISKS:-}" ]; then
        while IFS=';' read -ra _grps; do
            for _g in "${_grps[@]:-}"; do
                [ -n "${_g}" ] || continue
                _ncolon="$(printf '%s' "${_g}" | tr -cd ':' | wc -c)"
                if [ "${_ncolon}" -gt 1 ]; then
                    err "CEPH_DATA_DISKS 格式错误: 节点之间必须用分号 ; 分隔, 逗号只用于同一节点的多块盘"
                    err "  问题项: ${_g}"
                    err "  正确示例: node0:/dev/vdb;node1:/dev/vdb;node2:/dev/vdb"
                    err "  或全节点同盘: /dev/vdb"
                    return 1
                fi
                _hn="${_g%%:*}"; _ds="${_g#*:}"
                if [ "${_hn}" != "${_ds}" ]; then
                    if ! printf '%s\n' "${_hosts[@]:-}" | command grep -qxF -- "${_hn}"; then
                        err "CEPH_DATA_DISKS 含未知节点: ${_hn}(NODES 中不存在; 只写 hostname, 不要写角色前缀)"
                        return 1
                    fi
                fi
                for _d in ${_ds//,/ }; do
                    [ -n "${_d}" ] || continue
                    case "${_d}" in
                        *:*) err "CEPH_DATA_DISKS 磁盘项含 ':' (${_d}); 节点之间请用分号 ;, 不要用逗号"; return 1 ;;
                    esac
                done
            done
        done <<< "${CEPH_DATA_DISKS}"
    fi
    return 0
}

# Ceph 存储节点数量(复用上面的选择规则; 供预检/提示用)
ceph_storage_host_count() {
    local n
    n="$(ceph_storage_hosts | grep -c . || true)"
    echo "${n:-0}"
}

# ---------------- BlueStore 磁盘彻底擦除(共享: ceph-cleanup.sh 与 ceph 模块 7a) ----------------
# ★ 为什么不能只 dd 头/尾(2026-09-24 实机事故, 直接导致新集群 0 OSD):
#   Ceph v20(本仓库 CEPH_VERSION=v20.2.2)把 bdev label **复制到固定偏移 10GiB / 100GiB / 1000GiB**
#   —— 见 `ceph-bluestore-tool show-label --dev <盘>` 输出里的 locations 字段(实机 verify:
#   三处副本各含 "bluestore block device" + "ceph osd volume v026")。
#   旧实现只擦 头/尾/1GB/size÷20/size÷2, 这三处副本原样留下; 而 blkid / wipefs /
#   `ceph-volume inventory` 全都只看 offset 0 → 盘"看起来是干净的", 但 `ceph-volume raw list`
#   仍读得出旧 OSD(带旧 fsid)→ Rook osd-prepare 判 "Raw device ... is already prepared" →
#   试图认领这些(属于别的集群的)OSD → "belonging to a different ceph cluster" 全部跳过 →
#   **0 OSD**(CephCluster 还是 Ready, 只是 HEALTH_WARN "OSD count 0"), 重装必失败且看不出原因。
# ★ 首选官方 zap: `ceph-bluestore-tool zap-device --yes-i-really-really-mean-it` 读 label 自带的
#   locations 逐处清零, 与 Ceph 版本/偏移方案无关 —— **别再往脚本里写死偏移量**(写死正是本次根因)。
#   ceph 工具宿主机上没有(这正是旧版退回 dd 的原因), 但**预加载的 ceph 镜像**在节点 containerd 里
#   (kubespray 预加载 / k8s 阶段保证), 用 ctr 起来跑即可, 全程不联网。
# ★ 兜底: 镜像不可得(单独使用清理工具等)→ 按**已知候选偏移** dd(头 + 10/100/1000GiB + 旧方案的
#   size÷20, size÷2 + 尾)。无论走哪条路, 最后都擦一遍候选偏移并**校验** —— 残留时返回非 0,
#   由调用方明确报错, 绝不"假装擦干净了"(那正是本次 0 OSD 的成因)。
# 用法(部署机侧; 片段走 SSH stdin 送到节点执行):
#   ssh <节点> "sudo bash -s -- <盘>" <<< "$(bluestore_wipe_remote_lib; echo 'bluestore_wipe_dev "$@"')"
bluestore_wipe_remote_lib() {   # 只输出节点端函数定义, 不在本机执行
    cat <<'WIPELIB'
# 预加载的 ceph 镜像(用于官方 zap; 空 = 镜像不可得 → 走 dd 兜底)
_BSTORE_IMG="$( (ctr -n k8s.io images ls -q 2>/dev/null || true) | grep -m1 -E '^(quay\.io/ceph/ceph|docker\.io/ceph/ceph):' || true)"
[ -n "${_BSTORE_IMG}" ] || _BSTORE_IMG="$( (ctr -n k8s.io images ls -q 2>/dev/null || true) | grep -m1 -E '(^|/)ceph/ceph:' || true)"

_bstore_offsets() {   # <盘> → 候选偏移(MiB, 每行一个): 头 + label 副本 10/100/1000GiB + 尾(含旧方案比例位)
    local sz
    sz="$(blockdev --getsize64 "$1" 2>/dev/null || echo 0)"
    printf '%s\n' 0 10240 102400 1024000
    [ "${sz:-0}" -gt 0 ] 2>/dev/null || return 0
    printf '%s\n' "$((sz/1048576/20))" "$((sz/1048576/2))" "$(( sz/1048576 > 64 ? sz/1048576 - 64 : 0 ))"
}

bluestore_wipe_dev() {   # <盘> → 0=已擦净(校验通过); 非 0=仍有 bluestore 残留(调用方须报错)
    local d="$1" o r=0
    [ -b "$d" ] || return 1
    # ① 官方 zap(读 label 的 locations 逐处清零; 失败不致命 —— ② 会兜底并校验)
    if [ -n "${_BSTORE_IMG}" ]; then
        ctr -n k8s.io containers rm cubestack-bstore-zap >/dev/null 2>&1 || true
        ctr -n k8s.io run --rm --privileged \
            --mount type=bind,src=/dev,dst=/dev,options=rbind:rw \
            "${_BSTORE_IMG}" cubestack-bstore-zap \
            ceph-bluestore-tool zap-device --dev "$d" --yes-i-really-really-mean-it \
            </dev/null >/dev/null 2>&1 || true
    fi
    # ② 签名/分区表 + 候选偏移 dd(始终执行: zap 只管 label 位置, 不管 offset 0 的
    #    "bluestore block device" 魔法/GPT; 也是镜像不可得时的唯一手段)
    wipefs -a -f "$d" >/dev/null 2>&1 || true
    # ⚠ **禁用 `sgdisk --zap-all`**(2026-10-10 实机根因): 它退出时做**全局 `sync()`** ——
    #   内核若残留死 IO(历史事故的 D 状态写), sync 会遍历全部超级块、**永久挂死**(实测 5h50m,
    #   不可杀, 部署无限 pending)。GPT 头/备份表 + bluestore 标签区已由下方 dd 候选偏移覆盖
    #   (offset 0 与贴尾各 64MiB), 分区表重读由末尾 `partprobe`(BLKRRPART ioctl, **设备本地**)
    #   完成 —— 全程只碰目标盘, 不做任何全局 sync。**别把它加回来。**
    for o in $(_bstore_offsets "$d"); do
        dd if=/dev/zero of="$d" bs=1M seek="$o" count=64 conv=fsync status=none >/dev/null 2>&1 || true
    done
    partprobe "$d" >/dev/null 2>&1 || true
    # ③ 校验: 逐处读回, 找 bluestore 物证; 还在 → 非 0(把"静默 0 OSD"变成清盘期就报错)
    for o in 0 10240 102400 1024000; do
        if dd if="$d" bs=1M skip="$o" count=4 status=none 2>/dev/null \
             | grep -qaE 'bluestore block device|ceph osd volume'; then
            echo "    !! ${d} 偏移 $(( o / 1024 ))GiB 仍有 bluestore label 残留(未擦净)"
            r=1
        fi
    done
    return "$r"
}
# 毒化预检(有界 ≤10s, 只告警不阻断; 脚本顶层、每节点一次): 内核若残留死 IO, 全局 sync 会被
# 拖住 —— 检出即给"择机重启清毒"指引(本库其余步骤已全部设备本地化, 不受其影响)。
# ⚠ 2026-10-14 实机(卡 15h): 后台 sync 必须**重定向 fd** —— 死 IO 下 sync 永不退出(D 态,
#   TERM/KILL 皆无效), 若它继承着 SSH 的 stdout/stderr 管道, ssh 会一直等管道关闭 ⇒
#   `node_ssh ... bash -s` **永不返回**, 整个部署无限挂起(判据: 本函数已打完"本步已全部设备
#   本地化"的告警、后续却再无输出)。重定向后 sync 卡死只留在节点上, 不再攥住会话。
sync >/dev/null 2>&1 & _sp=$!
_sp_ok=0
for _si in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$_sp" 2>/dev/null || { _sp_ok=1; break; }; sleep 1; done
[ "${_sp_ok}" = "1" ] || echo "    ⚠ 该节点内核存在残留死 IO(全局 sync 被拖住>10s; 历史事故产物): 本步已全部设备本地化、不受影响; 建议择机重启清毒"
unset _sp _sp_ok _si
WIPELIB
}

# ---------------- 离线 deb 安装原语(共享; 2026-10-14 三轮实机事故重构, P0) ----------------
# 背景: "离线装 deb" 多处各写一份, 口径漂移 ⇒ 同类坑换文件复发(10-07 timesyncd 互斥守卫只进
#   reconcile; 10-14 chrony 直装只进 setup-ntp)。本区收口为**单一实现**, 三条硬口径:
#   ① 走 **dpkg 直装**: apt 对任何操作先做全局依赖检查, 节点"预先破损态"(半装包/版本错位)下
#      直接拒绝 —— 连纯本地事务也拒(10-14 实机: 节点三处破损, chrony 永远装不上);
#   ② **已装即跳(任何版本)**: 只补缺、不升级 —— 把较旧系统库升级会打断既有版本钉
#      (10-14 实机: 闭包的 libtinfo6 .3 打断本机 libncurses6=.2 ⇒ 新全局缺口);
#   ③ **互斥提供者声明表**: time-daemon 系(chrony/timesyncd/openntpd/ntp)只允许一个提供者,
#      装载前按表预卸(10-14 实机: dpkg 报 conflicting packages 拒装 chrony)。
#   ④ 批量 dpkg -i 一包失败**逐包隔离重试**(不连坐); ⑤ 输出全程保留(禁止 >/dev/null 吞)。
# ⚠ 禁令(10-14 实机血证): **禁止**在破损态节点上自动跑 `apt-get --fix-broken install` ——
#   它"修复"的手段是移除/改版(曾击穿 .203 的 sshd), 且离线时拿不到缺件 = 纯风险零收益。
# 互斥表(单一事实来源; 远程双胞胎 _pkg_conflict_providers 见 deb_install_remote_lib,
#   ⚠ 两处必须同步 —— tools/tests/test-deb-install-lib.sh 会断言两侧一致)
pkg_conflict_providers() {   # <包名> → 输出其互斥提供者(空格分隔; 无 → 空)
    case "$1" in
        chrony|systemd-timesyncd|openntpd|ntp)
            echo "chrony openntpd ntp systemd-timesyncd" | tr ' ' '\n' | grep -vx "$1" | tr '\n' ' ' ;;
        *) : ;;
    esac
}

# 节点侧安装原语(文本经 SSH stdin 送往节点; 与 bluestore_wipe_remote_lib 同机制)。
# 用法: { deb_install_remote_lib; printf '\ninstall_debs_offline %s %s\n' "<deb目录>" "<关注包...>"; } | ssh <节点> "sudo bash -s"
#   install_debs_offline <deb目录> [关注包...]: 预卸互斥 → 已装即跳过 → 批量 dpkg → 失败逐包隔离;
#   返回值恒 0, 由调用方按"关注包命令/状态"断言(如 command -v chronyd 或 assert_pkgs_ready)。
deb_install_remote_lib() {
    cat <<'DEBLIB'
# 互斥提供者表(⚠ 与 lib-common::pkg_conflict_providers 同步; 夹具断言两侧一致)
_pkg_conflict_providers() {
    case "$1" in
        chrony|systemd-timesyncd|openntpd|ntp)
            echo "chrony openntpd ntp systemd-timesyncd" | tr ' ' '\n' | grep -vx "$1" | tr '\n' ' ' ;;
        *) : ;;
    esac
}

# 安装一批离线 deb: 只补缺失、预卸互斥、失败逐包隔离、输出全程保留。
# 用法: install_debs_offline <deb目录> [关注包...]
install_debs_offline() {
    local d="$1"; shift
    local want="$*"
    local dlog=/tmp/cubestack-deb-install.log p c f pk list="" n_skip=0
    : >"${dlog}"
    # ① 预卸互斥提供者(对每个"关注包": 其提供者已装且不在同名关注列表 → 卸)
    for p in ${want}; do
        for c in $(_pkg_conflict_providers "${p}"); do
            case " ${want} " in *" ${c} "*) continue ;; esac
            if dpkg-query -W -f='${Status}' "${c}" 2>/dev/null | grep -q "install ok installed"; then
                echo "  [deb-install] 预卸互斥包 ${c}(与待装 ${p} 冲突, dpkg 级直卸)"
                dpkg --purge "${c}" >>"${dlog}" 2>&1 || true
            fi
        done
    done
    # ② 过滤: 已装即跳(任何版本); 只补缺, 不升级(防打断既有版本钉)
    for f in "${d}"/*.deb; do
        [ -f "${f}" ] || continue
        pk="$(dpkg-deb -f "${f}" Package 2>/dev/null || true)"
        [ -n "${pk}" ] || continue
        if [ -n "$(dpkg-query -W -f='${Status}' "${pk}" 2>/dev/null | grep -o 'install ok installed' || true)" ]; then
            n_skip=$((n_skip + 1)); continue
        fi
        list="${list} ${f}"
    done
    if [ -z "${list}" ]; then
        echo "  [deb-install] 全部已装(跳过 ${n_skip} 个), 无需安装"
        return 0
    fi
    # ③ 批量 dpkg -i; 失败 → 逐包隔离(一个坏包不连坐好包)
    # shellcheck disable=SC2086
    if dpkg -i ${list} >>"${dlog}" 2>&1; then
        echo "  [deb-install] dpkg 直装成功(跳过已装 ${n_skip}; 安装 $(echo ${list} | wc -w) 个)"
        return 0
    fi
    echo "  [deb-install] 批量安装部分失败, 逐包隔离重试(明细: ${dlog}):"
    local ok_n=0 fail_n=0
    for f in ${list}; do
        if dpkg -i "${f}" >>"${dlog}" 2>&1; then ok_n=$((ok_n + 1)); else fail_n=$((fail_n + 1)); fi
    done
    echo "  [deb-install] 隔离结果: 成功 ${ok_n} / 失败 ${fail_n}"
    [ "${fail_n}" -gt 0 ] && tail -8 "${dlog}" | sed 's/^/      /'
    return 0
}

# 断言关注包全部处于已装态(install_debs_offline 之后调用; 任一缺失 → 非 0)
assert_pkgs_ready() {
    local p
    for p in "$@"; do
        dpkg-query -W -f='${Status}' "${p}" 2>/dev/null | grep -q "install ok installed" \
            || { echo "PKG-MISSING:${p}"; return 1; }
    done
    return 0
}
DEBLIB
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
#   · 命中任意主机名(含 k8s-api.cubestack.io / k8s-api.nova.local / nova-k8s-* / node-* 旧版裸条目)即视为已有该块,
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
            -e '/node-[0-9]/d' \
            -e '/k8s-api\.\(nova\.local\|cubestack\.io\)/d' \
            /etc/hosts | sponge /etc/hosts 2>/dev/null || return 0
    else
        sed -e "/${start}/,/${end}/d" \
            -e '/nova-k8s-\(master\|node\)/d' \
            -e '/node-[0-9]/d' \
            -e '/k8s-api\.\(nova\.local\|cubestack\.io\)/d' \
            /etc/hosts > "${t}" 2>/dev/null || return 0
        cat "${t}" > /etc/hosts 2>/dev/null || { rm -f "${t}"; return 0; }
        rm -f "${t}"
    fi
    printf '%s\n' "${content}" >> /etc/hosts 2>/dev/null || true
}

# ---------------- 节点侧 /etc/hosts: 把 NODES 的 hostname → IP 同步到所有节点 ----------------
# 背景(2026-10-23 实机 MCCL/RoCE): NODES 的 hostname 是 kubespray inventory / K8s 节点名,
#   但 installer 此前只写**部署机** /etc/hosts, 节点侧没有这些 hostname 的解析。hostNetwork
#   Pod 按 hostname 找对端(MCCL socket)时 getent 失败 → 回退 127.0.0.1 → 多机通信失败。
# 做法(幂等, 不碰 /etc/hostname):
#   · 每台节点先删除**任一字段**等于受管 hostname 的旧行(含 127.0.1.1 / 换 IP 残留), 再追加当前映射;
#   · 重复执行每个 hostname 恰好一行; 不改节点实际主机名, 只加 alias;
#   · 远端写入用 SSH + sudo(密钥优先, 失败回退 sshpass 密码), 与扩容模块同款;
#   · 任一节点失败 → 打印节点清单并 return 1(调用方必须中止或显式告警, 不得静默成功)。
# 前置: load_config 已执行(NODES / SSH_KEY_* / SSH_DEFAULT_PASSWORD)。
# 用法: sync_nodes_hosts_remote || exit 1
sync_nodes_hosts_remote() {
    local line hn ip user pw key tmp e
    local -a entries=() targets=()
    local -A seen=()
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        [ -n "${NODE_IP}" ] && [ -n "${NODE_HOSTNAME}" ] || continue
        [ "${NODE_HOSTNAME}" = "-" ] && continue
        [ -n "${seen[${NODE_HOSTNAME}]:-}" ] && continue
        seen["${NODE_HOSTNAME}"]=1
        entries+=("${NODE_IP} ${NODE_HOSTNAME}")
        targets+=("${NODE_HOSTNAME}|${NODE_IP}|${NODE_USER}|${NODE_PW}")
    done
    if [ "${#entries[@]}" -eq 0 ]; then
        warn "  NODES 无可同步的 hostname/IP, 跳过节点侧 /etc/hosts"
        return 0
    fi
    local managed=""
    for e in "${entries[@]}"; do managed="${managed} ${e#* }"; done
    managed="${managed# }"
    key="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"

    # 远端脚本: 过滤旧行(任一字段命中受管 hostname) + 追加当前映射, 原地覆盖写(不 rename)
    tmp="$(mktemp)"
    {
        cat <<'EOS'
#!/bin/bash
set -e
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
EOS
        printf 'managed=%q\n' "${managed}"
        cat <<'EOS'
awk -v managed="$managed" 'BEGIN { n=split(managed, a, " "); for (i=1;i<=n;i++) m[a[i]]=1 }
/^[[:space:]]*(#|$)/ { print; next }
{ out=$1; kept=0
  for (i=2;i<=NF;i++) { if ($i ~ /^#/) { for (j=i;j<=NF;j++) out=out" "$j; break }
                        if (!m[$i]) { out=out" "$i; kept=1 } }
  if (kept) print out }' /etc/hosts > "$tmp"
EOS
        for e in "${entries[@]}"; do
            printf 'printf "%%s\\n" %q >> "$tmp"\n' "${e}"
        done
        printf 'cat "$tmp" > /etc/hosts\n'
    } > "${tmp}"

    local failed="" rcmd
    for line in "${targets[@]}"; do
        IFS='|' read -r hn ip user pw <<< "${line}"
        rcmd="sudo bash -s"; [ "${user}" = "root" ] && rcmd="bash -s"
        if [ -f "${key}" ] && ssh -i "${key}" -o BatchMode=yes -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
                "${user}@${ip}" "${rcmd}" < "${tmp}" >/dev/null 2>&1; then
            continue
        fi
        if [ -n "${pw}" ] && command -v sshpass >/dev/null 2>&1 && \
            env SSHPASS="${pw}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=8 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                "${user}@${ip}" "${rcmd}" < "${tmp}" >/dev/null 2>&1; then
            continue
        fi
        warn "  ${hn}(${ip}) 节点侧 /etc/hosts 写入失败(密钥/密码均不可达)"
        failed="${failed} ${hn}(${ip})"
    done
    rm -f "${tmp}"
    if [ -n "${failed}" ]; then
        err "  节点侧 /etc/hosts 同步失败:${failed}"
        err "  → 修复 SSH/免密后重跑; 否则 hostNetwork Pod 可能无法按 hostname 解析对端(回退 127.0.0.1)"
        return 1
    fi
    ok "  节点侧 /etc/hosts 同步完成(${#entries[@]} 个 hostname → ${#targets[@]} 个节点)"
    return 0
}

# ---------------- 宿主机 kubectl/helm 访问集群(共享, 防 TLS/DNAT 坑) ----------------
# 从第一个 master 下载 /etc/kubernetes/admin.conf 并同步到 ~/.kube/config, 同时:
#   ① server 改写为证书 SAN 内的 API_DOMAIN(k8s-api.cubestack.io) —— admin.conf 默认
#      直连 master IP, 证书 SAN 常不含该 IP → 宿主机 kubectl 会 TLS x509 校验失败;
#   ② 调用 tools/lb/setup-api-expose.sh 幂等配置宿主机 6443→first master 的 DNAT
#      (PREROUTING + OUTPUT), 让 API_DOMAIN 从宿主机可访问。
# 所有连 API 的模块(gpu_operator/ceph_*/...)统一复用本函数, 不各自复制。
# 用法: sync_kubeconfig → 退出码 0=宿主机可访问集群
sync_kubeconfig() {
    local tmp newctx
    tmp="$(mktemp)"
    local fm="${FIRST_MASTER:-$(first_master_ip)}"
    [ -n "${fm}" ] || { rm -f "${tmp}"; err "未找到 master 节点(无法下载 admin.conf)"; return 1; }
    # admin.conf 属 root(600), scp 会 Permission denied → 用 ssh + sudo cat 读取
    # BatchMode=yes: 密钥失败立即返回(不读 tty 密码提示; 交互终端下读 tty 会 SIGTTIN
    #   永久卡死, 见 ceph-detect-disks.sh 2026-09-09 注释)
    local _fm_user; _fm_user="$(ssh_user_for_ip "${fm}")"
    ssh -i "${SSH_KEY:-${HOME}/.ssh/cubestack_k8s}" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "${_fm_user}@${fm}" "sudo cat /etc/kubernetes/admin.conf" > "${tmp}" 2>/dev/null \
        || { rm -f "${tmp}"; return 1; }
    [ -s "${tmp}" ] || { rm -f "${tmp}"; return 1; }
    # ★ server 改写为证书 SAN 内的 API_DOMAIN(直连 master IP 不在 SAN → TLS 校验失败)
    API_DOMAIN="${API_DOMAIN:-k8s-api.cubestack.io}"
    sed -i -E "s|(server:[[:space:]]*https?://)[^:/]+(:[0-9]+)|\1${API_DOMAIN}\2|" "${tmp}"
    mkdir -p "${HOME}/.kube"
    # ★ `|| true`: kubeconfig 里没有 current-context 时 grep 无匹配, set -e+pipefail 会让这个
    #   赋值带走调用方(下面只在 newctx 非空时才重命名 ctx, 语义上本就允许为空)。
    newctx="$(grep -E '^[[:space:]]*current-context:' "${tmp}" | head -1 | awk '{print $2}' || true)"
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
    #   注意: K/_ctx/_cl 必须 local —— 各 addon 模块(gpu_operator/ceph_*)顶层也有同名
    #   全局 K(远端 kubectl), 若此处用全局并 unset 会把调用方的 K 冲掉 → set -u 报 unbound。
    local K _ctx _cl
    K="KUBECONFIG=${HOME}/.kube/config kubectl"
    _ctx="$(${K} config current-context 2>/dev/null || echo "${newctx}")"
    _cl="$(${K} config view -o jsonpath="{.contexts[?(@.name==\"${_ctx}\")].context.cluster}" 2>/dev/null | head -1 || true)"
    if [ -n "${_cl}" ]; then
        ${K} config set-cluster "${_cl}" --server="https://${API_DOMAIN}:6443" >/dev/null 2>&1 || true
    fi
    chmod 600 "${HOME}/.kube/config"
    rm -f "${tmp}"
    # ★ 宿主机 /etc/hosts 收敛两个受管域名(换环境旧 IP 残留会让 getent 命中旧集群 → 误报失败)。
    #   ensure_hosts_entry 的语义 = 先删该域名**所有**旧行, 再写当前一行(重复行不留存)。
    #   · API_DOMAIN → **api_entry_ip()**(显式 API_ENTRY_IP > kube-vip 已绑 ⇒ VIP > 首个 master)。
    #     ⚠ 不用 API_IP —— 那是"能通 NodePort 的节点 IP"语义(见其定义处注释)。本行原先写的就是
    #     API_IP, 而下面 setup-api-expose.sh 用 api_entry_ip()(双保险的那一半是对的): 两者不一致时
    #     以**后写者**为准, 故宿主机曾长期把 k8s-api.cubestack.io 解析到 192.0.2.28(单点)而不是
    #     已就绪的 VIP 192.0.2.240(2026-09-28 实机)。现两处同源。
    #   · REGISTRY_DOMAIN → REGISTRY_IP(MetalLB VIP; NodePort 模式为派生出的节点 IP)。
    #     补在这里的原因: 本函数是宿主机侧 kubectl/helm 消费者的公共入口(gpu_operator/
    #     multus/rdma/ceph + 接入引导都会走)⇒ 受管域名**每轮安装都收敛一次**, 不必等各自的 addon 模块。
    local _api_entry
    _api_entry="$(api_entry_ip 2>/dev/null)" || _api_entry="${API_IP}"
    ensure_hosts_entry "${_api_entry}" "${API_DOMAIN}"
    [ -n "${REGISTRY_DOMAIN:-}" ] && [ -n "${REGISTRY_IP:-}" ] && \
        ensure_hosts_entry "${REGISTRY_IP}" "${REGISTRY_DOMAIN}"
    # 宿主机 DNAT(6443→first master): 让 API_DOMAIN 从宿主机可达(幂等)
    bash "${SCRIPT_DIR}/tools/lb/setup-api-expose.sh" >/dev/null 2>&1 || \
        sudo bash "${SCRIPT_DIR}/tools/lb/setup-api-expose.sh" >/dev/null 2>&1 || true
    # 校验: 经 API_DOMAIN 访问集群
    if KUBECONFIG="${HOME}/.kube/config" timeout 15 kubectl get nodes --no-headers >/dev/null 2>&1; then
        return 0
    fi
    # ★ 失败时给**可行动**的诊断(2026-09-29 实机, 排查了数小时):
    #   同网段两套集群共用同一个 API VIP(K8S_API_VIP)时, 两边的 kube-vip 都持有该地址 ⇒
    #   到 VIP 的流量**随机落到任一集群的 apiserver** ⇒ kubectl 时好时坏地报
    #   `x509: certificate signed by unknown authority`; 而下面的校验把输出重定向丢了 ⇒
    #   现场只能看到"admin.conf 下载/同步失败", 完全看不出真因。
    #   判据(自包含, 不需要本机有集群 pki): 连取几次 VIP 上的服务端证书指纹 —— 出现**多个不同**指纹
    #   = 该地址被多个 apiserver 共用。
    local _fps="" _i _fp _uniq=0
    if command -v openssl >/dev/null 2>&1; then
        for _i in 1 2 3 4; do
            _fp="$(timeout 8 bash -c "echo | openssl s_client -connect ${API_DOMAIN}:6443 -servername ${API_DOMAIN} 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null" || true)"
            [ -n "${_fp}" ] && _fps="${_fps}${_fp}"$'\n'
            sleep 1
        done
        _uniq="$(printf '%s' "${_fps}" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
    fi
    if [ "${_uniq:-0}" -ge 2 ]; then
        err "  ${API_DOMAIN}:6443 的服务端证书指纹在 4 次探测中**不一致**(共 ${_uniq} 种)⇒ 该地址被**多个 apiserver 共用**!"
        err "  最可能: 同网段还有另一套集群, 其 kube-vip 也持有同一个 K8S_API_VIP(或 MetalLB 池重叠)。"
        err "  处置(二选一): ①给两套集群分配不同的 K8S_API_VIP + METALLB_POOL(cluster.conf), 再重跑;"
        err "              ②先拆除另一套集群(注意: 覆盖安装只会清 inventory 内的节点, 另一套的节点不在其中)"
    elif [ "${_uniq:-0}" = "1" ]; then
        err "  ${API_DOMAIN}:6443 证书指纹稳定 ⇒ 非多集群抢 VIP; 请在 master 本机 kubeconfig 上核对集群健康"
    else
        err "  未能从 ${API_DOMAIN}:6443 取到服务端证书(网络/DNS/openssl 缺失?) —— 请手工复核"
    fi
    return 1
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
        echo -e "\033[41m\033[97m      sudo ./deployments/scripts/tools/offline/fetch-offline-from-minio.sh\033[0m"
        echo -e "\033[41m\033[97m   ② 或手工拷贝离线文件到 ${OFFLINE_FILES_DIR:-deployments/offline-files}/   \033[0m"
        echo -e "\033[41m\033[97m   ③ kubespray 离线资源位于 ${LOCAL_REPO_DIR:-offline-files/kubespray}/    \033[0m"
        echo -e "\033[41m\033[97m      (镜像 images/ + 二进制 + packages/ 系统包)                    \033[0m"
        echo -e "\033[41m\033[97m================================================================\033[0m"
        echo ""
    fi
}

# ---------------- GPU 厂商探测(NVIDIA / 沐曦) ----------------
# 用于“纯 CPU 环境”判定(2026-10-22 用户口径): 只有 **NVIDIA 与沐曦都未检测到**
# 才允许提示“纯 CPU”; 任一厂商有卡都不能称为纯 CPU。
#   NVIDIA: PCI vendor 0x10de(sysfs, 不依赖驱动) → 数量
#   MetaX : mx-smi 'Attached GPUs'(依赖驱动); mx-smi 缺失/执行失败 → unknown
# 输出(stdout): "<nvidia_count> <metax_count|unknown>"
# 用法: read -r nv mx <<< "$(node_gpu_probe <ip> [user])"
# 前置: SSH_KEY 已设置(模块内 init_remote_kubectl 提供); SSH 失败/不可达 → "0 unknown"
node_gpu_probe() {
    local _ip="$1" _u="${2:-$(ssh_user_for_ip "$1")}" _out
    _out="$(ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
              "${_u}@${_ip}" '
        nv=$(grep -l 0x10de /sys/bus/pci/devices/*/vendor 2>/dev/null | wc -l | tr -d " ")
        [ -n "${nv}" ] || nv=0
        if command -v mx-smi >/dev/null 2>&1; then
            if mxout=$(sudo mx-smi 2>/dev/null); then
                mx=$(printf "%s\n" "${mxout}" | awk "/Attached GPUs/{print \$NF}" | tr -d " ")
                [ -n "${mx}" ] || mx=0
            else
                mx=unknown
            fi
        else
            mx=unknown
        fi
        echo "${nv} ${mx}"
    ' 2>/dev/null || echo "0 unknown")"
    printf '%s\n' "${_out:-0 unknown}"
}

# 是否可判定为纯 CPU: NVIDIA 数量为 0 且沐曦明确为 0(unknown 不算纯 CPU)
node_gpu_is_pure_cpu() { [ "${1:-1}" = "0" ] && [ "${2:-unknown}" = "0" ]; }

# 远程探测宿主 NVIDIA 驱动是否**可用**(用于决定 operator 是否走 pre-installed):
#   仅以 `nvidia-smi -L` 成功为 yes —— 必须同时具备内核模块 + 宿主用户态(nvidia-smi/库)。
#   ⚠ 不再用 /proc/driver/nvidia/version 兜底: operator 管理的驱动容器被卸载后, 内核模块
#     会保持加载到重启前, /proc 仍可读, 但宿主并没有可用的 pre-installed 驱动。这种假 yes
#     会让安装器跳过预编译内核门禁/驱动镜像准备 → 重装时 driver DS ImagePullBackOff
#     (2026-10-23 CodeRabbit)。
#   否则 → no; SSH 失败/不可达 → unknown
# 用法: st="$(node_host_nvidia_driver_works <ip> [user])"
# 前置: SSH_KEY 已设置
node_host_nvidia_driver_works() {
    local _ip="$1" _u="${2:-$(ssh_user_for_ip "$1")}" _out
    _out="$(ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
              "${_u}@${_ip}" '
        if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
            echo yes
        else
            echo no
        fi
    ' 2>/dev/null || echo unknown)"
    printf '%s\n' "${_out:-unknown}"
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

# 按 IP 解析该节点在 NODES 中的登录用户(逐行覆盖优先; "-" 已由 node_parse 归一为全局 SSH_USER)。
# 未命中(非 NODES 节点/池外地址) → 回退全局 SSH_USER。
# ★ node_parse 会写 NODE_* 全局量 —— 查找循环放在**命令替换子shell**内, 不污染调用方 shell。
# 用法: u="$(ssh_user_for_ip 10.0.0.1)"
ssh_user_for_ip() {
    local _ip="$1" _hit
    _hit="$(
        local _l
        for _l in "${NODES[@]:-}"; do
            [ -z "${_l}" ] && continue
            node_parse "${_l}"
            [ "${NODE_IP}" = "${_ip}" ] && { printf '%s' "${NODE_USER}"; break; }
        done
    )"
    printf '%s\n' "${_hit:-${SSH_USER:-ubuntu}}"
}

# 一致性点名: NODES 逐行显式 ssh_user 与全局 SSH_USER 不一致时告警(一处点名, 不刷屏)。
# 语义(2026-10-15): SSH_USER = 全局默认; NODES 第4字段显式值 = **该节点**覆盖。
# 逐行覆盖要真正生效, 要求访问该节点的各通道都按 NODES 解析用户(本仓库即席 SSH 已统一走
# ssh_user_for_ip/init_remote_kubectl); 但混用仍是进阶场景, 不一致时点名提醒而不是静默。
# 恒返回 0(不拦停); 由 deploy-cluster.sh 启动预检调用一次。
warn_ssh_user_mismatch() {
    local _list
    _list="$(
        local _l _out=""
        for _l in "${NODES[@]:-}"; do
            [ -z "${_l}" ] && continue
            node_parse "${_l}"
            [ -n "${NODE_HOSTNAME}" ] || continue
            [ "${NODE_USER}" = "${SSH_USER:-ubuntu}" ] && continue
            _out+="${_out:+, }${NODE_HOSTNAME}(${NODE_USER})"
        done
        printf '%s' "${_out}"
    )"
    [ -n "${_list}" ] || return 0
    warn "SSH 用户不一致: 全局 SSH_USER=${SSH_USER:-ubuntu}, 但 NODES 显式覆盖: ${_list}"
    warn "  逐行覆盖仅对该节点生效(其余节点仍用全局 SSH_USER); 通常建议 NODES 第4字段写 \"-\" 跟随全局"
    return 0
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
    # 登录用户按**首个 master 在 NODES 里的解析值**(逐行覆盖优先, 见 ssh_user_for_ip);
    # 未命中/未配置 → 全局 SSH_USER(root|ubuntu 单一旋钮)。
    FIRST_MASTER_USER="$(ssh_user_for_ip "${FIRST_MASTER}")"
    SSH() { ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
               "${FIRST_MASTER_USER}@${FIRST_MASTER}" "$@"; }
    # 字符串式(伪代码/单行命令场景, 如 addon_stub 步骤数组): ssh ... ${FIRST_MASTER_USER}@${FIRST_MASTER}
    SSH_CMD="ssh -i ${SSH_KEY} -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 ${FIRST_MASTER_USER}@${FIRST_MASTER}"
    K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"
    _INIT_REMOTE_KUBECTL=1
    return 0
}

# ---------------- 删除 CRD: 先清残留 CR 的 finalizer, 有界等待, 最后摘 CRD finalizer ----------------
# 背景(2026-10-23 C 集群实机): 平台卸载时组件控制器已先被删, CRD 下仍有 CR
#   (default/devenvironment test 带 ai.cubestack.io/dev-env-finalizer)。`kubectl delete crd`
#   会卡在 apiextensions 的 customresourcecleanup.apiextensions.k8s.io finalizer 上**无限等待**
#   (APIServer 要等该 CRD 下 CR 全部删完; 没有控制器 = 永不满足), 整个 teardown 只能等外层
#   timeout 强杀; 残留的 Terminating CRD 还会挡住重装时 [5/6] 的 CRD apply。
# 做法(幂等, 仅用于卸载/清理语义):
#   ① 摘该 CRD 下所有 CR 的 finalizers(metadata.finalizers=null)
#   ② kubectl delete crd --wait=false
#   ③ 有界轮询(默认 60s, 每 5s): 再摘 CR finalizers + 检查 CRD 是否消失
#   ④ 超时兜底: 摘 CRD 自身 finalizers → 强制删除(残留 CR 会成为孤儿, 但卸载场景宁可清干净)
# ⚠ 循环内调用 SSH 必须接 `< /dev/null`: 否则 ssh 会吞掉 while 的管道输入, 只处理第一条就退出
#   (2026-10-23 _reroll_stuck_pods 同类事故)。
# 用法: delete_crd_with_finalizer_cleanup <crd-name | customresourcedefinition.apiextensions.k8s.io/<crd-name>> [wait-seconds]
# 前置: init_remote_kubectl 已执行(提供 SSH/K)
delete_crd_with_finalizer_cleanup() {
    local crd="${1:-}" wait_s="${2:-60}" i=0
    crd="${crd##*/}"
    [ -n "${crd}" ] || return 0
    case "${wait_s}" in ''|*[!0-9]*) wait_s=60 ;; esac
    # 内部函数: 摘 <crd> 下所有 CR 的 finalizers(命名空间级与集群级都覆盖)
    _crd_clear_cr_finalizers() {
        local items ns name
        items="$( (SSH "${K} get ${crd} -A -o json" 2>/dev/null) || true )"
        [ -n "${items}" ] || return 0
        printf '%s' "${items}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in d.get("items", []) or []:
    md = m.get("metadata", {}) or {}
    print("%s\t%s" % (md.get("namespace", ""), md.get("name", "")))
' 2>/dev/null | while IFS=$'\t' read -r ns name; do
            [ -n "${name}" ] || continue
            if [ -n "${ns}" ]; then
                SSH "${K} -n ${ns} patch ${crd} ${name} --type=merge -p '{\"metadata\":{\"finalizers\":null}}'" >/dev/null 2>&1 < /dev/null || true
            else
                SSH "${K} patch ${crd} ${name} --type=merge -p '{\"metadata\":{\"finalizers\":null}}'" >/dev/null 2>&1 < /dev/null || true
            fi
        done
    }
    # ① 先清一轮(尽量在 CRD 进入 Terminating 前摘掉)
    _crd_clear_cr_finalizers
    # ② 非阻塞删除
    SSH "${K} delete crd ${crd} --ignore-not-found --wait=false" >/dev/null 2>&1 < /dev/null || true
    # ③ 有界等待: CRD 消失即返回; 期间反复清 CR finalizer
    while [ "${i}" -lt "${wait_s}" ]; do
        SSH "${K} get crd ${crd}" >/dev/null 2>&1 < /dev/null || return 0
        _crd_clear_cr_finalizers
        if [ $((i + 5)) -lt "${wait_s}" ]; then sleep 5; fi
        i=$((i + 5))
    done
    # ④ 兜底: 摘 CRD 自身 finalizer, 强制删除(避免整个卸载被一个残留对象拖死)
    warn "  CRD ${crd} 在 ${wait_s}s 内未删净(残留 CR finalizer 拖住 customresourcecleanup) → 摘 CRD finalizer 强制清理"
    SSH "${K} patch crd ${crd} --type=merge -p '{\"metadata\":{\"finalizers\":null}}'" >/dev/null 2>&1 < /dev/null || true
    SSH "${K} delete crd ${crd} --ignore-not-found --wait=false" >/dev/null 2>&1 < /dev/null || true
    return 0
}

# ---------------- Envoy Gateway 数据面 Service 类型对齐 ----------------
# 背景(2026-10-22 实机): CubeStackCluster 的 spec.global.serviceExposeMode 只作用于
#   operator 自己渲染的 Service; Envoy Gateway 数据面 Service 由 EnvoyProxy 决定, 默认
#   LoadBalancer。SERVICE_EXPOSE_MODE=nodeport(无 MetalLB)时公网 Service 会停在
#   LoadBalancer / EXTERNAL-IP <pending>, 公网 Gateway 无地址, Web UI 地址发现回退到
#   私有 ClusterIP(并被误标成 MetalLB)。
# 做法(幂等): 创建/更新 EnvoyProxy(mergeType=StrategicMerge, 保留 chart 的镜像覆盖) →
#   patch 公网 Gateway 的 spec.infrastructure.parametersRef → 等 Service 类型切换。
# 前置: 已调用 init_remote_kubectl(提供 SSH/K)。
# 用法: ensure_envoy_gateway_service_type [nodeport|metallb]
# 返回: 0=服务类型已对齐; 1=未确认(调用方决定 warn/fail)
ensure_envoy_gateway_service_type() {
    local _mode="${1:-${SERVICE_EXPOSE_MODE:-metallb}}"
    local _ns="${CUBESTACK_ENVOY_NAMESPACE:-envoy-gateway-system}"
    local _gw="${CUBESTACK_GATEWAY_NAME:-cubestack-gateway}"
    local _proxy="${CUBESTACK_GATEWAY_PROXY_NAME:-cubestack-proxy}"
    local _type _yaml _st="" _i
    case "${_mode,,}" in
        nodeport) _type="NodePort" ;;
        *)        _type="LoadBalancer" ;;
    esac

    # operator 异步创建公网 Gateway(上界 120s)
    for _i in $(seq 1 24); do
        SSH "${K} -n ${_ns} get gateway ${_gw} >/dev/null 2>&1" && break
        sleep 5
    done
    if ! SSH "${K} -n ${_ns} get gateway ${_gw} >/dev/null 2>&1"; then
        warn "  Envoy Gateway: 未找到公网 Gateway ${_ns}/${_gw}(operator 可能尚未就绪)"
        return 1
    fi

    _yaml="$(cat <<EOF
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: ${_proxy}
  namespace: ${_ns}
  labels:
    cubestack.io/cluster: ${CLUSTER_NAME:-cubestack}
    cubestack.io/component: envoy-gateway
    cubestack.io/managed-by: cubestack-operator
spec:
  mergeType: StrategicMerge
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: ${_type}
EOF
)"
    if ! printf '%s\n' "${_yaml}" | SSH "${K} apply -f - >/dev/null 2>&1"; then
        warn "  Envoy Gateway: EnvoyProxy ${_ns}/${_proxy} apply 失败"
        return 1
    fi

    # 用 stdin 传 patch, 避免 JSON 引号在远端 shell 被拆散
    if ! printf '{"spec":{"infrastructure":{"parametersRef":{"group":"gateway.envoyproxy.io","kind":"EnvoyProxy","name":"%s"}}}}' "${_proxy}" \
            | SSH "${K} -n ${_ns} patch gateway "${_gw}" --type=merge --patch-file=/dev/stdin >/dev/null 2>&1"; then
        warn "  Envoy Gateway: 公网 Gateway ${_gw} 挂载 EnvoyProxy 失败"
        return 1
    fi

    # Envoy Gateway 重建数据面 Service 需要一点时间(上界 120s)
    for _i in $(seq 1 24); do
        _st="$( (SSH "${K} -n ${_ns} get svc -l gateway.envoyproxy.io/owning-gateway-name=${_gw} -o jsonpath='{.items[0].spec.type}' 2>/dev/null" || true) )"
        [ "${_st}" = "${_type}" ] && break
        sleep 5
    done
    if [ "${_st}" = "${_type}" ]; then
        ok "  Envoy Gateway 公网 Service 类型: ${_type}"
        return 0
    fi
    warn "  Envoy Gateway 公网 Service 类型仍为 ${_st:-<未就绪>}(期望 ${_type})"
    return 1
}

# ---------------- RWO 单卷 Deployment 的更新策略守护 ----------------
# 背景(2026-10-19 实机): cubepilot-api 把单个 ReadWriteOnce PVC 挂在 Deployment 上,
#   默认 strategy=RollingUpdate + maxSurge>0 会**先**起新 Pod; 新 Pod 调度到另一节点后
#   无法挂载同一 RWO 卷(attachdetach 报 Multi-Attach, 卷仍被旧 Pod 占用), 而 maxUnavailable
#   又阻止旧 Pod 先退出 → Deployment 永久卡住(1 个旧 Pod Running + 1 个新 Pod ContainerCreating)。
#   正确策略是 Recreate: 先停旧 Pod / 释放卷, 再起新 Pod。
# 本函数在部署/单组件更新后扫描由 CubeStack operator 管理的 Deployment, 只把**确实引用
#   RWO PVC** 的那些改成 strategy=Recreate(幂等; 不碰无 PVC / RWX 的组件)。
# 用法: ensure_rwo_deployments_recreate <namespace> [label-selector] [wait-seconds]
#   wait-seconds: operator 异步创建组件时轮询等待的上界(默认 0 = 只看当前状态)。
#   ⚠ 调用前须已 init_remote_kubectl(提供 SSH/K)。
# 返回: 0=已检查/已纠正(或没有需要纠正的对象); 1=发现对象但 patch 失败。
ensure_rwo_deployments_recreate() {
    local ns="$1" selector="${2:-cubestack.io/managed-by=cubestack-operator}" wait_s="${3:-0}"
    case "${wait_s}" in ''|*[!0-9]*) wait_s=0 ;; esac
    local tries=$(( wait_s / 5 )); [ "${tries}" -ge 1 ] || tries=1
    local json="" targets="" i rc=0

    command -v python3 >/dev/null 2>&1 || { warn "  ensure_rwo_deployments_recreate: 缺少 python3, 跳过"; return 0; }

    for i in $(seq 1 "${tries}"); do
        json="$( (SSH "${K} -n ${ns} get deploy,pvc -l ${selector} -o json 2>/dev/null") || true )"
        # 解析 + 只输出 "namespace/name<TAB>claim1,claim2"(python 代码内不用单引号, 便于 -c)
        targets="$(printf '%s' "${json}" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
pvcs = {}
for item in data.get("items", []):
    if item.get("kind") == "PersistentVolumeClaim":
        pvcs[item["metadata"]["name"]] = item.get("spec", {}).get("accessModes", []) or []
for item in data.get("items", []):
    if item.get("kind") != "Deployment":
        continue
    spec = item.get("spec", {})
    if spec.get("strategy", {}).get("type") == "Recreate":
        continue
    hits = []
    for vol in spec.get("template", {}).get("spec", {}).get("volumes", []) or []:
        claim = (vol.get("persistentVolumeClaim") or {}).get("claimName", "")
        if claim and "ReadWriteOnce" in pvcs.get(claim, []):
            hits.append(claim)
    if hits:
        print(item["metadata"]["namespace"] + "/" + item["metadata"]["name"] + "\t" + ",".join(sorted(set(hits))))
' 2>/dev/null || true)"
        [ -n "${targets}" ] && break
        [ "${i}" -lt "${tries}" ] && sleep 5 || true
    done

    [ -n "${targets}" ] || return 0
    while IFS=$'\t' read -r d claims; do
        [ -n "${d}" ] || continue
        local dns="${d%%/*}" dname="${d#*/}"
        say "  RWO 单卷 Deployment → Recreate: ${d}(claims=${claims})"
        if printf '%s' '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}' \
                | SSH "${K} -n ${dns} patch deploy ${dname} --type=merge --patch-file=/dev/stdin" >/dev/null 2>&1; then
            ok "    已纠正 ${d}(下次滚动先停旧 Pod, 避免 Multi-Attach)"
        else
            warn "    纠正失败: kubectl -n ${dns} patch deploy ${dname} --type=merge -p <Recreate JSON>"
            rc=1
        fi
    done <<< "${targets}"
    return "${rc}"
}

# ---------------- 停消费者前的副本数登记 / 恢复(2026-10-13, CodeRabbit 评审修订) ----------------
# 背景: 覆盖预检/优雅卸载会 scale 0 Ceph 卷消费者(registry / cubestack-operator, 消灭在飞
#   IO), 02_ceph.sh 7.9 事后恢复; 整轮**异常退出**(失败/Ctrl-C)时由 deploy-cluster.sh 的
#   EXIT 钩子兜底(调用 stop_restore_known_consumers)。旧实现"对象存在即 replicas=1"有两个缺陷:
#   ① 任何一次 ceph 模块成功都会执行(即使本轮从未停机) → 把运维手动调整的副本数静默压回 1;
#   ② 停机前副本数若非 1, 恢复时原值丢失。
# 现行契约: **停机方**在 scale 0 前调 stop_mark_replicas 把原副本数写进注解(仅首次; 重复
#   停机不覆盖, 否则第二次时当前已是 0, 会把恢复目标错记成 0); **恢复方**只恢复带注解的
#   对象到记录值并清除注解; 无注解 = 从未被本工具停机 → 一律不动。
# ⚠ 注解键 cubestack.io/pre-stop-replicas 只在本节两函数中出现(单一事实来源), 禁止别处手写。
# ⚠ kind 必须与真实对象一致: registry 是 kubespray 建的**裸 ReplicaSet**(2026-10-13 实机
#   验证: `kubectl -n kube-system get rs registry` 存在, `deploy registry` 不存在 —— 曾致
#   停机/恢复对 registry 全部静默空转), operator 是 helm 装的 Deployment。
# 用法: stop_mark_replicas <deploy|rs> <ns> <name>
#       stop_restore_replicas <deploy|rs> <ns> <name>
stop_mark_replicas() {   # scale 0 前调用; 已登记则保留原值
    local _kind="$1" _ns="$2" _name="$3" _cur _have
    _cur="$( (SSH "${K} -n ${_ns} get ${_kind} ${_name} -o go-template='{{.spec.replicas}}' 2>/dev/null" || true) )"
    [ -n "${_cur}" ] || return 0     # 对象不存在(scale 会空转)
    _have="$( (SSH "${K} -n ${_ns} get ${_kind} ${_name} -o go-template='{{index .metadata.annotations \"cubestack.io/pre-stop-replicas\"}}' 2>/dev/null" || true) )"
    case "${_have}" in
        ''|*[!0-9]*) ;;              # 未登记(含 kubectl 缺失键输出 <no value>/异常值)
        *)           return 0 ;;     # 已登记 → 保留原值
    esac
    SSH "${K} -n ${_ns} annotate ${_kind} ${_name} cubestack.io/pre-stop-replicas=${_cur} >/dev/null 2>&1" \
        && say "     已登记 ${_ns}/${_name} 原副本数=${_cur}(停机前记录, 恢复用)" || true
    return 0
}

stop_restore_replicas() {   # 只恢复带登记注解的对象, 恢复后清除注解
    local _kind="$1" _ns="$2" _name="$3" _n
    _n="$( (SSH "${K} -n ${_ns} get ${_kind} ${_name} -o go-template='{{index .metadata.annotations \"cubestack.io/pre-stop-replicas\"}}' 2>/dev/null" || true) )"
    case "${_n}" in ''|*[!0-9]*) return 0 ;; esac   # 无注解/对象不存在 → 从未停机, 不动
    if SSH "${K} -n ${_ns} scale ${_kind} ${_name} --replicas=${_n} >/dev/null 2>&1"; then
        SSH "${K} -n ${_ns} annotate ${_kind} ${_name} cubestack.io/pre-stop-replicas- >/dev/null 2>&1 || true"
        say "  已恢复 ${_ns}/${_name} replicas=${_n}(此前被覆盖停机)"
    fi
    return 0
}

# 已知 Ceph 卷消费者(operator deploy + registry rs)的**整组恢复** —— 消费者清单只此一份:
#   02_ceph.sh 7.9(成功路径) 与 deploy-cluster.sh 异常退出 EXIT 钩子(失败/Ctrl-C 兜底)共用。
# 依据标记契约, 无标记对象自动跳过(如成功路径上 7.9 已恢复并清标, 钩子再跑即 no-op)。
stop_restore_known_consumers() {
    stop_restore_replicas deploy "${CUBESTACK_OPERATOR_NAMESPACE:-cubestack-system}" \
                                "${CUBESTACK_OPERATOR_RELEASE:-cubestack-operator}" || true
    stop_restore_replicas rs kube-system registry || true
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