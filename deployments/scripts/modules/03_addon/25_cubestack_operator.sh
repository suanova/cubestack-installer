#!/bin/bash
# ============================================================
# MODULE: cubestack_operator
# DESC: 部署 CubeStack 平台 Operator —— 本地 vendored chart 渲染提取镜像 → 推入集群内置
#       registry → helm upgrade --install(image.repository 指向集群 registry);
#       在线时每次部署比对 OCI chart digest 并刷新离线副本
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: CUBESTACK_OPERATOR_ENABLED
# UNINSTALL: 1
# REQUIRES: k8s_deploy k8s_registry
# 说明:
#   · 离线 / 在线(需求 1): CUBESTACK_OPERATOR_CHART_SYNC=offline(默认) —— 纯本地, 不发起联网动作;
#     显式 auto 时才探测 Harbor 可达性(可达→online 比对 digest, 否则 offline), 也可显式写 online 强制。
#     online: 拉远端 → 取 Digest 与 <tgz>.digest 边车比对 → 变了覆盖本地副本, 未变仓库保持干净。
#   · 部署模式切换(2026-10-13 用户口径; 2026-10-19 增补 Always/滚动):
#       ONLINE_DEPLOY_CUBESTACK_OPERATOR(true/false, 默认 false):
#       true  = **在线部署**: 镜像**按 chart 定义**(harbor.isuanova.com/**, 不覆盖不搬运)直接
#               拉取, 恒 pullPolicy=Always; 经 harbor-credentials secret 认证(无凭据时清空
#               imagePullSecrets 防"引用不存在的 secret 即 ImagePullBackOff"); 不推集群 registry。
#               同 :latest 新镜像靠 **digest podAnnotations** 触发滚动; digest 取不到时
#               helm 后 `rollout restart` 兜底。
#       false = **离线部署**(默认): 离线 tar → 推入集群内置 registry → 节点只从 registry 拉;
#               **同样恒 pullPolicy=Always**(2026-10-19 用户口径: 每次都从 registry 重新解析 tag);
#               CR 注入 registry 前缀 + 清 imagePullSecrets + digest podAnnotations 钉注。
#  · chart 来源(需求 2): oci://harbor.isuanova.com/suanova-private/cubestack-operator-chart,
#     离线副本 = deployments/offline-files/cubestack-operator/charts/<chart>-<版本>.tgz(+ .digest 边车),
#     随离线包(MinIO)分发, 与组件镜像 tar 同目录。安装**恒用这份本地副本** —— 线上拉到的东西
#     不直接装(见 scripts-development-spec §2.4)。旧路径 cubestack-addon/ 已不再参与解析。
#   · 镜像清单(需求 4): **从 chart 渲染结果动态提取**(不写死清单); 逐个推入集群内置 registry。
#     离线 tar 目录 = deployments/offline-files/cubestack-operator/(联网机用
#     tools/images/harbor-save-images.sh --group cubestack-operator 生成**本体**)。
#   ★ 2026-10-16 起平台组件 tar 按组件分子目录(offline-files/cubestack-operator/<组件>/,
#     组件名 = CR spec.components; 顶层 = operator 本体; charts/ = helm chart, 非组件); 单独更新某组件时可用
#     CUBESTACK_OPERATOR_COMPONENTS="<组件>" 只推它的镜像(见 [4b/6] 与目录 README)。
#   · 镜像拉取(需求 5): 节点**只从集群内置 registry 拉取**(--set image.repository=
#     <REGISTRY_DOMAIN>:<port>/suanova-private/cubestack-operator), 部署时节点不访问 Harbor。
#   · REPEAT:1(每次执行, 不是断点续跑): 滚动 chart(1.0.0-latest)与 release chart(如 2.0.0)
#     都每次执行; 滚动 chart 镜像 tag=latest, release chart 的 tag 由 chart 自带。
#     每次部署都必须重新比对刷新 —— REPEAT:0 的"完成后跳过"会让它永远停在首次拉到的版本。
#     安装本身幂等: helm upgrade --install + 镜像按 digest 比对后才推。
#   · 滚动 tag 的节点缓存陷阱(重要): 滚动 chart 的镜像 ref 恒为 ...:latest, 若只改内容不改 ref,
#     kubelet 在 IfNotPresent 下会直接用节点缓存 → 部署"成功"但跑的是旧镜像, 且 Deployment spec
#     没变不会触发滚动。故本模块: ① 把 operator 镜像的 **digest** 写进 podAnnotations
#     (cubestack.io/image-digest), digest 变了 pod 模板就变 → 自动滚动(**离线/在线都启用**;
#     2026-10-19 修复: 在线只靠 Always 不会重启运行中的旧 pod); ② pullPolicy **离线/在线恒 Always**
#     (每次新建 Pod 都从 registry/Harbor 重新解析 tag)。release chart(如 2.0.0)镜像 tag 由 chart
#     自带, installer **不再** --set image.tag 覆盖; CUBESTACK_OPERATOR_IMAGE_TAG 只用于清单登记。
#   · HA 拓扑(2026-10-27 用户口径): 按 cluster.conf NODES 的 master 数量自动决定 ——
#     1~2 台 master = non-HA: operator replicas=1 + CubeStackCluster.spec.global.ha.enabled=false;
#     >=3 台 master = HA: operator replicas=2 + CR global.ha.enabled=true(并显式 ha.replicas=2)。
#     与 master 是否 cordon 无关; 部署后还会对活体 CR/Deployment 做一次纠偏。
# 数据源: cluster.conf (CUBESTACK_OPERATOR_* / ONLINE_DEPLOY_CUBESTACK_OPERATOR / REGISTRY_* / HARBOR_MIRROR_* / NODES / SSH_KEY_NAME)
# 用法:   sudo ./deploy-cluster.sh --steps cubestack_operator
# 验证:   sudo ./deploy-cluster.sh --steps verify_cubestack_operator
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# 清除平台命名空间里"控制器已不在"的卡死 finalizer(2026-10-19 实机)。
# 现象: CSC CR 级联把 cuberouter 命名空间置 Terminating 时, opstree redis-operator
#   随命名空间一起被删, RedisReplication 的 redisReplicationFinalizer 无人执行 →
#   命名空间永久 Terminating → 下一轮覆盖部署无法重建 cuberouter(--fresh 失败)。
# 口径: 只处理带 cubestack.io/managed-by=cubestack-operator 标签且**已 Terminating**
#   的命名空间; Active 命名空间绝不触碰。逐个列出仍在的资源, 清空其 finalizers,
#   再等命名空间消失; 仍不消失才清 namespace finalizer(最后兜底)。
cleanup_stuck_managed_namespaces() {
    local _nss _line _ns _dt _out _i
    _nss="$( (SSH "${K} get ns -l cubestack.io/managed-by=cubestack-operator -o name 2>/dev/null") || true )"
    [ -n "${_nss}" ] || return 0
    while IFS= read -r _line; do
        [ -n "${_line}" ] || continue
        _ns="${_line#namespace/}"
        _dt="$( (SSH "${K} get ns ${_ns} -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null") || true )"
        case "${_dt}" in ""|null) continue ;; esac
        say "  清理卡死的 Terminating 命名空间 ${_ns} 的 finalizer..."
        _out="$(SSH "bash -s -- ${_ns}" <<'EOS'
set -u
ns="$1"
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"
for r in $(${K} api-resources --verbs=list --namespaced -o name 2>/dev/null); do
    ${K} -n "$ns" get "$r" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.finalizers}{"\n"}{end}' 2>/dev/null \
      | while IFS=$'\t' read -r n f; do
            [ -n "$n" ] || continue
            case "$f" in ""|"[]") continue ;; esac
            echo "CLEARED ${r} ${n} ${f}"
            ${K} -n "$ns" patch "$r" "$n" --type=merge \
                -p '{"metadata":{"finalizers":null}}' </dev/null >/dev/null 2>&1 || true
        done
done
EOS
)"
        [ -n "${_out}" ] && printf '%s\n' "${_out}" | sed 's/^/    /'
        for _i in $(seq 1 12); do
            SSH "${K} get ns ${_ns} --no-headers >/dev/null 2>&1" || break
            sleep 5
        done
        if SSH "${K} get ns ${_ns} --no-headers >/dev/null 2>&1"; then
            warn "  ${_ns} 仍 Terminating → 清 namespace finalizer 强制终结"
            printf '%s' '{"spec":{"finalizers":[]}}' \
                | SSH "${K} patch ns ${_ns} --type=merge --patch-file=/dev/stdin >/dev/null 2>&1 || true
            SSH "${K} delete ns ${_ns} --ignore-not-found --force --grace-period=0 </dev/null >/dev/null 2>&1 || true
        else
            ok "  ${_ns} 已删除"
        fi
    done <<< "${_nss}"
    return 0
}

# ---------------- 推送后触发 ImagePullBackOff Pod 重新拉取 ----------------
# 离线模式 [4/6]/[4b/6] 把 tar 推入 registry 后，kubelet 对 ImagePullBackOff 的退避
# 可达 5 分钟；仅推镜像不会立刻重试（2026-10-23 A 集群实机：镜像已推进 registry，
# portal/controller-manager 仍停在 11h 前的 not found 事件）。
# 只删除**镜像命中本次平台镜像集合**且处于 ImagePullBackOff/ErrImagePull 的 Pod，
# 由 Deployment/RS/Operator 重建后立即重新拉取；不碰其他故障 Pod（如 PVC Pending）。
# 用法: _reroll_stuck_pods <ref...>
_reroll_stuck_pods() {
    local _refs=("$@") _json _ns _pod _img _reason _r
    [ "${#_refs[@]}" -gt 0 ] || return 0
    _json="$( (SSH "${K} get pods -A -o json" 2>/dev/null) || true )"
    [ -n "${_json}" ] || return 0
    printf '%s' "${_json}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for p in d.get("items", []):
    md = p.get("metadata", {}) or {}
    for cs in (p.get("status", {}) or {}).get("containerStatuses", []) or []:
        w = (cs.get("state", {}) or {}).get("waiting", {}) or {}
        if w.get("reason") in ("ImagePullBackOff", "ErrImagePull"):
            print("%s\t%s\t%s\t%s" % (md.get("namespace", ""), md.get("name", ""), cs.get("image", ""), w.get("reason")))
            break
' | while IFS=$'\t' read -r _ns _pod _img _reason; do
        [ -n "${_ns}" ] && [ -n "${_pod}" ] || continue
        for _r in "${_refs[@]}"; do
            if [ "${_img}" = "${_r}" ]; then
                say "  ${_ns}/${_pod} 镜像已就绪但仍 ${_reason} → 删除 Pod 触发重新拉取"
                # ★ stdin 必须接 /dev/null: ssh 会把 stdin 转发给远端命令, 不重定向时
                #   ssh 会吞掉 while 循环的管道输入 → 只删第一个命中的 Pod 就提前结束
                #   (2026-10-23 A 集群实机: portal/controller-manager 未被重拉, 滞留 ImagePullBackOff)。
                SSH "${K} -n ${_ns} delete pod ${_pod} --wait=false >/dev/null 2>&1" < /dev/null || true
                break
            fi
        done
    done
}

# 卸载分支(优雅覆盖): ① 删平台实例 CR(clusterCR) → operator 级联优雅收掉 9 个平台组件
#   (含 ceph PVC 消费者, 等在飞 IO 收敛) ② helm uninstall operator(尽力; 需宿主机 kubeconfig)
#   ③ 命名空间/CRD 残留清理。⚠ 位于 TOGGLE 检查之前。
if [ "${CUBESTACK_MODULE_ACTION:-install}" = "uninstall" ]; then
    init_remote_kubectl || exit 1
    _ns="${CUBESTACK_OPERATOR_NAMESPACE:-cubestack-system}"
    _rel="${CUBESTACK_OPERATOR_RELEASE:-cubestack-operator}"
    _have=0
    SSH "${K} -n ${_ns} get deploy ${_rel} --no-headers >/dev/null 2>&1" && _have=1
    SSH "${K} -n ${_ns} get csc --no-headers >/dev/null 2>&1" && _have=1
    SSH "${K} get ns ${_ns} >/dev/null 2>&1" && _have=1
    if [ "${_have}" = "0" ]; then
        say "  cubestack-operator 不存在, 跳过"
        exit 0
    fi
    # ① 删平台实例 CR(级联收组件: 先 CR 后 operator —— CR 的 finalizer 需要 operator 活着处理)
    # 收敛等待上界(秒); env 可调, 主要供夹具测试(CUBESTACK_OPERATOR_CR_WAIT_SECONDS=10)
    _CR_WAIT_SECONDS="${CUBESTACK_OPERATOR_CR_WAIT_SECONDS:-120}"
    _CR_WAIT_TRIES=$(( _CR_WAIT_SECONDS / 10 )); [ "${_CR_WAIT_TRIES}" -ge 1 ] || _CR_WAIT_TRIES=1
    _CR_STUCK=0
    _crs="$( (SSH "${K} -n ${_ns} get csc -o name 2>/dev/null") || true)"
    if [ -n "${_crs}" ]; then
        say "  ① 删除平台实例 CR(级联收组件)..."
        while IFS= read -r _cr; do
            [ -n "${_cr}" ] && SSH "${K} -n ${_ns} delete "${_cr}" --wait=false >/dev/null 2>&1" || true
        done <<< "${_crs}"
        # ★ 收敛判据 = **csc CR 本体消失**(finalizer 完成的契约信号; 2026-10-13 CodeRabbit)。
        #   旧判据是"Pod 计数"(Running/Completed 视为已收敛) —— 但 delete --wait=false 立即返回,
        #   级联尚未开始时组件 Pod 全是 Running → 首轮检查即"收敛"放行, 等待形同虚设; 且
        #   Running 本就不代表级联完成。等 CR 消失 = operator 把组件(含在飞 IO)全部收干净。
        #   ⚠ 必须在 ② helm uninstall **之前**等: finalizer 靠 operator 执行, 先杀 operator
        #   会把 CR 永久卡在 Terminating(后续 ③ 再强删 ns 就走到"孤儿对象"路径)。
        say "  ① 等待 CR 终结(finalizer 级联完成; ≤$(( _CR_WAIT_SECONDS ))s)..."
        _CR_LEFT=1
        for _wi in $(seq 1 "${_CR_WAIT_TRIES}"); do
            _crs_now="$( (SSH "${K} -n ${_ns} get csc --no-headers 2>/dev/null") || true)"
            if [ -z "${_crs_now}" ]; then _CR_LEFT=0; break; fi
            [ "${_wi}" -lt "${_CR_WAIT_TRIES}" ] && sleep 10 || true
        done
        if [ "${_CR_LEFT}" = "1" ]; then
            _CR_STUCK=1
            warn "  平台实例 CR 未在 $(( _CR_WAIT_SECONDS ))s 内终结完成(级联未收敛)"
        fi
    fi
    # ★ 2026-10-13(CodeRabbit): **CR 残留 → 保留 operator**(finalizer 需要它活着执行), 提前
    #   告警 + 跳过全部后续破坏性步骤(helm uninstall / ns finalizer 清除 / 强制删 ns / CRD
    #   清理)并**非 0 退出** —— 引擎(run_component)据此不把本组件标 uninstalled(登记保持
    #   诚实), 优雅覆盖链对此容忍(告警继续)。kill 掉 operator 会把残留 CR 永久卡在
    #   Terminating; 保留它, 级联终结还有机会自行完成(重装链的 operator 亦会接管)。
    #   (采纳远端 CodeRabbit 平行修复的取向: 此判定必须先于 helm uninstall)
    if [ "${_CR_STUCK}" = "1" ]; then
        warn "  跳过 helm uninstall / ns finalizer 清除 / 强制删 ns / CRD 清理(CR 残留, 防孤儿对象复活)"
        warn "  排查: kubectl -n ${_ns} get csc -o yaml(看 finalizer 卡点) / kubectl -n ${_ns} get pods"
        warn "  cubestack-operator 卸载未完全收敛(operator 保留运行, 继续处理残留 CR)"
        exit 1
    fi
    # ①b CR 已终结 = 级联已完成; 收掉被级联删除但卡在 Terminating 的平台命名空间
    #   (如 cuberouter 的 redisReplicationFinalizer, 控制器已随命名空间退出)。
    cleanup_stuck_managed_namespaces
    # ② helm uninstall operator(尽力)
    if command -v helm >/dev/null 2>&1 && sync_kubeconfig >/dev/null 2>&1; then
        say "  ② helm uninstall ${_rel}(ns=${_ns})..."
        helm uninstall "${_rel}" -n "${_ns}" --wait --timeout 180s >/dev/null 2>&1 \
            || warn "  helm uninstall 未完成(残留由命名空间清理兜底)"
    else
        warn "  helm 不可用 / kubeconfig 同步失败 → 跳过 helm uninstall"
    fi
    # ③ 命名空间 / CRD 残留清理(幂等; CRD 随 K8s 覆盖也会消亡, 这里完整卸载顺手清)
    # ★ 破坏性清理的前提是 **CR 已全部终结** —— 未终结场景已在 ② 之前提前告警 exit 1(保留
    #   operator); 能走到此处 = CR 干净。语义(2026-10-13 CodeRabbit): 清 ns finalizer +
    #   强制删 ns 会把仍带 finalizer 的对象孤儿化(重装 --create-namespace 后可能复活);
    #   CRD 删除同理会把残留 CR 链式卡死(重装的 [5/6] CRD apply 也会撞上 Terminating CRD)。
    SSH "${K} patch ns ${_ns} --type=merge -p '{\"metadata\":{\"finalizers\":null}}' >/dev/null 2>&1" || true
    SSH "${K} delete ns ${_ns} --ignore-not-found --force --grace-period=0 >/dev/null 2>&1" || true
    for _crd in $( (SSH "${K} get crd -o name 2>/dev/null") | grep -i cubestack || true); do
        # ★ 2026-10-23 C 集群实机: 组件控制器先被删后, CRD 下残留 CR(如 devenvironment/test)
        #   的 finalizer 无人摘 → delete crd 卡在 customresourcecleanup 上无限等待。
        #   助手会反复清 CR finalizers, 有界等待(默认 60s), 超时摘 CRD finalizer 兜底。
        delete_crd_with_finalizer_cleanup "${_crd}" \
            "${CUBESTACK_OPERATOR_CRD_CLEANUP_WAIT_SECONDS:-60}"
    done
    ok "  cubestack-operator 已卸载(CR 级联 + helm uninstall + 残留清理)"
    exit 0
fi

# ---- 开关 ----
[ "${CUBESTACK_OPERATOR_ENABLED:-false}" = "true" ] || { say "CUBESTACK_OPERATOR_ENABLED=false, 跳过 CubeStack Operator 部署"; exit 0; }

init_remote_kubectl || exit 1
command -v helm >/dev/null 2>&1 || { err "未找到 helm(需 3.0+): 本模块用 helm template 提取镜像 + helm upgrade --install 安装(CLI 镜像已内置)"; exit 1; }

# ★ 2026-10-27 拓扑派生(用户口径): master 数量决定 operator 副本与平台 HA ——
#   · 仅 1 台 master(或 2 台): non-HA → operator replicas=1, CR spec.global.ha.enabled=false;
#   · 3 台及以上 master: HA → operator replicas=2(leader-election 热备), CR ha.enabled=true
#     (+ ha.replicas=2, 让 catalog 声明了 replica/反亲和的组件按 HA 展开)。
#   与 master 是否 cordon 无关; 只看 cluster.conf NODES 中 role=master 的数量。
read -r _MASTER_COUNT OP_REPLICAS HA_ENABLED <<< "$(cubestack_operator_ha_profile)"
say "  拓扑派生: master=${_MASTER_COUNT} 台 → operator replicas=${OP_REPLICAS}, clusterCR.spec.global.ha.enabled=${HA_ENABLED}"

# ---------------- 派生变量(全部来自 cluster.conf, 无硬编码) ----------------
NS="${CUBESTACK_OPERATOR_NAMESPACE:-cubestack-system}"
RELEASE="${CUBESTACK_OPERATOR_RELEASE:-cubestack-operator}"
CHART_REF="${CUBESTACK_OPERATOR_CHART_REF:-oci://harbor.isuanova.com/suanova-private/cubestack-operator-chart}"
CHART_VER="${CUBESTACK_OPERATOR_CHART_VERSION:-1.0.0-latest}"
CHART_NAME="$(basename "${CHART_REF}")"                      # cubestack-operator-chart
CHART_BASENAME="${CHART_NAME}-${CHART_VER}.tgz"
SYNC_MODE="${CUBESTACK_OPERATOR_CHART_SYNC:-offline}"
# operator 镜像 tag: 默认由 chart 自带(appVersion / values.image.tag); 允许 chart 版本与
# operator 版本不同(如 chart 1.0.0-latest + operator 2.0.0-rc1)。决策函数见下方 _IMG_TAG_FOR_HELM。
IMG_SRC_MODE="${CUBESTACK_OPERATOR_IMAGE_SOURCE:-auto}"
# operator 镜像 tag 决策(2026-10-22):
#   空 = **完全跟随 chart 自带版本**(appVersion / values.image.tag);
#   非空 = 显式 CUBESTACK_OPERATOR_IMAGE_TAG_OVERRIDE —— 只覆盖 cubestack-operator 自身镜像,
#          不覆盖 operator 内 catalog 定义的其他组件(平台 operator/服务)版本。
_IMG_TAG_FOR_HELM="$(operator_image_tag_for_helm "${CUBESTACK_OPERATOR_IMAGE_TAG_OVERRIDE:-}")"
_TAG_SET_ARGS=()
[ -n "${_IMG_TAG_FOR_HELM}" ] && _TAG_SET_ARGS+=( --set "image.tag=${_IMG_TAG_FOR_HELM}" )
ONLINE_DEPLOY="${ONLINE_DEPLOY_CUBESTACK_OPERATOR:-false}"   # 部署模式: true=在线(按 chart 定义恒拉); false=离线(tar→集群 registry)
IMG_PULL_POLICY="Always"   # 2026-10-19 用户口径: 离线/在线都恒 Always —— 离线镜像已推入集群 registry
                           # (在线从 Harbor 拉), 每次新建 Pod 必须重新解析 tag, 防止节点缓存旧镜像。
                           # CUBESTACK_OPERATOR_IMAGE_PULL_POLICY 保留兼容但不再生效(见 cluster.defaults.conf)。
PIN_DIGEST="${CUBESTACK_OPERATOR_PIN_IMAGE_DIGEST:-true}"
OFFLINE_DIR="${CUBESTACK_OPERATOR_OFFLINE_DIR:-${REPO_ROOT}/deployments/offline-files/cubestack-operator}"
# chart 跟随离线包分发: 默认在离线包的 charts/ 子目录(dev/release 均同构); 不再使用 cubestack-addon 旧路径。
EXPLICIT_CHART_DIR="${CUBESTACK_OPERATOR_CHART_DIR:-}"
PRIMARY_CHART_DIR="${OFFLINE_DIR}/charts"
CHART_DIR=""
CHART_SOURCE=""
CHART_TGZ=""
CR_ENABLED="${CUBESTACK_OPERATOR_CLUSTER_CR_ENABLED:-true}"
CR_VALUES_FILE="${CUBESTACK_OPERATOR_CR_VALUES_FILE:-}"
BUNDLES_ENABLED="${CUBESTACK_OPERATOR_MODEL_BUNDLES_ENABLED:-true}"   # 默认 true=保留 chart 的 8 个 bundles
# 只接受显式 true|false: 大写/笔误(如 TRUE)不得静默落到"清空 bundles"分支(CodeRabbit 2026-10-20)。
case "${BUNDLES_ENABLED}" in
    true|false) : ;;
    *) err "CUBESTACK_OPERATOR_MODEL_BUNDLES_ENABLED 仅接受 true|false(当前=${BUNDLES_ENABLED})"; exit 1 ;;
esac
HARBOR_HOST="${CUBESTACK_OPERATOR_HARBOR_HOST:-${HARBOR_MIRROR_REGISTRY:-harbor.isuanova.com}}"
# 私有项目凭据: 未单独配置时复用镜像源凭据(HARBOR_MIRROR_USER/PASSWORD, 同一台 Harbor)
HARBOR_USER="${CUBESTACK_OPERATOR_HARBOR_USER:-${HARBOR_MIRROR_USER:-}}"
HARBOR_PASSWORD="${CUBESTACK_OPERATOR_HARBOR_PASSWORD:-${HARBOR_MIRROR_PASSWORD:-}}"
# 集群内置 registry 双端点(与 gpu_operator 同款):
#   REG_BASE   = 节点可解析的域名端点(K8s 按此拉取)   REG_DIRECT = 推送用直连端点(无 DNS 依赖)
REG_BASE="${REGISTRY_DOMAIN:-${REGISTRY_IP}}:${REGISTRY_PORT:-5000}"
REG_DIRECT="${REGISTRY_DIRECT:-${REGISTRY_IP:-$(first_master_ip)}:${REGISTRY_PORT:-5000}}"
_EXTRA_VALUES=()          # 额外 values 文件(-f)
_CR_VALUES=()             # clusterCR 相关 --set
# 两模式共用的基础 values: 空=chart 默认 tag; 非空=显式/release 默认 tag。
_BASE_SET_ARGS=( "${_TAG_SET_ARGS[@]}" )

# ---------------- 凭据(skokpeo / helm 共用, 不进 ps) ----------------
# 仅在**在线刷新 chart / 在线拉镜像**时需要; 部署路径(本地 chart + 集群 registry)不需要凭据。
_AUTH_FILE=""
_cleanup() { [ -n "${_AUTH_FILE}" ] && rm -f "${_AUTH_FILE}" || true; }
trap '_cleanup' EXIT
if [ -n "${HARBOR_USER}" ] && [ -n "${HARBOR_PASSWORD}" ]; then
    _AUTH_FILE="$(mktemp)"; chmod 600 "${_AUTH_FILE}"
    _b64="$(printf '%s:%s' "${HARBOR_USER}" "${HARBOR_PASSWORD}" | base64 -w0 2>/dev/null \
            || printf '%s:%s' "${HARBOR_USER}" "${HARBOR_PASSWORD}" | base64)"
    printf '{"auths":{"%s":{"auth":"%s"}}}' "${HARBOR_HOST}" "${_b64}" > "${_AUTH_FILE}"
    unset _b64
    export REGISTRY_AUTH_FILE="${_AUTH_FILE}"     # skopeo 读它(密码不进命令行, ps 看不到)
fi

# Harbor 可达性探测(000=不可达; 200/401 都算"在")。用 /v2/ 而非具体仓库: 只判"网络是否通"。
_harbor_reachable() {
    local code
    code="$(curl -s -o /dev/null -m 6 -w '%{http_code}' "https://${HARBOR_HOST}/v2/" 2>/dev/null || true)"
    [ -n "${code}" ] && [ "${code}" != "000" ]
}

# 解析同步模式: auto 由"能否连上 Harbor"决定 —— 离线机不会发起 chart 拉取(不阻塞部署),
# 联网机自动取最新。显式 online 时若网络不通, helm_chart_ensure 会降级回退本地副本(告警不中断)。
case "${SYNC_MODE}" in
    auto)    if _harbor_reachable; then _MODE=online; else _MODE=offline; fi ;;
    online|offline) _MODE="${SYNC_MODE}" ;;
    *) err "CUBESTACK_OPERATOR_CHART_SYNC 仅支持 auto|online|offline(当前=${SYNC_MODE})"; exit 1 ;;
esac

# chart 目录解析: 显式 CUBESTACK_OPERATOR_CHART_DIR 优先; 否则恒用离线包的 charts/。
# 旧 cubestack-addon 路径**不再参与解析** —— 手动构建镜像时不需要再往那里放 chart。
# 版本解析(2026-10-22): **不要求 installer 写死 chart 版本** —— 在目录里按
#   desired(CUBESTACK_OPERATOR_CHART_VERSION) / release(CUBESTACK_RELEASE) / Chart.yaml
#   版本定位; release 树通常只有一份 <释放版本>.tgz, 直接命中。
_resolve_chart_dir() {
    if [ -n "${EXPLICIT_CHART_DIR}" ]; then
        CHART_DIR="${EXPLICIT_CHART_DIR}"; CHART_SOURCE="explicit"
    else
        CHART_DIR="${PRIMARY_CHART_DIR}"; CHART_SOURCE="offline-bundle"
    fi
    local _hit=""
    if _hit="$(resolve_operator_chart_tgz "${CHART_DIR}" "${CHART_NAME}" \
                "${CUBESTACK_OPERATOR_CHART_VERSION:-}" "${CUBESTACK_RELEASE:-}")"; then
        CHART_TGZ="${_hit%%$'\t'*}"
        CHART_VER="${_hit#*$'\t'}"
        CHART_BASENAME="$(basename "${CHART_TGZ}")"
        vlog "  chart 定位: ${CHART_TGZ}(version=${CHART_VER}; desired=${CUBESTACK_OPERATOR_CHART_VERSION:-<空>}; release=${CUBESTACK_RELEASE:-<空>})"
    else
        # 未找到: 保留期望路径, 让 helm_chart_ensure/错误信息可读
        CHART_BASENAME="${CHART_NAME}-${CHART_VER}.tgz"
        CHART_TGZ="${CHART_DIR}/${CHART_BASENAME}"
        CHART_SOURCE="missing"
    fi
}

# 渲染提取镜像 ref(动态, 不写死): 只看行首为 image: 的键 —— 不会误匹配 imagePullPolicy/imagePullSecrets
_render_images() {
    helm template "${RELEASE}" "${CHART_TGZ}" -n "${NS}" "$@" 2>/dev/null \
        | sed -n 's/^[[:space:]]*image:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' \
        | sort -u
}

# 镜像 digest(取 amd64/linux 那一层的清单 digest; 取不到输出空 → 调用方保守重推, 不会误判)
#   ⚠ skopeo inspect **不支持** --override-arch(CLI 镜像内 1.16.1 实测), 多架构 index 上
#     {{.Digest}} 给的是 index 自身摘要、与"推过去的单架构镜像"不可比(会比不出相等而每次重推)。
#     故自己解析 --raw: index → 取 amd64/linux 条目的 digest; 单架构清单 → 清单字节的 sha256
#     (= 该清单在 registry 里的 digest, 与 --override-arch 推过去的目标同一比对空间)。
_digest() {   # <docker://ref | docker-archive:path>
    local ref="$1" raw=""
    raw="$(skopeo inspect --raw --tls-verify=false "${ref}" 2>/dev/null || true)"
    [ -n "${raw}" ] || return 0
    printf '%s' "${raw}" | python3 -c '
import hashlib, json, sys
raw = sys.stdin.buffer.read()
try:
    d = json.loads(raw)
except Exception:
    sys.exit(0)
ms = d.get("manifests")
if isinstance(ms, list):                 # 多架构 index → amd64/linux 条目
    for m in ms:
        p = m.get("platform") or {}
        if p.get("architecture") == "amd64" and p.get("os") == "linux":
            print(m.get("digest", "")); break
else:                                     # 单架构清单 → 字节 sha256 = 它自己的 digest
    print("sha256:" + hashlib.sha256(raw).hexdigest())
' 2>/dev/null || true
}

# 镜像**内容** digest(config digest): docker-archive ↔ registry 之间唯一可比的指纹。
# 为什么不能复用 _digest(manifest digest): `docker save` 存的是**未压缩层**, skopeo push
# 到 docker:// 默认重新 gzip → 层摘要与 manifest 字节全变, 源/目标 manifest digest 必然
# 不等 → 每次执行都重推(2026-10-23 A 集群实测: 54 个组件镜像全部重推, 幂等形同虚设)。
# config digest 覆盖 rootfs.diff_ids(未压缩层摘要)+ history, 与压缩方式无关; 相同即镜像
# 内容相同, 可安全跳过(实测自研/第三方镜像均一致)。
# 多架构 index 没有 config 字段 → 输出空 → 调用方保守重推, 不会误判。
_content_digest() {   # <docker://ref | docker-archive:path>
    local ref="$1"
    skopeo inspect --raw --tls-verify=false "${ref}" 2>/dev/null \
        | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d.get("manifests"), list):
    sys.exit(0)
print((d.get("config") or {}).get("digest", ""))
' 2>/dev/null || true
}

# ---------------- [1/6] chart 离线副本就绪(在线则比对 digest 刷新) ----------------
say "[1/6] chart 离线副本就绪(sync=${SYNC_MODE} → ${_MODE})..."
_resolve_chart_dir
if [ "${_MODE}" = "online" ]; then
    if [ -n "${HARBOR_USER}" ]; then
        # --password-stdin: 不进 ps/日志(与 harbor-save-images.sh 的 auth 文件同一考虑)
        printf '%s' "${HARBOR_PASSWORD}" | helm registry login "${HARBOR_HOST}" -u "${HARBOR_USER}" --password-stdin >/dev/null 2>&1 \
            || warn "  helm registry login ${HARBOR_HOST} 失败(检查凭据); 远端拉取将 401 → 自动回退本地离线副本"
    else
        warn "  未配置 ${HARBOR_HOST} 凭据(CUBESTACK_OPERATOR_HARBOR_USER/HARBOR_MIRROR_USER): 依赖既有 helm 登录态, 否则远端拉取 401 并回退本地副本"
    fi
fi
# 不在这里 exit: 让下面的 fail-fast 统一打印"搜索过哪些路径 + 怎么补料"
helm_chart_ensure "${RELEASE}" "${CHART_TGZ}" "${CHART_VER}" "${_MODE}" "${CHART_REF}" || true
if [ ! -f "${CHART_TGZ}" ]; then
    err "  chart 缺失: ${CHART_TGZ}(source=${CHART_SOURCE})"
    err "    已查找: ${EXPLICIT_CHART_DIR:-<未设置>} / ${PRIMARY_CHART_DIR}"
    if [ -d "${CHART_DIR}" ]; then
        _cands="$(cd "${CHART_DIR}" && ls -1 "${CHART_NAME}"-*.tgz 2>/dev/null | tr '\n' ' ' || true)"
        [ -n "${_cands}" ] && err "    目录内候选: ${_cands}"
        unset _cands
    fi
    err "    离线包: ./deployments/scripts/tools/offline/fetch-offline-from-minio.sh --sub cubestack-operator"
    [ -n "${CUBESTACK_RELEASE:-}" ] && err "    发布版本: ./deployments/scripts/tools/offline/fetch-offline-from-minio.sh --release ${CUBESTACK_RELEASE} --dest ${CUBESTACK_RELEASE_ROOT:-<本地桶根>}"
    err "    在线/手工: helm pull ${CHART_REF} --version ${CHART_VER} -d ${PRIMARY_CHART_DIR}"
    err "              并把 helm 输出的 Digest: 写入 ${CHART_BASENAME}.digest(不要用 sha256sum)"
    exit 1
fi
ok "  chart 就绪: ${CHART_TGZ}(source=${CHART_SOURCE}; 部署恒用它)"

# ---------------- [2/6] 前置检查 ----------------
say "[2/6] 前置检查(registry 可达 / 集群可达 / kubeconfig)..."
skopeo_require "cubestack_operator"
# 宿主机 /etc/hosts 收敛(registry 域名 → 当前集群 IP; 复用 ensure_hosts_entry, 防多集群残留旧 IP)
API_ENTRY_IP="$(api_entry_ip)" || exit 1
ensure_hosts_entry "${REGISTRY_IP}" "${REGISTRY_DOMAIN}"
ensure_hosts_entry "${API_ENTRY_IP}" "${API_DOMAIN}"
grep -qE "^${REGISTRY_IP}[[:space:]]+${REGISTRY_DOMAIN}" /etc/hosts 2>/dev/null \
    || warn "无法写入宿主机 /etc/hosts(非 root?), ${REGISTRY_DOMAIN} 可能无法从宿主按域名访问"
wait_registry_ready "http://${REG_DIRECT}/v2/" \
    || { err "集群内置 registry ${REG_DIRECT}/v2/ 不可达(检查 REGISTRY_* 与 k8s_registry 模块; REGISTRY_SERVICE_TYPE=${REGISTRY_SERVICE_TYPE:-nodeport})"; exit 1; }
SSH "${K} get nodes --no-headers >/dev/null 2>&1" \
    || { err "无法访问集群(${FIRST_MASTER}); 检查 kubectl/集群状态"; exit 1; }
# helm 从宿主连 API Server(kubeconfig 的 server 改写为 API_DOMAIN + 宿主机 DNAT, 见 sync_kubeconfig)
sync_kubeconfig >/dev/null 2>&1 \
    || { err "宿主机 kubeconfig 同步失败(admin.conf 下载失败?); helm 无法连集群"; exit 1; }
ok "  前置检查通过(registry=${REG_DIRECT}, API=${API_DOMAIN}→${API_ENTRY_IP})"

# ---------------- [3/6] 从 chart 渲染提取镜像清单(动态) ----------------
say "[3/6] 渲染 chart 提取镜像清单(helm template, 不写死清单)..."
EXTRA_CR_VALUES_ARG=()
if [ "${CR_ENABLED}" = "true" ]; then
    _CR_VALUES=( --set "clusterCR.enabled=true" )
    # HA 全局开关由 master 数量派生(见文首): 单 master=false(组件保持默认单副本);
    # >=3 master=true + ha.replicas=2(catalog 支持 HA 的组件展开 2 副本 + 反亲和)。
    _CR_VALUES+=( --set "clusterCR.spec.global.ha.enabled=${HA_ENABLED}" )
    if [ "${HA_ENABLED}" = "true" ]; then
        _CR_VALUES+=( --set "clusterCR.spec.global.ha.replicas=${OP_REPLICAS}" )
        # ★ 组件级 HA 例外(2026-10-27 容器 c 实测, 别再踩):
        #   · cuberouter Deployment 挂 RWO PVC(app-data/app-logs) → 2 副本必然 Multi-Attach,
        #     保持单副本(catalog 的 HA 注入路径 = cubeRouter.replicaCount);
        #   · lws 第 2 副本在 3 master 上因 CPU 不足 + required 反亲和 Pending, 保持单副本
        #     (catalog 的 HA 注入路径 = chart 顶层 replicaCount, 不是 controller.replicaCount)。
        #   用户 values 优先级高于 global HA 注入, 这两条覆盖可稳定收敛。
        _CR_VALUES+=(
            --set "clusterCR.spec.components.cuberouter.values.cubeRouter.replicaCount=1"
            --set "clusterCR.spec.components.lws.values.replicaCount=1"
        )
    fi
    # 服务暴露方式: CRD 默认是 nodeport, 但 metallb 集群必须显式写 loadbalancer, 否则
    # operator 渲染的组件 Service 会走 NodePort(2026-10-22 实机: CR 里看到 nodeport
    # 而集群实际用 MetalLB 时即为漏配)。Envoy Gateway 数据面另有 EnvoyProxy 兜底, 见 [6.2/6]。
    _want_expose="loadbalancer"
    [ "${SERVICE_EXPOSE_MODE:-metallb}" = "nodeport" ] && _want_expose="nodeport"
    _CR_VALUES+=( --set "clusterCR.spec.global.serviceExposeMode=${_want_expose}" )
    if [ "${ONLINE_DEPLOY}" = "true" ]; then
        # 在线部署: 镜像源**保留 chart 定义**(harbor.isuanova.com/suanova + /mirrors, 不覆盖不搬运),
        # 恒 Always 跟踪滚动 :latest; imagePullSecrets 保留 chart 默认(harbor-credentials, 由本模块
        # 用配置的凭据创建); 无凭据则清空 —— 引用不存在的 secret 会让组件直接 ImagePullBackOff。
        _CR_VALUES+=( --set "clusterCR.spec.global.imagePullPolicy=Always" )
        if [ -z "${HARBOR_USER}" ] || [ -z "${HARBOR_PASSWORD}" ]; then
            warn "  在线部署但未配置 Harbor 凭据(HARBOR_MIRROR_USER/PASSWORD 或 CUBESTACK_OPERATOR_HARBOR_*): 清空 imagePullSecrets(仅匿名可拉的镜像可用)"
            _CR_VALUES+=( --set-json "clusterCR.spec.global.imagePullSecrets=[]" )
        fi
    else
        # ★ 2026-10-08 平台组件离线链路: CR 全局镜像源注入 → **集群内置 registry**(离线可用性的关键)。
        #   自研组件走 imageRegistry(平铺布局), 第三方走 externalImageRegistryPrefix(原样前置);
        #   与 [4b/6] 的推送目标映射一一对应(镜像由本模块预先推入)。
        #   · imagePullSecrets 置空 —— 集群 registry 匿名可拉; 保留渲染默认(harbor-credentials)而
        #     Secret 不存在时, 所有组件会 ImagePullBackOff(k8s: 引用不存在的 pull secret 直接失败)。
        _CR_VALUES+=(
            --set "clusterCR.spec.global.imageRegistry=${REG_BASE}"
            --set "clusterCR.spec.global.externalImageRegistryPrefix=${REG_BASE}/mirrors"
            --set-json "clusterCR.spec.global.imagePullSecrets=[]"
            --set "clusterCR.spec.global.imagePullPolicy=Always"
        )
    fi
    # 模型 bundles 开关(2026-10-20 用户口径; 单步 --steps cubestack_operator 与全量部署共用):
    #   CUBESTACK_OPERATOR_MODEL_BUNDLES_ENABLED 默认 true = **不覆盖** chart 默认的
    #   spec.bundles(全部 8 个) / components.modelBundles(开启), 推理目录开箱可用;
    #   与上游 helm/cubestack-operator-chart/values.yaml 保持一致, 尽量减少定制。
    #   false = 显式清空 bundles + 关闭 modelBundles(只装平台服务)。
    #   开关仅接受 true|false; 其他值在变量派生处直接报配置错误退出(不会静默清空 bundles)。
    #   bmc 不在此开关内: 跟随 chart 默认(开启); 未建 cubestack-bmc-credentials Secret 时会 Degraded。
    #   自定义 bundle 列表/裁剪用 CUBESTACK_OPERATOR_CR_VALUES_FILE(-f): true 分支没有 --set 抢先,
    #   用户 values 文件能真正生效。
    if [ "${BUNDLES_ENABLED}" = "false" ]; then
        _CR_VALUES+=(
            --set-json "clusterCR.spec.bundles=[]"
            --set "clusterCR.spec.components.modelBundles.enabled=false"
        )
    fi
    EXTRA_CR_VALUES_ARG=( "${_CR_VALUES[@]}" )
fi
if [ -n "${CR_VALUES_FILE}" ]; then
    [ -f "${CR_VALUES_FILE}" ] || { err "CUBESTACK_OPERATOR_CR_VALUES_FILE 不存在: ${CR_VALUES_FILE}"; exit 1; }
    _EXTRA_VALUES=( -f "${CR_VALUES_FILE}" )
fi

SRC_IMAGES=()
while IFS= read -r _line; do
    [ -n "${_line}" ] && SRC_IMAGES+=("${_line}")
done < <( _render_images "${_BASE_SET_ARGS[@]}" "${EXTRA_CR_VALUES_ARG[@]}" "${_EXTRA_VALUES[@]}" )
[ "${#SRC_IMAGES[@]}" -gt 0 ] \
    || { err "chart 未渲染出任何镜像(helm template 失败? 手工确认: helm template ${RELEASE} ${CHART_TGZ} -n ${NS})"; exit 1; }
say "  chart 需要 ${#SRC_IMAGES[@]} 个镜像:"
for _img in "${SRC_IMAGES[@]}"; do say "    ${_img}"; done

# operator 镜像识别(用于 digest 注解; chart 多镜像时按路径匹配, 兜底第一个)
_OP_IMAGE=""
for _img in "${SRC_IMAGES[@]}"; do
    case "${_img}" in *"/cubestack-operator:"*) _OP_IMAGE="${_img}"; break ;; esac
done
[ -n "${_OP_IMAGE}" ] || _OP_IMAGE="${SRC_IMAGES[0]}"
# 镜像 tag 来源(2026-10-22): 空=chart 自带; 非空=显式 override(仅 operator 自身镜像)。
if [ -n "${_IMG_TAG_FOR_HELM}" ]; then
    _TAG_SRC="显式 override(仅 operator 镜像; 其他组件版本由 operator catalog 决定)"
else
    _TAG_SRC="chart 默认(appVersion/values.image.tag)"
fi
say "  operator 镜像 tag: ${_OP_IMAGE##*:}(来源: ${_TAG_SRC}; chart ${CHART_VER})"
unset _TAG_SRC
if [ -n "${CUBESTACK_RELEASE:-}" ]; then
    # release 版本不允许 :latest(发布清单的硬约束); chart 未带正确版本时直接失败,
    # 避免把滚动 :latest 镜像当成 release 2.0.0 部署。
    if [ "${_OP_IMAGE##*:}" = "latest" ]; then
        err "release ${CUBESTACK_RELEASE} 的 operator chart 渲染出 :latest —— chart 未带正确版本"
        err "  修法: 确认 chart 的 Chart.yaml appVersion / values.image.tag = ${CUBESTACK_RELEASE}"
        exit 1
    fi
    _rel_tsv="${REPO_ROOT}/deployments/releases/${CUBESTACK_RELEASE}/release-images.tsv"
    if [ -f "${_rel_tsv}" ] \
        && ! awk -F'\t' -v ref="${_OP_IMAGE}" '$3==ref {found=1} END{exit !found}' "${_rel_tsv}"; then
        warn "  chart 渲染的 operator 镜像不在 release-images.tsv: ${_OP_IMAGE}"
        warn "  → 确认 chart 的镜像 tag 与发布树一致(发布树 tar 必须按该 ref 命名)"
    fi
fi
say "  operator 镜像: ${_OP_IMAGE}"
_OPERATOR_DIGEST=""

if [ "${ONLINE_DEPLOY}" = "true" ]; then
    # 在线部署: 不推集群 registry —— 镜像按 chart 定义从 ${HARBOR_HOST} 直接拉([6/6] 不覆盖
    # image.repository)。[3/6] 的渲染清单仍保留(信息 + chart 完整性自检)。
    say "[4/6]+[4b/6] 在线部署: 跳过镜像推送/搬运 —— 镜像按 chart 定义从 ${HARBOR_HOST} 拉取(pullPolicy=Always)"
    # 在线模式也要取 operator digest 写 podAnnotations: 仅 Always 不会重启运行中的旧 pod,
    # 同 :latest 新镜像必须靠模板注解变化触发滚动(2026-10-19 修复)。
    _OPERATOR_DIGEST="$(_digest "docker://${_OP_IMAGE}")"
    [ -n "${_OPERATOR_DIGEST}" ] \
        || warn "  在线模式未取到 operator 镜像 digest(检查 Harbor 凭据/网络); 将用 rollout restart 兜底"
else
# (以下整块为离线部署路径; 为控制 diff 未整体缩进)

# ---------------- [4/6] 推送镜像 → 集群内置 registry ----------------
# 目标 ref = 去注册域、保仓库路径(与 multus 一致, 避免与其它组件撞名):
#   harbor.isuanova.com/suanova-private/cubestack-operator:latest
#     → <REG_BASE>/suanova-private/cubestack-operator:latest
say "[4/6] 推送镜像 → ${REG_BASE}/**(节点只从这个 registry 拉, 不访问 Harbor)..."
declare -a TARGET_REFS=()
for _img in "${SRC_IMAGES[@]}"; do
    _path="${_img#*/}"                                   # 去注册域(保 suanova-private/... 路径)
    _tag="${_path##*:}"
    _dst="docker://${REG_DIRECT}/${_path}"               # 推送用直连端点
    _dst_ref="${REG_BASE}/${_path}"                      # 写进 chart 的引用(节点用它拉)
    _d_dst="$(_digest "${_dst}")"                        # manifest digest(用于 podAnnotations)
    _c_dst="$(_content_digest "${_dst}")"                # 内容 digest(仅用于幂等比对)

    _pushed=0
    # 源优先级: auto → ① Harbor(在线, 最新) ② 离线 tar ③ 本地 docker daemon; 也可显式指定
    _try=()
    case "${IMG_SRC_MODE}" in
        harbor) _try=( harbor ) ;;
        tar)    _try=( tar ) ;;
        docker) _try=( docker ) ;;
        auto)   if [ "${_MODE}" = "online" ]; then _try+=( harbor ); fi
                _try+=( tar docker ) ;;
        *) err "CUBESTACK_OPERATOR_IMAGE_SOURCE 仅支持 auto|harbor|tar|docker(当前=${IMG_SRC_MODE})"; exit 1 ;;
    esac

    _tar="$(find_offline_tar "/${_path}" "*$(basename "${_path%%:*}")*.tar" "${OFFLINE_DIR}" 2>/dev/null || true)"

    for _s in "${_try[@]}"; do
        _src_arg=""; _c_src=""
        case "${_s}" in
            harbor)
                _src_arg="docker://${_img}"
                # 私有无凭据且未登录时, inspect 会失败 → digest 空 → 直接尝试 copy(失败则换下一个源)
                _c_src="$(_content_digest "${_src_arg}")" ;;
            tar)
                [ -n "${_tar}" ] || continue
                _src_arg="docker-archive:${_tar}"
                _c_src="$(_content_digest "${_src_arg}")" ;;
            docker)
                _local="$(sudo docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -Fx "${_img}" | head -1 || true)"
                [ -n "${_local}" ] || continue
                _tmp_tar="/tmp/cubestack-operator-${_tag}-$$.tar"
                say "  从本地 docker daemon 导出: ${_local}"
                if sudo docker save "${_local}" -o "${_tmp_tar}" >/dev/null 2>&1; then
                    _src_arg="docker-archive:${_tmp_tar}"
                    _c_src="$(_content_digest "${_src_arg}")"
                else
                    rm -f "${_tmp_tar}"; continue
                fi ;;
        esac

        # 幂等: 目标已有同**内容** digest → 跳过(rolling :latest 必须比 digest, 不能只看 tag 存在;
        # docker-archive 用 manifest digest 会永远不等 —— 见 _content_digest)
        if [ -n "${_c_dst}" ] && [ -n "${_c_src}" ] && [ "${_c_dst}" = "${_c_src}" ]; then
            ok "  ${_path} 内容未变(digest ${_c_dst:0:19}...), 跳过推送(源=${_s})"
            _pushed=1; break
        fi
        if push_image_skopeo "${_src_arg}" "${_dst}"; then
            _d_dst="$(_digest "${_dst}")"
            ok "  ${_path} 已推送(源=${_s}${_d_dst:+, digest ${_d_dst:0:19}...})"
            _pushed=1; break
        fi
        warn "  源 ${_s} 推送失败, 尝试下一个源..."
    done

    [ "${_pushed}" = "1" ] || {
        err "镜像推送失败: ${_img}"
        err "  可用源都不成立(Harbor 不可达/无凭据 + 本地无离线 tar + docker daemon 无该镜像)"
        err "  修法: ① 联网机生成离线 tar: sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group cubestack-operator"
        err "        ② 或配好 CUBESTACK_OPERATOR_HARBOR_USER/PASSWORD 后重跑(在线直拉)"
        err "        ③ 或把 ${_img} 手工 pull/save 到 ${OFFLINE_DIR}/"
        exit 1
    }
    # 精确采集 operator 镜像的 target digest(用于 podAnnotations); 多镜像 chart 时不能用最后一个。
    if [ "${_img}" = "${_OP_IMAGE}" ]; then
        _OPERATOR_DIGEST="${_d_dst}"
    fi
    TARGET_REFS+=("${_dst_ref}")
done
# 兜底: 未匹配到 operator 镜像路径时用最后一个(与旧行为一致; 正常不会走到)
[ -n "${_OPERATOR_DIGEST}" ] || _OPERATOR_DIGEST="${_d_dst}"

# ---------------- [4b/6] CR 平台组件镜像推送(仅 CR_ENABLED=true) ----------------
# 组件镜像集 = OFFLINE_DIR 下全部离线 tar(人工维护口径; 2026-10-08 起与 operator 镜像内
# assets/charts 的渲染对账而来, 清单与维护方法见 offline-files/cubestack-operator/README.md)。
# ★ 2026-10-16 目录分类: 组件 tar 按平台组件分子目录(offline-files/cubestack-operator/<组件>/,
#   组件名 = CR spec.components 的键: lws / envoy-gateway / controller-manager / prometheus /
#   perses / cuberouter / bmc / cubepilot / portal); **顶层** = operator 本体镜像;
#   **charts/** = operator helm chart(.tgz), 不是平台组件, 扫描时显式跳过。
#   过滤: CUBESTACK_OPERATOR_COMPONENTS="cubepilot,prometheus" → 只推列出的组件子目录
#   (更新某个 operator 后单独推送其镜像的入口; 组件名不存在会 err 并列出可用目录)。
# 目标映射(与 [3/6] 的 CR 两条前缀注入一一对应):
#   自研 harbor.isuanova.com/suanova/<name>:tag  → <REG>/suanova/<name>:tag (imageRegistry)
#   第三方 <上游ref>(docker.io/quay.io/ghcr.io…) → <REG>/mirrors/<上游ref> (externalImageRegistryPrefix)
# 幂等: config digest(内容)比对 —— docker-archive 的 manifest digest 与 registry 不可比,
#       用它会每次重推(见 _content_digest)。失败即 err —— CR 模式缺组件镜像=组件将 ImagePullBackOff。
if [ "${CR_ENABLED}" = "true" ]; then
    say "[4b/6] 推送平台组件镜像(CR 用; 源=离线 tar, 幂等内容(config digest)比对)..."
    _n_push=0; _n_skip=0
    _PLATFORM_REFS=()
    _cand_tars=()
    if [ -n "${CUBESTACK_OPERATOR_COMPONENTS:-}" ]; then
        for _c in ${CUBESTACK_OPERATOR_COMPONENTS//,/ }; do
            [ -n "${_c}" ] || continue
            # charts/ 放 operator helm chart, 不是平台组件; 误选时给明确错误
            [ "${_c}" = "charts" ] && { err "CUBESTACK_OPERATOR_COMPONENTS=charts 无效: charts/ 是 operator chart 目录, 不是平台组件"; exit 1; }
            [ -d "${OFFLINE_DIR}/${_c}" ] || {
                err "CUBESTACK_OPERATOR_COMPONENTS 指定了不存在的组件: ${_c}"
                err "  可用组件(子目录): $(cd "${OFFLINE_DIR}" 2>/dev/null && ls -d */ 2>/dev/null | tr -d '/' | grep -vx 'charts' | tr '\n' ' ')"
                exit 1
            }
            for _t in "${OFFLINE_DIR}/${_c}"/*.tar; do [ -f "${_t}" ] && _cand_tars+=("${_t}"); done
        done
        [ "${#_cand_tars[@]}" -gt 0 ] || { err "组件 ${CUBESTACK_OPERATOR_COMPONENTS} 子目录下没有 *.tar"; exit 1; }
    else
        for _t in "${OFFLINE_DIR}"/*.tar; do [ -f "${_t}" ] && _cand_tars+=("${_t}"); done
        for _d in "${OFFLINE_DIR}"/*/; do
            [ -d "${_d}" ] || continue
            # charts/ 只放 helm chart(.tgz), 不是平台组件; 跳过, 避免被当成空组件
            [ "$(basename "${_d}")" = "charts" ] && continue
            for _t in "${_d}"*.tar; do [ -f "${_t}" ] && _cand_tars+=("${_t}"); done
        done
        [ "${#_cand_tars[@]}" -gt 0 ] || warn "  ⚠ 未找到任何组件 tar(检查 ${OFFLINE_DIR}/<组件>/ 与顶层 *.tar)"
    fi
    for _tarfile in ${_cand_tars[@]+"${_cand_tars[@]}"}; do
        [ -f "${_tarfile}" ] || continue
        _tra="$(tar -xOf "${_tarfile}" manifest.json 2>/dev/null \
            | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["RepoTags"][0])' 2>/dev/null || true)"
        # ★ 目标 ref **以 tar 文件名为权威**(文件名 = 上游 ref 的 / 与 : 替换为 _ 的产物,
        #   与 CR 注入的镜像引用同源)。为什么不用 tar 内 RepoTags: 早期(09-23 时代)生成的
        #   tar RepoTags 可能是**短式**(如 envoyproxy/gateway, 缺 docker.io 域)⇒ 按它推会把
        #   镜像放到 <REG>/mirrors/envoyproxy/gateway, 而节点按 CR 引用拉
        #   <REG>/mirrors/docker.io/envoyproxy/gateway ⇒ not found(2026-10-08 实机踩到)。
        #   解析: <域>_<路径段…>_<tag> ⇒ 域/路径(段内 _ → /):tag; RepoTags 仅作**尾部校验**。
        _base="$(basename "${_tarfile}" .tar)"
        _domain="${_base%%_*}"
        _tag="${_base##*_}"
        _mid="${_base%_*}"; _mid="${_mid#*_}"
        _src_ref="${_domain}/$(printf '%s' "${_mid}" | tr '_' '/')${_tag:+:${_tag}}"
        if [ -n "${_tra}" ]; then
            case "${_tra}" in
                *"${_src_ref#*/}") : ;;   # RepoTags 尾部(去域)与文件名解析一致
                *) warn "  $(basename "${_tarfile}") 文件名解析(${_src_ref})与 RepoTags(${_tra})不符, 跳过"; continue ;;
            esac
        fi
        case "${_src_ref}" in
            "${HARBOR_HOST}"/suanova/*|"${HARBOR_HOST}"/mirrors/*) _dst_path="${_src_ref#${HARBOR_HOST}/}" ;;
            *) _dst_path="mirrors/${_src_ref}" ;;
        esac
        _PLATFORM_REFS+=("${REG_BASE}/${_dst_path}")
        _dst="docker://${REG_DIRECT}/${_dst_path}"
        # 幂等: 比 **config digest**(内容), 不比 manifest digest —— 后者在 docker-archive
        # 推送时因 skopeo 重新压缩而必然变化(见 _content_digest 注释)。
        _d_dst="$(_content_digest "${_dst}")"
        _d_src="$(_content_digest "docker-archive:${_tarfile}")"
        if [ -n "${_d_dst}" ] && [ "${_d_dst}" = "${_d_src}" ]; then
            _n_skip=$((_n_skip + 1)); continue
        fi
        if push_image_skopeo "docker-archive:${_tarfile}" "${_dst}"; then
            _n_push=$((_n_push + 1))
        else
            err "组件镜像推送失败: ${_src_ref}(源=$(basename "${_tarfile}"))"
            err "  → 检查 registry 可达/磁盘空间; 重跑本模块会自动续推(已推送的按 digest 跳过)"
            exit 1
        fi
    done
    ok "  组件镜像就绪: 新推 ${_n_push} 个, digest 相同跳过 ${_n_skip} 个"
fi

# 推送完成后立即触发卡在 ImagePullBackOff/ErrImagePull 的平台 Pod 重新拉取
# (kubelet 退避可达 5min; 只推镜像不保证 Pod 立刻重试)
_reroll_stuck_pods ${TARGET_REFS[@]+"${TARGET_REFS[@]}"} ${_PLATFORM_REFS[@]+"${_PLATFORM_REFS[@]}"}

fi   # 结束 ONLINE_DEPLOY!=true 的离线推送块([4/6]+[4b/6])

# ---------------- [5/6] CRD 预应用(helm 的 crds/ 只在"CRD 不存在"时装) ----------------
# README 明确: 已装过 operator 的集群升级前必须先 apply 新 CRD, 否则旧 CRD 会剪掉新字段。
# 幂等无副作用(SSA), 故每次部署都跑 —— 不依赖 helm 的"仅首次安装"语义。
say "[5/6] 应用 chart 内的 CRD(crds/ 目录)..."
_WORK="$(mktemp -d)"
trap '_cleanup; rm -rf "${_WORK}"' EXIT

# 节点池(2026-10-27): operator pod 自身钉 master + 容忍 control-plane/unschedulable。
# 平台组件：cubepilot-api/operator、cubestack-controller-manager、cubestack-portal 等
# **组件 chart 原生支持 nodeSelector/tolerations**，这里通过 CubeStackCluster 的
# components.<name>.values 在**创建 Deployment 时**就下发（不依赖部署末尾 patch）。
# 其余平台组件(envoy/ai-gateway/lws/cuberouter/monitoring)仍由 node_pool 模块的
# cubestack-placement.sh 兜底；**不使用** CR spec.global 的 placement 字段 —— 它会注入
# 到所有组件(含 model bundle 推理负载)。
if [ "${NODE_POOL_CUBESTACK_PLACEMENT:-true}" = "true" ]; then
    _NODE_POOL_VALUES="${_WORK}/node-pool-values.yaml"
    cat > "${_NODE_POOL_VALUES}" <<'EOF'
nodeSelector:
  node-role.kubernetes.io/control-plane: ""
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
  - key: node.kubernetes.io/unschedulable
    operator: Exists
    effect: NoSchedule

# 平台组件：通过 component values 传给各自 chart（chart 已原生支持）。
# cubepilot-chart: operator/api/web；controller-manager/portal chart: 顶层。
clusterCR:
  spec:
    components:
      cubepilot:
        values:
          operator:
            nodeSelector:
              node-role.kubernetes.io/control-plane: ""
            tolerations:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
                effect: NoSchedule
              - key: node.kubernetes.io/unschedulable
                operator: Exists
                effect: NoSchedule
          api:
            nodeSelector:
              node-role.kubernetes.io/control-plane: ""
            tolerations:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
                effect: NoSchedule
              - key: node.kubernetes.io/unschedulable
                operator: Exists
                effect: NoSchedule
          web:
            nodeSelector:
              node-role.kubernetes.io/control-plane: ""
            tolerations:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
                effect: NoSchedule
              - key: node.kubernetes.io/unschedulable
                operator: Exists
                effect: NoSchedule
      cubestackControllerManager:
        values:
          nodeSelector:
            node-role.kubernetes.io/control-plane: ""
          tolerations:
            - key: node-role.kubernetes.io/control-plane
              operator: Exists
              effect: NoSchedule
            - key: node.kubernetes.io/unschedulable
              operator: Exists
              effect: NoSchedule
      cubestackPortal:
        values:
          nodeSelector:
            node-role.kubernetes.io/control-plane: ""
          tolerations:
            - key: node-role.kubernetes.io/control-plane
              operator: Exists
              effect: NoSchedule
            - key: node.kubernetes.io/unschedulable
              operator: Exists
              effect: NoSchedule
EOF
    _EXTRA_VALUES+=( -f "${_NODE_POOL_VALUES}" )
fi

tar -xzf "${CHART_TGZ}" -C "${_WORK}"
CRD_DIR="$(find "${_WORK}" -maxdepth 2 -type d -name crds | head -1 || true)"
if [ -n "${CRD_DIR}" ] && ls "${CRD_DIR}"/*.yaml >/dev/null 2>&1; then
    for _crd in "${CRD_DIR}"/*.yaml; do
        if cat "${_crd}" | SSH "${K} apply --server-side --force-conflicts -f -" >/dev/null 2>&1; then
            ok "  CRD 已应用: $(basename "${_crd}")"
        else
            err "CRD apply 失败: $(basename "${_crd}")(手工确认: kubectl apply --server-side -f <chart>/crds/)"; exit 1
        fi
    done
else
    warn "  chart 内未找到 crds/ 目录(跳过; 若 operator 依赖 CRD 请检查 chart 结构)"
fi

# ---------------- [6/6] helm upgrade --install(本地 chart; 在线=按 chart 定义拉 Harbor / 离线=集群 registry) ----------------
if [ "${ONLINE_DEPLOY}" = "true" ]; then
    say "[6/6] helm upgrade --install(本地 chart; **在线模式**: 镜像按 chart 定义从 ${HARBOR_HOST} 拉, pullPolicy=Always)..."
    _SET_ARGS=( --set "image.pullPolicy=Always" --set "replicas=${OP_REPLICAS}" "${_TAG_SET_ARGS[@]}" )
    if [ -n "${HARBOR_USER}" ] && [ -n "${HARBOR_PASSWORD}" ]; then
        _SET_ARGS+=( --set "imagePullSecrets[0].name=harbor-credentials" )
        # harbor-credentials: 节点向 Harbor 拉私有镜像(cubestack-operator 在 suanova-private 项目)。
        # apply + stringData: 密码经 stdin 传递(不进 argv; 与模块内 auth 文件同一考虑); 幂等可重放。
        # ⚠ NS 需先存在(helm --create-namespace 在下面才执行)。
        SSH "${K} get ns ${NS} >/dev/null 2>&1 || ${K} create namespace ${NS} >/dev/null 2>&1" || true
        _b64="$(printf '%s:%s' "${HARBOR_USER}" "${HARBOR_PASSWORD}" | base64 -w0 2>/dev/null \
                || printf '%s:%s' "${HARBOR_USER}" "${HARBOR_PASSWORD}" | base64)"
        if SSH "${K} -n ${NS} apply -f - >/dev/null 2>&1" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: harbor-credentials
  namespace: ${NS}
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: '{"auths":{"${HARBOR_HOST}":{"auth":"${_b64}"}}}'
EOF
        then
            ok "  harbor-credentials 已同步(节点向 ${HARBOR_HOST} 拉私有镜像)"
        else
            warn "  harbor-credentials 创建失败(节点拉私有镜像会 401; 检查 kubectl/命名空间)"
        fi
        unset _b64
    else
        warn "  无 Harbor 凭据: 未创建 harbor-credentials 且未设 imagePullSecrets(仅匿名可拉镜像可用)"
    fi
    IMG_REPO_OVERRIDE="(chart 定义: ${HARBOR_HOST}/**)"
    IMG_TAG_OVERRIDE="${_OP_IMAGE##*:}"      # 实际镜像 tag 以 chart 渲染结果为准
else
    say "[6/6] helm upgrade --install(本地 chart; 镜像走集群 registry)..."
    IMG_REPO_OVERRIDE="${TARGET_REFS[0]%:*}"     # <REG_BASE>/suanova-private/cubestack-operator
    IMG_TAG_OVERRIDE="${_OP_IMAGE##*:}"          # chart 自带 tag(如 2.0.0), installer 不覆盖
    _SET_ARGS=(
        --set "image.repository=${IMG_REPO_OVERRIDE}"
        "${_TAG_SET_ARGS[@]}"
        --set "image.pullPolicy=Always"
        --set "replicas=${OP_REPLICAS}"
    )
fi

# 两模式共用: 把 operator 镜像 digest 写进 podAnnotations —— digest 变了模板就变, helm 才会
# 滚动新 pod。⚠ 2026-10-19 修复: 在线模式只靠 pullPolicy=Always **不会重启运行中的旧 pod**,
# 同 :latest 新镜像必须同样用 digest 注解触发滚动。
if [ "${PIN_DIGEST}" = "true" ] && [[ "${_OPERATOR_DIGEST:-}" =~ ^sha256:[[:xdigit:]]{64}$ ]]; then
    _SET_ARGS+=( --set "podAnnotations.cubestack\\.io/image-digest=${_OPERATOR_DIGEST}" )
fi

# 渲染自检: 离线模式要求覆盖后的镜像**全部**落在集群 registry 下(否则离线集群 ImagePullBackOff);
# 在线模式则要求**全部**来自 chart 定义域(Harbor) —— chart 以后新增第 2 个镜像时都会响亮失败。
FINAL_IMAGES=()
while IFS= read -r _line; do
    [ -n "${_line}" ] && FINAL_IMAGES+=("${_line}")
done < <( _render_images "${_SET_ARGS[@]}" "${EXTRA_CR_VALUES_ARG[@]}" "${_EXTRA_VALUES[@]}" )
for _img in "${FINAL_IMAGES[@]}"; do
    if [ "${ONLINE_DEPLOY}" = "true" ]; then
        case "${_img}" in
            "${HARBOR_HOST}/"*) : ;;
            *) err "渲染出非 Harbor 镜像: ${_img}(在线模式要求全部按 chart 定义从 ${HARBOR_HOST} 拉)"
               err "  → chart 变更? 确认镜像来源后再调整本模块"
               exit 1 ;;
        esac
    else
        case "${_img}" in
            "${REG_BASE}/"*) : ;;
            *) err "渲染后仍有镜像不在集群 registry 下: ${_img}"
               err "  → chart 可能新增了镜像; 请在本模块补 --set 覆盖(并登记 images.manifest)"
               exit 1 ;;
        esac
    fi
done
if [ "${ONLINE_DEPLOY}" = "true" ]; then
    ok "  渲染自检通过: ${#FINAL_IMAGES[@]} 个镜像全部指向 ${HARBOR_HOST}(chart 定义)"
else
    ok "  渲染自检通过: ${#FINAL_IMAGES[@]} 个镜像全部指向 ${REG_BASE}"
fi

if [ "${CR_ENABLED}" = "true" ]; then
    if [ "${BUNDLES_ENABLED}" = "true" ]; then
        _BUNDLES_STATE_MSG="保留 chart 默认的 8 个模型 bundles + modelBundles 开启(可用 CR_VALUES_FILE 改列表; bmc 同 chart 默认, 未建 Secret 时 Degraded)"
    else
        _BUNDLES_STATE_MSG="模型 bundles 清空 + modelBundles 关闭(CUBESTACK_OPERATOR_MODEL_BUNDLES_ENABLED=false)"
    fi
    if [ "${ONLINE_DEPLOY}" = "true" ]; then
        say "  clusterCR.enabled=true(**在线模式**): 组件镜像按 chart 定义(global.imageRegistry="
        say "    ${HARBOR_HOST})恒拉(pullPolicy=Always); harbor-credentials 已同步供节点认证。"
        say "    CR 默认值: ${_BUNDLES_STATE_MSG}。"
        say "    覆盖: CUBESTACK_OPERATOR_CR_VALUES_FILE; 开关: CUBESTACK_OPERATOR_MODEL_BUNDLES_ENABLED。"
    else
        say "  clusterCR.enabled=true: 平台组件镜像已由 [4b/6] 推入集群 registry, 且 CR 全局镜像源"
        say "    已注入 ${REG_BASE}(自研)+ ${REG_BASE}/mirrors(第三方)—— 节点不访问 Harbor。"
        say "    CR 默认值: ${_BUNDLES_STATE_MSG}。"
        say "    覆盖: CUBESTACK_OPERATOR_CR_VALUES_FILE; 开关: CUBESTACK_OPERATOR_MODEL_BUNDLES_ENABLED。"
        if [ ! -f "${OFFLINE_DIR}/docker.io_envoyproxy_ratelimit_0482748e.tar" ] \
            && [ ! -f "${OFFLINE_DIR}/envoy-gateway/docker.io_envoyproxy_ratelimit_0482748e.tar" ]; then
            warn "    已知缺口: docker.io/envoyproxy/ratelimit:0482748e 未备料(gateway-helm v1.9.2 的 chart 默认 tag; 本网络到 docker.io 不通) —— 默认不拉起(仅配 RateLimitPolicy 时用); 补料: 从 Harbor mirrors 拉取或按 image-list.tsv 刷新 ${OFFLINE_DIR}/envoy-gateway/"
        fi
    fi
fi

helm upgrade --install "${RELEASE}" "${CHART_TGZ}" \
    --namespace "${NS}" --create-namespace \
    "${_SET_ARGS[@]}" "${EXTRA_CR_VALUES_ARG[@]}" "${_EXTRA_VALUES[@]}" \
    --wait --timeout 300s \
    || warn "  helm 安装/等待超时(资源可能已创建, 继续等待 Deployment; 排查: helm status ${RELEASE} -n ${NS})"

# 在线模式兜底: 若取不到 Harbor 镜像 digest(无凭据/网络瞬断), podAnnotations 无法触发滚动;
# 显式 restart operator, 让 Always 重新解析 :latest(仅在 digest 缺失时执行, 不造成无谓重启)。
if [ "${ONLINE_DEPLOY}" = "true" ] && [ -z "${_OPERATOR_DIGEST}" ]; then
    warn "  在线模式未取到 operator 镜像 digest → rollout restart operator 以确保拉取最新镜像"
    SSH "${K}" -n "${NS}" rollout restart deployment/${RELEASE} >/dev/null 2>&1 \
        || SSH "${K}" -n "${NS}" rollout restart deployment/${RELEASE}-cubestack-operator >/dev/null 2>&1 \
        || warn "  operator Deployment 未找到, 无法自动 restart; 请手工确认"
fi

# ---------------- CR 取值断言 + 纠偏(2026-10-13 实机教训) ----------------
# helm 的三路合并对 **CR 对象的更新不可靠**(实测: 在线模式跑过一轮后, 切回离线模式重跑——
# helm release/manifest 都已是离线值, 但活体 CR 的 spec.global 仍残留 harbor 取值, 组件持续
# 按旧值拉镜像 ImagePullBackOff)。⇒ 部署后显式校验并按模式纠正(merge patch, 幂等)。
if [ "${CR_ENABLED}" = "true" ]; then
    _cr_name="$( (SSH "${K} -n ${NS} get csc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null" || true) )"
    _cr_reg="$( (SSH "${K} -n ${NS} get csc -o jsonpath='{.items[0].spec.global.imageRegistry}' 2>/dev/null" || true) )"
    _cr_expose="$( (SSH "${K} -n ${NS} get csc -o jsonpath='{.items[0].spec.global.serviceExposeMode}' 2>/dev/null" || true) )"
    _cr_secs="$( (SSH "${K} -n ${NS} get csc -o jsonpath='{.items[0].spec.global.imagePullSecrets}' 2>/dev/null" || true) )"
    _cr_secs_norm="$(printf '%s' "${_cr_secs}" | tr -d '[:space:]')"
    _cr_ha="$( (SSH "${K} -n ${NS} get csc -o jsonpath='{.items[0].spec.global.ha.enabled}' 2>/dev/null" || true) )"
    _want_expose="loadbalancer"
    [ "${SERVICE_EXPOSE_MODE:-metallb}" = "nodeport" ] && _want_expose="nodeport"
    # HA 取值同样做活体纠偏(helm 三路合并对 CR 不可靠): 单 master=false; >=3 master=true+replicas=2。
    if [ "${HA_ENABLED}" = "true" ]; then
        _want_ha_patch='{"enabled":true,"replicas":'"${OP_REPLICAS}"'}'
    else
        _want_ha_patch='{"enabled":false}'
    fi
    if [ "${ONLINE_DEPLOY}" = "true" ]; then
        # CR global.imageRegistry 是**注册域**(不含项目前缀); 组件镜像路径自带 suanova/。
        # 写成 harbor.isuanova.com/suanova 会拼成 .../suanova/suanova/...(2026-10-22 实机)。
        _want_reg="${HARBOR_HOST}"; _want_pref="${HARBOR_HOST}/mirrors"; _want_pol="Always"
        if [ -n "${HARBOR_USER}" ] && [ -n "${HARBOR_PASSWORD}" ]; then
            _want_secs='["harbor-credentials"]'
        else
            _want_secs='[]'
        fi
    else
        _want_reg="${REG_BASE}"; _want_pref="${REG_BASE}/mirrors"; _want_pol="Always"; _want_secs='[]'
    fi
    # 模式切换保护(2026-10-25 实机): InferenceRuntimeProfile 的 CRD 有 ValidatingAdmissionPolicy
    # "spec is immutable"; 离线创建的 profile 里是内置 registry 镜像, 切在线后 operator 尝试改成
    # Harbor 会被拒绝 → model-bundles Degraded。registry 变化时先删除 profile, 让 operator 按新
    # registry 重建(模式切换的一次性代价; 模型服务需重新调谐)。
    # 注意: helm 可能已先把 CR 改到目标 registry, 所以不能只看 CR; 还要扫描 profile 内实际
    # image 前缀是否已属于目标 registry。
    _need_recreate="0"
    if [ -n "${_cr_name}" ] && [ -n "${_cr_reg}" ] && [ "${_cr_reg}" != "${_want_reg}" ]; then
        _need_recreate="1"
    else
        _prof_json="$( (SSH "${K} get inferenceruntimeprofiles.ai.cubestack.io -o json 2>/dev/null" || true) )"
        if [ -n "${_prof_json}" ]; then
            _stale="$(printf '%s' "${_prof_json}" | python3 -c '
import json, sys
want = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "image" and isinstance(v, str) and v and not v.startswith(want):
                print("1"); raise SystemExit
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(d.get("items", []))
' "${_want_reg}" 2>/dev/null || true)"
            [ -n "${_stale}" ] && _need_recreate="1"
        fi
    fi
    if [ "${_need_recreate}" = "1" ]; then
        say "  检测到 InferenceRuntimeProfile 镜像前缀与目标 registry(${_want_reg})不一致: 先纠偏 CR, 再重建 immutable profile..."
    fi
    if [ -n "${_cr_name}" ] && { [ "${_cr_reg}" != "${_want_reg}" ] || [ "$( (SSH "${K} -n ${NS} get csc -o jsonpath='{.items[0].spec.global.imagePullPolicy}' 2>/dev/null" || true) )" != "${_want_pol}" ] || [ "${_cr_expose}" != "${_want_expose}" ] || [ "${_cr_secs_norm}" != "${_want_secs}" ] || [ "${_cr_ha}" != "${HA_ENABLED}" ]; }; then
        warn "  CR 取值漂移(当前 imageRegistry=${_cr_reg:-<空>}, serviceExposeMode=${_cr_expose:-<空>}, ha.enabled=${_cr_ha:-<空>}), kubectl patch 纠正为 ${_want_reg}/${_want_expose}/ha=${HA_ENABLED} ..."
        SSH "${K} -n ${NS} patch csc ${_cr_name} --type=merge -p '{\"spec\":{\"global\":{\"imageRegistry\":\"${_want_reg}\",\"externalImageRegistryPrefix\":\"${_want_pref}\",\"imagePullSecrets\":${_want_secs},\"imagePullPolicy\":\"${_want_pol}\",\"serviceExposeMode\":\"${_want_expose}\",\"ha\":${_want_ha_patch}}}}' >/dev/null 2>&1" \
            && ok "  CR 已纠偏(operator 将按新值滚动组件)" \
            || warn "  CR 纠偏失败(手工: kubectl -n ${NS} get csc -o yaml)"
    else
        ok "  CR 取值与部署模式一致(${_want_reg}/${_want_expose}/ha=${HA_ENABLED})"
    fi
    # ★ 组件级 HA 例外也要活体纠偏(helm 对 CR 的更新不可靠; 仅 HA 开启时):
    #   cuberouter 的 RWO PVC 不支持 2 副本; lws 第 2 副本在 3 master 上 CPU 不足。
    if [ "${HA_ENABLED}" = "true" ] && [ -n "${_cr_name}" ]; then
        SSH "${K} -n ${NS} patch csc ${_cr_name} --type=merge -p '{\"spec\":{\"components\":{\"lws\":{\"values\":{\"replicaCount\":1}},\"cuberouter\":{\"values\":{\"cubeRouter\":{\"replicaCount\":1}}}}}}' >/dev/null 2>&1" \
            && ok "  CR 组件 HA 例外已收敛(lws/cuberouter=1; RWO/CPU 约束)" \
            || warn "  CR 组件 HA 例外纠偏失败(手工检查 lws/cuberouter replicas)"
    fi
    # ★ profile 删除必须在 CR 纠偏**之后**并等待完成(2026-10-26 CodeRabbit):
    #   先删再 patch 时, operator 会趁窗口按**旧 registry** 重建 immutable profile;
    #   随后的纠偏被 ValidatingAdmissionPolicy("spec is immutable")拒绝 → model-bundles Degraded。
    #   删除前再读一次 CR: 只有它确实已是目标 registry 才删, 否则跳过(避免按旧值重建);
    #   --wait + timeout 保证报告"已删除"时旧 profile 确实消失(不再停留在 terminating)。
    if [ "${_need_recreate}" = "1" ]; then
        _cr_now_reg="$( (SSH "${K} -n ${NS} get csc -o jsonpath='{.items[0].spec.global.imageRegistry}' 2>/dev/null" || true) )"
        if [ -n "${_cr_name}" ] && [ "${_cr_now_reg}" != "${_want_reg}" ]; then
            warn "  CR 尚未切到 ${_want_reg}(当前 ${_cr_now_reg:-<空>}) → 跳过 profile 重建(避免 operator 按旧 registry 生成新的 immutable profile)"
        else
            say "  删除旧 InferenceRuntimeProfile 并等待删除完成(operator 将按 ${_want_reg} 重建)..."
            if SSH "${K} delete inferenceruntimeprofiles.ai.cubestack.io --all --ignore-not-found --wait=true --timeout=120s" </dev/null >/dev/null 2>&1; then
                ok "  已删除旧 InferenceRuntimeProfile(operator 将按 ${_want_reg} 重建)"
            else
                warn "  删除/等待 InferenceRuntimeProfile 失败; model-bundles 可能 Degraded"
            fi
        fi
    fi
    unset _cr_name _cr_reg _cr_expose _cr_secs _cr_secs_norm _cr_now_reg _cr_ha _want_reg _want_pref _want_pol _want_secs _want_expose _want_ha_patch
fi

# ---------------- [6.5/6] RWO 单卷 Deployment 的更新策略守护 ----------------
# 背景(2026-10-19 实机): cubepilot-api 的单个 RWO PVC + Deployment 默认 RollingUpdate,
#   更新时新 Pod 先调度到另一节点 → Multi-Attach(卷仍被旧 Pod 占用), 旧 Pod 又因
#   maxUnavailable 不退 → 永久 ContainerCreating。这里在 operator 创建组件后把这类
#   Deployment 纠正为 Recreate(幂等; 无 PVC / RWX 的不动)。
if [ "${CR_ENABLED}" = "true" ]; then
    say "[6.5/6] 修正 RWO 单卷 Deployment 的更新策略(防 Multi-Attach)..."
    ensure_rwo_deployments_recreate "${NS}" "cubestack.io/managed-by=cubestack-operator" \
        "${CUBESTACK_OPERATOR_RWO_STRATEGY_WAIT_SECONDS:-60}" \
        || warn "  RWO 策略纠正未全部成功; 下次滚动前请手工确认(见 docs/troubleshooting.md 五.2)"
fi

# 等 operator 就绪(名字 = release 名; 用户改了 release 名时回退 <release>-cubestack-operator)
SSH "${K} -n ${NS} rollout status deployment/${RELEASE} --timeout=180s" >/dev/null 2>&1 \
    || SSH "${K} -n ${NS} rollout status deployment/${RELEASE}-cubestack-operator --timeout=180s" >/dev/null 2>&1 \
    || warn "  operator Deployment 未在 180s 内就绪(继续汇总; 端到端验证会给出确切状态)"

# 副本数纠偏: helm --set 正常会生效; 若活体仍与拓扑目标不一致(旧 release/手工 scale),
# 显式 scale, 避免"单 master 跑 2 副本 / 3 master 只跑 1 副本"。
_DEP_NAME="${RELEASE}"
SSH "${K} -n ${NS} get deploy ${_DEP_NAME} >/dev/null 2>&1" || _DEP_NAME="${RELEASE}-cubestack-operator"
_cur_reps="$( (SSH "${K} -n ${NS} get deploy ${_DEP_NAME} -o jsonpath='{.spec.replicas}' 2>/dev/null" || true) )"
if [ -n "${_cur_reps}" ] && [ "${_cur_reps}" != "${OP_REPLICAS}" ]; then
    warn "  operator Deployment 副本数漂移(当前=${_cur_reps}, 目标=${OP_REPLICAS}) → 纠正"
    SSH "${K} -n ${NS} scale deploy ${_DEP_NAME} --replicas=${OP_REPLICAS}" >/dev/null 2>&1 \
        && ok "  operator replicas 已纠正为 ${OP_REPLICAS}" \
        || warn "  operator replicas 纠正失败(手工: kubectl -n ${NS} scale deploy ${_DEP_NAME} --replicas=${OP_REPLICAS})"
fi
unset _cur_reps _DEP_NAME

# ---------------- [6.6/6] Envoy Gateway 公网数据面 Service 类型对齐 ----------------
# operator 的 spec.global.serviceExposeMode 不作用于 Envoy Gateway 数据面(其 Service 类型由
# EnvoyProxy 决定, 默认 LoadBalancer)。NodePort 集群必须在这里补一个 EnvoyProxy 并挂到
# 公网 Gateway; 否则 Service 停在 EXTERNAL-IP <pending>, Web UI 地址发现会误取私有 ClusterIP。
# 放在 operator 就绪之后: Gateway 由 operator 异步创建。
if [ "${CR_ENABLED}" = "true" ]; then
    say "[6.6/6] Envoy Gateway 公网 Service 类型对齐(SERVICE_EXPOSE_MODE=${SERVICE_EXPOSE_MODE:-metallb})..."
    ensure_envoy_gateway_service_type "${SERVICE_EXPOSE_MODE:-metallb}" \
        || warn "  Envoy Gateway 公网 Service 类型未确认; Web UI 可能暂时无法从节点外访问"
fi

# ★ 2026-10-27 容器 c 全新安装实测: operator 组件是**异步创建**的, [6.5/6] 的 60s 窗口内
#   cuberouter 可能还没出现 → 策略保持 RollingUpdate, 首次 HA/模板收敛滚动撞 RWO Multi-Attach
#   (旧 Pod 持卷, 新 Pod Init 卡死)。结束前再兜一次(此时组件已基本创建完)。
if [ "${CR_ENABLED}" = "true" ]; then
    ensure_rwo_deployments_recreate "${NS}" "cubestack.io/managed-by=cubestack-operator" \
        "${CUBESTACK_OPERATOR_RWO_STRATEGY_WAIT_SECONDS:-120}" \
        || warn "  RWO 策略二次纠正未全部成功; 下次滚动前请手工确认"
fi

echo "---------------------------------------------"
( SSH "${K} -n ${NS} get pods,deploy -o wide 2>/dev/null" || true ) | sed 's/^/    /'
echo "---------------------------------------------"
ok "CubeStack Operator 部署完成"
echo "  release:      ${RELEASE}(namespace ${NS})"
echo "  拓扑/HA:      master=${_MASTER_COUNT} → operator replicas=${OP_REPLICAS}, clusterCR.spec.global.ha.enabled=${HA_ENABLED}"
echo "  chart:        $(basename "${CHART_TGZ}")(sync=${SYNC_MODE}→${_MODE}; source=${CHART_SOURCE}; dir=${CHART_DIR})"
if [ "${ONLINE_DEPLOY}" = "true" ]; then
    echo "  部署模式:     在线(ONLINE_DEPLOY_CUBESTACK_OPERATOR=true)"
    echo "  镜像:         ${IMG_REPO_OVERRIDE}(pullPolicy=Always —— 恒拉最新; 节点直连 ${HARBOR_HOST})"
else
    echo "  部署模式:     离线(ONLINE_DEPLOY_CUBESTACK_OPERATOR=false; 默认)"
    echo "  镜像:         ${IMG_REPO_OVERRIDE}:${IMG_TAG_OVERRIDE}(pullPolicy=${IMG_PULL_POLICY})"
    echo "  集群 registry: ${REG_BASE}(镜像已推入; 节点从这里拉, 不访问 Harbor)"
fi
echo "  平台实例 CR:  clusterCR.enabled=${CR_ENABLED}(改 cluster.conf CUBESTACK_OPERATOR_CLUSTER_CR_ENABLED)"
echo "  端到端验证:   sudo ./deploy-cluster.sh --steps verify_cubestack_operator"
echo "  状态查看:     kubectl get csc -n ${NS}"

# 优雅覆盖登记(仅安装路径到达此处; 本模块 REPEAT:1, 重跑只更新 lastSeenAt, seq 保持首装序)
record_installed_component "cubestack_operator"
