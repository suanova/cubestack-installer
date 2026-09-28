#!/bin/bash
# 桩式单元测试: API 入口模式判定(不连集群, 只验纯函数)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
export CLUSTER_CONF="$(mktemp)"
fail=0
chk() { # chk <描述> <期望> <实际>
    if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi
}

_run() { # _run <conf 内容> <表达式>
    printf '%s\n' "$1" > "${CLUSTER_CONF}"
    ( set +u; source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
      load_config >/dev/null 2>&1
      eval "$2" )
}

echo "== api_entry_mode =="
chk "external 优先" "external" "$(_run 'NODES=("master,m1,10.0.0.1,ubuntu,p") ; API_EXTERNAL_ADDR=10.0.0.9' 'api_entry_mode')"
chk "vip" "vip" "$(_run 'NODES=("master,m1,10.0.0.1,ubuntu,p") ; KUBE_VIP_ENABLED=true' 'api_entry_mode')"
chk "node 回退" "node" "$(_run 'NODES=("master,m1,10.0.0.1,ubuntu,p") ; KUBE_VIP_ENABLED=false' 'api_entry_mode')"

echo "== api_local_lb_enabled (含兼容别名) =="
chk "显式 true" "0" "$(_run 'API_LOCAL_LB_ENABLED=true' 'api_local_lb_enabled; echo $?')"
chk "显式 false" "1" "$(_run 'API_LOCAL_LB_ENABLED=false' 'api_local_lb_enabled; echo $?')"
chk "未定义+旧开关 true → 别名生效" "0" "$(_run 'KUBE_VIP_LOCAL_PROXY=true' 'api_local_lb_enabled; echo $?')"
chk "未定义+旧开关未设 → 关(旧行为)" "1" "$(_run 'X=1' 'api_local_lb_enabled; echo $?')"

echo "== api_entry_addr =="
chk "external 直出" "10.0.0.9" "$(_run 'NODES=("master,m1,10.0.0.1,ubuntu,p") ; API_EXTERNAL_ADDR=10.0.0.9' 'api_entry_addr')"
chk "node 取首 master" "10.0.0.1" "$(_run 'NODES=("master,m1,10.0.0.1,ubuntu,p") ; KUBE_VIP_ENABLED=false' 'api_entry_addr')"

echo "== api_entry_validate_config 互斥 =="
chk "external + kube-vip → 失败" "1" "$(_run 'API_EXTERNAL_ADDR=10.0.0.9 ; KUBE_VIP_ENABLED=true' 'api_entry_validate_config; echo $?')"
chk "external + haproxy → 失败" "1" "$(_run 'API_EXTERNAL_ADDR=10.0.0.9 ; KUBE_VIP_ENABLED=false ; HAPROXY_ENABLED=true' 'api_entry_validate_config; echo $?')"
chk "external 单独 → 通过" "0" "$(_run 'API_EXTERNAL_ADDR=10.0.0.9 ; KUBE_VIP_ENABLED=false' 'api_entry_validate_config; echo $?')"
chk "非法 IP → 失败" "1" "$(_run 'API_EXTERNAL_ADDR=not-an-ip ; KUBE_VIP_ENABLED=false' 'api_entry_validate_config; echo $?')"

# ---- 回归锚点(C1): node 模式必须**显式 warn**"外部入口无 HA" ----
# 修复前(spec D5 / §2.2 / §5 S1 四处承诺, 代码里一句没有): KUBE_VIP_ENABLED=false 时整场部署
# 没有任何提示, 运维会以为拿到了高可用入口 —— 正是本方案要消灭的"静默单点"。
# 判据: ① 打印含"无 HA"; ② 只是提示, 不拦停(仍返回 0); ③ 进程内去重(同进程调两次只提示一次);
#       ④ vip / external 模式不得误报。
echo "== api_entry_validate_config: node 模式显式 warn(无 HA) =="
_node_out="$(_run 'NODES=("master,m1,10.0.0.1,ubuntu,p") ; KUBE_VIP_ENABLED=false' 'api_entry_validate_config; echo "rc=$?"')"
chk "node 模式打印'无 HA'提示" "1" "$(grep -c '无 HA' <<<"${_node_out}")"
chk "node 模式不拦停(返回 0)" "1" "$(grep -c '^rc=0$' <<<"${_node_out}")"
chk "node 模式同进程重复调用只提示一次" "1" \
    "$(_run 'NODES=("master,m1,10.0.0.1,ubuntu,p") ; KUBE_VIP_ENABLED=false' 'api_entry_validate_config; api_entry_validate_config' | grep -c '无 HA')"
chk "vip 模式不误报" "0" \
    "$(_run 'NODES=("master,m1,10.0.0.1,ubuntu,p") ; KUBE_VIP_ENABLED=true' 'api_entry_validate_config' | grep -c '无 HA')"
chk "external 模式不误报" "0" \
    "$(_run 'NODES=("master,m1,10.0.0.1,ubuntu,p") ; API_EXTERNAL_ADDR=10.0.0.9 ; KUBE_VIP_ENABLED=false' 'api_entry_validate_config' | grep -c '无 HA')"
unset _node_out

# ---- 库存事实 vs VIP 稳定性(桩式: 只造 inventory 文件, 不连集群) ----
# 回归锚点(R7): kube_vip_current_entry 必须保持"只读 all.yml"的窄语义 —— 它的另两个消费者
# (09_kube_vip.sh 清理护栏 / 06_k8s_deploy.sh 阶段二切换确认门)一旦拿到伪造值就会 fail-open;
# VIP 的稳定性改由 kube_vip_derive 第 2 步回退保证, 故下面同时断言"derive 仍复用记录值"。
echo "== kube_vip_current_entry: 窄语义(读不到=空, 不得回退) =="
FIX="$(mktemp -d)"; mkdir -p "${FIX}/group_vars/all" "${FIX}/group_vars/k8s_cluster"
printf 'kube_vip_address: 10.0.0.211\n' > "${FIX}/group_vars/k8s_cluster/addons.yml"
_conf="NODES=(\"master,m1,10.0.0.1,ubuntu,p\" \"worker,w1,10.0.0.11,ubuntu,w\") ; KUBESPRAY_INV_DIR=${FIX}"

printf '# loadbalancer_apiserver:\n#   address: 10.0.0.211\n' > "${FIX}/group_vars/all/all.yml"
chk "块被注释(本地代理模式) → 空" "" "$(_run "${_conf}" 'kube_vip_current_entry')"
printf 'loadbalancer_apiserver:\n  address: 10.0.0.211\n' > "${FIX}/group_vars/all/all.yml"
chk "all.yml 有值 → 读它" "10.0.0.211" "$(_run "${_conf}" 'kube_vip_current_entry')"
rm -f "${FIX}/group_vars/all/all.yml"
chk "无 all.yml → 空" "" "$(_run "${_conf}" 'kube_vip_current_entry')"

echo "== kube_vip_derive 第 2 步: 块被注释时复用 addons.yml 记录值(VIP 不漂移) =="
printf '# loadbalancer_apiserver:\n#   address: 10.0.0.211\n' > "${FIX}/group_vars/all/all.yml"
chk "块被注释 → 复用记录的 VIP" "10.0.0.211" "$(_run "${_conf}" 'kube_vip_derive')"
printf 'loadbalancer_apiserver:\n  address: 10.0.0.211\n' > "${FIX}/group_vars/all/all.yml"
chk "all.yml 有值 → 复用 all.yml 的值" "10.0.0.211" "$(_run "${_conf}" 'kube_vip_derive')"
rm -rf "${FIX}"

rm -f "${CLUSTER_CONF}"
[ "${fail}" = "0" ] && { echo "全部通过"; exit 0; } || { echo "有失败项"; exit 1; }
