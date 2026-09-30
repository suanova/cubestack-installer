#!/bin/bash
# ============================================================
# MODULE: api_local_lb
# DESC: API 入口本地代理(节点侧就近出口) — 双向收敛
#       (开关开=断言各 worker 本地代理就位 + 收敛 /etc/hosts; 开关关=清理残留 manifest)
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# TOGGLE: API_LOCAL_LB_ENABLED
# REQUIRES: k8s_deploy
# 说明:
#   · **本模块不安装 nginx-proxy 静态 Pod** —— 它由 kubespray 上游按
#     `loadbalancer_apiserver_localhost` + `loadbalancer_apiserver_type` 自动部署
#     (roles/kubernetes/node/tasks/main.yml:27-43)。本模块只做上游不做的两件事:
#       ① **节点 /etc/hosts 的域名行收敛**: 本地代理模式下 all.yml 不再定义 loadbalancer_apiserver,
#          上游 preinstall 的 hosts 写入任务条件为假(0090-etchosts.yml:27-38), 没人再写这一行;
#          而人 SSH 到节点跑 kubectl 时, admin.conf 的 server 仍是域名, 需要它可解析。
#       ② **关闭时的 manifest 清理**: 上游只互相删 nginx/haproxy 的 manifest
#          (nginx-proxy.yml:1-6 只删 haproxy), **不会**在 localhost=false 时删 nginx-proxy.yml。
#   · **DEFAULT: 1 是刻意的**(与 09_kube_vip.sh 同因): 带 TOGGLE 的模块默认只在开关为 true 时进
#     RUN_STEPS, 开关一翻 false 就彻底不被调度 —— 于是没有任何东西去清理残留的静态 Pod。
#     DEFAULT: 1 让它成为常驻项, 由脚本内部按开关分派安装/清理。
#   · **不做**: 不在 master 上装本地代理(master 打自己的 apiserver, 无跨节点依赖; 且上游因
#     kube_apiserver_bind_address='::' 会端口冲突而刻意排除控制面)。
#   · **节点不可达必须响亮失败(fail-closed, R9)**: 一律**不允许**把"不可达"当作"已收敛/已干净"。
#     "连通性"与"存在性"必须分开判(`test -f` 在 SSH 不通时同样返回非零, 合并判断会把网络故障
#     误诊成"上游没装本地代理"): 清理前先显式探活(`_hssh <ip> true`), 删完再复核容器确实消失;
#     任一台节点失败 → 收集进 `_fail` → err 明细 + return 1(**退出码非 0**)。
#     ⚠ **别把它"简化"回 `converge_hosts … && vlog …` / `… || true` 的写法** —— 那会让 SSH 失败被吞掉、
#       结尾照样打印 ✅。本模块的全部价值就是"断言收敛", 静默成功等于没有断言。
#       (2026-09-28 实测: 修复前 enabled / disabled 两种模式在节点全不可达时都 EXIT=0 且打印 ✅;
#        回归锚点见 tools/tests/test-api-local-lb.sh。)
# 数据源: cluster.conf (API_LOCAL_LB_ENABLED / API_LOCAL_LB_TYPE / NODES / SSH_KEY_NAME)
# 用法: sudo ./deploy-cluster.sh --steps api_local_lb
# ============================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config
init_remote_kubectl || exit 1

MANIFEST="/etc/kubernetes/manifests/nginx-proxy.yml"
HOSTS_DOMAIN="${API_DOMAIN}"
SSH_USER_NAME="${SSH_USER:-ubuntu}"

_hssh() {  # _hssh <ip> <cmd...>
    local h="$1"; shift
    ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER_NAME}@${h}" "$@"
}

_workers() {  # 输出所有 worker IP(每行一个)
    local line
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        [ "${NODE_ROLE}" = "worker" ] && printf '%s\n' "${NODE_IP}"
    done
    # ⚠ 显式 return 0: for 循环的退出码 = 末次迭代的命令, 末节点是 master 时会是 1。
    #   当前调用方都是 `for ip in $(_workers)`(命令替换失败不触发 set -e), 但一旦有人写成
    #   `IPS=$(_workers)`, 那种拓扑下模块会**静默中止** —— 这条 return 就是防这个(R9/疑虑 4)。
    return 0
}

_all_nodes() {
    local line
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        printf '%s\n' "${NODE_IP}"
    done
    return 0   # 同上: 退出码不许依赖"末节点角色"
}

# 收敛一个节点上的 hosts 域名行(先删同域名旧行, 再写一行)
converge_hosts() {  # converge_hosts <ip> <addr>
    local ip="$1" addr="$2"
    _hssh "${ip}" "sudo sed -i '/[[:space:]]${HOSTS_DOMAIN}\$/d' /etc/hosts && \
                   echo '${addr} ${HOSTS_DOMAIN}' | sudo tee -a /etc/hosts >/dev/null" >/dev/null
}

# 删除后复核: 该节点上的 nginx-proxy 容器是否**真的**消失了(只删 manifest ≠ kubelet 已回收容器)。
# 输出恰好一个词: GONE / RUNNING / UNKNOWN(UNKNOWN = 无法判定: crictl 缺失, 或 SSH/sudo 异常)。
# ⚠ 恒 return 0(值函数: 调用方按输出判定) —— 这样"确实没了"与"判不了"不会被混为一谈。
# ⚠ 不写成 `… | grep -q nginx-proxy` 直接当条件: grep 无匹配也返回 1, 与 SSH 失败不可区分。
_nginx_proxy_state() {  # _nginx_proxy_state <ip>
    local out=""
    out="$(_hssh "$1" 'if ! command -v crictl >/dev/null 2>&1; then echo NOCRICTL; elif sudo crictl ps 2>/dev/null | grep -q nginx-proxy; then echo RUNNING; else echo GONE; fi' 2>/dev/null)" || out=""
    case "${out}" in
        GONE|RUNNING) printf '%s\n' "${out}" ;;
        *)            printf 'UNKNOWN\n' ;;
    esac
    return 0
}

run_enabled() {
    local entry; entry="$(api_entry_addr)" || { err "无法解析 API 入口地址"; return 1; }
    say "本地代理模式: 入口地址 = ${entry}"

    local ip _fail=() _done=0
    for ip in $(_workers); do
        # ⚠ 连通性与"文件在不在"分开判: SSH 不可达时 `test -f` 也返回非零, 合并判断会把
        #   网络/密钥故障误诊成"上游没装本地代理"(排查方向全错, 实测踩到过)
        if ! _hssh "${ip}" "true" >/dev/null 2>&1; then
            err "worker ${ip} SSH 不可达 —— 无法断言本地代理是否就位"
            err "  排查: ssh ${SSH_USER_NAME}@${ip} 能否免密登入(密钥/网络/防火墙)"
            return 1
        fi
        if ! _hssh "${ip}" "sudo test -f ${MANIFEST}" >/dev/null 2>&1; then
            err "worker ${ip} 上缺少 ${MANIFEST} —— 上游未部署本地代理?"
            err "  排查: all.yml 的 loadbalancer_apiserver 块是否已被 sync 脚本摘掉(见 docs/api-ha/02)"
            return 1
        fi
        # kubelet.conf 的 server 应为 localhost:6443
        if ! _hssh "${ip}" "sudo grep -q 'server: https://localhost:6443' /etc/kubernetes/kubelet.conf"; then
            warn "worker ${ip} 的 kubelet.conf 不是 localhost:6443 —— 可能需要重跑 k8s_deploy 让上游改写"
        fi
        ok "worker ${ip}: 本地代理就位"
    done

    # ⚠ 收敛失败必须收集并报错退出 —— 曾经写成 `converge_hosts … && vlog …` + 无条件 `ok`,
    #   节点不可达时照样打印 ✅ 且 EXIT=0(2026-09-28 R9 修, 锚点见 tools/tests/test-api-local-lb.sh)
    for ip in $(_all_nodes); do
        if converge_hosts "${ip}" "${entry}"; then
            vlog "  ${ip}: /etc/hosts ${HOSTS_DOMAIN} → ${entry}"
            _done=$((_done + 1))
        else
            _fail+=("${ip}")
        fi
    done
    if [ "${#_fail[@]}" -gt 0 ]; then
        err "以下节点的 /etc/hosts 域名行收敛失败: ${_fail[*]}"
        err "  排查: SSH 可达性(ssh ${SSH_USER_NAME}@<ip>) / sudo 权限"
        return 1
    fi
    ok "节点 /etc/hosts 域名行已收敛到 ${entry}(${_done} 台节点)"
}

run_disabled() {
    say "本地代理已关闭: 清理残留的 nginx-proxy 静态 Pod(上游不会删)"
    local entry ip _state _fail=() _deleted=()
    entry="$(api_entry_addr)" || entry=""
    for ip in $(_all_nodes); do
        # ---- 0. 可达性前置: 不可达 ≠ 已干净(fail-closed) ----
        # ⚠ `if _hssh … "test -f"` 无法区分"文件不在"与"根本连不上", 而后者恰恰最危险:
        #   把它当成"已干净"会得到"清理完成 ✅ EXIT=0", 实际一台都没核到(2026-09-28 R9 修)。
        if ! _hssh "${ip}" "true" >/dev/null 2>&1; then
            err "节点 ${ip} SSH 不可达 —— 无法确认 ${MANIFEST} 是否已清理(不计入'已干净')"
            _fail+=("${ip}(不可达)")
            continue
        fi
        # ---- 1. 可达时才判存在性 ----
        if _hssh "${ip}" "sudo test -f ${MANIFEST}" >/dev/null 2>&1; then
            if _hssh "${ip}" "sudo rm -f ${MANIFEST}" >/dev/null; then
                ok "已删除 ${ip}:${MANIFEST}"
                _deleted+=("${ip}")
            else
                err "删除 ${ip}:${MANIFEST} 失败"
                _fail+=("${ip}(删除失败)")
                continue
            fi
        else
            vlog "  ${ip}: 无 ${MANIFEST}, 跳过"
        fi
        # ---- 2. hosts 域名行收敛(失败不再被 `|| true` 吞掉) ----
        if [ -n "${entry}" ]; then
            if converge_hosts "${ip}" "${entry}"; then
                vlog "  ${ip}: /etc/hosts ${HOSTS_DOMAIN} → ${entry}"
            else
                err "节点 ${ip}: /etc/hosts 域名行收敛失败"
                _fail+=("${ip}(hosts)")
            fi
        fi
    done

    # ---- 3. 只删文件不等于停了: 复核容器确实消失(与 09_kube_vip.sh 同一口径) ----
    if [ "${#_deleted[@]}" -gt 0 ]; then
        say "等待 kubelet 回收 nginx-proxy 静态 Pod(15s)..."
        sleep 15
        for ip in "${_deleted[@]}"; do
            _state="$(_nginx_proxy_state "${ip}")"
            case "${_state}" in
                GONE)    vlog "  ${ip}: nginx-proxy 容器已消失" ;;
                RUNNING) err "节点 ${ip}: manifest 已删但 nginx-proxy 容器仍在运行"
                         _fail+=("${ip}(容器未停)") ;;
                *)       err "节点 ${ip}: 无法判定 nginx-proxy 容器状态(crictl 缺失或 SSH/sudo 异常)"
                         _fail+=("${ip}(复核失败)") ;;
            esac
        done
    fi

    if [ "${#_fail[@]}" -gt 0 ]; then
        err "清理未完成, 以下节点存在问题: ${_fail[*]}"
        err "  排查: SSH 可达性(ssh ${SSH_USER_NAME}@<ip>) / sudo 权限 / sudo crictl ps -a | grep nginx-proxy"
        return 1
    fi

    # ---- 4. 操作顺序提示: 只提示, 不拦停 ----
    # 本模块只做"删 manifest + 收敛 hosts"; 把各节点 kubelet.conf 从 https://localhost:6443 改回
    # https://<域名>:6443 是**上游 k8s_deploy 的活**(关闭态下 sync 脚本会取消注释 all.yml 的
    # loadbalancer_apiserver 块并写回入口地址, kubespray 据此重写各节点 kubelet.conf)。
    # 若运维只跑 `--steps api_local_lb` 关开关就收工, 会留下"代理已删、kubelet 仍指 localhost"的窗口
    # → worker 打不到任何 apiserver → NotReady。按仓库惯例(2026-09-17 起"人为操作顺序"类护栏
    # 一律**只提示不拦停**), 这里只 warn —— 本模块的产出是干净的, 只是集群还需要上游那一步。
    warn "本地代理已清理, 但各节点的 kubelet.conf 仍指向 https://localhost:6443(kubespray 上游才会改写它)"
    warn "  请随后重跑 k8s_deploy(./deploy-cluster.sh --steps k8s_deploy)让上游改回 https://${API_DOMAIN}:6443,"
    warn "  否则 worker 的 kubelet 打不到 API 而 NotReady(代理已删, 该地址已不存在)"
    ok "清理完成: 全部节点可达、无残留 manifest、无运行中的 nginx-proxy"
}

if api_local_lb_enabled; then run_enabled; else run_disabled; fi
