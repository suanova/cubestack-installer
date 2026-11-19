#!/bin/bash
# ============================================================
# test-k8s-hosts-deploy-node.sh — 单节点部署机 /etc/hosts 默认开启回归(issue #187)
# 背景: 单节点安装时部署机就是 master; 旧默认 UPDATE_ETC_HOSTS=0 → 部署机 /etc/hosts
#   没有 k8s-api.cubestack.io, kubespray 在 kubeadm 之后创建 bootstrap token 时
#   `lookup k8s-api.cubestack.io: no such host`。修复: 部署机在 NODES 里时默认开启。
# 覆盖:
#   ① is_single_node_topology: 1 master/0 worker 才为真;
#   ② deploy_host_is_node: hostname 命中 / IP 命中 / 都不命中;
#   ③ 03_k8s_hosts.sh 的开关块: auto 时部署机是节点就写; 显式 0 尊重运维;
#   ④ _hosts_filter_domain 按完整字段删除(节点名 k8s 不会误删 k8s-api.cubestack.io)。
# 隔离: hostname 用 PATH 桩; 开关块从模块原样抽取, 不执行 -- 不碰本机 /etc/hosts。
# 用法: bash deployments/scripts/tools/tests/test-k8s-hosts-deploy-node.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="${REPO_ROOT}/deployments/scripts/lib-common.sh"
MOD="${REPO_ROOT}/deployments/scripts/modules/02_k8s/03_k8s_hosts.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }

mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/hostname" <<'FAKE'
#!/bin/bash
if [ "${1:-}" = "-I" ]; then printf '%s\n' "${FAKE_IPS:-}"; else printf '%s\n' "${FAKE_HOSTNAME:-}"; fi
FAKE
chmod +x "${TMP}/bin/hostname"

topo() {   # topo <NODES行...> → yes|no
    local -a nodes=("$@")
    (
        set +u
        NODES=("${nodes[@]}")
        # shellcheck disable=SC1090
        source "${LIB}" >/dev/null 2>&1
        is_single_node_topology && echo yes || echo no
    )
}

echo "== ① 单节点判定 =="
chk "1 master / 0 worker → 单节点" "yes" "$(topo 'master,m1,10.0.0.1,-,-')"
chk "1 master / 1 worker → 非单节点" "no" "$(topo 'master,m1,10.0.0.1,-,-' 'worker,w1,10.0.0.2,-,-')"
chk "2 master / 0 worker → 非单节点" "no" "$(topo 'master,m1,10.0.0.1,-,-' 'master,m2,10.0.0.2,-,-')"
chk "空 NODES → 非单节点" "no" "$(topo)"
chk "不污染调用方 NODE_* 状态" "sentinel" \
    "$( ( set +u; NODES=('master,m1,10.0.0.1,-,-'); source "${LIB}" >/dev/null 2>&1; \
         NODE_HOSTNAME=sentinel; is_single_node_topology >/dev/null; printf '%s' "${NODE_HOSTNAME}" ) )"
echo "== ② 部署机是否 NODES 节点 =="
dhi() {  # dhi <hostname> <ips> <NODES行...> → yes|no
    local hn="$1" ips="$2"; shift 2
    local -a nodes=("$@")
    (
        export PATH="${TMP}/bin:${PATH}" FAKE_HOSTNAME="${hn}" FAKE_IPS="${ips}"
        set +u
        NODES=("${nodes[@]}")
        # shellcheck disable=SC1090
        source "${LIB}" >/dev/null 2>&1
        deploy_host_is_node && echo yes || echo no
    )
}
chk "hostname 命中" "yes" "$(dhi m1 '' 'master,m1,10.0.0.1,-,-')"
chk "IP 命中(hostname 不同)" "yes" "$(dhi deploy-host '10.0.0.1 192.168.1.9' 'master,m1,10.0.0.1,-,-')"
chk "都不命中" "no" "$(dhi deploy-host '192.168.1.9' 'master,m1,10.0.0.1,-,-')"
chk "worker IP 也能命中" "yes" "$(dhi x '10.0.0.2' 'master,m1,10.0.0.1,-,-' 'worker,w1,10.0.0.2,-,-')"
chk "空 NODE_IP 不误判" "no" "$(dhi other '' 'master,m1,,-,-')"

echo "== ③ 模块开关块: auto 跟随节点判定, 显式 0 尊重运维 =="
sed -n '/^_DO_UPDATE=0$/,/^fi$/p' "${MOD}" > "${TMP}/decision.sh"
[ -s "${TMP}/decision.sh" ] || { echo "FAIL 抽取开关块失败"; exit 1; }
run_decision() {  # run_decision <UPDATE_ETC_HOSTS> <is_node 0|1> → 输出 _DO_UPDATE; 跳过路径为空
    {
        echo 'say() { :; }'
        echo 'warn() { :; }'
        echo "deploy_host_is_node() { return $((1 - $2)); }"
        cat "${TMP}/decision.sh"
        echo 'printf "%s" "${_DO_UPDATE:-0}"'
    } > "${TMP}/run.sh"
    UPDATE_ETC_HOSTS="$1" bash "${TMP}/run.sh"
}
chk "auto + 部署机是节点 → 写" "1" "$(run_decision auto 1)"
chk "auto + 部署机不是节点 → 跳过(exit 0)" "" "$(run_decision auto 0)"
chk "未设置(=auto) + 节点 → 写" "1" "$(run_decision '' 1)"
chk "显式 1 + 非节点 → 强制写" "1" "$(run_decision 1 0)"
chk "显式 0 + 节点 → 尊重运维, 不写" "" "$(run_decision 0 1)"
chk "非法值 + 节点 → 按 auto 写" "1" "$(run_decision whatever 1)"

echo "== ④ hosts 按完整字段删除(节点名 k8s 不能误删 k8s-api.*) =="
_filter() {   # _filter <content> <domain>
    ( set +u; source "${LIB}" >/dev/null 2>&1; printf '%s' "$1" | _hosts_filter_domain "$2" )
}
_sample=$'10.0.0.1 k8s\n10.0.0.1 k8s-api.cubestack.io # api\n10.0.0.2 k8s-api.cubestack.io-alias\n# k8s-api.cubestack.io comment\n10.0.0.3 k8s other-host # note\n'
_out="$(_filter "${_sample}" k8s)"
chk "节点名 k8s 行已删除" "0" "$(printf '%s\n' "${_out}" | command grep -cE '^10\.0\.0\.1 k8s$' || true)"
chk "k8s-api 行保留" "1" "$(printf '%s\n' "${_out}" | command grep -c 'k8s-api.cubestack.io # api' || true)"
chk "别名/注释行保留" "2" "$(printf '%s\n' "${_out}" | command grep -cE 'k8s-api.cubestack.io-alias|^# k8s-api' || true)"
chk "同行其它别名/注释保留" "10.0.0.3 other-host # note" \
    "$(printf '%s\n' "${_out}" | command grep -E '^10\.0\.0\.3 ' || true)"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-k8s-hosts-deploy-node: 全部通过"
else
    echo "❌ test-k8s-hosts-deploy-node: 存在失败项"
fi
exit "${fail}"
