#!/bin/bash
# 桩式测试: sync-kubespray-config.sh 按"入口模式 + 本地代理开关"收敛 all.yml(不连集群、不碰真库存)
#
# 隔离手段:
#   ① CLUSTER_CONF 指向临时配置 —— load_config 从它读 NODES/开关, 不读真 cluster.conf
#   ② KUBESPRAY_INV_DIR 指向临时 inventory —— 脚本(含其末尾调用的 sync-addons-config.sh)
#      读写的全部是桩文件; 文件尾有真库存 md5 断言兜底(防止将来引入跨目录写入)
# 依赖事实: KUBE_VIP_ENABLED + 显式 K8S_API_VIP 让 kube_vip_derive 走"第 1 步显式指定"直接命中,
#          不进入"从 .210 起逐个 SSH 探测"的分支 —— 否则单次运行要等几十秒/次。
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SYNC="${REPO_ROOT}/deployments/scripts/tools/k8s/sync-kubespray-config.sh"
REAL_INV="${REPO_ROOT}/deployments/kubespray/inventory/cubestack-cluster"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { # chk <描述> <期望> <实际>
    if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi
}
cnt() { grep -c "$1" "$2" 2>/dev/null || true; }   # 无匹配时 grep -c 退出码非 0 → 值仍是 0
# SAN 区段内容(排序后比较 —— awk 的 `for (i in arr)` 顺序未定义, 不能按行号断言)
san() {  # san <all.yml>
    awk '/^supplementary_addresses_in_ssl_keys:/{f=1;next} f && /^[[:space:]]*-/{print $2; next} f{exit}' "$1" \
        | sort | tr '\n' ' '
}
# 首个 loadbalancer_apiserver 块的 address —— kube_vip_current_entry/nonnumeric_entry 读的就是它
# (所以"示例块被误解注释"会让这两个函数读到假地址, 进而让 kube_vip_derive 把假地址当 VIP 接管)
first_entry() { awk '/^loadbalancer_apiserver:/{f=1;next} f && /^[[:space:]]+address:/{print $2; exit}' "$1"; }

# 桩 inventory: 只造脚本会读写的几个文件。
# all.yml 刻意用**与真库存相同的版式**(supplementary 区段后面还有别的行)—— 现有 awk 只在
# "区段之后还有行"时才回填条目, 区段在文件末尾会被静默丢弃(既有行为, 与本次改动无关)。
mk_inv() {  # mk_inv <目录>
    local d="$1"
    mkdir -p "${d}/group_vars/all" "${d}/group_vars/k8s_cluster"
    cat > "${d}/group_vars/all/all.yml" <<'EOF'
## External LB example config
## apiserver_loadbalancer_domain_name: "elb.some.domain"
# loadbalancer_apiserver:
#   address: 1.2.3.4
#   port: 1234

## Internal loadbalancers for apiservers
loadbalancer_apiserver_localhost: false
apiserver_loadbalancer_domain_name: "k8s-api.cubestack.io"
loadbalancer_apiserver:
  address: 10.0.0.1
  port: 6443
supplementary_addresses_in_ssl_keys:
  - k8s-api.cubestack.io
  - 10.0.0.1
# 由脚本按 hosts.yml 自动生成(API 域名 + 全部 master IP)
kube_webhook_token_auth: false
EOF
    cat > "${d}/group_vars/k8s_cluster/k8s-cluster.yml" <<'EOF'
kube_apiserver_extra_args:
  advertise-address: "10.0.0.1"
kube_service_addresses: 10.233.0.0/18
kube_pods_subnet: 10.233.64.0/18
nodelocaldns_ip: 169.254.25.10
kube_network_plugin: calico
# 2026-09-28 补: 真库存里本来就有这一行(k8s-cluster.yml:124);sync 在 KUBE_VIP_ENABLED=true 时
# 会**确保**它为 true 并在此行缺失时 fail-loud(kubespray 的 kube-vip 任务在 ipvs 集群上硬要求它)。
# 桩里缺它 ⇒ 所有 KUBE_VIP_ENABLED=true 的用例都会因这条前置而失败。
kube_proxy_strict_arp: true
EOF
    cat > "${d}/group_vars/k8s_cluster/addons.yml" <<'EOF'
# Kube VIP
kube_vip_address: 10.0.0.211
metallb_config:
  address_pools:
    primary:
      ip_range:
        - 10.244.2.0/24
EOF
    cat > "${d}/group_vars/k8s_cluster/k8s-net-calico.yml" <<'EOF'
calico_ip_auto_method: "can-reach=10.0.0.11"
EOF
    printf 'containerd_registries_mirrors:\n' > "${d}/group_vars/all/containerd.yml"
}

# 桩配置: 后写的行覆盖前面的(load_config 是 source, 赋值即覆盖)
mk_conf() {  # mk_conf <文件> <API_LOCAL_LB_ENABLED true|false> [追加的配置行...]
    local f="$1" local_lb="$2"; shift 2
    {
        echo 'NODES=("master,m1,10.0.0.1,ubuntu,p" "master,m2,10.0.0.2,ubuntu,p" "worker,w1,10.0.0.11,ubuntu,w")'
        echo 'KUBE_VIP_ENABLED=true'
        echo 'K8S_API_VIP=10.0.0.211'
        echo "API_LOCAL_LB_ENABLED=${local_lb}"
        echo 'METALLB_POOL="10.244.2.1-10.244.2.254"'
        # 10 个 k8s 基座版本钉子:sync 的"写 k8s-versions.yml"一步**缺任一个即 err 退出**,
        # 而本测试断言 sync 的退出码(用例 ⑤)⇒ 不补这组钉子会恒红。
        # ⚠ 2026-09-28 补:此前这里没有钉子, 例 ⑤ 已静默失败一段时间(本测试当时不在 check-modules ⑮
        #   的调度清单里 ⇒ 没人跑到)。现已在 ⑮ 挂了调度, 这类"写了没人跑"的回归不会再无声无息。
        echo 'K8S_VERSION=v1.35.8'
        echo 'COREDNS_VERSION=v1.12.4'
        echo 'PAUSE_VERSION=3.10.1'
        echo 'ETCD_VERSION=v3.6.14'
        echo 'CALICO_VERSION=v3.31.7'
        echo 'METRICS_SERVER_VERSION=v0.9.0'
        echo 'CPA_VERSION=v1.10.3'
        echo 'DNS_NODE_CACHE_VERSION=1.25.0'
        echo 'LOCAL_VOLUME_PROVISIONER_VERSION=2.5.0'
        echo 'NFD_VERSION=0.19.0'
        printf '%s\n' "$@"
    } > "${f}"
}

run_sync() {  # run_sync <inv 目录> <conf 文件> → 输出同步脚本退出码
    CLUSTER_CONF="$2" KUBESPRAY_INV_DIR="$1" bash "${SYNC}" >/dev/null 2>&1
}

# 直接调 lib-common 的值函数(桩式, 不连集群; 用法同 test-api-entry-mode.sh 的 _run)
libfn() {  # libfn <inv 目录> <conf 文件> <表达式>
    (
        export CLUSTER_CONF="$2" KUBESPRAY_INV_DIR="$1"
        set +u
        source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
        load_config >/dev/null 2>&1
        eval "$3"
    )
}

REAL_MD5_BEFORE="$(cat "${REAL_INV}"/group_vars/all/all.yml "${REAL_INV}"/group_vars/k8s_cluster/addons.yml 2>/dev/null | md5sum)"

# ============================================================
echo "== ① 本地代理开: 块被注释 + localhost: true =="
D1="${TMP}/d1"; mk_inv "${D1}"; C1="${TMP}/c1"; mk_conf "${C1}" true
chk "退出码 0" "0" "$(run_sync "${D1}" "${C1}"; echo $?)"
chk "loadbalancer_apiserver 已注释" "0" "$(cnt '^loadbalancer_apiserver:' "${D1}/group_vars/all/all.yml")"
chk "注释块带 [api-ha] 标记" "1" "$(cnt '^# \[api-ha\] 本地代理模式' "${D1}/group_vars/all/all.yml")"
chk "块内容保留(降级为注释)" "1" "$(cnt '^#   address: 10.0.0.1' "${D1}/group_vars/all/all.yml")"
chk "localhost=true" "1" "$(cnt '^loadbalancer_apiserver_localhost: true' "${D1}/group_vars/all/all.yml")"
# 入口=第一个 master(node 口径) → SAN 里 domain + 2 master + 入口, 入口与 master01 重复
# (kubeadm 侧 apiserver_sans 有 `| unique`, 见 kubeadm-setup.yml:28, 重复无害)
chk "SAN = 域名 + masters + 入口" "10.0.0.1 10.0.0.1 10.0.0.2 k8s-api.cubestack.io " "$(san "${D1}/group_vars/all/all.yml")"
chk "上游示例块未被误动(保持注释)" "1" "$(cnt '^#   address: 1\.2\.3\.4' "${D1}/group_vars/all/all.yml")"

echo "== ② 幂等: 同配置重跑不产生重复/漂移 =="
chk "重跑退出码 0" "0" "$(run_sync "${D1}" "${C1}"; echo $?)"
chk "标记仍只有 1 处" "1" "$(cnt '^# \[api-ha\] 本地代理模式' "${D1}/group_vars/all/all.yml")"
chk "被注释的真块只有 1 份" "1" "$(cnt '^#   address: 10\.0\.0\.1' "${D1}/group_vars/all/all.yml")"
chk "块内容未被重复注释" "1" "$(cnt '^#   port: 6443' "${D1}/group_vars/all/all.yml")"
chk "无生效的 loadbalancer_apiserver 键" "0" "$(cnt '^loadbalancer_apiserver:' "${D1}/group_vars/all/all.yml")"
chk "SAN 未累积重复条目" "10.0.0.1 10.0.0.1 10.0.0.2 k8s-api.cubestack.io " "$(san "${D1}/group_vars/all/all.yml")"

echo "== ③ 关掉本地代理: 块原地恢复 + localhost: false =="
C2="${TMP}/c2"; mk_conf "${C2}" false
chk "退出码 0" "0" "$(run_sync "${D1}" "${C2}"; echo $?)"
chk "块已取消注释(且只有 1 个真块)" "1" "$(cnt '^loadbalancer_apiserver:' "${D1}/group_vars/all/all.yml")"
chk "标记行已清除" "0" "$(cnt '^# \[api-ha\]' "${D1}/group_vars/all/all.yml")"
chk "真块无残留注释行" "0" "$(cnt '^#   address: 10\.0\.0\.1' "${D1}/group_vars/all/all.yml")"
chk "address 已解注释且有值" "1" "$(cnt '^  address: 10\.0\.0\.1' "${D1}/group_vars/all/all.yml")"
chk "localhost=false" "1" "$(cnt '^loadbalancer_apiserver_localhost: false' "${D1}/group_vars/all/all.yml")"
# ★ 回归锚点: 上游"External LB example config"示例块必须**保持注释**
#   (曾因"见注释就解"把它解开 → 文件里出现第二个 loadbalancer_apiserver 键, 而
#    kube_vip_current_entry/nonnumeric_entry 只读首个块 → 读到假地址 1.2.3.4 →
#    1.2.3.4 既非节点 IP 也不在地址池, 会被 kube_vip_derive 当成可用 VIP 接管 = VIP 漂移)
chk "示例块仍保持注释" "1" "$(cnt '^#   address: 1\.2\.3\.4' "${D1}/group_vars/all/all.yml")"
chk "示例块的假地址未变成活配置" "0" "$(cnt '^  address: 1\.2\.3\.4' "${D1}/group_vars/all/all.yml")"
chk "首个真块地址 = 本次入口" "10.0.0.1" "$(first_entry "${D1}/group_vars/all/all.yml")"

echo "== ④ 外部入口模式 + 本地代理开: 入口地址进 SAN, 且块内 address 不被改写 =="
D2="${TMP}/d2"; mk_inv "${D2}"; C3="${TMP}/c3"
mk_conf "${C3}" true 'KUBE_VIP_ENABLED=false' 'API_EXTERNAL_ADDR=10.0.0.61'
chk "退出码 0" "0" "$(run_sync "${D2}" "${C3}"; echo $?)"
chk "块被注释" "0" "$(cnt '^loadbalancer_apiserver:' "${D2}/group_vars/all/all.yml")"
chk "块内 address 保持原值(sed 已跳过)" "1" "$(cnt '^#   address: 10.0.0.1' "${D2}/group_vars/all/all.yml")"
# external 模式: 入口(10.0.0.61)不属于任何 master → 必须靠这一步进 SAN(否则证书不认这个入口)
chk "SAN = 域名 + masters + 外部入口" "10.0.0.1 10.0.0.2 10.0.0.61 k8s-api.cubestack.io " "$(san "${D2}/group_vars/all/all.yml")"
chk "localhost=true" "1" "$(cnt '^loadbalancer_apiserver_localhost: true' "${D2}/group_vars/all/all.yml")"

echo "== ⑤ 外部入口模式 + 本地代理关: 块内 address = 外部入口地址 =="
D3="${TMP}/d3"; mk_inv "${D3}"; C4="${TMP}/c4"
mk_conf "${C4}" false 'KUBE_VIP_ENABLED=false' 'API_EXTERNAL_ADDR=10.0.0.61'
chk "退出码 0" "0" "$(run_sync "${D3}" "${C4}"; echo $?)"
chk "块保持未注释" "1" "$(cnt '^loadbalancer_apiserver:' "${D3}/group_vars/all/all.yml")"
chk "address 改写为外部入口" "1" "$(cnt '^  address: 10\.0\.0\.61' "${D3}/group_vars/all/all.yml")"
chk "localhost=false" "1" "$(cnt '^loadbalancer_apiserver_localhost: false' "${D3}/group_vars/all/all.yml")"

echo "== ⑥ loadbalancer_apiserver_type: 非默认写入, 回默认时清除 =="
D4="${TMP}/d4"; mk_inv "${D4}"; C5="${TMP}/c5"; C6="${TMP}/c6"
mk_conf "${C5}" true 'API_LOCAL_LB_TYPE=haproxy'
mk_conf "${C6}" true 'API_LOCAL_LB_TYPE=nginx'
chk "haproxy 写入" "1" "$(run_sync "${D4}" "${C5}"; cnt '^loadbalancer_apiserver_type: haproxy' "${D4}/group_vars/all/all.yml")"
chk "回默认时不再生效(已注释)" "0" "$(run_sync "${D4}" "${C6}"; cnt '^loadbalancer_apiserver_type:' "${D4}/group_vars/all/all.yml")"

echo "== ⑦ 真库存未被测试改动(md5 前后一致) =="
REAL_MD5_AFTER="$(cat "${REAL_INV}"/group_vars/all/all.yml "${REAL_INV}"/group_vars/k8s_cluster/addons.yml 2>/dev/null | md5sum)"
chk "真 inventory 未变" "${REAL_MD5_BEFORE}" "${REAL_MD5_AFTER}"

echo "== ⑧ 回归锚点(R8): 本地代理模式 + 已确认切换时, VIP 必须**沿用记录值**而不是重新探测 =="
# 背景: 本地代理模式下 all.yml 的块恒为注释 → kube_vip_current_entry 恒空 → 模块的阶段二门会
# 误判"要切换"并 export KUBE_VIP_SWITCH_CONFIRMED=1 重跑 sync。若 kube_vip_derive 第 2 步仍
# 因该标志跳过"复用记录值", 就会落到逐地址探测 —— 而**当前已绑定的 VIP 在探测口径里恰是"被占用"**
# → 每确认一次换一个地址(VIP 漂移)。下面两条锚点把"复用优先于探测""显式值仍优先于复用"钉住。
# 复用发生在第 3 步 SSH 探测**之前**, 所以本条可离线测(第 1 步显式值更是纯字符串)。
D5="${TMP}/d5"; mk_inv "${D5}"
cat > "${D5}/group_vars/all/all.yml" <<'EOF'
loadbalancer_apiserver_localhost: true
# [api-ha] 本地代理模式: 该块必须保持注释 —— 否则 kubelet 走域名, 本地代理静默失效
# loadbalancer_apiserver:
#   address: 10.0.0.211
#   port: 6443
supplementary_addresses_in_ssl_keys:
  - k8s-api.cubestack.io
# 由脚本按 hosts.yml 自动生成(API 域名 + 全部 master IP)
kube_webhook_token_auth: false
EOF
awk '/^kube_vip_address:/{print "kube_vip_address: 10.0.0.211"; next} {print}' \
    "${D5}/group_vars/k8s_cluster/addons.yml" > "${D5}/t" && mv "${D5}/t" "${D5}/group_vars/k8s_cluster/addons.yml"
C7="${TMP}/c7"; mk_conf "${C7}" true 'K8S_API_VIP=""' 'KUBE_VIP_SWITCH_CONFIRMED=1'
C8="${TMP}/c8"; mk_conf "${C8}" true 'K8S_API_VIP=10.0.0.99' 'KUBE_VIP_SWITCH_CONFIRMED=1'
chk "已确认切换 → 仍复用记录值(addons.yml)" "10.0.0.211" "$(libfn "${D5}" "${C7}" 'kube_vip_derive' | tail -1)"
chk "第 1 步显式 K8S_API_VIP 仍优先(守卫未动)" "10.0.0.99" "$(libfn "${D5}" "${C8}" 'kube_vip_derive' | tail -1)"
chk "返回码 0(未落到第 3 步探测)" "0" "$(libfn "${D5}" "${C7}" 'kube_vip_derive >/dev/null 2>&1; echo $?')"

[ "${fail}" = "0" ] && { echo "全部通过"; exit 0; } || { echo "有失败项"; exit 1; }
