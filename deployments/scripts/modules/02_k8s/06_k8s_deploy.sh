#!/bin/bash
# ============================================================
# MODULE: k8s_deploy
# DESC: 部署 kubespray 集群(离线)
# PHASE: k8s
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: K8S_ENABLED
# 说明: 调用 cubestack-offline.sh install; 透传 cluster.conf 中 PRELOAD_IMAGE_PATTERNS
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ⚠ 部署 kubespray 前醒目提示当前服务暴露方式(nodeport / metallb)+ 各自注意事项,
# (sleep 30 倒计时供人工确认/修改), 与原有 METALLB_POOL 提示合并为统一提醒。
#   nodeport → 未部署 MetalLB, 提示入口/端口范围/单节点风险等;
#   metallb  → 提示地址池要求(METALLB_POOL)与池管理注意事项。
_EXPOSE_MODE="$(echo "${SERVICE_EXPOSE_MODE:-nodeport}" | tr '[:upper:]' '[:lower:]')"
echo ""
echo -e "\033[41m\033[97m================================================================\033[0m"
if [ "${_EXPOSE_MODE}" = "nodeport" ]; then
    _NIP="$(first_node_ip 2>/dev/null || echo '<节点IP>')"
    echo -e "\033[41m\033[97m ⚠⚠⚠  即将部署 kubespray — 当前为 NodePort 暴露模式  ⚠⚠⚠\033[0m"
    echo -e "\033[41m\033[97m  当前: SERVICE_EXPOSE_MODE=nodeport(未部署 MetalLB)\033[0m"
    echo -e "\033[41m\033[97m  访问入口 = 任意节点 IP + NodePort(自动取首个节点 IP: ${_NIP}):\033[0m"
    echo -e "\033[41m\033[97m    · registry: http://${_NIP}:${REGISTRY_NODEPORT:-31148}/\033[0m"
    echo -e "\033[41m\033[97m    · Envoy Gateway(若启用): 数据面转 NodePort 后访问 —— tools/lb/gateway-nodeport.sh <gateway名>\033[0m"
    echo -e "\033[41m\033[97m  ⚠ NodePort 注意事项:\033[0m"
    echo -e "\033[41m\033[97m    · 端口默认 30000-32767, 超限需改 kube-apiserver --service-node-port-range\033[0m"
    echo -e "\033[41m\033[97m    · 无固定 VIP, 入口=单节点 IP, 节点重启/换 IP 后入口会变\033[0m"
    echo -e "\033[41m\033[97m    · 对外服务用单节点 IP 有单点风险; 生产请用 metallb(SERVICE_EXPOSE_MODE=metallb)\033[0m"
    echo -e "\033[41m\033[97m  如需修改: ${CLUSTER_CONF} 的 SERVICE_EXPOSE_MODE 行\033[0m"
else
    echo -e "\033[41m\033[97m ⚠⚠⚠  即将部署 kubespray — 当前为 MetalLB LoadBalancer 暴露模式(生产默认)  ⚠⚠⚠\033[0m"
    echo -e "\033[41m\033[97m  当前: METALLB_POOL=${METALLB_POOL:-<未设置>}\033[0m"
    echo -e "\033[41m\033[97m  要求: 池内 IP 必须与集群节点同一二层网络且空闲(避免被 DHCP 占用):\033[0m"
    echo -e "\033[41m\033[97m    · 虚拟机集群: 已由 create-vms.sh 自动推导为 VM 网段(如 10.244.1.200-209)\033[0m"
    echo -e "\033[41m\033[97m    · 裸金属集群: 手动填节点物理网段空闲段(如 10.66.1.130-139)\033[0m"
    echo -e "\033[41m\033[97m  ⚠ MetalLB 注意事项:\033[0m"
    echo -e "\033[41m\033[97m    · 地址池建议 >1 个地址, 否则新建 LoadBalancer 可能无 VIP 可分配(verify_metallb 会校验)\033[0m"
    echo -e "\033[41m\033[97m    · 改池后部署会自动核对并重 apply 池 CR(见 kubespray 前预检); 已存在的 LoadBalancer 需删除重建才换新 VIP\033[0m"
    echo -e "\033[41m\033[97m  如需修改: ${CLUSTER_CONF} 的 METALLB_POOL / SERVICE_EXPOSE_MODE 行\033[0m"
fi
echo -e "\033[41m\033[97m================================================================\033[0m"
# 倒计时(单行刷新, 两种模式统一, 30s)
for _c in $(seq 30 -1 1); do
    printf "\r%s" "$(printf '\033[41m\033[97m  ⏳ 倒计时 %d 秒继续        \033[0m' "${_c}")"
    sleep 1
done
printf "\r%s\n" "$(printf '\033[0m  %s             ')"
printf "\r%s\n" "$(printf '\033[0m  %s             ')"
unset _EXPOSE_MODE

# ⚠ Ceph 部署前确认(需求: 部署 kubespray 之前提醒): CEPH_ENABLED=true 时, Rook 会在集群
# 就绪后(模块 ceph, 03_addon)用检测到的"未使用裸盘"建 OSD。这里在 kubespray 部署之前
# 提前亮出"存储节点 + 将使用的裸盘", sleep 倒计时供人工 double-check(节点/盘正确、避免覆盖
# 系统盘), 避免跑完整个 k8s 部署才发现节点/盘选错。检测为 SSH 直连, 不依赖集群(kubespray 之前可用);
# 结果仅供参考, 实际 OSD 设备以 ceph 模块部署时再次检测为准。CEPH_CONFIRM_SLEEP=0 可跳过。
if [ "${CEPH_ENABLED:-false}" = "true" ]; then
    _CEPH_CONFIRM_SLEEP="${CEPH_CONFIRM_SLEEP:-60}"
    # 候选存储节点: CEPH_NODES(hostname) 显式列出; 空 = 全部 NODES
    _CEPH_HOSTS=()
    if [ -n "${CEPH_NODES:-}" ]; then
        for _h in ${CEPH_NODES//,/ }; do [ -n "${_h}" ] && _CEPH_HOSTS+=("${_h}"); done
    else
        for _line in "${NODES[@]:-}"; do
            [ -z "${_line}" ] && continue
            node_parse "${_line}"
            [ -n "${NODE_HOSTNAME}" ] && _CEPH_HOSTS+=("${NODE_HOSTNAME}")
        done
    fi
    echo ""
    echo -e "\033[41m\033[97m================================================================================\033[0m"
    if [ "${#_CEPH_HOSTS[@]}" -ge 1 ]; then
        declare -A _CEPH_DISKS
        # 裸盘来源: 显式 CEPH_DATA_DISKS 优先(与 ceph 模块两轮解析一致: hostname 条目优先,
        # 全部节点条目仅填充未指定节点); 否则 SSH 直连自动检测(同工具)。
        if [ -n "${CEPH_DATA_DISKS:-}" ]; then
            while IFS=';' read -ra _grp; do
                for _g in "${_grp[@]}"; do
                    [ -z "${_g}" ] && continue
                    _hn="${_g%%:*}"; _ds="${_g#*:}"
                    [ -z "${_hn}" ] || [ "${_hn}" = "${_ds}" ] && continue    # 全部节点条目第二轮再处理
                    _norm=""
                    for _d in ${_ds//,/ }; do                # 盘名补 /dev/ 前缀(兼容裸名)
                        _norm="${_norm:+${_norm},}/dev/${_d#/dev/}"
                    done
                    _CEPH_DISKS["${_hn}"]="${_norm}"
                done
            done <<< "${CEPH_DATA_DISKS}"
            while IFS=';' read -ra _grp; do
                for _g in "${_grp[@]}"; do
                    [ -z "${_g}" ] && continue
                    _hn="${_g%%:*}"; _ds="${_g#*:}"
                    [ -z "${_hn}" ] || [ "${_hn}" = "${_ds}" ] || continue
                    _norm=""
                    for _d in ${_ds//,/ }; do
                        _norm="${_norm:+${_norm},}/dev/${_d#/dev/}"
                    done
                    for _h2 in "${_CEPH_HOSTS[@]}"; do
                        [ -n "${_CEPH_DISKS[${_h2}]:-}" ] || _CEPH_DISKS["${_h2}"]="${_norm}"
                    done
                done
            done <<< "${CEPH_DATA_DISKS}"
        else
            _DETECT_ARGS=()
            for _h in "${_CEPH_HOSTS[@]}"; do _DETECT_ARGS+=(--node "${_h}"); done
            _DETECT_OUT="$(bash "${SCRIPT_DIR}/tools/k8s/ceph-detect-disks.sh" "${_DETECT_ARGS[@]}" -m 2>/dev/null)" || true
            if [ -n "${_DETECT_OUT}" ]; then
                while IFS= read -r _l; do
                    [ -z "${_l}" ] && continue
                    [[ "${_l}" == *"/dev/"* ]] || continue   # 只取 host:/dev/x 机器行, 过滤 say/warn 噪音
                    _hn="${_l%%:*}"; _ds="${_l#*:}"
                    _CEPH_DISKS["${_hn}"]="${_ds%,}"
                done <<< "${_DETECT_OUT}"
            fi
        fi
        echo -e "\033[41m\033[97m ⚠⚠⚠  CEPH_ENABLED=true — 部署 kubespray 前请 double-check Ceph 存储规划 ⚠⚠⚠\033[0m"
        echo -e "\033[41m\033[97m  Rook 将在集群就绪后(模块 ceph)用以下节点/裸盘建 OSD(副本=${CEPH_POOL_REPLICAS:-3}):\033[0m"
        for _h in "${_CEPH_HOSTS[@]}"; do
            echo -e "\033[41m\033[97m   · ${_h}  →  裸盘: ${_CEPH_DISKS[${_h}]:-<未指定/未检测到>}\033[0m"
        done
        echo -e "\033[41m\033[97m  ⚠ 确认要点: ① CEPH_NODES 是想部署 Ceph 的节点(空=全部 NODES)         \033[0m"
        echo -e "\033[41m\033[97m    ② 每台存储节点裸盘存在且确实空闲; ③ 盘名正确, 不覆盖系统盘/在用盘 \033[0m"
        echo -e "\033[41m\033[97m    有误请 Ctrl-C 中止, 修正 ${CLUSTER_CONF} 后重跑(CEPH_NODES/CEPH_DATA_DISKS)\033[0m"
    else
        echo -e "\033[41m\033[97m ⚠⚠⚠  CEPH_ENABLED=true, 但未找到存储节点(NODES / CEPH_NODES 为空) ⚠⚠⚠\033[0m"
        echo -e "\033[41m\033[97m   请检查 ${CLUSTER_CONF} 的 NODES / CEPH_NODES; 否则 ceph 模块无法选择存储节点  \033[0m"
    fi
    echo -e "\033[41m\033[97m================================================================================\033[0m"
    if [ "${_CEPH_CONFIRM_SLEEP}" -gt 0 ] 2>/dev/null; then
        say "Ceph 已启用: sleep ${_CEPH_CONFIRM_SLEEP}s 供核对上方节点/裸盘(CEPH_CONFIRM_SLEEP=0 可跳过)..."
        for _c in $(seq "${_CEPH_CONFIRM_SLEEP}" -1 1); do
            printf "\r%s" "$(printf '\033[41m\033[97m  ⏳ 倒计时 %d 秒继续(请核对上方 Ceph 存储节点/裸盘)      \033[0m' "${_c}")"
            sleep 1
        done
        printf "\r%s\n" "$(printf '\033[0m  %s             ')"
        printf "\r%s\n" "$(printf '\033[0m  %s             ')"
    else
        say "CEPH_CONFIRM_SLEEP=0, 跳过 ceph 部署前等待(请务必已人工核对上方节点/裸盘)"
    fi
    unset _CEPH_HOSTS _CEPH_CONFIRM_SLEEP _DETECT_ARGS _DETECT_OUT _CEPH_DISKS _hn _ds _l _line _h _c
fi

# 部署前强制重新生成 inventory(hosts.yml + group_vars 均由当前 cluster.conf 派生):
# 即使本次未执行 inventory 模块(--skip inventory / --steps k8s), 也保证 kubespray
# 始终按当前 cluster.conf 的节点部署, 不因断点续跑跳过而使用过期的 hosts.yml
say "重新生成 inventory(依据当前 ${CLUSTER_CONF})..."
bash "${SCRIPT_DIR}/tools/k8s/gen-inventory.sh"

# registry 暴露归一化 + 预检(kubespray 对 registry_service_* 严格校验: 定义了 loadbalancer_ip 但
# type≠LoadBalancer 直接 fail, 曾因 addons.yml 残留旧环境 VIP 导致整次部署中断)。
# gen-inventory 已内部调用 sync, 此处再显式兜底归一化一次, 并在 kubespray 前快速失败给出可操作提示。
bash "${SCRIPT_DIR}/tools/k8s/sync-kubespray-config.sh" >/dev/null 2>&1 || \
    warn "sync-kubespray-config.sh 归一化失败(以下方预检为准)"
_ADDONS_YML="${KUBESPRAY_INV_DIR:-${REPO_ROOT}/deployments/kubespray/inventory/cubestack-cluster}/group_vars/k8s_cluster/addons.yml"
if [ -f "${_ADDONS_YML}" ]; then
    _EXPOSE="$(echo "${SERVICE_EXPOSE_MODE:-nodeport}" | tr '[:upper:]' '[:lower:]')"
    _BAD=""
    if [ "${_EXPOSE}" = "nodeport" ] && grep -qE '^[[:space:]]*registry_service_loadbalancer_ip:[[:space:]]*[^#[:space:]]' "${_ADDONS_YML}"; then
        _BAD="registry_service_loadbalancer_ip(nodeport 模式须注释)"
    fi
    if [ "${_EXPOSE}" != "nodeport" ] && grep -qE '^[[:space:]]*registry_service_nodeport:' "${_ADDONS_YML}"; then
        _BAD="${_BAD:+${_BAD} + }registry_service_nodeport(metallb 模式须注释)"
    fi
    if [ -n "${_BAD}" ]; then
        err "addons.yml registry 暴露配置与 SERVICE_EXPOSE_MODE=${SERVICE_EXPOSE_MODE:-nodeport} 不一致: ${_BAD}"
        err "修复: 重跑 bash tools/k8s/sync-kubespray-config.sh(自动归一化), 或手工注释 ${_ADDONS_YML} 对应行后再部署"
        exit 1
    fi
    unset _BAD _EXPOSE
fi
unset _ADDONS_YML

# ⚠ MetalLB 地址池一致性: kubespray 重跑不重 apply 已存在的 IPAddressPool CR, 旧池残留
# 会让新 LoadBalancer 分到过期/冲突地址(曾把 registry 分到其他集群已占用的 VIP, 导致
# 节点拉镜像 NotFound)。集群已存在时, 显式核对并纠正池与 cluster.conf METALLB_POOL 一致。
if [ -n "${METALLB_POOL:-}" ] && [ "${SERVICE_EXPOSE_MODE:-nodeport}" = "metallb" ]; then
    _FM_IP="$(first_master_ip 2>/dev/null || true)"
    if [ -n "${_FM_IP}" ]; then
        _cur_pool="$(ssh -i "${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
            "${SSH_USER:-ubuntu}@${_FM_IP}" \
            "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf -n metallb-system get ipaddresspool -o jsonpath='{.items[0].spec.addresses[0]}' 2>/dev/null" 2>/dev/null || true)"
        if [ -n "${_cur_pool}" ] && [ "${_cur_pool}" != "${METALLB_POOL}" ]; then
            warn "集群 MetalLB 池=${_cur_pool} 与 cluster.conf METALLB_POOL=${METALLB_POOL} 不一致, 重新应用池 CR..."
            ssh -i "${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}" \
                -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
                "${SSH_USER:-ubuntu}@${_FM_IP}" \
                "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf -n metallb-system patch ipaddresspool primary --type=merge -p '{\"spec\":{\"addresses\":[\"${METALLB_POOL}\"]}}' 2>/dev/null" >/dev/null 2>&1 \
                && ok "已重新应用 MetalLB 池 → ${METALLB_POOL}" \
                || warn "重新应用池失败(请手动: kubectl -n metallb-system patch ipaddresspool primary --type=merge -p '{\"spec\":{\"addresses\":[\"${METALLB_POOL}\"]}}')"
            # 已存在的 LoadBalancer(如 registry)不会自动换 VIP, 提示人工处理
            warn "提示: 已存在的 LoadBalancer(如 registry)不会自动换 VIP; 需删除该 Service 让其按新池重新分配"
        fi
        unset _cur_pool
    fi
    unset _FM_IP
fi

OFFLINE_SCRIPT="${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh"
[ -f "${OFFLINE_SCRIPT}" ] || { err "未找到 ${OFFLINE_SCRIPT}"; exit 1; }

say "执行 kubespray 离线部署 (via cubestack-offline.sh) ..."
# 透传 cluster.conf 的预加载镜像集合; 仅当显式定义了该变量(含空串=全量同步)才传递,
# 否则由 cubestack-offline.sh 回退内置默认最小集合
# 离线文件路径: OFFLINE_FILES_DIR(全局切换根目录) + CUBESTACK_LOCAL_REPO_DIR(完整路径, 最高优先)
OFFLINE_ENV=(
    "CUBESTACK_KUBESPRAY_DIR=${KUBESPRAY_DIR}"
    "CUBESTACK_INVENTORY_DIR=${KUBESPRAY_INV_DIR}"
    "OFFLINE_FILES_DIR=${OFFLINE_FILES_DIR}"
    "CUBESTACK_LOCAL_REPO_DIR=${LOCAL_REPO_DIR}"
)
[ -n "${PRELOAD_IMAGE_PATTERNS+x}" ] && \
    OFFLINE_ENV+=("CUBESTACK_PRELOAD_IMAGE_PATTERNS=${PRELOAD_IMAGE_PATTERNS}")
env "${OFFLINE_ENV[@]}" bash "${OFFLINE_SCRIPT}" install
ok "kubespray 集群部署完成"
