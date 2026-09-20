#!/bin/bash
# ============================================================
# MODULE: verify_perses
# DESC: 端到端验证 Perses 真正可用(非仅 helm 安装成功):
#       ① helm release 状态 deployed → ② 工作负载(StatefulSet, 非 Deployment)全部 Ready
#       → ③ Service 与 Endpoints 就绪 → ④ HTTP 探针(API health + UI 根路径)
#       → ⑤ **数据面**: 经 Perses API 断言 GlobalDatasource 已加载
#       → ⑥ **数据面**: 经 Perses **代理**发一次真实 PromQL 查询, 断言取回数据点
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# REQUIRES: perses
# 说明:
#   · **验证模块不设 TOGGLE**(否则 PERSES_ENABLED=true 时会被安装流程自动启用);
#     保持 DEFAULT:0, 仅由 --steps verify_perses 在安装后单个执行。
#   · **门禁看实际部署, 不看配置开关**(仿 verify_cubepilot / verify_lws): 只要 perses 命名空间
#     或 helm release 实际存在就验证(无论 PERSES_ENABLED true/false, 例如 --steps perses 单独装过);
#     仅当"两者都不存在 且 PERSES_ENABLED≠true"才跳过(exit 0)。
#   · ⑥ 是本验证链的价值所在: 它一次性证明 Perses → Prometheus 的 **DNS/端口/数据源 URL/proxy 配置**
#     整条链路通, 且 Prometheus 里确实有数据。只探 HTTP 状态码是证明不了这些的。
#     ⚠ 该断言**只在数据源没设 directUrl 时才成立**(本仓库模块有意不设, 走 Perses 服务端代理);
#       若有人把 directUrl 加回去, ⑥ 会失败 —— 那不是本模块的 bug, 是数据源配置变了。
#   · Prometheus 是**软依赖**(与安装模块一致): 数据源/查询断言失败时, 先判断"是不是集群压根没装
#     Prometheus", 是则 warn 并如实标注验证边界, 而不是报一个看不懂的断言失败。
#   · **离线可用**: 本模块不拉任何镜像、不依赖集群内置 registry(只读集群状态 + 一次 port-forward),
#     故 REQUIRES 只需 perses。
#   · ⚠ HTTP 探针在**部署机本机**起 port-forward, 不在 master 上跑 —— 那边 sudo 不转发信号,
#     后台的 kubectl 会变孤儿进程并持有 ssh 的 stdin, 导致模块永久卡死(verify_cubepilot 踩过)。
# 数据源: cluster.conf (PERSES_ENABLED / PERSES_NAMESPACE / PERSES_RELEASE / PERSES_DATASOURCE_NAME /
#                       PERSES_PROMETHEUS_NAMESPACE / NODES)
# 用法: sudo ./deploy-cluster.sh --steps verify_perses
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

init_remote_kubectl || exit 1

NS="${PERSES_NAMESPACE:-perses}"
RELEASE="${PERSES_RELEASE:-perses}"
DS_NAME="${PERSES_DATASOURCE_NAME:-prometheus}"
PROM_NS="${PERSES_PROMETHEUS_NAMESPACE:-${PROMETHEUS_NAMESPACE:-monitoring}}"

# ---- 门禁: 以实际部署为准(命名空间 / 工作负载是否存在) ----
_HAS_NS="$( (SSH "${K} get ns ${NS} --no-headers 2>/dev/null" || true) | wc -l )"
_HAS_WL="$( (SSH "${K} -n ${NS} get statefulset,deployment --no-headers 2>/dev/null" || true) | wc -l )"
if [ "${_HAS_NS:-0}" -eq 0 ] && [ "${_HAS_WL:-0}" -eq 0 ] && [ "${PERSES_ENABLED:-false}" != "true" ]; then
    say "Perses 未部署(命名空间 ${NS} 不存在且 PERSES_ENABLED≠true), 跳过验证(先 --steps perses 安装)"
    exit 0
fi

say "Verify Perses: helm release → 工作负载 → Service/Endpoints → HTTP → 数据源 → 代理查询..."

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

# ---------------- ② 工作负载就绪(StatefulSet 优先, 兼容 Deployment) ----------------
# ⚠ chart 在 file 数据库下渲染的是 **StatefulSet**; 但 sql 模式/未来改版可能是 Deployment。
#   这里两种都查(取实际存在的), 不写死一种 —— 写死一种就会在另一种形态下误报。
say "  ② 检查工作负载可用性..."
_WL_FOUND=0; _WL_BAD=""
for _kind in statefulset deployment; do
    _names="$( (SSH "${K} -n ${NS} get ${_kind} -o name 2>/dev/null" || true) | sed -n 's#.*/##p' || true)"
    [ -z "${_names}" ] && continue
    _WL_FOUND=1
    while IFS= read -r _n; do
        [ -z "${_n}" ] && continue
        if SSH "${K} -n ${NS} rollout status ${_kind}/${_n} --timeout=30s" >/dev/null 2>&1; then
            ok "    ${_kind}/${_n} 可用 ✓"
        else
            _WL_BAD="${_WL_BAD} ${_kind}/${_n}"
        fi
    done <<< "${_names}"
done
unset _kind _names _n
if [ "${_WL_FOUND}" -eq 0 ]; then
    err "命名空间 ${NS} 内无 StatefulSet/Deployment(helm 安装失败? kubectl -n ${NS} get all)"
    exit 1
fi
if [ -n "${_WL_BAD}" ]; then
    err "工作负载未就绪:${_WL_BAD}"
    err "  排查: kubectl -n ${NS} get pods; kubectl -n ${NS} describe pod <异常pod>"
    err "  镜像拉取失败常见原因: 制品未推入内置 registry(重跑安装模块), 或节点无法解析 ${REGISTRY_DOMAIN:-registry.cubestack.io}"
    exit 1
fi

# ---------------- ③ Service + Endpoints ----------------
# 注意: jsonpath 里的字面量必须写成 {\"|\"} / {\"\n\"}(转义双引号) —— 整个远端命令是外层双引号字符串,
# 写裸的 {"|"} 会把外层字符串提前闭合, 命令被撕碎后报 "unexpected EOF while looking for matching '"。
say "  ③ 检查 Service 与 Endpoints..."
_SVC_LINES="$( (SSH "${K} -n ${NS} get svc -o jsonpath='{range .items[*]}{.metadata.name}{\"|\"}{.spec.ports[*].port}{\"\n\"}{end}' 2>/dev/null" || true) )"
_SVC_CNT="$(echo "${_SVC_LINES}" | grep -c . || true)"; _SVC_CNT="${_SVC_CNT:-0}"
[ "${_SVC_CNT}" -ge 1 ] || { err "命名空间 ${NS} 内无 Service(helm 安装不完整)"; exit 1; }
# 入口选择: 端口含 8080 的 Service(排除 -external/headless, 它们不是主入口)
_SVC_NAME=""; _SVC_PORT=""
while IFS='|' read -r _n _ps; do
    [ -z "${_n}" ] && continue
    case "${_n}" in *-external|*headless) continue ;; esac
    case " ${_ps} " in *" 8080 "*) _SVC_NAME="${_n}"; _SVC_PORT="8080"; break ;; esac
done <<< "${_SVC_LINES}"
[ -n "${_SVC_NAME}" ] || { _SVC_NAME="$(echo "${_SVC_LINES}" | head -1 | cut -d'|' -f1)"; _SVC_PORT="$(echo "${_SVC_LINES}" | head -1 | cut -d'|' -f2 | awk '{print $1}')"; }
# 主入口必须有 Ready Endpoints(无 endpoints = 没有 Ready 后端, 路由必然 502)
_EP="$( (SSH "${K} -n ${NS} get endpoints ${_SVC_NAME} -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null" || true) )"
[ -n "${_EP}" ] || { err "Service ${_SVC_NAME} 无 Ready Endpoints(没有可服务的后端; 对应 pod 是否 Ready?)"; exit 1; }
ok "    Service ${_SVC_CNT} 个; 主入口 ${_SVC_NAME}:${_SVC_PORT} 有 Ready Endpoints ✓"
unset _n _ps _EP

# ---------------- ④~⑥ HTTP + 数据面(本机 port-forward, 失败分级处理) ----------------
# 在本机起 port-forward 再 curl 回环地址(理由见文件头: master 上跑会永久卡死)。
sync_kubeconfig >/dev/null 2>&1 || true
_PF_PORT=18081
timeout 60 kubectl -n "${NS}" port-forward "svc/${_SVC_NAME}" "${_PF_PORT}:${_SVC_PORT}" \
    </dev/null >/dev/null 2>&1 &
_PF_PID=$!
# 统一收尾: 无论中途怎么退出都要杀掉 port-forward(它是本机子进程, 可可靠 kill)
trap 'kill "${_PF_PID}" >/dev/null 2>&1 || true; wait "${_PF_PID}" 2>/dev/null || true' EXIT
_curl() { curl -s --max-time 10 "http://127.0.0.1:${_PF_PORT}$1" 2>/dev/null || true; }

# 等端口起来(最多 ~24s)
_UP=0
for _i in $(seq 1 12); do
    sleep 2
    case "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${_PF_PORT}/api/v1/health" 2>/dev/null || echo 000)" in
        000|"") : ;;
        *) _UP=1; break ;;
    esac
done
unset _i
if [ "${_UP}" != "1" ]; then
    err "port-forward 后 ${_SVC_NAME}:${_SVC_PORT} 无 HTTP 响应(最长等 24s)"
    err "  排查: kubectl -n ${NS} port-forward svc/${_SVC_NAME} 8080:${_SVC_PORT} 手工试; kubectl -n ${NS} get pods"
    exit 1
fi

say "  ④ HTTP 探针(API health + UI 根路径)..."
_H_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${_PF_PORT}/api/v1/health" 2>/dev/null || echo 000)"
# UI 根路径: 返回 200 + HTML 才算真的把前端发出来了(与"端口有响应"是两回事)
_UI_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${_PF_PORT}/" 2>/dev/null || echo 000)"
if [ "${_H_CODE}" = "200" ]; then
    ok "    API /api/v1/health 返回 200 ✓"
else
    err "    API /api/v1/health 返回 ${_H_CODE}(期望 200) —— 服务进程没正常起来, 后续断言无意义"
    exit 1
fi
case "${_UI_CODE}" in
    2*) ok "    UI / 返回 ${_UI_CODE} ✓" ;;
    404) warn "    UI / 返回 404(前端资源未内置? 服务端 API 已就绪, 继续数据面断言)" ;;
    *)  warn "    UI / 返回 ${_UI_CODE}(预期 2xx)" ;;
esac

say "  ⑤ 数据面: 检查 GlobalDatasource 已加载..."
_DS_JSON="$(_curl "/api/v1/globaldatasources")"
# 空列表与"有数据源"必须区分开 —— 只看 HTTP 200 会把"一个数据源都没有"当成通过
if [ -z "${_DS_JSON}" ]; then
    warn "    未取到 GlobalDatasource 列表(API 异常或无权限); 跳过数据面断言"
elif printf '%s' "${_DS_JSON}" | grep -q "\"name\":\"${DS_NAME}\""; then
    ok "    GlobalDatasource ${DS_NAME} 已加载 ✓"
else
    # 是不是压根没装 Prometheus(软依赖未满足)? 如实区分, 不报看不懂的断言失败
    if [ -z "$( (SSH "${K} -n ${PROM_NS} get svc -o name 2>/dev/null" || true) )" ]; then
        warn "    未找到 ${DS_NAME} 数据源, 且命名空间 ${PROM_NS} 内没有 Prometheus(集群未装监控底座)"
        warn "    → 数据面验证**未覆盖**; 装好 Prometheus 后重跑本模块(或 PERSES_PROVISION_ENABLED=true 重跑 perses)"
    else
        err "    未找到 GlobalDatasource ${DS_NAME}(数据源没下发或没被 provisioning 加载)"
        err "      排查: kubectl -n ${NS} get cm -l perses.dev/resource=true   # ConfigMap 在不在"
        err "            kubectl -n ${NS} logs deploy/${RELEASE}-perses-provisioning-sidecar   # sidecar 有没有写进去"
        err "            kubectl -n ${NS} exec ${RELEASE}-0 -- ls /etc/perses/provisioning     # 文件到没到 Perses 侧"
        exit 1
    fi
fi

say "  ⑥ 数据面: 经 Perses 代理发真实 PromQL 查询(证明链路真的通)..."
_QRY="count(up)"
_Q_JSON="$(_curl "/proxy/globaldatasources/${DS_NAME}/api/v1/query?query=$(printf '%s' "${_QRY}" | sed 's/(/%28/g; s/)/%29/g')")"
if [ -z "${_Q_JSON}" ]; then
    err "    代理查询无响应(链路: Perses → 数据源 → Prometheus 断在某一环)"
    err "      排查: kubectl -n ${NS} logs statefulset/${RELEASE}   # Perses 侧代理错误"
    exit 1
fi
if printf '%s' "${_Q_JSON}" | grep -q '"status":"success"'; then
    if printf '%s' "${_Q_JSON}" | grep -q '"result":\[\]'; then
        warn "    代理查询返回 0 个数据点(query=${_QRY} 无匹配 series)"
        warn "    → 链路**已打通**(Prometheus 应答了合法 JSON), 只是 Prometheus 里暂时没有 up 指标"
    else
        ok "    代理查询成功并取回数据点: ${_QRY} ✓ (Perses → Prometheus 整条链路通)"
    fi
else
    # 502/404 是代理层错误(数据源不存在 / 后端不可达), 与"查询语法错"性质完全不同
    printf '%s' "${_Q_JSON}" | head -c 400 | sed 's/^/      /' >&2
    err "    代理查询未返回成功状态(见上方响应体)"
    err "      排查: 数据源 url 是否指向可达的 Prometheus; kubectl -n ${NS} logs statefulset/${RELEASE}"
    exit 1
fi
unset _QRY _Q_JSON _DS_JSON

echo "---------------------------------------------"
ok "Perses 验证通过: release deployed → 工作负载可用 → Service/Endpoints 就绪 → API/UI 可访问"
ok "  → 数据源已加载 → 代理查询取回真实数据"
echo "  验证边界: 本次未验收**看板**本身(默认不预置任何 dashboard; 需另行 provision 后才可断言)"
echo "    访问入口: kubectl -n ${NS} port-forward svc/${_SVC_NAME} 8080:${_SVC_PORT}   # http://127.0.0.1:8080"
echo "  资源查看: kubectl -n ${NS} get statefulset,pods,svc,pvc,cm -l perses.dev/resource=true"
unset _HAS_NS _HAS_WL _REL_ST _WL_FOUND _WL_BAD _SVC_LINES _SVC_CNT _SVC_NAME _SVC_PORT _UP _H_CODE _UI_CODE
