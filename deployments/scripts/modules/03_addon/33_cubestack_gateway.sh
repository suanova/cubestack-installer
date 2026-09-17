#!/bin/bash
# ============================================================
# MODULE: cubestack_gateway
# DESC: 平台统一网关 cubestack-gateway(单 Gateway + 单 HTTP Listener + 多 hostname;
#       每服务一条 HTTPRoute 跨 ns 绑定, 替代"每组件一个 *-external NodePort"的分散暴露)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: CUBESTACK_GATEWAY_ENABLED
# REQUIRES: envoy_gateway
# 说明:
#   · 复用 EG 的 GatewayClass eg(**不重复建 class**), 基座 =
#     deployments/cubestack-addon/gateway/base-gateway.yaml(Namespace cubestack-gateway-system
#     + Gateway cubestack-gateway, listener:80, service-type=NodePort 注解持久声明)。
#     数据面(envoy-<ns>-<gw>-<hash> Deployment/Service)由 EG 控制器按 Gateway 动态生成,
#     数据面 Service 落在 **EG 控制面命名空间**(envoy-gateway-system), 非 Gateway 命名空间。
#   · 路由: deployments/cubestack-addon/gateway/routes/*.yaml 逐文件 apply(幂等);
#     每条路由在下面 case 里声明下发条件(组件未部署则跳过, 不给网关留 ResolvedRefs=False 噪音):
#       monitoring.yaml        ← PROMETHEUS_ENABLED
#       cubepilot.yaml         ← CUBEPILOT_ENABLED             (API: cubepilot-api.cubestack.io)
#       cubepilot-portal.yaml  ← CUBEPILOT_ENABLED && CUBEPILOT_WEB_ENABLED (UI: cubepilot.cubestack.io)
#     新增对外服务只需在 routes/ 加一条 HTTPRoute + 这里加一条门控, 本基座与其余逻辑都不动。
#   · ★ 序号 33 = **必须排在所有组件模块之后**(原来叫 18_cubestack_gateway.sh):
#     路由落在后端组件自己的命名空间里, 排在组件之前时 apply 会因 "namespaces not found" 失败 ——
#     2026-09-17 实机: cubepilot 路由就是这么丢的(apply 比模块 31 建 ns 早 16 秒), 当时只落一行
#     warn 就继续, 全量日志里被淹没, HTTPRoute 从未落地。现加"后端存在性预检"(见 [5/7]),
#     预检不过会明确跳过 + 汇总里提示"部署组件后重跑本模块即下发"。
#     ⚠ 新增组件模块请用**小于本模块的序号**(或部署后重跑 --steps cubestack_gateway 补下发)。
#   · 固定入口: 默认跑 tools/lb/gateway-nodeport.sh 建固定名别名 <gw>-external, 端口 =
#     CUBESTACK_GATEWAY_NODEPORT(默认 30080; 与 AI 示例网关的 GATEWAY_EXTERNAL_NODEPORT=30880
#     区分, 避免同一节点 NodePort 冲突)。不想建固定别名置 CUBESTACK_GATEWAY_FIXED_ENTRY=false。
#   · 部署机 /etc/hosts(第 [7/7] 步): 把**已下发路由**里的 hostnames 写到部署机 /etc/hosts,
#     指向网关访问入口 —— 与 registry.cubestack.io / k8s-api.cubestack.io 同一套做法
#     (lib-common 的 ensure_hosts_entry, 先删同域名旧行再写):
#       nodeport → 第一个 master IP;  metallb → 数据面别名 Service 的 MetalLB VIP。
#     ⚠ /etc/hosts 不映射端口: nodeport 模式仍需带 NodePort 访问(http://<host>:30080/)。
#   · REPEAT:1(非断点续跑): 本模块是**声明式 apply**(幂等, 秒级), 每次执行重新收敛 ——
#     用户加了新 HTTPRoute 后重跑 --steps cubestack_gateway 即生效, 不会被"已完成"状态挡住。
#   · ⚠ 2026-09-16 事故根因: 本次提交(1cfbcf0)只落地了 base-gateway.yaml + routes/ + README,
#     **没有配套模块脚本** —— 框架按 modules/NN_*/NN_*.sh 自动发现, 无文件即无步骤, 全量重装后
#     cubestack-gateway-system/网关/路由全部不存在(当时"实机验证通过"是手工 kubectl apply 的结果,
#     不可复现)。本模块即为补上的自动化。
#   · ⚠ 2026-09-17 同类第二次: 模块在、但 cluster.conf 的 CUBESTACK_GATEWAY_ENABLED=false
#     → TOGGLE 未开 → 模块**不进 RUN_STEPS**: 不执行、不打印、不写 state, 部署"全绿结束"而
#     cubestack-gateway-system 等资源全部缺失。现框架收尾会汇总"本次未部署的组件"
#     (lib-module.sh print_undeployed_summary), 且 cluster.conf.example 默认已改 true。
# 数据源: cluster.conf (CUBESTACK_GATEWAY_ENABLED / CUBESTACK_GATEWAY_FIXED_ENTRY /
#                       CUBESTACK_GATEWAY_NODEPORT / CUBESTACK_GATEWAY_NODEPORT_MAX /
#                       PROMETHEUS_ENABLED / PROMETHEUS_RELEASE_NAME /
#                       CUBEPILOT_ENABLED / CUBEPILOT_WEB_ENABLED /
#                       SERVICE_EXPOSE_MODE / NODES)
# 用法:   sudo ./deploy-cluster.sh --steps cubestack_gateway
#         或 cluster.conf 置 CUBESTACK_GATEWAY_ENABLED=true(全量部署时一并创建)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if [ "${CUBESTACK_GATEWAY_ENABLED:-false}" != "true" ]; then
    say "跳过平台统一网关 cubestack-gateway(配置 CUBESTACK_GATEWAY_ENABLED=true 可启用)"
    exit 0
fi

init_remote_kubectl || exit 1

ENVOY_GATEWAYCLASS="${ENVOY_GATEWAYCLASS:-eg}"                          # 与模块 15/16 同一个 EG class
GATEWAY_DIR="${REPO_ROOT}/deployments/cubestack-addon/gateway"
BASE_GATEWAY="${GATEWAY_DIR}/base-gateway.yaml"
ROUTES_DIR="${GATEWAY_DIR}/routes"
GW_NS="cubestack-gateway-system"                                        # 与 base-gateway.yaml 一致
NODEPORT_TOOL="${SCRIPT_DIR}/tools/lb/gateway-nodeport.sh"

# ── [1/7] 前置检查(Gateway API CRD / GatewayClass / 基座文件) ──
say "[1/7] 前置检查(Gateway API CRD / GatewayClass ${ENVOY_GATEWAYCLASS} / 基座文件)..."
[ -f "${BASE_GATEWAY}" ] || { err "基座 YAML 缺失: ${BASE_GATEWAY}(应随仓库提供: deployments/cubestack-addon/gateway/)"; exit 1; }
SSH "${K} get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1" \
    || { err "Gateway API CRD 未安装(先部署 Envoy Gateway: --steps envoy_gateway)"; exit 1; }
[ -n "$( (SSH "${K} get gatewayclass ${ENVOY_GATEWAYCLASS} --no-headers 2>/dev/null" || true) )" ] \
    || { err "GatewayClass ${ENVOY_GATEWAYCLASS} 不存在(先部署 Envoy Gateway: --steps envoy_gateway)"; exit 1; }
ok "  前置满足(CRD 已装; GatewayClass ${ENVOY_GATEWAYCLASS} 存在)"

# ── [2/7] 下发基座(Namespace + Gateway) ──
say "[2/7] 下发基座(Namespace ${GW_NS} + Gateway; listener:80; service-type=NodePort)..."
SSH "${K} apply -f -" < "${BASE_GATEWAY}" >/dev/null 2>&1 \
    || { err "kubectl apply 基座失败: ${BASE_GATEWAY}(kubectl apply --dry-run=server -f ${BASE_GATEWAY} 复查)"; exit 1; }
ok "  基座已下发: ${BASE_GATEWAY}"

# 网关名从集群读取(而非在模块里再写一遍), 保证与 base-gateway.yaml 单一事实源一致
GW_NAME="$( (SSH "${K} -n ${GW_NS} get gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null" || true) )"
[ -n "${GW_NAME}" ] || { err "命名空间 ${GW_NS} 内未发现 Gateway(基座 apply 未生效?)"; exit 1; }
say "  平台网关: ${GW_NS}/${GW_NAME}(gatewayClassName=${ENVOY_GATEWAYCLASS})"

# ── [3/7] 等待 Gateway 被接受(Accepted=True) ──
# 说明: Accepted 由控制器解析 GatewayClass/listener 后立即置位(实测秒级), 是 HTTPRoute 能被
#       挂接的前提, 故在此等待。
# ⚠ 这里**不**阻塞等 Programmed=True: 它要等数据面 Pod 真正 Ready, 首次部署含镜像拉取,
#   实测本次耗时约 6 分钟(数据面 Deployment 03:40:46 创建 → Programmed 03:46:36 才 True),
#   短超时等待只会稳定产出"假告警" —— 与本次修复的静默失败属同类反模式(告警噪音让人忽略真问题)。
#   Programmed 状态改为末尾信息性汇总打印(见文件末)。
say "[3/7] 等待 Gateway 被 Envoy Gateway 接受(Accepted=True; 最长 60s)..."
_GW_ACC=0
for _i in $(seq 1 12); do
    _acc="$( (SSH "${K} -n ${GW_NS} get gateway ${GW_NAME} -o jsonpath='{.status.conditions[?(@.type==\"Accepted\")].status}' 2>/dev/null" || true) )"
    if [ "${_acc}" = "True" ]; then _GW_ACC=1; break; fi
    sleep 5
done
if [ "${_GW_ACC}" = "1" ]; then
    ok "  Gateway 已 Accepted(数据面由控制器接管)"
else
    warn "  60s 内未 Accepted(kubectl -n ${GW_NS} describe gateway ${GW_NAME}; GatewayClass/listener 配置有误?)"
fi
unset _acc _GW_ACC _i

# ── [4/7] 等待数据面 Service + 定位所在命名空间 ──
# ⚠ 数据面 Service 默认创建在 **EG 控制面命名空间**(envoy-gateway-system), 不在 Gateway 命名空间;
#   名称带控制器生成的 hash(envoy-<gw ns>-<gw 名>-<hash>), 不可写死。按 EG 打的标签定位:
#   gateway.envoyproxy.io/owning-gateway-name=<gw 名>。
# ⚠ 列序敏感(与 gateway-nodeport.sh 同坑): 单命名空间 get 输出列为 NAME TYPE..., -A 输出为
#   NAMESPACE NAME...。这里统一用 -A 并按 $1=ns/$2=名称 解析, 避免列序混用。
# ⚠⚠ -A 必须放在动词**之后**(kubectl get svc -A): kubectl v1.32 下 `-A` 不是全局 flag,
#   写成 `kubectl -A get svc` 会直接报 "flags cannot be placed before plugin name" 且**返回空** ——
#   循环里静默变成"永远发现不了数据面 Service"。本模块 [4/7] 与 16_envoy_ai_gateway.sh、
#   tools/lb/gateway-nodeport.sh 都曾踩此坑(2026-09-16 实测 kubectl v1.32.5)。
say "[4/7] 等待数据面 Service 调和(最长 180s)..."
_DP_SVC=""; _DP_NS=""; _DP_NAME=""
for _i in $(seq 1 36); do
    _DP_SVC="$( (SSH "${K} get svc -A -l gateway.envoyproxy.io/owning-gateway-name=${GW_NAME} --no-headers 2>/dev/null" || true) | head -1 )"
    _DP_NS="$(echo "${_DP_SVC}" | awk '{print $1}')"
    case "${_DP_NS}" in envoy-gateway-system|"${GW_NS}") _DP_NAME="$(echo "${_DP_SVC}" | awk '{print $2}')"; break ;; esac
    _DP_SVC=""; sleep 5
done
if [ -n "${_DP_NS}" ] && [ -n "${_DP_NAME}" ]; then
    ok "  数据面 Service 已调和: ${_DP_NS}/${_DP_NAME}"
else
    _DP_NS="envoy-gateway-system"     # 调和超时也继续(路由/固定入口仍按默认 ns 尝试)
    warn "  180s 内未发现数据面 Service(EG 控制面未调和; 后续固定入口可能失败, 可稍后重跑本模块)"
fi
unset _DP_SVC _i

# ── [5/7] 下发服务路由(routes/*.yaml, 幂等) ──
say "[5/7] 下发服务路由(${ROUTES_DIR}/*.yaml)..."
shopt -s nullglob
_ROUTE_FILES=("${ROUTES_DIR}"/*.yaml)
shopt -u nullglob
if [ "${#_ROUTE_FILES[@]}" -eq 0 ]; then
    warn "  routes/ 下无 YAML 文件(本次仅建基座, 未接任何对外服务)"
fi
# 从路由 YAML 抽取 hostnames(供第 [7/7] 步写部署机 /etc/hosts —— 加一条 HTTPRoute 即自动带上解析):
# 只认 `hostnames:` 块下的 `- <域名>` 列表项; backendRefs 的 `- name: xxx` 含冒号故不匹配。
# ⚠ 三个抽取函数都要**去掉行尾内联注释**(# ...): 路由 YAML 里 name/namespace 常带 `# 说明`
#   这种注释, 原样带进变量会变成 kubectl 的额外参数(预检假失败 / /etc/hosts 写进脏域名)。
_gw_route_hostnames() {
    awk '
        /^[[:space:]]*hostnames:[[:space:]]*$/ { h=1; next }
        h && /^[[:space:]]*-[[:space:]]*/ {
            s=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",s); gsub(/["\047]/,"",s); sub(/[[:space:]]*#.*$/,"",s); sub(/[[:space:]]+$/,"",s)
            if (s!="") print s
            next
        }
        h { h=0 }
    ' "$1"
}
# 路由 YAML 的 metadata.namespace: **只认 2 空格缩进**(metadata 层)。
# ⚠ 不能随便取第一个 "namespace:" —— parentRefs 里还有一个(6 空格缩进)指向网关自己的命名空间,
#   按它去预检会永远通过, 预检形同虚设。
_gw_route_ns() {
    awk '/^  namespace:/{ s=$2; sub(/[[:space:]]*#.*$/,"",s); print s; exit }' "$1"
}
# 路由第一条 backendRef 的 Service 名: **只在 backendRefs: 块内取**。
# ⚠ 同理: 不能取文件里第一个 "- name:"(那是 parentRefs 里的网关名 cubestack-gateway)。
_gw_route_backend() {
    awk '
        /backendRefs:/ { b=1; next }
        b && /^[[:space:]]*-[[:space:]]*name:/ {
            s=$0; sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/,"",s); sub(/[[:space:]]*#.*$/,"",s); print s; exit
        }
    ' "$1"
}
_ROUTE_N=0; _ROUTE_PEND=0
_GW_HOSTS=()
for _rf in "${_ROUTE_FILES[@]:-}"; do
    [ -n "${_rf}" ] || continue
    _rbase="$(basename "${_rf}")"
    # 后端组件未部署的路由不下发(否则 HTTPRoute 会停在 ResolvedRefs=False 的噪音状态)。
    # 新增"依赖组件才下发"的路由: 在下面 case 里加一条即可(与本模块其余逻辑解耦)。
    _route_gate=""
    case "${_rbase}" in
        monitoring.yaml)   # 后端 = kube-prometheus-stack 的 Service
            [ "${PROMETHEUS_ENABLED:-false}" = "true" ] || _route_gate="PROMETHEUS_ENABLED != true, 监控未部署" ;;
        cubepilot.yaml)    # 后端 = cubepilot-api(见 31_cubepilot.sh; 与内置 Portal 开关无关, 恒存在)
            [ "${CUBEPILOT_ENABLED:-false}" = "true" ] || _route_gate="CUBEPILOT_ENABLED != true, CubePilot 未部署" ;;
        cubepilot-portal.yaml)   # 后端 = 内置 Portal 的 nginx(svc/cubepilot; 仅 web.enabled=true 时存在)
            if [ "${CUBEPILOT_ENABLED:-false}" != "true" ]; then
                _route_gate="CUBEPILOT_ENABLED != true, CubePilot 未部署"
            elif [ "${CUBEPILOT_WEB_ENABLED:-true}" != "true" ]; then
                _route_gate="CUBEPILOT_WEB_ENABLED != true, 内置 Portal 未启用(无 svc/cubepilot)"
            fi ;;
    esac
    if [ -n "${_route_gate}" ]; then
        say "  跳过 ${_rbase}(${_route_gate})"
        continue
    fi
    # ★ 后端 Service 名含 kube-prometheus-stack 的 release 名(PROMETHEUS_RELEASE_NAME 可改),
    #   vendored 路由文件按默认名 kube-prometheus 书写 → apply 前重写为实际 release 名(与 08 模块同源),
    #   源文件保持原样(仿 09_multus 的 sed 副本做法, 只在临时副本上改)。
    _tmp_route="$(mktemp)"
    if [ "${_rbase}" = "monitoring.yaml" ] && [ "${PROMETHEUS_RELEASE_NAME:-kube-prometheus}" != "kube-prometheus" ]; then
        sed -E "s#(name: )kube-prometheus-#\1${PROMETHEUS_RELEASE_NAME}-#g" "${_rf}" > "${_tmp_route}"
    else
        cp "${_rf}" "${_tmp_route}"
    fi
    # ★ 后端存在性预检(2026-09-17 实机事故的根治):
    #   路由落在**后端组件自己的命名空间**里, 命名空间还没建时 kubectl apply 直接报
    #   `namespaces "x" not found` —— 旧版只把 apply 失败当普通 warn, 继续往下跑,
    #   全量日志里一行 warn 被淹没, **路由静默缺失**(cubepilot 路由当时就是这么丢的)。
    #   现在: 后端(命名空间 / Service)不存在就明确跳过 + 计数, 汇总里给出"重跑本模块"指引。
    _rns="$(_gw_route_ns "${_tmp_route}")"
    _rbackend="$(_gw_route_backend "${_tmp_route}")"
    _pending=""
    if [ -n "${_rns}" ] && [ -z "$( (SSH "${K} get ns ${_rns} --no-headers 2>/dev/null" || true) )" ]; then
        _pending="命名空间 ${_rns} 尚不存在"
    elif [ -n "${_rns}" ] && [ -n "${_rbackend}" ] && ! SSH "${K} -n ${_rns} get svc ${_rbackend} >/dev/null 2>&1"; then
        _pending="后端 Service ${_rns}/${_rbackend} 尚不存在"
    fi
    if [ -n "${_pending}" ]; then
        warn "  跳过 ${_rbase}: ${_pending}(组件未部署) —— 组件部署完成后重跑本模块即下发"
        _ROUTE_PEND=$((_ROUTE_PEND + 1))
        rm -f "${_tmp_route}"
        continue
    fi
    if SSH "${K} apply -f -" < "${_tmp_route}" >/dev/null 2>&1; then
        ok "  ${_rbase} 已下发"
        _ROUTE_N=$((_ROUTE_N + 1))
        # 只收已成功下发的路由的 hostname(跳过的文件不写 /etc/hosts, 否则解析到不存在的服务)
        while IFS= read -r _h; do
            [ -n "${_h}" ] && _GW_HOSTS+=("${_h}")
        done < <(_gw_route_hostnames "${_tmp_route}")
    else
        warn "  ${_rbase} apply 失败(kubectl get httproute -A 复查)"
    fi
    rm -f "${_tmp_route}"
done
unset _rf _rbase _tmp_route _h _route_gate _rns _rbackend _pending

# ── [6/7] 固定入口(别名 Service + 固定 NodePort) ──
# 数据面 Service 若用 k8s 自动分配的 nodePort, 每次重建端口都会变, 不便于对外发布 →
# 由 gateway-nodeport.sh 建固定名别名 <gw>-external + 固定 NodePort(该工具 nodeport/metallb 双模式兼容)。
if [ "${CUBESTACK_GATEWAY_FIXED_ENTRY:-true}" = "true" ]; then
    # 复用公共分配函数(校验 ≥30000 且不超上限; 规律端口 = base+off)
    _GW_NP="$(nodeport_alloc "${CUBESTACK_GATEWAY_NODEPORT:-30080}" 1 "${CUBESTACK_GATEWAY_NODEPORT_MAX:-32767}" 0)"
    say "[6/7] 创建固定名入口(别名 Service ${GW_NAME}-external; NodePort=${_GW_NP})..."
    # ⚠ 工具固定端口取自 GATEWAY_EXTERNAL_NODEPORT(默认 30880 —— 该端口由 AI 示例网关占用),
    #   平台网关用独立端口: 经环境变量传入(load_config 是 ${VAR:-默认} 语义, 已设值不会被覆盖)。
    if GATEWAY_EXTERNAL_NODEPORT="${_GW_NP}" bash "${NODEPORT_TOOL}" "${GW_NAME}" "${_DP_NS}"; then
        ok "  固定入口已就绪: kubectl -n ${_DP_NS} get svc ${GW_NAME}-external"
    else
        warn "  gateway-nodeport.sh 失败(稍后手工: sudo ${NODEPORT_TOOL} ${GW_NAME} ${_DP_NS})"
    fi
else
    say "[6/7] CUBESTACK_GATEWAY_FIXED_ENTRY=false, 跳过固定入口(数据面 nodePort 由 k8s 自动分配)"
fi

# ── [7/7] 部署机 /etc/hosts: 网关 hostname 解析 ──
# 目的: 部署机(跑安装脚本的机器/容器)按域名直连平台网关, 免记节点 IP;
#   与 registry.cubestack.io / k8s-api.cubestack.io 的既有做法完全一致
#   (同样复用 lib-common 的 ensure_hosts_entry; 见 06_gpu_operator.sh / 07_gpu_lws.sh)。
# hostname 来源 = 上面**成功下发**的路由文件(加一条 HTTPRoute 即自动带上解析, 无需改本模块)。
# 入口 IP 按暴露模式派生(与 lib-common 的 REGISTRY_IP 同规则):
#   nodeport → 第一个 master IP(任一节点 IP 均可达; 取 master 与 API/registry 约定一致);
#   metallb  → 数据面别名 Service 的 LoadBalancer VIP(由 MetalLB 分配, 与 REGISTRY_IP 同为池内地址)。
# ⚠ /etc/hosts 只映射 hostname→IP, **不映射端口**: nodeport 模式访问仍需带 NodePort
#   (http://grafana.cubestack.io:${CUBESTACK_GATEWAY_NODEPORT:-30080}/); metallb 模式数据面 port=80 → 可省略端口。
# ⚠ ensure_hosts_entry 是"先删同域名旧行再写当前 IP"(多集群切换不留旧 IP 残留); 非 root 时静默返回,
#   故下面用 grep 校验 + warn(与 06_gpu_operator 同款, 不做"写失败还报成功")。
if [ "${#_GW_HOSTS[@]}" -eq 0 ]; then
    say "[7/7] 无已下发路由的 hostname, 跳过 /etc/hosts"
else
    say "[7/7] 写入部署机 /etc/hosts(网关 hostname 解析)..."
    _GW_IP=""
    if [ "${SERVICE_EXPOSE_MODE:-nodeport}" = "metallb" ]; then
        # VIP 由 MetalLB 异步分配(Service 创建后数秒~数十秒), 轮询等待(30s)
        for _i in $(seq 1 15); do
            _GW_IP="$( (SSH "${K} -n ${_DP_NS} get svc ${GW_NAME}-external -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null" || true) )"
            [ -n "${_GW_IP}" ] && break
            sleep 2
        done
        [ -n "${_GW_IP}" ] || warn "  数据面别名 30s 内未分配 VIP(检查 MetalLB 池是否有空闲地址; 稍后重跑本模块补写 /etc/hosts)"
    else
        _GW_IP="$(first_master_ip || true)"
    fi
    if [ -n "${_GW_IP}" ]; then
        for _h in "${_GW_HOSTS[@]:-}"; do
            [ -n "${_h}" ] && ensure_hosts_entry "${_GW_IP}" "${_h}"
        done
        if grep -qE "^${_GW_IP}[[:space:]]+${_GW_HOSTS[0]}" /etc/hosts 2>/dev/null; then
            ok "  已写入 /etc/hosts: ${_GW_HOSTS[*]} → ${_GW_IP}"
        else
            warn "  无法写入 /etc/hosts(非 root?); 可手工添加: ${_GW_IP} ${_GW_HOSTS[*]}"
        fi
    else
        warn "  未取到网关访问入口 IP(nodeport 需 master 节点; metallb 需 MetalLB 已分配 VIP), 跳过 /etc/hosts"
    fi
    unset _GW_IP _h _i
fi

# ── 汇总 ──
# Programmed 信息性汇报(不阻塞、不判失败): 该条件要等数据面 Pod 真正 Ready 才置 True,
# 首次部署含 envoy 镜像拉取, 实测可滞后数分钟 —— 未 True 属正常中间态, 不代表本次部署失败。
_GW_PROG="$( (SSH "${K} -n ${GW_NS} get gateway ${GW_NAME} -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}' 2>/dev/null" || true) )"
if [ "${_GW_PROG}" = "True" ]; then
    _GW_PROG_DESC="True(数据面已就绪)"
else
    _GW_PROG_DESC="${_GW_PROG:-未知}(数据面启动中; 首次拉镜像可能数分钟, 稍后 kubectl -n ${GW_NS} get gateway ${GW_NAME} 复查)"
fi
echo "---------------------------------------------"
ok "平台统一网关 cubestack-gateway 部署完成"
echo "  Programmed:  ${_GW_PROG_DESC}"
echo "  网关:        ${GW_NS}/${GW_NAME}(GatewayClass ${ENVOY_GATEWAYCLASS}; 数据面由 EG 控制器托管)"
echo "  数据面:      ${_DP_NS}/${_DP_NAME:-(未调和)}"
if [ "${_ROUTE_PEND}" -gt 0 ]; then
    echo "  已下发路由:  ${_ROUTE_N} 条(kubectl get httproute -A)"
    warn "  ⚠ 另有 ${_ROUTE_PEND} 条路由因后端未就绪被跳过(上面 warn 里逐条列了原因)—— 对应组件部署完成后**重跑本模块**即补下发"
else
    echo "  已下发路由:  ${_ROUTE_N} 条(kubectl get httproute -A)"
fi
if [ "${CUBESTACK_GATEWAY_FIXED_ENTRY:-true}" = "true" ]; then
    _NODE_IP="$(first_node_ip || true)"
    echo "  固定入口:    http://${_NODE_IP:-<节点IP>}:${CUBESTACK_GATEWAY_NODEPORT:-30080}/  (固定名 ${_DP_NS}/${GW_NAME}-external; 任一节点 IP 均可)"
fi
if [ "${#_GW_HOSTS[@]}" -gt 0 ]; then
    echo "  已配解析:    ${_GW_HOSTS[*]}(部署机 /etc/hosts; 端口仍需用 ${CUBESTACK_GATEWAY_NODEPORT:-30080})"
fi
echo "  访问方式:    curl -H \"Host: <上面已配解析的任一 hostname>\"  http://<节点IP>:${CUBESTACK_GATEWAY_NODEPORT:-30080}/"
echo "  接入新服务:  在 ${ROUTES_DIR}/ 加一条 HTTPRoute 后重跑本模块(同时在上面的 case 加一条门控)"
echo "               ⚠ 后端命名空间/Service 必须已存在 —— 组件模块序号要**小于本模块(33)**, 否则会被预检跳过"
echo "  验证:        sudo ./deploy-cluster.sh --steps cubestack_gateway(幂等重跑); 状态 self-check:"
echo "               kubectl -n ${GW_NS} get gateway ${GW_NAME} -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}'"
echo "  撤网:        kubectl delete -f ${ROUTES_DIR}/            # 只撤服务(保留网关)"
echo "               kubectl delete gateway ${GW_NAME} -n ${GW_NS}; kubectl delete ns ${GW_NS}   # 彻底撤网"
