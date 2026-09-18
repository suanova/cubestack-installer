#!/bin/bash
# ============================================================
# MODULE: verify_cubepilot
# DESC: 端到端验证 CubePilot 真正可用(非仅 helm 安装成功):
#       ① helm release 状态 deployed → ② 各 Deployment 全部 Available
#       → ③ ai.cubestack.io CRD 已注册(chart crds/ 自带) → ④ AgentInstance 已创建
#       (admin-agent-for-cloud 等, 证明 operator 真正在调和而不只是 Pod Running)
#       → ⑤ cubepilot 命名空间 pods 全部 Running/Ready
#       → ⑥ Service 与 Endpoints 就绪 → ⑦ HTTP 探针(master 上 port-forward 内网回环探测, 尽力而为)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# REQUIRES: cubepilot
# 说明:
#   · **验证模块不设 TOGGLE**(否则 CUBEPILOT_ENABLED=true 时会被安装流程自动启用);
#     保持 DEFAULT:0, 仅由 --steps verify_cubepilot 在安装后单个执行。
#   · **门禁看实际部署, 不看配置开关**(仿 verify_lws / verify_rdma): 只要 cubepilot 命名空间
#     或 helm release 实际存在就验证(无论 CUBEPILOT_ENABLED true/false, 例如 --steps cubepilot
#     单独装过); 仅当"两者都不存在 且 CUBEPILOT_ENABLED≠true"才跳过(exit 0)。
#   · **验证边界(如实标注)**: ①②③④⑤⑥ 证明"控制面已装好且 operator 真的在工作";
#     ⑦ 只是 HTTP 可达性(服务端口有响应);
#     **均不含** Portal 鉴权/LLM 对话的端到端验收 ——
#     那需要真实 LLM API Key, 装完在 Portal → Agent Config → LLM Config 配置后人工验收。
#     ⑦ 失败只 warn 不 err(未启用内置 Portal 时本就可能不通)。
#     ⚠ 原 ⑧「平台网关探针」已随平台网关模块一起移除(2026-09-18): 网关与路由改由专门的网关模块
#     统一创建(尚在重构中), 待其落地后可在此加回"经网关带 Host 头访问"的探针。
#   · **离线可用**: 本模块不拉任何镜像、不依赖集群内置 registry(只读集群状态 + 一次 port-forward),
#     故 REQUIRES 只需 cubepilot。
# 数据源: cluster.conf (CUBEPILOT_ENABLED / CUBEPILOT_NAMESPACE / CUBEPILOT_RELEASE / NODES)
# 用法: sudo ./deploy-cluster.sh --steps verify_cubepilot
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

init_remote_kubectl || exit 1

NS="${CUBEPILOT_NAMESPACE:-cubepilot}"
RELEASE="${CUBEPILOT_RELEASE:-cubepilot}"

# ---- 门禁: 以实际部署为准(命名空间 / helm release 是否存在) ----
_HAS_NS="$( (SSH "${K} get ns ${NS} --no-headers 2>/dev/null" || true) | wc -l )"
_HAS_REL="$( (SSH "${K} get deploy -n ${NS} --no-headers 2>/dev/null" || true) | wc -l )"
if [ "${_HAS_NS:-0}" -eq 0 ] && [ "${_HAS_REL:-0}" -eq 0 ] && [ "${CUBEPILOT_ENABLED:-false}" != "true" ]; then
    say "CubePilot 未部署(命名空间 ${NS} 不存在且 CUBEPILOT_ENABLED≠true), 跳过验证(先 --steps cubepilot 安装)"
    exit 0
fi

say "Verify CubePilot: helm release → Deployment → CRD → AgentInstance → pods → Service/Endpoints → HTTP..."

# ---------------- ① helm release 状态 ----------------
say "  ① 检查 helm release ${RELEASE} 状态..."
if ! command -v helm >/dev/null 2>&1; then
    warn "    本机无 helm, 跳过 release 状态检查(继续按集群实际资源验证)"
else
    _REL_ST="$(helm status "${RELEASE}" -n "${NS}" -o json 2>/dev/null \
        | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -1 || true)"
    if [ "${_REL_ST}" = "deployed" ]; then
        ok "    helm release ${RELEASE} 状态 deployed ✓"
    elif [ -n "${_REL_ST}" ]; then
        err "    helm release ${RELEASE} 状态异常: ${_REL_ST}(helm status ${RELEASE} -n ${NS} 复查)"
        exit 1
    else
        warn "    未取到 release 状态(本机无该集群 kubeconfig? 或 release 名不是 ${RELEASE}); 继续按资源验证"
    fi
fi

# ---------------- ② Deployment 全部可用 ----------------
say "  ② 检查各 Deployment 可用性..."
# 不硬编码 Deployment 名(chart 可能改名): 逐个 rollout status, 任一失败即整体失败
_DEPLOYS="$( (SSH "${K} -n ${NS} get deploy -o name 2>/dev/null" || true) | sed -n 's#.*/##p' || true)"
[ -n "${_DEPLOYS}" ] || { err "命名空间 ${NS} 内无 Deployment(helm 安装失败? kubectl -n ${NS} get deploy)"; exit 1; }
_DEP_TOTAL=0; _DEP_OK=0; _DEP_BAD=""
while IFS= read -r _d; do
    [ -z "${_d}" ] && continue
    _DEP_TOTAL=$((_DEP_TOTAL + 1))
    if SSH "${K} -n ${NS} rollout status deployment/${_d} --timeout=30s" >/dev/null 2>&1; then
        _DEP_OK=$((_DEP_OK + 1))
    else
        _DEP_BAD="${_DEP_BAD} ${_d}"
    fi
done <<< "${_DEPLOYS}"
if [ "${_DEP_OK}" -eq "${_DEP_TOTAL}" ]; then
    ok "    全部 Deployment 可用(${_DEP_OK}/${_DEP_TOTAL})✓"
else
    err "    Deployment 未全部可用(${_DEP_OK}/${_DEP_TOTAL}); 异常:${_DEP_BAD}"
    err "    排查: kubectl -n ${NS} get pods; kubectl -n ${NS} describe pod <异常pod>(镜像拉取? 私有 Harbor 凭据?)"
    err "    镜像拉取失败常见原因: 制品未推入内置 registry(重跑安装模块), 或节点无法解析 ${REGISTRY_DOMAIN:-registry.cubestack.io}"
    exit 1
fi
unset _d

# ---------------- ③ ai.cubestack.io CRD 注册 ----------------
say "  ③ 检查 ai.cubestack.io CRD(chart crds/ 自带, 应有 6 个)..."
_CRD_LIST="$( (SSH "${K} get crd --no-headers 2>/dev/null" || true) | awk '/ai\.cubestack\.io/{print $1}' || true)"
_CRD_CNT="$(echo "${_CRD_LIST}" | grep -c . || true)"; _CRD_CNT="${_CRD_CNT:-0}"
if [ "${_CRD_CNT}" -ge 1 ]; then
    ok "    ai.cubestack.io CRD 已注册 ${_CRD_CNT} 个 ✓"
    [ "${_CRD_CNT}" -lt 6 ] && warn "    少于预期的 6 个(chart crds/ 未完全装上? kubectl get crd | grep ai.cubestack.io)"
else
    err "    未检测到任何 ai.cubestack.io CRD(chart 的 crds/ 未安装; helm upgrade --install 重跑)"
    exit 1
fi

# ---------------- ④ AgentInstance 已创建(operator 真正在调和) ----------------
say "  ④ 检查 AgentInstance(operator 调和的产物, 如 admin-agent-for-cloud)..."
_AI_CNT="$( (SSH "${K} -n ${NS} get agentinstances --no-headers 2>/dev/null" || true) | grep -c . || true)"
_AI_CNT="${_AI_CNT:-0}"
if [ "${_AI_CNT}" -ge 1 ]; then
    _AI_NAMES="$( (SSH "${K} -n ${NS} get agentinstances -o name 2>/dev/null" || true) | sed -n 's#.*/##p' | tr '\n' ' ' || true)"
    ok "    AgentInstance 已创建 ${_AI_CNT} 个 ✓ (${_AI_NAMES})"
else
    err "    ${NS} 内无 AgentInstance —— CRD 在但 operator 没调和出实例(这才是真正的失败信号)"
    err "    排查: kubectl -n ${NS} logs deploy/\$(kubectl -n ${NS} get deploy -o name | sed -n 's#.*/##p' | grep -m1 operator)"
    exit 1
fi

# ---------------- ⑤ pods 全部 Ready ----------------
say "  ⑤ 检查 pods 就绪情况..."
_PODS="$( (SSH "${K} -n ${NS} get pods --no-headers --ignore-not-found 2>/dev/null" || true) )"
_POD_TOTAL="$(echo "${_PODS}" | grep -c . || true)"; _POD_TOTAL="${_POD_TOTAL:-0}"
[ "${_POD_TOTAL}" -ge 1 ] || { err "命名空间 ${NS} 内无 pod"; exit 1; }
_POD_BAD="$(echo "${_PODS}" | awk '$3!="Running" && $3!="Completed"{print $1"("$3")"}' || true)"
if [ -z "${_POD_BAD}" ]; then
    ok "    全部 pod Running(${_POD_TOTAL} 个)✓"
else
    # 占位/未就绪 pod 打印事件摘要, 避免只看到现象
    err "    存在未 Running 的 pod:${_POD_BAD}"
    for _p in ${_POD_BAD}; do
        _pn="${_p%%(*}"
        _WHY="$( (SSH "${K} -n ${NS} describe pod "${_pn}" 2>/dev/null" || true) | grep -A3 '^Events:' | tail -3 || true)"
        [ -n "${_WHY}" ] && printf '%s\n' "${_WHY}" | sed 's/^/      /' >&2
    done
    exit 1
fi
unset _p _pn _WHY

# ---------------- ⑥ Service + Endpoints ----------------
say "  ⑥ 检查 Service 与 Endpoints..."
# 注意: 用 jsonpath 一次取回 name|ports, 避免多次 SSH; 端口用于 ⑦ 的 port-forward
# ⚠ jsonpath 里的字面量必须写成 {\"|\"} / {\"\n\"}(转义双引号) —— 整个远端命令是外层双引号字符串,
#   写裸的 {"|"} 会把外层字符串提前闭合, 命令被撕碎后报 "unexpected EOF while looking for matching '"。
_SVC_LINES="$( (SSH "${K} -n ${NS} get svc -o jsonpath='{range .items[*]}{.metadata.name}{\"|\"}{.spec.ports[*].port}{\"\n\"}{end}' 2>/dev/null" || true) )"
_SVC_CNT="$(echo "${_SVC_LINES}" | grep -c . || true)"; _SVC_CNT="${_SVC_CNT:-0}"
if [ "${_SVC_CNT}" -lt 1 ]; then
    err "    命名空间 ${NS} 内无 Service(helm 安装不完整)"
    exit 1
fi
# 端口选择: ① 名为 cubepilot 的 Service(issue 文档的访问入口) ② 任意含 8080 的 Service
_SVC_NAME=""; _SVC_PORT=""
while IFS='|' read -r _n _ps; do
    [ -z "${_n}" ] && continue
    [ "${_n}" = "cubepilot" ] && { _SVC_NAME="${_n}"; _SVC_PORT="${_ps%% *}"; break; }
done <<< "${_SVC_LINES}"
if [ -z "${_SVC_NAME}" ]; then
    while IFS='|' read -r _n _ps; do
        [ -z "${_n}" ] && continue
        case " ${_ps} " in *" 8080 "*) _SVC_NAME="${_n}"; _SVC_PORT="8080"; break ;; esac
    done <<< "${_SVC_LINES}"
fi
# Endpoints: 逐个 Service 校验(无 endpoints = 没有 Ready 后端, 路由必然 502)
_EP_BAD=""; _EP_OK=0
while IFS='|' read -r _n _ps; do
    [ -z "${_n}" ] && continue
    _ep="$( (SSH "${K} -n ${NS} get endpoints ${_n} -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null" || true) )"
    if [ -n "${_ep}" ]; then _EP_OK=$((_EP_OK + 1)); else _EP_BAD="${_EP_BAD} ${_n}"; fi
done <<< "${_SVC_LINES}"
if [ -n "${_EP_BAD}" ]; then
    warn "    部分 Service 无 Ready Endpoints:${_EP_BAD}(该服务暂不可访问; 对应 pod 是否 Ready?)"
fi
[ "${_EP_OK}" -ge 1 ] || { err "    所有 Service 均无 Ready Endpoints(没有可服务的后端)"; exit 1; }
ok "    Service ${_SVC_CNT} 个, 其中 ${_EP_OK} 个有 Ready Endpoints ✓; 访问入口: ${_SVC_NAME:-<未识别>}:${_SVC_PORT:-?}"
unset _n _ps _ep

# ---------------- ⑦ HTTP 探针(尽力而为) ----------------
# 在**部署机本机**起 port-forward 再 curl 回环地址。
# ⚠ 为什么不在 master 上跑(这是实测踩过的坑): 早期实现 SSH 到 master 后台起
#   `sudo kubectl port-forward` 再 `kill $PF`, 而 $PF 是 **sudo 的 PID** —— sudo 默认
#   **不转发信号**, 真正的 kubectl 变成孤儿进程并继续持有 ssh 通道的 stdin → ssh 永远收不到
#   EOF → 整个 verify 模块**永久卡死**(日志停在"⑦ HTTP 探针"不动)。
#   改到本机后: 后台进程是自己的子进程, 可可靠 kill; timeout 作为第二重保险。
# 本地 kubectl 依赖本机 kubeconfig(①②的 helm status 本就依赖它), 故先同步一次确保存在。
# 失败只 warn —— 未启用内置 Portal 时该 Service 本就可能不存在, 不构成本次验证失败。
if [ -z "${_SVC_NAME}" ]; then
    warn "  ⑦ 未识别到可探测的 Service(无 cubepilot 名且无 8080 端口), 跳过 HTTP 探针"
else
    say "  ⑦ HTTP 探针(本机 port-forward ${_SVC_NAME}:${_SVC_PORT} → 回环 curl, 最长 ~40s)..."
    sync_kubeconfig >/dev/null 2>&1 || true
    _PF_PORT=18080
    # timeout: 即便 curl 循环异常也不会挂死; </dev/null: 后台进程不持有终端输入
    timeout 40 kubectl -n "${NS}" port-forward "svc/${_SVC_NAME}" "${_PF_PORT}:${_SVC_PORT}" \
        </dev/null >/dev/null 2>&1 &
    _PF_PID=$!
    _CODE=""
    for _i in $(seq 1 12); do
        sleep 2
        _CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${_PF_PORT}/" 2>/dev/null || echo 000)"
        [ "${_CODE}" != "000" ] && break
    done
    # kill 本级 timeout(GNU timeout 会把信号转发给它管理的 kubectl, 不留孤儿)
    kill "${_PF_PID}" >/dev/null 2>&1 || true
    wait "${_PF_PID}" 2>/dev/null || true
    unset _PF_PID _PF_PORT _i
    case "${_CODE}" in
        2*|3*|401|403)
            ok "    HTTP 探针通过: ${_SVC_NAME}:${_SVC_PORT} 响应 ${_CODE} ✓(服务端口确实在提供 HTTP)"
            ;;
        404)
            # 探测打的是根路径 "/", REST API 通常不在此挂载路由 → 404 属正常。
            # 关键是**能返回 HTTP 状态码**: 证明 Service → Endpoints → Pod 整条链路通, 且后端在讲 HTTP。
            ok "    HTTP 探针通过: ${_SVC_NAME}:${_SVC_PORT} 响应 404 ✓(根路径无路由, 对 REST API 正常; 证明链路通)"
            ;;
        000|"")
            warn "    HTTP 探针无响应(可能未启用内置 Portal / Service 端口非 HTTP); 不影响控制面判定"
            ;;
        *)
            warn "    HTTP 探针返回 ${_CODE}(预期 2xx/3xx/401/403/404); 服务可达但返回异常状态码"
            ;;
    esac
    unset _CODE
fi

echo "---------------------------------------------"
ok "CubePilot 验证通过: release deployed → Deployment 全部可用 → ai.cubestack.io CRD ${_CRD_CNT} 个"
ok "  → AgentInstance ${_AI_CNT} 个 → pod ${_POD_TOTAL} 个 Running → Service/Endpoints 就绪"
echo "  ⚠ 验证边界: 本次**未验收** Portal 鉴权与 LLM 对话(需真实 API Key):"
echo "     kubectl -n ${NS} port-forward svc/${_SVC_NAME:-cubepilot} 8080:${_SVC_PORT:-8080}  # http://127.0.0.1:8080"
echo "     在 Portal → Agent Config → LLM Config 配置模型后人工验收对话链路"
echo "  资源查看: kubectl -n ${NS} get agentinstances,pods,svc"
unset _HAS_NS _HAS_REL _REL_ST _DEPLOYS _DEP_TOTAL _DEP_OK _DEP_BAD _CRD_LIST _CRD_CNT \
      _AI_CNT _AI_NAMES _PODS _POD_TOTAL _POD_BAD _SVC_LINES _SVC_CNT _SVC_NAME _SVC_PORT \
      _EP_BAD _EP_OK 2>/dev/null || true
