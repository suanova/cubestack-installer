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
#         否则后续 push 镜像的模块(gpu_operator/ceph/...)会 ImagePullBackOff 且难以定位。
#     ⚠ 顺序保证: addon 阶段按文件序号执行 metallb→ceph→ceph_csi→local_path→registry;
#       ceph/ceph_csi 模块已内置"等集群 Ready / CSI 就绪"的等待。本模块额外等 registry 自身 Ready。
#   · PVC 容量保障(2026-10-13 实机事故): kubespray 默认 registry_disk_size=10Gi, 连一轮 dev_lab
#     (6 镜像 ≈ 47G)都放不下 —— 推到一半盘满后 registry 对**所有** push 返回 500
#     ("no space left on device"), 表象是"第一个镜像推成功、其余全部失败"。kubespray 重装 apply
#     不会让已存在的 PVC 变大 ⇒ 本模块对存量 PVC 幂等扩容到 REGISTRY_DISK_SIZE
#     (默认 200Gi, 与 sync-addons-config.sh 写入 addons.yml 的值同一数据源)。
#   · coredns 解析快照自愈(2026-10-13 实机): pod sandbox 创建期的 resolv.conf 快照若含 127.0.0.1
#     (部署中途 resolved 动态文件瞬态) ⇒ coredns loop 插件探测打到 pod 内自己的 127.0.0.1:53 →
#     误判回环 FATAL 无限重启; 本模块对"CrashLoopBackOff+plugin/loop"的 pod 重建一次即愈
#     (新 sandbox 快照稳定后的文件; 实机双对照: 旧 sandbox 30 次崩溃 vs 新 pod 零重启)。
# 数据源: cluster.conf (REGISTRY_DOMAIN / REGISTRY_IP / REGISTRY_PORT / REGISTRY_STORAGE_CLASS / REGISTRY_DISK_SIZE / CEPH_ENABLED / NODES)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

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
    exit 0
fi

# 开关: 默认不部署, REGISTRY_ENABLED=1/true 或 --steps/--enable 显式启用
if [ "${REGISTRY_ENABLED:-0}" != "1" ] && [ "${REGISTRY_ENABLED:-false}" != "true" ]; then
    say "跳过内置 registry(集群内 registry 默认不部署, 配置 REGISTRY_ENABLED=true 可启用)"
    exit 0
fi

# 前置校验: registry 后端指定 ceph 但 Ceph 体系未启用 → PVC 永久 Pending, 直接中止给出指引
# ceph 体系 = CEPH_ENABLED(internal 自建)或 CEPH_CSI_ENABLED(external 接入外部 Ceph), 任一 true 即可。
if [ -n "${REGISTRY_STORAGE_CLASS:-}" ] && [ "${REGISTRY_STORAGE_CLASS}" != "local-path" ] \
    && [ "${CEPH_ENABLED:-false}" != "true" ] && [ "${CEPH_CSI_ENABLED:-false}" != "true" ]; then
    err "REGISTRY_STORAGE_CLASS=${REGISTRY_STORAGE_CLASS} 但 Ceph 未启用(CEPH_ENABLED/CEPH_CSI_ENABLED 均非 true): registry 的 PVC 将永远 Pending"
    err "  请任选其一: ① cluster.conf 设 CEPH_ENABLED=true(集群内自建, 需先准备 ceph 离线镜像/裸盘, 见 docs/ceph-rook.md);"
    err "  ② CEPH_MODE=external + CEPH_CSI_ENABLED=true + CEPH_MONITORS/CEPH_KEYRING 接入外部 Ceph(见 docs/ceph-rook.md);"
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
bash "${SCRIPT_DIR}/tools/lb/deploy-registry.sh"

# ---------------- 就绪等待(关键) ----------------
# registry pod 就绪前, 后续 push 镜像的模块(gpu_operator/ceph/...)会 ImagePullBackOff 且难定位。
# ceph-block 后端: registry-pvc 在 k8s 阶段创建时 SC 未出现 → Pending, ceph_csi 模块创建
# ceph-block SC 后(WaitForFirstConsumer)由首个消费者触发 RBD 卷创建/挂载, 需要额外时间。
# 就绪判定(任一层不可跳): ① PVC 已 Bound ② registry pod 1/1 Running ③ registry Service 暴露且 /v2/ 可达。
# 超时: 默认 600s(10 分钟), 覆盖首次 RBD 卷创建 + 镜像下载; CEPH/大镜像环境可 REGISTRY_WAIT_SECONDS 调整。
# ⚠ set -u 安全: 必须无条件赋默认值 —— `${VAR:-600}` 在 [ ] 判断里展开为 600 后判断为真,
#   `|| VAR=600` 永不执行 → VAR 从未赋值 → 后续裸引用 unbound(曾致模块在部署成功后崩溃)。
REGISTRY_WAIT_SECONDS="${REGISTRY_WAIT_SECONDS:-600}"
_READY=0
for _i in $(seq 1 $((REGISTRY_WAIT_SECONDS / 10))); do
    _pc="$( (SSH "${K} -n kube-system get pvc registry-pvc -o jsonpath='{.status.phase}' 2>/dev/null" || true) )"
    if [ -z "${_pc}" ] || [ "${_pc}" != "Bound" ]; then
        [ "$((_i % 6))" -eq 0 ] && say "  registry-pvc 未 Bound(当前 ${_pc:-<无>}, 等 ${REGISTRY_STORAGE_CLASS:-local-path} SC 供给), 等待第 ${_i}/$((REGISTRY_WAIT_SECONDS / 10)) 次 ..."
        sleep 10; continue
    fi
    _pod="$( (SSH "${K} -n kube-system get pod -l k8s-app=registry -o jsonpath='{.items[0].status.phase}' 2>/dev/null" || true) )"
    _rdy="$( (SSH "${K} -n kube-system get pod -l k8s-app=registry -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null" || true) )"
    if [ "${_pod}" = "Running" ] && [ "${_rdy}" = "true" ]; then
        _base=""; [ "${SERVICE_EXPOSE_MODE:-nodeport}" = "nodeport" ] && _base="http://${FIRST_MASTER:-localhost}:${REGISTRY_NODEPORT:-31148}" || _base="http://${REGISTRY_IP:-localhost}:${REGISTRY_PORT:-5000}"
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

# ---------------- PVC 容量保障(存量集群幂等扩容; 2026-10-13 实机事故) ----------------
# 事故链: kubespray registry_disk_size 默认仅 10Gi → dev_lab 的 jupyter-minimal(≈1.6G)推完后盘满,
#   后续每个镜像(含 multus)的 blob 上传都被 registry 以 500 拒绝("no space left on device"),
#   且 skopeo 整包重试必然再满 —— 表象极具误导性("registry 可达但全部 500")。
# 契约: REGISTRY_DISK_SIZE(默认 200Gi, 与 sync-addons-config.sh 写入 addons.yml 的值同源)
#   须 ≥ 实际所需(dev_lab ≈47G + metax ≈8G + 滚动更新冗余)。新建 PVC 由 addons.yml 直接声明;
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
