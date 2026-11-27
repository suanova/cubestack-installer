#!/bin/bash
# ============================================================
# MODULE: k8s_registry
# DESC: 配置集群内置 docker registry addon(节点 hosts + containerd certs.d; REGISTRY_EXPOSE_HOST=1 时可选宿主机对外 DNAT)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: REGISTRY_ENABLED
# UNINSTALL: 1
# REQUIRES: k8s_deploy local_path metallb
# 说明:
#   · 集群内 registry(kubespray addon), **默认部署**(REGISTRY_ENABLED 默认 1/true)
#   · 对**已部署**集群幂等配置内置 registry, 需集群就绪后显式执行
#   · 启用方式: deploy-cluster.sh --enable k8s_registry 或 REGISTRY_ENABLED=true
#   · 集群外镜像仓库 Harbor 为预留配置(modules/01_env/04_harbor.sh, 未来实现, 默认关闭)
#   · 复用 deploy-registry.sh: 各节点 /etc/hosts 解析 REGISTRY_DOMAIN → REGISTRY_IP(MetalLB VIP),
#     containerd certs.d 信任该 HTTP registry; REGISTRY_EXPOSE_HOST=1 时配宿主机 DNAT 对外 push 入口(默认 0 只用 VIP)
#   · REGISTRY_ENABLED 控制 addons.yml 中 registry addon 是否安装(见 sync-addons-config.sh)
#   · 后端存储 + 就绪等待(重要): REGISTRY_STORAGE_CLASS 决定 registry 数据盘后端:
#       · local-path(默认)→ k8s 阶段 local-path SC 已存在, PVC 即时绑定;
#       · ceph-block → registry-pvc 在 k8s 阶段创建时 SC 尚未出现 → Pending; ceph_csi 模块
#         创建 SC 后自动绑定(WaitForFirstConsumer)。本模块部署后**必须等待 PVC Bound + pod Ready**,
#         否则后续 push 镜像的模块(metax_gpu/ceph/...)会 ImagePullBackOff 且难以定位。
#         ⚠ --with-k8s 跳过 ceph_csi: 若 SC 仍不存在, 本模块立即失败并提示先跑 ceph_csi(issue #206),
#         不再空等 REGISTRY_WAIT_SECONDS。
#     ⚠ 顺序保证: addon 阶段按文件序号执行 metallb→ceph→ceph_csi→local_path→registry;
#       ceph/ceph_csi 模块已内置"等集群 Ready / CSI 就绪"的等待。本模块额外等 registry 自身 Ready。
#   · PVC 容量保障(2026-10-13 实机事故): kubespray 默认 registry_disk_size=10Gi, 连一轮 dev_lab
#     (当时 6 个镜像 ≈ 47G)都放不下 —— 推到一半盘满后 registry 对**所有** push 返回 500
#     ("no space left on device"), 表象是"第一个镜像推成功、其余全部失败"。kubespray 重装 apply
#     不会让已存在的 PVC 变大 ⇒ 本模块对存量 PVC 幂等扩容到 REGISTRY_DISK_SIZE
#     (默认 200Gi, 与 sync-addons-config.sh 写入 addons.yml 的值同一数据源)。
#   · coredns 解析快照自愈(2026-10-13 实机): pod sandbox 创建期的 resolv.conf 快照若含 127.0.0.1
#     (部署中途 resolved 动态文件瞬态) ⇒ coredns loop 插件探测打到 pod 内自己的 127.0.0.1:53 →
#     误判回环 FATAL 无限重启; 本模块对"CrashLoopBackOff+plugin/loop"的 pod 重建一次即愈
#     (新 sandbox 快照稳定后的文件; 实机双对照: 旧 sandbox 30 次崩溃 vs 新 pod 零重启)。
#   · Pod 侧 registry 解析(nodeport, 2026-11-20 实机): 节点 containerd 经 certs.d 把
#     <REGISTRY_DOMAIN>:5000 改写到 <master>:<NodePort>, 但 cubestack-operator 在 Pod 内直接
#     拉 OCI chart, 不走 containerd → 打到未监听的 master:5000, 组件 Degraded。本模块在 registry
#     就绪后把 CoreDNS/nodelocaldns 的 hosts 改指 Service ClusterIP(Pod 侧端口仍 5000);
#     节点侧 /etc/hosts + containerd 仍用 NodePort, 镜像拉取路径不变。
#   · 覆盖安装清理(2026-11-03 实机): 新 registry 后端不是 local-path 时, 卸载分支会清理旧集群
#     遗留的 /opt/local-path-provisioner/pvc-*_kube-system_registry-pvc 孤儿目录(仅当无 PV/PVC
#     引用且未挂载)。否则旧数据可能撑爆节点根盘 → kubelet DiskPressure → Ceph mon canary
#     Pending → ceph 模块 900s 超时(实机 master03 65G)。
# 数据源: cluster.conf (REGISTRY_DOMAIN / REGISTRY_IP / REGISTRY_PORT / REGISTRY_STORAGE_CLASS / REGISTRY_DISK_SIZE / CEPH_MODE / NODES)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---------------- 旧 local-path registry 孤儿数据清理(2026-11-03 实机) ----------------
# 背景: 上一次集群用 local-path 时, registry 数据落在
#   /opt/local-path-provisioner/pvc-<uid>_kube-system_registry-pvc; 集群重建后 PV/PVC 已不存在,
#   但目录仍在(实机 master03 上 65G) → 根盘 DiskPressure → Ceph mon-c canary Pending
#   → 02_ceph 等待 900s 超时。详见 docs/troubleshooting.md §三.15。
# 只在**覆盖安装/卸载**分支执行, 且满足全部条件才删(绝不误删仍在使用的数据):
#   ① 新 registry 后端不是 local-path; ② 目录 UID 不被当前任何 PV/PVC 引用; ③ 目录未被挂载。
_reg_node_ssh() {
    local _nip="$1" _nuser="$2"
    shift 2
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "${_nuser}@${_nip}" "$@"
}
_reg_current_ref_uids() {   # <pv-json> <pvc-json>
    printf '%s\n' "$1" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for it in d.get("items",[]):
    print(it.get("metadata",{}).get("uid",""))
    cr=(it.get("spec") or {}).get("claimRef") or {}
    print(cr.get("uid",""))' 2>/dev/null || true
    printf '%s\n' "$2" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for it in d.get("items",[]):
    print(it.get("metadata",{}).get("uid",""))' 2>/dev/null || true
}
_cleanup_orphan_registry_localpath() {
    [ "${REGISTRY_STORAGE_CLASS:-local-path}" != "local-path" ] || return 0
    local _refs _line _ip _u _hn _dirs _d _uid _sz _pv_json _pvc_json
    # 安全门: 读不到 PV/PVC 时**不清理** —— 无法证明目录已无引用(例如 API 不可达)。
    SSH "${K}" get nodes --no-headers >/dev/null 2>&1 \
        || { warn "  集群 API 不可达, 跳过旧 local-path registry 数据清理"; return 0; }
    _pv_json="$( (SSH "${K}" get pv -o json 2>/dev/null) || true )"
    _pvc_json="$( (SSH "${K}" get pvc -A -o json 2>/dev/null) || true )"
    if [ -z "${_pv_json}" ] || [ -z "${_pvc_json}" ]; then
        warn "  无法读取 PV/PVC, 跳过旧 local-path registry 数据清理(无法证明无引用)"
        return 0
    fi
    _refs="$(_reg_current_ref_uids "${_pv_json}" "${_pvc_json}")"
    for _line in "${NODES[@]:-}"; do
        [ -n "${_line}" ] || continue
        node_parse "${_line}" || continue
        _ip="${NODE_IP}"; _hn="${NODE_HOSTNAME}"
        _u="$(ssh_user_for_ip "${_ip}")"
        _dirs="$(_reg_node_ssh "${_ip}" "${_u}" "sudo sh -c 'ls -d /opt/local-path-provisioner/pvc-*_kube-system_registry-pvc 2>/dev/null' || true")"
        # 目录名只含 UID(无空格), 允许按空白切分
        # shellcheck disable=SC2086
        for _d in ${_dirs}; do
            _uid="$(basename "${_d}" | sed -n 's/^pvc-\([0-9a-f-]*\)_kube-system_registry-pvc$/\1/p')"
            [ -n "${_uid}" ] || continue
            if command grep -qxF -- "${_uid}" <<< "${_refs}"; then
                say "  保留仍被 PV/PVC 引用的 local-path registry 数据: ${_hn}:${_d}"
                continue
            fi
            if _reg_node_ssh "${_ip}" "${_u}" "mount | command grep -qF '${_uid}'" >/dev/null 2>&1; then
                warn "  ${_hn}: ${_d} 仍被挂载, 跳过(不清理)"
                continue
            fi
            _sz="$(_reg_node_ssh "${_ip}" "${_u}" "sudo du -sh '${_d}' 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)"
            if _reg_node_ssh "${_ip}" "${_u}" "sudo rm -rf --one-file-system -- '${_d}'"; then
                ok "  已清理旧 local-path registry 孤儿数据: ${_hn}:${_d} (${_sz:-?})"
            else
                warn "  ${_hn}: 清理失败 ${_d}(可手工 sudo rm -rf)"
            fi
        done
    done
}

# 卸载分支(优雅覆盖): registry 是 ceph PVC 消费者之一 —— K8s 覆盖前先优雅停机
# (scale 0; registry-pvc 受保护不动, kubespray 重装 apply 自带恢复副本)。
# ⚠ 对象是 kubespray 建的**裸 ReplicaSet**(`rs/registry`, 非 Deployment; 2026-10-13 实机
#   验证 —— 旧代码 `deploy registry` 从未命中, 停机静默空转, 实际靠 ceph 扫荡 delrs 被动整删)。
# 停机前用 stop_mark_replicas 登记原副本数(注解), 供 02_ceph.sh 7.9 在"K8s 不重装"路径恢复。
# ⚠ 位于 TOGGLE 检查之前: 本次配置关掉 REGISTRY_ENABLED 时, 旧集群里的 registry 也要能停。
if [ "${CUBESTACK_MODULE_ACTION:-install}" = "uninstall" ]; then
    init_remote_kubectl || exit 1
    if SSH "${K} -n kube-system get rs registry --no-headers 2>/dev/null | grep -q ."; then
        say "  registry: 优雅停机(scale 0; registry-pvc 保留, 不删声明)"
        stop_mark_replicas rs kube-system registry
        SSH "${K} -n kube-system scale rs registry --replicas=0 >/dev/null 2>&1 || true"
    else
        say "  registry: 不存在, 跳过"
    fi
    # 切换 registry 后端/覆盖安装时, 清掉旧 local-path 数据(否则可能撑爆根盘 → DiskPressure)
    _cleanup_orphan_registry_localpath
    exit 0
fi

# 开关: 默认不部署, REGISTRY_ENABLED=1/true 或 --steps/--enable 显式启用
if [ "${REGISTRY_ENABLED:-0}" != "1" ] && [ "${REGISTRY_ENABLED:-false}" != "true" ]; then
    say "跳过内置 registry(集群内 registry 默认不部署, 配置 REGISTRY_ENABLED=true 可启用)"
    exit 0
fi

# 前置校验: registry 后端指定 ceph 但 Ceph 体系未启用 → PVC 永久 Pending, 直接中止给出指引
# ceph 体系 = CEPH_MODE=internal/external(load_config 已归一化)。
if [ -n "${REGISTRY_STORAGE_CLASS:-}" ] && [ "${REGISTRY_STORAGE_CLASS}" != "local-path" ] \
    && [ "${CEPH_MODE:-internal}" = "none" ]; then
    err "REGISTRY_STORAGE_CLASS=${REGISTRY_STORAGE_CLASS} 但 Ceph 未启用(CEPH_MODE=none): registry 的 PVC 将永远 Pending"
    err "  请任选其一: ① cluster.conf 设 CEPH_MODE=internal(集群内自建, 需先准备 ceph 离线镜像/裸盘, 见 docs/ceph-rook.md);"
    err "  ② CEPH_MODE=external + CEPH_MONITORS/CEPH_KEYRING 接入外部 Ceph(见 docs/ceph-rook.md);"
    err "  ③ 改回 REGISTRY_STORAGE_CLASS=local-path"
    exit 1
fi

say "配置集群内置 docker registry(域名=${REGISTRY_DOMAIN:-registry.cubestack.io})..."
if [ -n "${REGISTRY_STORAGE_CLASS:-}" ] && [ "${REGISTRY_STORAGE_CLASS}" != "local-path" ]; then
    say "  后端存储: REGISTRY_STORAGE_CLASS=${REGISTRY_STORAGE_CLASS}(PVC 由 kubespray 在 k8s 阶段创建, 等该 SC 出现后自动绑定)"
fi
# ★ K/SSH/FIRST_MASTER 定义(远端 kubectl): 本模块在"就绪等待"用 SSH "${K}" 轮询 PVC/pod。
#   这些变量其他模块(metallb/ceph)在各自文件内定义, 不会跨模块可见 —— 必须在本文件定义,
#   否则 set -u 下裸引用 unbound → 部署成功(registry 已部署)后模块崩溃(本次事故根因)。
init_remote_kubectl || exit 1

# ★ 后端 SC 必须已存在(issue #206): --with-k8s 只跑基座, 会跳过 ceph_csi; 若 registry
#   用 ceph SC, PVC 会 Pending 到 REGISTRY_WAIT_SECONDS 超时。这里立即失败并给出恢复命令。
#   已 Bound 的 PVC 不依赖 SC 继续存在, 跳过检查避免误伤存量集群。
if [ -n "${REGISTRY_STORAGE_CLASS:-}" ] && [ "${REGISTRY_STORAGE_CLASS}" != "local-path" ]; then
    _reg_pvc_phase="$(SSH "${K}" -n kube-system get pvc registry-pvc -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [ "${_reg_pvc_phase}" != "Bound" ] \
        && ! SSH "${K}" get storageclass "${REGISTRY_STORAGE_CLASS}" >/dev/null 2>&1; then
        err "registry 后端 StorageClass '${REGISTRY_STORAGE_CLASS}' 尚不存在, registry-pvc 会一直 Pending"
        err "  external Ceph: 先运行 --steps ceph_csi(创建 CephConnection/StorageClass), 再重跑本模块"
        err "  internal Ceph: 先运行 --steps ceph,ceph_csi"
        err "  或把 REGISTRY_STORAGE_CLASS 改为 local-path"
        exit 1
    fi
    unset _reg_pvc_phase
fi
bash "${SCRIPT_DIR}/tools/lb/deploy-registry.sh"

# ---------------- 就绪等待(关键) ----------------
# registry pod 就绪前, 后续 push 镜像的模块(metax_gpu/ceph/...)会 ImagePullBackOff 且难定位。
# ceph-block 后端: registry-pvc 在 k8s 阶段创建时 SC 未出现 → Pending, ceph_csi 模块创建
# ceph-block SC 后(WaitForFirstConsumer)由首个消费者触发 RBD 卷创建/挂载, 需要额外时间。
# 就绪判定(任一层不可跳): ① PVC 已 Bound ② registry pod 1/1 Running ③ registry Service 暴露且 /v2/ 可达。
# 超时: 默认 600s(10 分钟), 覆盖首次 RBD 卷创建 + 镜像下载; CEPH/大镜像环境可 REGISTRY_WAIT_SECONDS 调整。
# ⚠ set -u 安全: 必须无条件赋默认值 —— `${VAR:-600}` 在 [ ] 判断里展开为 600 后判断为真,
#   `|| VAR=600` 永不执行 → VAR 从未赋值 → 后续裸引用 unbound(曾致模块在部署成功后崩溃)。
REGISTRY_WAIT_SECONDS="${REGISTRY_WAIT_SECONDS:-600}"
_READY=0
_CSI_STALE_FIXED=0
for _i in $(seq 1 $((REGISTRY_WAIT_SECONDS / 10))); do
    _pc="$( (SSH "${K} -n kube-system get pvc registry-pvc -o jsonpath='{.status.phase}' 2>/dev/null" || true) )"
    if [ -z "${_pc}" ] || [ "${_pc}" != "Bound" ]; then
        # ★ 2026-10-19 实机: ceph-block SC 晚于 registry PVC 出现时, CSI 可能创建了 RBD 卷
        #   但 PV 未绑定; 后续重试一直报 "Volume ID pvc-... already exists", PVC 永远 Pending。
        #   一次性清理 rbd-pool 半成品镜像并重启 RBD CSI controller, 让 provisioner 重建。
        #   ⚠ 必须**周期**检查(每 30s)而不是只在第 6 次看一次: 实机的 already-exists 事件在
        #   等待约 4 分钟后才出现, 一次性检查会错过 → 600s 超时(2026-10-19 实机)。
        if [ "${_CSI_STALE_FIXED}" = "0" ] && [ "${_i}" -ge 3 ] && [ $((_i % 3)) -eq 0 ]; then
            _ev="$( (SSH "${K} -n kube-system describe pvc registry-pvc 2>/dev/null") || true )"
            if printf '%s' "${_ev}" | grep -q 'already exists'; then
                warn "  registry PVC CSI 半成品卷(already exists) → 清 rbd-pool + 重启 RBD CSI controller..."
                SSH "timeout 60 ${K} -n rook-ceph exec deploy/rook-ceph-tools -- timeout 30 sh -c 'for i in \$(rbd ls -p rbd-pool 2>/dev/null); do rbd snap purge rbd-pool/\$i >/dev/null 2>&1 || true; rbd rm rbd-pool/\$i >/dev/null 2>&1 || true; done'" >/dev/null 2>&1 || true
                SSH "${K} -n rook-ceph rollout restart deploy/rook-ceph.rbd.csi.ceph.com-ctrlplugin >/dev/null 2>&1" || true
                _CSI_STALE_FIXED=1
            fi
        fi
        [ "$((_i % 6))" -eq 0 ] && say "  registry-pvc 未 Bound(当前 ${_pc:-<无>}, 等 ${REGISTRY_STORAGE_CLASS:-local-path} SC 供给), 等待第 ${_i}/$((REGISTRY_WAIT_SECONDS / 10)) 次 ..."
        sleep 10; continue
    fi
    _pod="$( (SSH "${K} -n kube-system get pod -l k8s-app=registry -o jsonpath='{.items[0].status.phase}' 2>/dev/null" || true) )"
    _rdy="$( (SSH "${K} -n kube-system get pod -l k8s-app=registry -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null" || true) )"
    if [ "${_pod}" = "Running" ] && [ "${_rdy}" = "true" ]; then
        # 就绪探测用**推送同款**直连端点(REGISTRY_DIRECT: nodeport=REGISTRY_IP:NODEPORT,
        # loadbalancer=REGISTRY_IP:PORT)。旧逻辑 nodeport 固定 FIRST_MASTER: 显式
        # REGISTRY_IP 指向其他节点时会 curl 错地址, 一直等到超时(2026-10-23 CodeRabbit)。
        _base="http://${REGISTRY_DIRECT:-${REGISTRY_IP:-localhost}:${REGISTRY_PORT:-5000}}"
        if curl -s -m 5 "${_base}/v2/" >/dev/null 2>&1; then _READY=1; break; fi
    fi
    [ "$((_i % 6))" -eq 0 ] && say "  registry pod 未就绪(${_pod:-<无>}/${_rdy:-<无>}), 等待第 ${_i}/$((REGISTRY_WAIT_SECONDS / 10)) 次 ..."
    sleep 10
done
if [ "${_READY}" = "1" ]; then
    ok "  registry 就绪: PVC ${_pc} / pod Running / ${_base}/v2/ 可达"
else
    err "  registry 未在 ${REGISTRY_WAIT_SECONDS}s 内就绪 —— 后端 ${REGISTRY_STORAGE_CLASS:-local-path}"
    # ★ 2026-09-24: 超时时**自动打印现场快照**(PVC 阶段 / pod 状态 / 最近的 PVC 事件)。
    #   之前只给"排查: kubectl get pvc,pods"的提示, 而真正费时的是猜"卡在哪一步"——
    #   实机那次的关键证据就是 PVC 事件里先后两条 `storageclass "ceph-block" not found`
    #   与随后的 `Provisioning ... Succeeded`(即 SC 出现得比 PVC 晚, 但最终自愈)。
    err "  —— 现场快照 ——"
    ( SSH "${K} -n kube-system get pvc registry-pvc -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,VOLUME:.spec.volumeName,SC:.spec.storageClassName --no-headers 2>/dev/null" || true ) | sed 's/^/    PVC  /' >&2
    ( SSH "${K} -n kube-system get pods -l k8s-app=registry -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready,NODE:.spec.nodeName --no-headers 2>/dev/null" || true ) | sed 's/^/    POD  /' >&2
    ( SSH "${K} -n kube-system get events --sort-by=.lastTimestamp 2>/dev/null | grep -iE registry | tail -6" || true ) | sed 's/^/    EVT  /' >&2
    err "  排查: kubectl -n kube-system get pvc,pods | grep registry(ceph-block: 先确认 ceph_csi 已建 SC ceph-block; 检查 rbd 卷创建, 见 docs/ceph-rook.md §8)"
    exit 1
fi

# ---------------- nodeport 模式: Pod 侧 DNS 指向 registry Service ClusterIP ----------------
# 背景(2026-11-20 实机, 容器 b): nodeport 暴露下节点 containerd 有
#   certs.d/registry.cubestack.io:5000/hosts.toml(server=http://<master>:31148), 拉镜像正常;
#   但 cubestack-operator 是在 **Pod 内**直接用 oci://<REGISTRY_DOMAIN>:5000/suanova/<chart>
#   拉组件 chart, 不走 containerd 的 hosts.toml 改写。Pod 按 dns_etchosts 解析到首个 master IP
#   的 5000, 而节点 5000 并未监听(只有 NodePort 31148) ⇒ cuberouter/cubepilot/
#   cubestack-controller-manager 持续 Degraded("dial tcp <master>:5000: connection refused"),
#   依赖它们的组件 Pod 不会创建; 镜像拉取链路本身不受影响, 所以症状只在 operator 侧出现。
# 修复: 集群就绪后把 CoreDNS/nodelocaldns 的 hosts 里 registry 域名改指 **Service ClusterIP**
#   (Service port 仍是 5000, Pod 内直连 ClusterIP:5000 实测可用)。节点侧 /etc/hosts +
#   containerd certs.d 保持 NodePort(<master>:31148) 不变, 镜像拉取路径不动。
#   ClusterIP 在 inventory 生成时未知, 所以只能在 registry 就绪后 patch。
# 注: 后续 k8s_deploy 会用 dns_etchosts 重渲染成节点 IP; 全量部署中本模块在其后执行, 会再次纠正。
_POD_DNS_EXPECT_IP=""
_patch_registry_pod_dns() {
    local _cip _cm _exists _cur _new _json
    _cip="$( (SSH "${K}" -n kube-system get svc registry -o jsonpath='{.spec.clusterIP}' 2>/dev/null) || true )"
    [ -n "${_cip}" ] || { warn "  未取到 registry Service ClusterIP, 跳过 Pod 侧 DNS 修正"; return 0; }
    for _cm in coredns nodelocaldns; do
        _exists="$( (SSH "${K}" -n kube-system get cm "${_cm}" --no-headers 2>/dev/null) || true )"
        if [ -z "${_exists}" ]; then
            if [ "${_cm}" = "coredns" ]; then
                err "  未找到 kube-system/coredns ConfigMap, 无法修正 Pod 侧 registry 解析"
                return 1
            fi
            warn "  未找到 kube-system/${_cm} ConfigMap(未启用 NodeLocalDNS?), 跳过"
            continue
        fi
        # 保留用户/其它组件写入的行, 只替换解析到 registry 域名的行(按第 2 列判断)。
        # ⚠ 失败关闭: 读取失败 ≠ 读到空内容。把 SSH/kubectl 失败当成空字符串会让后续
        #   patch 用只有 registry 一行的新值覆盖掉其它 hosts 映射, 因此这里区分返回码:
        #   读取成功但 .data.hosts 为空 → 允许继续; 读取失败 → 直接中止。
        if ! _cur="$(SSH "${K}" -n kube-system get cm "${_cm}" -o jsonpath='{.data.hosts}' 2>/dev/null)"; then
            err "  读取 kube-system/${_cm} 的 hosts 失败(无法确认现有映射, 拒绝覆盖)"
            return 1
        fi
        _new="$(printf '%s\n' "${_cur}" | python3 -c '
import sys
dom, ip = sys.argv[1], sys.argv[2]
keep = []
for line in sys.stdin.read().splitlines():
    parts = line.split()
    if not parts or (len(parts) >= 2 and parts[1] == dom):
        continue
    keep.append(line)
keep.append("%s %s" % (ip, dom))
print("\n".join(keep))
' "${REGISTRY_DOMAIN:-registry.cubestack.io}" "${_cip}")" \
            || { err "  解析 ${_cm} hosts 失败"; return 1; }
        _json="$(printf '%s' "${_new}" | python3 -c 'import json,sys; print(json.dumps({"data":{"hosts":sys.stdin.read()+"\n"}}))')" \
            || { err "  生成 ${_cm} patch 失败"; return 1; }
        if printf '%s' "${_json}" | SSH "${K}" -n kube-system patch cm "${_cm}" --type merge --patch-file=/dev/stdin >/dev/null 2>&1; then
            ok "  ${_cm}: registry 域名 → ${_cip}(Pod 侧端口 ${REGISTRY_PORT:-5000})"
        else
            err "  patch ${_cm} hosts 失败(operator 拉 chart 将不可用; 检查 CoreDNS/nodelocaldns)"
            return 1
        fi
    done
    _POD_DNS_EXPECT_IP="${_cip}"
    return 0
}

_REG_TYPE_LC="$(echo "${REGISTRY_SERVICE_TYPE:-nodeport}" | tr '[:upper:]' '[:lower:]')"
if [ "${_REG_TYPE_LC}" = "nodeport" ]; then
    say "  nodeport 模式: 修正 Pod 侧 registry DNS → Service ClusterIP(节点侧仍用 NodePort ${REGISTRY_NODEPORT:-31148})..."
    _patch_registry_pod_dns || exit 1
fi

# ---------------- Pod 内 registry 解析/访问自检(2026-11-19 实机; 2026-11-20 nodeport 修正) ----------------
# 节点侧 /etc/hosts 只覆盖宿主机与 containerd; Pod 走 CoreDNS/nodelocaldns, 之前拿不到
# registry 域名 → operator 拉 chart 报 `lookup registry.cubestack.io ... server misbehaving`。
# 这里用预加载的 busybox(不联网)从 Pod 内真实解析域名并打通 HTTP, 把"只有 operator 才暴露"
# 的问题提前到 registry 模块收尾。
# nodeport 模式(2026-11-20): 上方已把 Pod 侧 DNS 指向 Service ClusterIP, 因此自检走
# **ClusterIP 的 Service 端口 5000**(而不是 NodePort 31148); 节点侧 NodePort 可达性由就绪
# 等待的 _base curl 覆盖, 两条路径分别验证。
_DNS_IMAGE="$(mirror_image_ref "docker.io/library/busybox:${BUSYBOX_TAG:-1.38.0}")"
_DNS_DOMAIN="${REGISTRY_DOMAIN:-registry.cubestack.io}"
# set -u: clusterip 分支不设置期望 IP; 先给空默认值, 避免下面未加引号的 heredoc
# 展开 ${_DNS_EXPECT_IP} 时触发 unbound variable。nodeport/loadbalancer 分支会覆盖它。
_DNS_EXPECT_IP=""
# nodeport: 上方已把 Pod 侧 DNS 指向 Service ClusterIP, 这里按 **Service 端口 5000** 自检;
# 节点侧 NodePort(31148) 的可达性由上面的 _base curl 负责 —— 两条路径都要通。
if [ "${_REG_TYPE_LC}" = "nodeport" ]; then
    _DNS_PORT="${REGISTRY_PORT:-5000}"
    _DNS_EXPECT_IP="${_POD_DNS_EXPECT_IP}"
elif [ "${_REG_TYPE_LC}" = "clusterip" ]; then
    _DNS_PORT="${REGISTRY_PORT:-5000}"
    # ClusterIP 模式: sync 不写 dns_etchosts(实际 ClusterIP 部署前未知) → 改验 Service DNS。
    # 该模式下 registry.cubestack.io 仍需外部解析(入口/operator 侧另行配置), 这里只证明
    # "Pod 能访问 registry", 避免把已知限制当成部署失败。
    _DNS_TARGET="registry.kube-system.svc.cluster.local"
    warn "  registry 为 ClusterIP 模式: 不写 dns_etchosts, Pod 内改用 Service DNS 自检"
else
    _DNS_PORT="${REGISTRY_PORT:-5000}"
    _DNS_EXPECT_IP="${REGISTRY_IP:-}"
fi
_DNS_TARGET="${_DNS_TARGET:-${_DNS_DOMAIN}}"
# 预加载镜像缺失时不再把自检变成硬依赖(用户可裁剪 PRELOAD_IMAGE_PATTERNS):
# mirror 命名下没有该镜像 = 离线也拉不到, 给告警并跳过; 上游命名(online)允许 Pod 自行拉取。
if [ -n "$(harbor_mirror_base)" ] && ! SSH "sudo ctr -n k8s.io images ls -q 2>/dev/null | grep -Fx '${_DNS_IMAGE}'" >/dev/null 2>&1; then
    warn "  节点 containerd 无 ${_DNS_IMAGE}(PRELOAD_IMAGE_PATTERNS 未含 busybox?) → 跳过 Pod 内 DNS 自检"
    unset _DNS_IMAGE _DNS_DOMAIN _DNS_PORT _DNS_TARGET _DNS_EXPECT_IP
else
_DNS_POD="registry-dns-check-$$"
say "  Pod 内自检: 解析 ${_DNS_TARGET} 并访问 http://${_DNS_TARGET}:${_DNS_PORT}/v2/ ..."
rm -f "/tmp/${_DNS_POD}.yaml"
cat > "/tmp/${_DNS_POD}.yaml" <<DNSYAML
apiVersion: v1
kind: Pod
metadata:
  name: ${_DNS_POD}
  namespace: default
spec:
  restartPolicy: Never
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  containers:
    - name: check
      image: ${_DNS_IMAGE}
      imagePullPolicy: IfNotPresent
      command:
        - /bin/sh
        - -c
        - |
          set -e
          # CoreDNS/nodelocaldns 的 ConfigMap 投递到节点有延迟: 轮询到期望 IP 再访问。
          for _i in \$(seq 1 60); do
            _ip=\$(nslookup ${_DNS_TARGET} 2>/dev/null | sed -n 's/^Address:[[:space:]]*//p' | tail -1 | tr -d '[:space:]')
            if [ -z "${_DNS_EXPECT_IP}" ] || [ "\$_ip" = "${_DNS_EXPECT_IP}" ]; then break; fi
            sleep 2
          done
          nslookup ${_DNS_TARGET}
          printf 'GET /v2/ HTTP/1.0\r\n\r\n' | nc -w 5 ${_DNS_TARGET} ${_DNS_PORT} | head -n1 | grep -q 'HTTP/'
          echo OK
DNSYAML
scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -q \
    "/tmp/${_DNS_POD}.yaml" "${FIRST_MASTER_USER}@${FIRST_MASTER}:/tmp/${_DNS_POD}.yaml" \
    && SSH "${K} apply -f /tmp/${_DNS_POD}.yaml" >/dev/null \
    || { rm -f "/tmp/${_DNS_POD}.yaml"; err "  创建 DNS 自检 Pod 失败"; }
rm -f "/tmp/${_DNS_POD}.yaml"
_DNS_PHASE=""
for _i in $(seq 1 40); do
    _DNS_PHASE="$( (SSH "${K}" -n default get pod "${_DNS_POD}" -o jsonpath='{.status.phase}' 2>/dev/null) || true )"
    if [ "${_DNS_PHASE}" = "Succeeded" ] || [ "${_DNS_PHASE}" = "Failed" ]; then
        break
    fi
    sleep 5
done
_DNS_LOG="$( (SSH "${K}" -n default logs "${_DNS_POD}" 2>/dev/null) || true )"
SSH "${K}" -n default delete pod "${_DNS_POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
if [ "${_DNS_PHASE}" = "Succeeded" ] && printf '%s' "${_DNS_LOG}" | grep -q OK; then
    ok "  Pod 内解析并访问 registry 成功(${_DNS_TARGET}:${_DNS_PORT})"
else
    ( SSH "${K}" -n default describe pod "${_DNS_POD}" 2>/dev/null | grep -A8 'Events:' | tail -12 ) >&2 || true
    err "  Pod 内无法解析/访问 registry(${_DNS_TARGET}:${_DNS_PORT}, phase=${_DNS_PHASE:-?}, log=${_DNS_LOG:-<空>})"
    err "  排查: kubectl -n kube-system get cm coredns -o yaml | grep -A4 hosts(应含 ${_DNS_EXPECT_IP:-${REGISTRY_IP:-<ip>}} ${_DNS_DOMAIN});"
    if [ "${_REG_TYPE_LC}" = "nodeport" ]; then
        err "        nodeport 模式期望 Pod 侧解析到 Service ClusterIP ${_POD_DNS_EXPECT_IP:-<clusterIP>}, 并使用 Service 端口 ${_DNS_PORT}(节点侧仍走 NodePort ${REGISTRY_NODEPORT:-31148})"
    fi
    err "        nodelocaldns 同理(inventory 的 dns_etchosts 由 sync-kubespray-config.sh 写入后 kubespray 渲染; 本模块在其后 patch)"
    exit 1
fi
unset _DNS_IMAGE _DNS_DOMAIN _DNS_PORT _DNS_TARGET _DNS_POD _DNS_PHASE _DNS_LOG _DNS_EXPECT_IP _REG_TYPE_LC _POD_DNS_EXPECT_IP
fi

# ---------------- PVC 容量保障(存量集群幂等扩容; 2026-10-13 实机事故) ----------------
# 事故链: kubespray registry_disk_size 默认仅 10Gi → dev_lab 的首个镜像(当时 ≈1.6G)推完后盘满,
#   后续每个镜像(含 multus)的 blob 上传都被 registry 以 500 拒绝("no space left on device"),
#   且 skopeo 整包重试必然再满 —— 表象极具误导性("registry 可达但全部 500")。
# 契约: REGISTRY_DISK_SIZE(默认 200Gi, 与 sync-addons-config.sh 写入 addons.yml 的值同源)
#   须 ≥ 实际所需(dev_lab ≈21G + metax ≈8G + 滚动更新冗余)。新建 PVC 由 addons.yml 直接声明;
#   **存量/覆盖安装** 的 PVC 靠这里扩: 当前 spec < 目标 → patch 扩容并等 status.capacity 追平
#   (csi-resizer → rook RBD 在线扩 + 节点在线扩 FS, 实测秒级)。
# ⚠ 只比整数前缀(约定 "NNGi"); local-path 后端不支持扩容(本地目录不强制配额), 只提示不阻断。
_DESIRED_SIZE="${REGISTRY_DISK_SIZE:-200Gi}"
_CUR_SIZE="$( (SSH "${K} -n kube-system get pvc registry-pvc -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null" || true) )"
case "${_CUR_SIZE}" in
    ''|*[!0-9A-Za-z]*) ;;   # 拿不到/形态异常 → 跳过(不阻断; 容量问题会在 push 阶段显式暴露)
    *)
        case "${_DESIRED_SIZE%Gi}" in
            ''|*[!0-9]*) warn "  REGISTRY_DISK_SIZE=${_DESIRED_SIZE} 形态异常(约定 NNGi), 跳过容量保障" ;;
            *)
                if [ "${_CUR_SIZE%Gi}" -lt "${_DESIRED_SIZE%Gi}" ] 2>/dev/null; then
                    if [ "${REGISTRY_STORAGE_CLASS:-local-path}" = "local-path" ]; then
                        warn "  registry-pvc 容量 ${_CUR_SIZE} < REGISTRY_DISK_SIZE=${_DESIRED_SIZE}(local-path 不支持在线扩容, 仅提示; 本地目录不强制配额, 节点盘需实际放得下)"
                    else
                        say "  registry-pvc 扩容: ${_CUR_SIZE} → ${_DESIRED_SIZE}(存量集群兼容; dev_lab 等大镜像需要, 防盘满 500)"
                        if SSH "${K} -n kube-system patch pvc registry-pvc -p '{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"${_DESIRED_SIZE}\"}}}}' >/dev/null 2>&1"; then
                            _cap=""
                            for _j in $(seq 1 18); do
                                _cap="$( (SSH "${K} -n kube-system get pvc registry-pvc -o jsonpath='{.status.capacity.storage}' 2>/dev/null" || true) )"
                                [ "${_cap}" = "${_DESIRED_SIZE}" ] && break
                                sleep 10
                            done
                            if [ "${_cap}" = "${_DESIRED_SIZE}" ]; then
                                ok "  registry-pvc 已扩容至 ${_DESIRED_SIZE}"
                            else
                                warn "  registry-pvc 扩容未在 180s 内完成(当前 capacity=${_cap:-<无>}); 通常稍后自愈, 可重跑本模块复查(kubectl -n kube-system get pvc registry-pvc)"
                            fi
                        else
                            warn "  registry-pvc 扩容请求失败(检查 SC allowVolumeExpansion / PVC 事件; 手工: kubectl -n kube-system patch pvc registry-pvc -p '{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"${_DESIRED_SIZE}\"}}}}')"
                        fi
                    fi
                else
                    say "  registry-pvc 容量 ${_CUR_SIZE}(≥ REGISTRY_DISK_SIZE=${_DESIRED_SIZE}), 无需扩容"
                fi
                ;;
        esac
        ;;
esac

# ---------------- coredns 解析快照自愈(2026-10-13 实机根因, 双重验证) ----------------
# 根因链(实机抓包 + 对照实验闭环): kubelet 只在 **pod sandbox 创建时**写入 pod 的 /etc/resolv.conf,
#   之后容器级重启永不更新。部署中途节点端 /run/systemd/resolve/resolv.conf(由 resolved 动态生成,
#   其 FallbackDNS 含 upstream_dns_servers 的值)可能处于**瞬态**(含 127.0.0.1)。coredns 的 loop
#   插件会把探测查询(HINFO <两个随机数>)发往 pod resolv.conf 里的**每个 nameserver**; 发往
#   127.0.0.1:53, 在 pod 网络命名空间内 = **coredns 自己** → 收到自身探测 → 判回环 → FATAL 自杀。
#   sandbox 复用 ⇒ 容器无限重启、永不恢复(实机: 30 次崩溃 vs 同配置新 pod 零重启健康 —— 差异
#   仅在 sandbox 创建时刻)。稳定后新建的 pod(新 sandbox 读到干净文件)自然健康。
# ⇒ 自愈: 对"CrashLoopBackOff/Error 且最近日志含 plugin/loop"的 coredns pod 重建一次(刷新快照)。
# ⚠ 仅对明确 loop 症状动手; 重建后仍异常则只告警, 不与真实故障无限对抗。
_COREDNS_REPAIRED=0
for _p in $( (SSH "${K} -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[0].state.waiting.reason}{" "}{end}' 2>/dev/null" || true) ); do
    _name="${_p%%=*}"; _why="${_p#*=}"
    case "${_why}" in
        *CrashLoopBackOff*|*Error*) ;;
        *) continue ;;   # Running/其他状态不动
    esac
    if ( (SSH "${K} -n kube-system logs ${_name} --previous --tail=20 2>/dev/null" || true) ) | grep -q "plugin/loop"; then
        warn "  coredns ${_name} 解析快照毒化(plugin/loop — sandbox 期 resolv.conf 含 127.0.0.1); 重建 pod 刷新快照 ..."
        SSH "${K} -n kube-system delete pod ${_name} --wait=false >/dev/null 2>&1" || true
        _COREDNS_REPAIRED=$((_COREDNS_REPAIRED + 1))
    fi
done
if [ "${_COREDNS_REPAIRED}" -gt 0 ]; then
    _ready=0
    for _i in $(seq 1 12); do
        _all="$( (SSH "${K} -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{" "}{end}' 2>/dev/null" || true) )"
        case "${_all}" in
            *false*|'') sleep 10 ;;
            *) _ready=1; break ;;
        esac
    done
    if [ "${_ready}" = "1" ]; then
        ok "  coredns 重建后已全部 Ready(解析快照自愈完成)"
    else
        warn "  coredns 重建后 120s 内未全部 Ready; 若仍报 plugin/loop, 检查节点解析链(见模块头注释)"
    fi
fi
unset _p _name _why _i _ready _all

ok "内置 registry 配置完成"

# 优雅覆盖登记(registry 就绪才登记)
record_installed_component "k8s_registry"
