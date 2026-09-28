#!/bin/bash
# ============================================================
# MODULE: verify_api_ha
# DESC: 端到端验证 API 入口高可用(本地代理 + 入口地址):
#       ① 各 worker 上 nginx-proxy 静态 Pod 容器 Running
#       → ② worker kubelet.conf = https://localhost:6443
#       → ③ master kubelet.conf = https://127.0.0.1:6443
#       → ④ 本机代理端到端可用(curl -sk https://localhost:6443/healthz == ok)
#       → ⑤ 各节点 /etc/hosts 的域名行 == 当前入口地址
#       → ⑥ kubernetes Service 的 Endpoints ≥ 2(非单点)
#       → ⑦ apiserver 证书 SAN 含当前入口地址(防止"切到 VIP 后 TLS 校验失败")
# PHASE: k8s
# DEFAULT: 0
# REPEAT: 1
# REQUIRES: k8s_deploy
# 说明:
#   · **不设 TOGGLE**: 否则开启开关时会被安装流程自动启用(同 08_verify_kube_vip.sh 的理由)。
#     仅在部署后显式 `--steps verify_api_ha` 执行。
#   · 破坏性演练(黑洞后端/杀代理)见 docs/api-ha/05-operations.md §6, 不进本模块。
#   · **本模块是"本地代理没生效"在仓库内的唯一检测手段** —— ② (worker 的 kubelet.conf 真的指到
#     localhost:6443) 是全部断言的锚: 上游把代理容器拉起来了 ≠ kubelet 真的走了它。每条断言都
#     指向一个"若没做对就会不同"的事实, **不写恒真检查**。
#   · **断言按模式分派**(`api_local_lb_enabled()`): ① ② ④ 只在本地代理**开启**时成立 ——
#     关闭态 (API_LOCAL_LB_ENABLED=false) 上游根本不装 nginx-proxy, kubelet.conf 也按域名走
#     (all.yml 的 loadbalancer_apiserver 块在场, 见 kubespray_defaults/.../main.yml kube_apiserver_endpoint)。
#     那种配置下照抄开启态的断言会整片假红, 而本模块同时被 `--steps verify` 全量验证流程收录。
#     故关闭态改断言"关闭态应得的形态"(全节点 kubelet.conf = https://<API_DOMAIN>:6443)。
#   · 节点不可达一律**响亮失败**(fail-closed, 与 10_api_local_lb.sh 的 R9 同一口径): 不可达
#     ≠ "没有本地代理", 必须分开判, 否则网络/密钥故障会被误诊成"上游没装"。
# 数据源: cluster.conf (API_LOCAL_LB_ENABLED / NODES / SSH_KEY_NAME)
# 用法: sudo ./deploy-cluster.sh --steps verify_api_ha
# ============================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config
init_remote_kubectl || exit 1

SSH_USER_NAME="${SSH_USER:-ubuntu}"
DOMAIN="${API_DOMAIN}"
FAIL=0
MANIFEST="/etc/kubernetes/manifests/nginx-proxy.yml"

# ⚠ 一律传 IP, 不传主机名: 部署容器里通常没有节点名的 /etc/hosts 解析(历史假故障来源)
_hssh() { local h="$1"; shift
    ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER_NAME}@${h}" "$@"; }

# ⚠ **必须显式 return 0**: 循环的退出码 = 末次迭代的命令, 末节点角色不匹配时本函数返回 1。
#   调用方 `ALL_IPS="$(_by_role master; _by_role worker)"` 会被赋值语句原样拿到该退出码,
#   在 set -e 下**静默中止模块**(09_kube_vip 曾因同一形态在遍历到 worker 时无任何报错死掉)。
_by_role() { local r="$1" line
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        [ "${NODE_ROLE}" = "${r}" ] && printf '%s\n' "${NODE_IP}"
    done
    return 0; }

# 连通性与"存在性"分开判: SSH 不通时 `test -f`/`grep` 同样返回非零, 合并判断会把网络故障
# 误诊成"没有本地代理"(排查方向全错)。
_reachable() { _hssh "$1" "true" >/dev/null 2>&1; }

# nginx-proxy 容器状态。恰好输出一个词: RUNNING / GONE / NOCRICTL / UNKNOWN。
# ⚠ 恒 return 0(值函数: 调用方按输出判定) —— 这样"确实没跑"与"判不了"不会被混为一谈;
#   与 10_api_local_lb.sh 的 _nginx_proxy_state 同一口径(那边是清理后复核, 这边是就位断言)。
# ⚠ 不写成 `! _hssh … "crictl ps | grep -q nginx-proxy"`: grep 无匹配也返回 1, 与 SSH/sudo
#   失败不可区分, 那正是要分开的两件事。
_proxy_state() {  # _proxy_state <ip>
    local out=""
    out="$(_hssh "$1" 'if ! command -v crictl >/dev/null 2>&1; then echo NOCRICTL; elif sudo crictl ps --name nginx-proxy -q 2>/dev/null | grep -q .; then echo RUNNING; else echo GONE; fi' 2>/dev/null)" || out=""
    case "${out}" in
        RUNNING|GONE|NOCRICTL) printf '%s\n' "${out}" ;;
        *)                     printf 'UNKNOWN\n' ;;
    esac
    return 0
}

ALL_IPS="$(_by_role master; _by_role worker)"

ENTRY="$(api_entry_addr)" || { err "无法解析 API 入口地址"; exit 1; }
[ -n "${DOMAIN}" ] || { err "API_DOMAIN 为空 —— 无法校验节点 /etc/hosts 的域名行"; exit 1; }

_LOCAL_LB=0
if api_local_lb_enabled; then _LOCAL_LB=1; fi

say "Verify API 入口高可用: 本地代理=$([ "${_LOCAL_LB}" = "1" ] && echo 开 || echo 关) 入口地址=${ENTRY} 域名=${DOMAIN}"

_MASTERS="$(_by_role master)"
_WORKERS="$(_by_role worker)"
[ -n "${_MASTERS}" ] || { err "cluster.conf 中无 master 节点 —— 无集群可验"; exit 1; }

if [ "${_LOCAL_LB}" = "1" ]; then
    # ---------------- ① ④ ② 每台 worker 的本地代理 ----------------
    _WN=0
    for ip in ${_WORKERS}; do
        _WN=$((_WN + 1))

        if ! _reachable "${ip}"; then
            err "worker ${ip} SSH 不可达 —— 无法断言本地代理是否就位(不计入'通过')"
            err "  排查: ssh ${SSH_USER_NAME}@${ip} 能否免密登入(密钥/网络/防火墙)"
            FAIL=1; continue
        fi

        _st="$(_proxy_state "${ip}")"
        case "${_st}" in
            RUNNING)  ok "① worker ${ip}: nginx-proxy 容器 Running" ;;
            GONE)     err "① worker ${ip}: nginx-proxy 容器不在运行(manifest 在场但 kubelet 没拉起?)"
                      FAIL=1 ;;
            NOCRICTL) err "① worker ${ip}: crictl 不可用 —— 无法判定本地代理容器(不等于'没跑')"
                      FAIL=1 ;;
            *)        err "① worker ${ip}: 无法判定本地代理容器状态(SSH/sudo 异常)"
                      FAIL=1 ;;
        esac

        if ! _hssh "${ip}" "sudo test -f ${MANIFEST}" >/dev/null 2>&1; then
            err "① worker ${ip}: 缺少 ${MANIFEST}(上游未部署本地代理? 也可能是 SSH/sudo 异常)"
            err "  排查: all.yml 的 loadbalancer_apiserver 块是否已被 sync 脚本摘掉(见 docs/api-ha/02)"
            FAIL=1
        fi

        # ④ 端到端: 经本机代理访问 API。装在 ≠ 能用 —— 代理配置错/后端为空时这条会红。
        if [ "$(_hssh "${ip}" "curl -sk --max-time 8 https://localhost:6443/healthz" 2>/dev/null | tr -d '\n')" = "ok" ]; then
            ok "④ worker ${ip}: localhost:6443 端到端可用"
        else
            err "④ worker ${ip}: localhost:6443 不可用(代理在跑但打不通后端 apiserver?)"
            FAIL=1
        fi

        # ② 全局唯一的"本地代理真的生效"锚点: kubelet 的 kubeconfig 是否真指到了本机代理。
        #    上游把容器拉起来 ≠ kubelet 走它 —— all.yml 的 loadbalancer_apiserver 块若还在,
        #    kubelet 仍走 <域名>:6443, 代理就是个摆设(假修复)。
        if _hssh "${ip}" "sudo grep -q 'server: https://localhost:6443' /etc/kubernetes/kubelet.conf"; then
            ok "② worker ${ip}: kubelet.conf = localhost:6443(kubelet 真的走了本机代理)"
        else
            err "② worker ${ip}: kubelet.conf 不是 localhost:6443 —— 代理装了但 kubelet 没走它"
            err "  处置: 确认 all.yml 的 loadbalancer_apiserver 块已被摘掉, 再重跑 --steps k8s_deploy 让上游改写 kubelet.conf"
            FAIL=1
        fi
    done
    [ "${_WN}" -gt 0 ] || warn "cluster.conf 无 worker 节点 —— ① ② ④ 无可断言对象(⑤ ⑥ ⑦ 仍有效)"

    # ---------------- ③ 每台 master 的 kubelet 走自己的 apiserver ----------------
    # 上游: kube_apiserver_endpoint 对 control-plane = bind_address('::' → 127.0.0.1)(kubespray_defaults
    # defaults/main/main.yml)。**但** loadbalancer_apiserver 块在场时该分支被抢先 → 会变成域名, 故这条
    # 同时是"块真的被摘掉了"的旁证。
    for ip in ${_MASTERS}; do
        if ! _reachable "${ip}"; then
            err "master ${ip} SSH 不可达 —— 无法断言 kubelet.conf"
            FAIL=1; continue
        fi
        if _hssh "${ip}" "sudo grep -q 'server: https://127.0.0.1:6443' /etc/kubernetes/kubelet.conf"; then
            ok "③ master ${ip}: kubelet.conf = 127.0.0.1:6443"
        else
            err "③ master ${ip}: kubelet.conf 不是 127.0.0.1:6443(上游未改写? 或 all.yml 仍留着 loadbalancer_apiserver 块)"
            FAIL=1
        fi
    done
else
    # ---------------- 关闭态: 断言"应得的形态"(不是跳过) ----------------
    # 关闭态下 all.yml 的 loadbalancer_apiserver 块**应当在场**(sync 脚本负责取消注释),
    # 上游据此把所有节点(含 master)的 kube_apiserver_endpoint 写成 https://<域名>:6443。
    # 断言"等于域名"而非"不等于 localhost:6443": 后者能抓本地代理残留, 前者还能抓
    # "块被摘了却没重跑 k8s_deploy"的半收敛态 —— 那种态下代理 manifest 已删、kubelet 仍指 localhost
    # → kubelet 连不上 API(节点 NotReady), 是必须响亮失败的形态。
    say "本地代理未启用(API_LOCAL_LB_ENABLED=false) → ① ② ④ 不适用, 改验关闭态形态: 全节点 kubelet.conf = ${DOMAIN}:6443"
    for ip in ${_MASTERS} ${_WORKERS}; do
        if ! _reachable "${ip}"; then
            err "${ip} SSH 不可达 —— 无法断言 kubelet.conf"
            FAIL=1; continue
        fi
        if _hssh "${ip}" "sudo grep -q 'server: https://${DOMAIN}:6443' /etc/kubernetes/kubelet.conf"; then
            ok "② ${ip}: kubelet.conf = ${DOMAIN}:6443(关闭态应得)"
        else
            err "② ${ip}: kubelet.conf 不是 ${DOMAIN}:6443"
            err "  若它仍是 localhost:6443: 代理静态 Pod 已被清理 → kubelet 连不上 API(节点会 NotReady)"
            err "  处置: 重跑 --steps k8s_deploy(上游按 loadbalancer_apiserver 块改写 kubelet.conf)"
            FAIL=1
        fi
    done
fi

# ---------------- ⑤ 各节点 /etc/hosts 的域名行 ----------------
# 断言"恰好等于当前入口"(取全部 IPv4 去重后比较), 不是"能解析就行":
# 陈旧多余行会让一部分节点走错入口, 而只取第一行(head -1)时看不出来(10_api_local_lb.sh 的
# converge_hosts 会把同域名的旧行删掉, 所以"恰为一条 = 入口地址"才是收敛后的应得形态)。
# ⚠ 取字段(awk $1)放在**本地**做, 远端只跑 getent: 少一层引号嵌套(本仓库被它坑过多次),
#   且远端 getent 的输出形态怎样都不影响判定。非 IPv4 行(如 ::1)按 IPv4 过滤, 不参与比较。
for ip in ${ALL_IPS}; do
    got="$(_hssh "${ip}" "getent hosts ${DOMAIN} 2>/dev/null" 2>/dev/null \
          | awk '{print $1}' | grep -oE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u | tr '\n' ' ')" || got=""
    got="${got% }"
    if [ "${got}" = "${ENTRY}" ]; then
        ok "⑤ ${ip}: ${DOMAIN} → ${got}"
    else
        err "⑤ ${ip}: ${DOMAIN} 解析为 '${got:-<无>}', 期望恰为 '${ENTRY}'"
        err "  处置: 重跑 --steps api_local_lb(收敛节点 /etc/hosts 的域名行)"
        FAIL=1
    fi
done

# ---------------- ⑥ kubernetes Service 的端点非单点 ----------------
# ⚠ 计数用"抠出 IP + **去重**"而不是 `wc -w`(与 08_verify_kube_vip.sh ⑤ 同一手法), 两个理由:
#   ① 去重是**判据正确性**问题: 同一个 apiserver 可能出现在多个 subset/EndpointSlice 里,
#      `wc -w` 会把它数两次 → 真单点也可能凑出 ≥2(假绿, 正是本模块最不能犯的错);
#   ② 抠 IP 与分隔符形态无关(`wc -w` 依赖 jsonpath 的输出分隔 —— 实测 kubectl v1.32 会插空格,
#      但那是实现细节不是契约, 换版本/换输出形态就可能粘成一个词)。
# ⚠ 用法约定(见 08_verify_kube_vip.sh:149-150): jsonpath 这类含单引号/花括号的载荷必须走
#   ${SSH_CMD}(字符串形式) —— 经 SSH() 函数参数会多一层引号解析而失败
_EPS_RAW="$(${SSH_CMD} "${K} get endpoints kubernetes -n default -o jsonpath='{.subsets[*].addresses[*].ip}'" 2>/dev/null || true)"
if [ -z "${_EPS_RAW}" ]; then
    # 回退: Endpoints(已标记弃用)在部分版本/被裁剪时为空 → 换 EndpointSlice
    _EPS_RAW="$(${SSH_CMD} "${K} get endpointslice -n default -l kubernetes.io/service-name=kubernetes -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{end}'" 2>/dev/null || true)"
fi
_EPS="$(printf '%s' "${_EPS_RAW}" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u || true)"
n="$(printf '%s\n' "${_EPS}" | grep -c . || true)"
if [ "${n:-0}" -ge 2 ]; then
    ok "⑥ kubernetes Service 端点数 = ${n}(非单点):$(printf ' %s' ${_EPS})"
elif [ "${n:-0}" -eq 1 ]; then
    err "⑥ kubernetes Service 端点数 = 1(单点: ${_EPS}) —— 集群内经 Service 访问 API 无冗余"
    err "  处置: 确认 kube_apiserver_extra_args.advertise-address 已按节点取值, 再重跑 --steps k8s_deploy"
    FAIL=1
else
    err "⑥ 未取到 kubernetes Service 端点(kubectl 查询失败 / 集群不可达)"
    err "  排查: ssh ${SSH_USER_NAME}@${FIRST_MASTER} ${K} get endpoints kubernetes -n default"
    FAIL=1
fi

# ---------------- ⑦ 证书 SAN 含入口地址 ----------------
# ⚠ 用**锚定的**正则而非裸 ${ENTRY}: 裸串会让入口 10.66.1.13 在 SAN 的 10.66.1.130 上假通过
#   (前缀相同)。[.] 代替 \. 避免经 ${SSH_CMD} 字符串传递时的转义歧义。
_ENTRY_RE="${ENTRY//./[.]}"
if ${SSH_CMD} "sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -qE '(^|[^0-9.])${_ENTRY_RE}([^0-9.]|\$)'"; then
    ok "⑦ apiserver 证书 SAN 含 ${ENTRY}(走该入口 TLS 校验可通过)"
else
    err "⑦ apiserver 证书 SAN 不含 ${ENTRY} —— 走该入口会 TLS 校验失败(或证书读不到: SSH/sudo/openssl 异常)"
    err "  处置: 确认入口地址进了 all.yml 的 supplementary_addresses_in_ssl_keys, 再重跑 --steps k8s_deploy 重签证书"
    FAIL=1
fi

if [ "${FAIL}" = "0" ]; then
    if [ "${_LOCAL_LB}" = "1" ]; then
        ok "API 入口高可用验证全部通过(本地代理 + 入口地址 + 证书 SAN)"
    else
        ok "API 入口验证通过(本地代理未启用: ① ② ④ 按关闭态口径校验)"
    fi
else
    err "API 入口高可用验证存在失败项(见上方【错误】逐条排查)"
fi
exit "${FAIL}"
