#!/bin/bash
# 桩式单元测试: kube-vip 收编后 addons.yml 的开关↔映射写入(不连集群、不碰真 inventory)
#
# 背景: 2026-09-28 收编 —— 静态 Pod 改由 kubespray 按 addons.yml 的 kube_vip_* 渲染,
#   lib-common.sh#update_kube_vip_addons_yml 从"恒写 kube_vip_enabled: false 的单一写入者契约"
#   改为"按 KUBE_VIP_ENABLED 写真实映射"。本套件锁死这张映射表与幂等性:
#   · 开关键必须跟随开关(收编的**全部意义**都在这一个键上);
#   · 策略键(arp/controlplane/cp_detect/services/lb/interface)必须与收编前渲染器钉死的值逐项一致 ——
#     少写一项, 上游就会用自己的默认值渲染出**行为不同**的清单(arp 不写 = 选举关闭;
#     controlplane 不写 = 没有控制面 VIP);
#   · 反复调用必须字节幂等(否则每次 sync 都改文件 → kube-vip pod 重启, 正是当年立契约要防的事)。
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
export CLUSTER_CONF="$(mktemp)"
fail=0
chk() { # chk <描述> <期望> <实际>
    if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi
}
val() { # val <文件> <键>   —— 取顶层键的值(无该键则空)
    awk -v k="${2}:" 'index($0, k)==1 {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' "$1"
}

# 每个用例: 写一份带 "# Kube VIP" 锚点的 addons.yml(含一段"历史形态"的旧块), 跑 sync 里的写入函数。
# 退出码落在全局 _RC(不回显, 免得刷屏; 用例 ⑥ 直接读它)。
_RC=0
_run() { # _run <conf 内容> <vip> <addons 文件>
    printf '%s\n' "$1" > "${CLUSTER_CONF}"
    printf '# 其它 addons\n# Kube VIP\nkube_vip_enabled: false\nloadbalancer_apiserver:\n  address: 10.9.9.9\n' > "$3"
    ( set +u; source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
      load_config >/dev/null 2>&1
      update_kube_vip_addons_yml "$3" "$2" ) >/dev/null 2>&1
    _RC=$?
}

A="$(mktemp)"; B="$(mktemp)"
NODES_CONF='NODES=("master,m1,10.0.0.1,ubuntu,p" "master,m2,10.0.0.2,ubuntu,p" "master,m3,10.0.0.3,ubuntu,p")'

echo "== ① 开关键跟随 KUBE_VIP_ENABLED(收编的核心) =="
_run "${NODES_CONF} ; KUBE_VIP_ENABLED=true"  "10.0.0.210" "${A}"
chk "开启态 → kube_vip_enabled: true" "true" "$(val "${A}" kube_vip_enabled)"
chk "开启态 → 写入 VIP"                "10.0.0.210" "$(val "${A}" kube_vip_address)"
_run "${NODES_CONF} ; KUBE_VIP_ENABLED=false" "10.0.0.210" "${A}"
chk "关闭态 → kube_vip_enabled: false" "false" "$(val "${A}" kube_vip_enabled)"
chk "关闭态 → VIP 仍保留(喂证书 SAN, 免得开回来要重签)" "10.0.0.210" "$(val "${A}" kube_vip_address)"

echo "== ② 策略键与收编前渲染器逐项一致 =="
_run "${NODES_CONF} ; KUBE_VIP_ENABLED=true" "10.0.0.210" "${A}"
chk "arp=true(上游默认 false; 不写=选举关闭)"     "true"  "$(val "${A}" kube_vip_arp_enabled)"
chk "controlplane=true(上游默认 false)"         "true"  "$(val "${A}" kube_vip_controlplane_enabled)"
chk "services=false(D1: 服务 LB 归 MetalLB)"     "false" "$(val "${A}" kube_vip_services_enabled)"
chk "lb_enable=false(D4: local 转发等于不转发)"   "false" "$(val "${A}" kube_vip_lb_enable)"
chk "cp_detect 默认 false"                       "false" "$(val "${A}" kube_vip_cp_detect)"
chk "未设 KUBE_VIP_INTERFACE → 不写该键(交给 kube-vip 自检)" "" "$(val "${A}" kube_vip_interface)"
_run "${NODES_CONF} ; KUBE_VIP_ENABLED=true ; KUBE_VIP_CP_DETECT=true ; KUBE_VIP_INTERFACE=ens5" "10.0.0.210" "${A}"
chk "cp_detect 跟随开关"  "true" "$(val "${A}" kube_vip_cp_detect)"
chk "interface 跟随开关"  "ens5" "$(val "${A}" kube_vip_interface)"

echo "== ③ 旧块被清干净(不留 loadbalancer_apiserver / 重复键) =="
chk "旧块的 loadbalancer_apiserver 行已消失" "0" "$(grep -c 'loadbalancer_apiserver' "${A}")"
chk "kube_vip_enabled 只出现一次"           "1" "$(grep -c '^kube_vip_enabled:' "${A}")"
chk "锚点行仍在(下次还能重写)"              "1" "$(grep -c '^# Kube VIP' "${A}")"

echo "== ④ 幂等: 同样输入连跑两次字节一致 =="
_run "${NODES_CONF} ; KUBE_VIP_ENABLED=true ; KUBE_VIP_INTERFACE=ens5" "10.0.0.210" "${A}"
md5_a="$(md5sum "${A}" | cut -d' ' -f1)"
_run "${NODES_CONF} ; KUBE_VIP_ENABLED=true ; KUBE_VIP_INTERFACE=ens5" "10.0.0.210" "${B}"
md5_b="$(md5sum "${B}" | cut -d' ' -f1)"
chk "两次写入 md5 相同" "${md5_a}" "${md5_b}"

echo "== ⑤ 开关反转: true→false 必须真的翻回来(清理才不会被写回) =="
_run "${NODES_CONF} ; KUBE_VIP_ENABLED=true"  "10.0.0.210" "${A}"
chk "先为 true" "true" "$(val "${A}" kube_vip_enabled)"
_run "${NODES_CONF} ; KUBE_VIP_ENABLED=false" "10.0.0.210" "${A}"
chk "翻回 false" "false" "$(val "${A}" kube_vip_enabled)"

echo "== ⑥ 失败面: 启用但 VIP 为空 → 非零退出(不能写出空 address) =="
_run "${NODES_CONF} ; KUBE_VIP_ENABLED=true" "" "${A}"
chk "rc=1" "1" "${_RC}"

rm -f "${A}" "${B}" "${CLUSTER_CONF}"
if [ "${fail}" = "0" ]; then echo "== 全部通过 =="; else echo "== 有失败项 =="; fi
exit "${fail}"
