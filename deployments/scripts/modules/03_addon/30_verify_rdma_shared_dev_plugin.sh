#!/bin/bash
# ============================================================
# MODULE: verify_rdma_shared_dev_plugin
# DESC: 端到端验证 k8s-rdma-shared-dev-plugin 真正工作(非仅 DaemonSet Running):
#       ① DaemonSet pod 全 Running → ② ConfigMap(资源池)存在
#       → ③ 从 ConfigMap 解析全部扩展资源 + 逐个资源遍历节点检查 allocatable 注册
#       (pool 单资源 / per-hca 每块 HCA 一个资源, 自动适配; 无 HCA 节点自然没有, warn 说明)
#       → ④ 创建测试 pod **申请 RDMA 设备资源**(取首个已注册资源)并等待 Running
#       → ⑤ 容器内断言 /dev/infiniband 字符设备已注入(uverbs* 必需, rdma_cm 缺失仅告警)
#       → 测试命名空间由 trap 清理
#       ★ 占位模式(ConfigMap 标注 cubestack.io/rdma-placeholder=true): ③ 无任何资源注册属**预期**,
#         放行 exit 0 并明确标注"仅验证到 DaemonSet/ConfigMap 层, 未验收真实 RDMA"; 非占位维持硬失败。
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# REQUIRES: rdma_shared_dev_plugin k8s_registry
# 说明:
#   · **验证模块不设 TOGGLE**(否则 RDMA_ENABLED=true 时会被安装流程自动启用);
#     保持 DEFAULT:0, 仅由 --steps verify_rdma_shared_dev_plugin 在安装后单个执行。
#   · **门禁看实际部署, 不看配置开关**(仿 verify_lws): 只要 rdma-shared-dp-ds 实际在跑
#     就验证(无论 RDMA_ENABLED true/false, 例如 --steps rdma_shared_dev_plugin 单独部署过);
#     仅当"DaemonSet 不在 且 RDMA_ENABLED≠true"才跳过。
#   · 资源注册: 插件经 /var/lib/kubelet/device-plugins 把资源注册进 kubelet → 节点
#     allocatable 出现扩展资源。无 HCA 节点不注册(自然)。
#   · **资源名动态解析**: 不依赖 RDMA_RESOURCE_NAME 单一资源(pool 模式是单资源, per-hca
#     模式每块 HCA 一个资源名如 mlx5_0/mlx5_1...)。本模块从 ConfigMap 的 config.json 解析
#     configList 全部条目, 逐个资源逐个节点检查 allocatable。
#   · **离线可用(硬要求)**: ④ 的测试 pod 镜像**不碰 docker.io、也不依赖节点 containerd 预载** ——
#     统一用 lib-common 的 ensure_registry_nginx 把 nginx 推进**集群内置 registry**
#     (来源: 本地 docker daemon → deployments/offline-files/nginx/nginx.tar; 在线源仅在
#     VERIFY_IMAGE_ONLINE=true 时启用, 离线部署默认禁止), pod 再从内置 registry 拉取。
#     故 REQUIRES 带上 k8s_registry。
#   · **验证边界(如实标注)**: ④⑤ 证明的是"扩展资源可被调度 + 设备插件 Allocate 的字符设备
#     真正注入容器"(= 项目文档 deployments/cubestack-addon/rdma/CUBESTACK.md §107 的验收点)。
#     **不含真实 RDMA 流量**(ib_write_bw / ibv_devinfo 需 perftest / rdma-core 镜像, 不在
#     离线镜像集内); 需要吞吐/时延验收请另配 perftest 镜像单独跑, 不要据此判定数据面已验收。
#   · **占位模式放行(纯 VM 无 RDMA 卡)**: 10_rdma 走 RDMA_PLACEHOLDER_HCAS 占位时会给 ConfigMap
#     打标注 cubestack.io/rdma-placeholder=true。本模块**从集群实际状态读该标注**(不读本地
#     cluster.conf —— 防"配置文件换了、集群没换"的错配), 命中则 ①② 照常真检查、③ 无资源注册
#     放行 exit 0, 并明确标注"未验收真实 RDMA"。非占位集群维持硬失败不变。
# 数据源: cluster.conf (RDMA_ENABLED / RDMA_RESOURCE_PREFIX / RDMA_NAMESPACE / NODES /
#         SSH_KEY_NAME); 资源列表动态读取自 ConfigMap(rdma-devices/config.json),
#         占位标注动态读取自同 ConfigMap 的 annotation
# 用法: sudo ./deploy-cluster.sh --steps verify_rdma_shared_dev_plugin
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

init_remote_kubectl || exit 1

NS="${RDMA_NAMESPACE:-kube-system}"
DS_NAME="rdma-shared-dp-ds"
RES_PREFIX="${RDMA_RESOURCE_PREFIX:-nvidia.com}"
TEST_NS="verify-rdma-$$"        # 唯一命名空间(PID 后缀), 避免与残留 Terminating ns 冲突
TEST_POD="verify-rdma-pod"
TEST_IMAGE=""                   # ④ 里经 ensure_registry_nginx 解析(集群内置 registry, 离线可用)
_RES_PICK=""                    # 首个"有节点注册"的资源 → ④ 测试 pod 申请它
_DEV_OK=""                      # ⑤ 成功后的摘要(资源@节点/设备列表)
_PLACEHOLDER="0"                # 1 = ConfigMap 标注 rdma-placeholder=true(纯 VM 占位) → ③ 无资源属预期

# ---- 门禁: 以实际部署为准(DaemonSet 是否在跑) ----
DEPLOYED="$( (SSH "${K} -n ${NS} get ds ${DS_NAME} --no-headers 2>/dev/null" || true) | wc -l )"
if [ "${DEPLOYED:-0}" -eq 0 ] && [ "${RDMA_ENABLED:-false}" != "true" ]; then
    say "RDMA 插件未部署(DaemonSet 不存在且 RDMA_ENABLED≠true), 跳过验证(先 --steps rdma_shared_dev_plugin 部署)"
    exit 0
fi

cleanup() {
    # 清理测试命名空间(含其中的 pod); 幂等 —— 未创建时 --ignore-not-found 无副作用,
    # trap 兜底保证**失败路径也不残留**(下面任何 err/exit 都会触发)
    SSH "${K}" delete ns ${TEST_NS} --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

say "Verify RDMA 共享设备插件: DaemonSet → ConfigMap → 节点扩展资源注册 → 测试 pod 申请设备..."

say "  ① 检查 rdma-shared-dp-ds pod 全 Running..."
_NRUN="$( (SSH "${K} -n ${NS} get pods -l name=rdma-shared-dp --no-headers 2>/dev/null" || true) | awk '$3=="Running"{n++} END{print n+0}' )"
_NTOT="$( (SSH "${K} -n ${NS} get pods -l name=rdma-shared-dp --no-headers --ignore-not-found 2>/dev/null" || true) | wc -l )"
[ "${_NRUN:-0}" -ge 1 ] || { err "rdma-shared-dp-ds 无 Running pod(${_NRUN}/${_NTOT}); 检查镜像拉取/privileged 状态"; exit 1; }
ok "    rdma pod Running ${_NRUN}/${_NTOT} ✓"

say "  ② 检查 ConfigMap(资源池)存在..."
_CM="$(SSH "${K} -n ${NS} get cm rdma-devices --no-headers 2>/dev/null" || true)"
[ -n "${_CM}" ] && ok "    ConfigMap ${NS}/rdma-devices 存在 ✓" \
    || { err "ConfigMap ${NS}/rdma-devices 不存在(先 --steps rdma_shared_dev_plugin 部署)"; exit 1; }
# 占位标注: 与 config.json 同源同对象(10_rdma 恒写 true/false), 从**集群实际状态**读而非本地
# cluster.conf —— 防"配置文件改了、集群还是旧的"错配。go-template index 同 ③ 取 config.json 的做法
# (键含 '.' 与 '/' 不能走 jsonpath 点路径); 老 ConfigMap 无此标注时 index 输出 "<no value>" → 非 true。
_PH_CM="$(SSH "${K} -n ${NS} get cm rdma-devices -o go-template='{{index .metadata.annotations \"cubestack.io/rdma-placeholder\"}}' 2>/dev/null" || true)"
case "${_PH_CM}" in *true*) _PLACEHOLDER="1" ;; *) _PLACEHOLDER="0" ;; esac
[ "${_PLACEHOLDER}" = "1" ] && warn "    占位模式: ConfigMap 标注 rdma-placeholder=true(无真实 RDMA 硬件, ③ 无资源注册属预期)"

say "  ③ 从 ConfigMap 解析全部扩展资源, 遍历节点检查 allocatable..."
# config.json 由 10_rdma 模块生成: pool=单条目, per-hca=每块 HCA 一个条目
# 取 data["config.json"]: 键含点号不能走 jsonpath 点路径, 用 go-template index
_CM_JSON="$(SSH "${K} -n ${NS} get cm rdma-devices -o go-template='{{index .data \"config.json\"}}' 2>/dev/null" || true)"
# 解析 configList 各条目 resourcePrefix + resourceName(纯 awk, 不依赖 jq/python3):
# config.json 每条 configList 条目按顺序含一个 resourcePrefix 和紧跟的 resourceName,
# awk 逐行提取二者并逐对配对输出 "前缀/资源名"。
_RES_LIST="$(echo "${_CM_JSON}" | awk '
/"resourcePrefix"/ {
    p=$0
    sub(/^.*"resourcePrefix"[[:space:]]*:[[:space:]]*"/, "", p)
    sub(/"[[:space:]]*,?[[:space:]]*$/, "", p)
}
/"resourceName"/ {
    n=$0
    sub(/^.*"resourceName"[[:space:]]*:[[:space:]]*"/, "", n)
    sub(/"[[:space:]]*,?[[:space:]]*$/, "", n)
    if (p!="" && n!="") { printf " %s/%s", p, n; p="" }
}' 2>/dev/null || true)"
# ★ 资源名合法性过滤: 上面 awk 依赖 config.json 的"每键一行"格式(= 10_rdma 模块的生成格式)。
#   若 ConfigMap 被手工改成"一 entry 一行"的紧凑 JSON, awk 会抽出含引号/花括号/逗号的垃圾串 ——
#   既会让下面的 grep(正则!)误判"该资源已在节点注册", 也会让 ④ 去申请一个根本不存在的扩展资源
#   (pod 永远 Pending, 白等 180s 才报错)。这里按"合法扩展资源名"过滤(必须含 '/' 且不含 JSON 结构字符)。
_SANE=""
for _r in ${_RES_LIST}; do
    case "${_r}" in
        */*) ;;                  # 扩展资源名形如 <prefix>/<name>, 必须含 '/'
        *) continue ;;
    esac
    case "${_r}" in
        *[!A-Za-z0-9._/-]*) ;;   # 含 '/'-分隔外的任何其它字符(引号/花括号/逗号/空格...) → 丢弃
        *) _SANE="${_SANE} ${_r}" ;;
    esac
done
if [ "${_SANE}" != "${_RES_LIST}" ]; then
    warn "  config.json 解析出非法资源名(ConfigMap 疑似被改成紧凑 JSON); 已丢弃:${_RES_LIST}"
    warn "  请恢复 10_rdma 模块生成的'每键一行'格式, 或直接重跑 --steps rdma_shared_dev_plugin 重建 ConfigMap"
fi
_RES_LIST="${_SANE}"
# 兜底: 解析失败/为空则退回配置里的单一资源(pool 模式)
if [ -z "${_RES_LIST}" ]; then
    RES_NAME="${RDMA_RESOURCE_NAME:-mlx5_0}"
    _RES_LIST="${RES_PREFIX}/${RES_NAME}"
    warn "  ConfigMap config.json 解析失败或为空, 退回配置单一资源: ${RES_PREFIX}/${RES_NAME}(per-hca 多资源请检查 10_rdma 生成的 config.json)"
fi
say "    资源列表:${_RES_LIST}"
_NODES="$(SSH "${K} get nodes --no-headers 2>/dev/null" || true)"
_NODES_TOTAL="$(echo "${_NODES}" | grep -c . || true)"; _NODES_TOTAL="${_NODES_TOTAL:-0}"
[ "${_NODES_TOTAL:-0}" -ge 1 ] || { err "未获取到任何节点(kubectl get nodes 为空); 检查集群可达性"; exit 1; }
_FOUND=0; _RES_OK=""; _RES_MISS=""
for _res in ${_RES_LIST}; do
    _NODES_WITH=0
    while IFS= read -r _n; do
        [ -z "${_n}" ] && continue
        _node="$(echo "${_n}" | awk '{print $1}')"
        # 查该节点 allocatable 是否含该扩展资源
        _alloc="$(SSH "${K} get node ${_node} -o jsonpath='{.status.allocatable}' 2>/dev/null" || true)"
        if echo "${_alloc}" | grep -q "${_res}"; then
            _NODES_WITH=$((_NODES_WITH + 1))
        fi
    done <<< "${_NODES}"
    if [ "${_NODES_WITH}" -ge 1 ]; then
        _FOUND=1; _RES_OK="${_RES_OK} ${_res}(${_NODES_WITH}节点)"
        # 记首个已注册资源 → ④ 的测试 pod 申请它(存在即有节点能提供该扩展资源)
        [ -n "${_RES_PICK}" ] || _RES_PICK="${_res}"
        say "    ${_res}: ${_NODES_WITH}/${_NODES_TOTAL} 节点注册 ✓"
    else
        _RES_MISS="${_RES_MISS} ${_res}"
        say "    ${_res}: 无节点注册(该 HCA 未检测到或驱动未加载, 属正常)"
    fi
done
if [ "${_FOUND}" = "1" ]; then
    ok "    已注册:${_RES_OK}(RDMA 扩展资源可用) ✓"
    if [ -n "${_RES_MISS}" ]; then
        warn "    未注册:${_RES_MISS}(无 HCA 网卡节点/驱动未加载/该资源本节点不存在, 单节点验证可通过)"
    fi

    # ---------------- ④ 创建测试 pod 申请 RDMA 设备资源 ----------------
    # 资源选择: 取**首个已注册**的资源(per-hca 各 HCA 一个资源名 / pool 单资源); 不钉节点 ——
    #   让调度器自己挑有该资源的节点, 顺带证明调度器识别该扩展资源(未注册 → Insufficient → Pending)。
    say "  ④ 创建测试 pod ${TEST_NS}/${TEST_POD} 申请 RDMA 设备资源(${_RES_PICK})并等待 Running..."
    # 镜像(离线硬要求): ensure_registry_nginx 把 nginx 推进**集群内置 registry**(不碰 docker.io,
    #   也不依赖节点 containerd 预载), pod 从内置 registry 拉取; 来源 = 本地 docker →
    #   offline-files/nginx/nginx.tar →(仅 VERIFY_IMAGE_ONLINE=true)在线。故纯离线环境同样可用。
    TEST_IMAGE="$(ensure_registry_nginx)" || exit 1
    LOCAL_YAML="$(mktemp)"
    cat > "${LOCAL_YAML}" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${TEST_NS}
---
apiVersion: v1
kind: Pod
metadata:
  name: ${TEST_POD}
  namespace: ${TEST_NS}
spec:
  containers:
  - name: rdma-verify
    image: ${TEST_IMAGE}
    imagePullPolicy: IfNotPresent
    command: ["/bin/sh","-c","sleep infinity"]
    resources:
      limits:
        ${_RES_PICK}: 1
YAML
    # 提交走 scp + apply(不用 heredoc→SSH stdin 管道: 历史上会挂起, 同 21_verify_metallb)
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -q \
        "${LOCAL_YAML}" "${SSH_USER:-ubuntu}@${FIRST_MASTER}:/tmp/${TEST_POD}.yaml" \
        || { rm -f "${LOCAL_YAML}"; err "测试 pod YAML 投递失败(scp → ${FIRST_MASTER})"; exit 1; }
    SSH "${K} apply -f /tmp/${TEST_POD}.yaml" \
        || { rm -f "${LOCAL_YAML}"; err "apply 测试 pod YAML 失败(检查内置 registry 可达性)"; exit 1; }
    SSH "rm -f /tmp/${TEST_POD}.yaml" >/dev/null 2>&1 || true
    rm -f "${LOCAL_YAML}"

    _POD_RUNNING=0
    for _i in $(seq 1 36); do
        _st="$(SSH "${K}" -n ${TEST_NS} get pod ${TEST_POD} -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        [ "${_st}" = "Running" ] && { _POD_RUNNING=1; break; }
        _cst="$(SSH "${K}" -n ${TEST_NS} get pod ${TEST_POD} -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null || true)"
        if echo "${_cst}" | grep -q "ImagePullBackOff\|ErrImage"; then
            err "测试 pod 镜像拉取失败(${_cst}); 检查内置 registry 可达性与 ${TEST_IMAGE}"; exit 1
        fi
        sleep 5
    done
    if [ "${_POD_RUNNING}" != "1" ]; then
        # 典型失败: 资源未注册/配额耗尽 → 调度器判 Insufficient。打印调度事件, 避免只看到 Pending
        _WHY="$(SSH "${K}" -n ${TEST_NS} get events --field-selector involvedObject.name=${TEST_POD} -o custom-columns=REASON:.reason,MSG:.message --no-headers 2>/dev/null | tail -3 || true)"
        err "测试 pod 180s 内未 Running(phase=${_st:-?}); 调度或设备分配失败"
        if [ -n "${_WHY}" ]; then printf '%s\n' "${_WHY}" | sed 's/^/      /' >&2; fi
        exit 1
    fi
    _POD_NODE="$(SSH "${K}" -n ${TEST_NS} get pod ${TEST_POD} -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
    ok "    测试 pod Running(node=${_POD_NODE}) ✓ 调度器已识别扩展资源"

    # ---------------- ⑤ 容器内断言 /dev/infiniband 设备已注入 ----------------
    # 设备插件 Allocate 返回 DeviceSpec → kubelet 把字符设备挂进容器。验收点取自项目文档
    # deployments/cubestack-addon/rdma/CUBESTACK.md: "容器内 ls -l /dev/infiniband/ 应看到
    # uverbs0、rdma_cm"。uverbs* = HCA 字符设备, 缺失即 RDMA 不可用(硬失败);
    # rdma_cm 由内核模块提供, 部分内核/插件版本可能没有, 仅告警(见文件头"验证边界")。
    say "  ⑤ 容器内断言 /dev/infiniband 设备注入(设备插件 Allocate → kubelet 挂载)..."
    _DEVS="$(SSH "${K}" -n ${TEST_NS} exec ${TEST_POD} -- ls -1 /dev/infiniband 2>/dev/null || true)"
    if [ -z "${_DEVS}" ]; then
        err "    容器内 /dev/infiniband 不存在或为空 —— 字符设备未注入容器"
        err "    排查: kubectl -n ${NS} logs -l name=rdma-shared-dp --tail=50(插件 Allocate/设备探测)"
        exit 1
    fi
    _UVERB="$(echo "${_DEVS}" | grep -m1 '^uverbs' || true)"
    if [ -z "${_UVERB}" ]; then
        err "    容器内 /dev/infiniband 无 uverbs* 字符设备(HCA 不可用); 实际内容: $(echo "${_DEVS}" | tr '\n' ' ')"
        exit 1
    fi
    ok "    uverbs 字符设备已注入: ${_UVERB} ✓"
    if echo "${_DEVS}" | grep -q '^rdma_cm'; then
        ok "    rdma_cm 已注入 ✓(RDMA-CM/MAD 建链可用)"
    else
        warn "    未见 rdma_cm(由 rdma_cm 内核模块提供; 不影响本次判定, 但 NCCL/MPI 走 RDMA-CM 建链会受影响)"
    fi
    _DEV_OK="${_RES_PICK} @ ${_POD_NODE} → $(echo "${_DEVS}" | tr '\n' ' ')"
elif [ "${_PLACEHOLDER}" = "1" ]; then
    warn "    占位模式(rdma-placeholder=true): 本集群无真实 RDMA 硬件, 不注册任何扩展资源属**预期行为**"
    warn "    (共 ${_NODES_TOTAL} 节点); 已跳过 ④⑤(测试 pod 申请设备 + 容器内 uverbs 注入)。"
else
    warn "    暂无节点注册任何 RDMA 资源(共 ${_NODES_TOTAL} 节点)。"
    warn "    可能原因: ① 节点无 RDMA 网卡/驱动(ibstat 验证); ② RDMA_VENDORS/RDMA_IF_NAMES 与设备不匹配;"
    warn "    ③ 插件尚未周期更新(periodicUpdateInterval)。查看: kubectl -n ${NS} logs -l name=rdma-shared-dp --tail=50"
fi

echo "---------------------------------------------"
if [ "${_FOUND}" = "1" ]; then
    ok "RDMA 共享设备插件验证通过: DaemonSet Ready → ConfigMap 存在 → 节点注册资源:${_RES_OK}"
    ok "  → 测试 pod 申请 RDMA 设备并通过: ${_DEV_OK}(字符设备已注入容器)"
    echo "  清理: 测试命名空间 ${TEST_NS} 已自动删除(trap)"
elif [ "${_PLACEHOLDER}" = "1" ]; then
    ok "RDMA 共享设备插件验证通过(占位模式): DaemonSet pod Running → ConfigMap 存在 → 无扩展资源注册(符合占位预期)"
    warn "  ⚠ 本次**未验收真实 RDMA 能力**: 集群无 HCA, ④⑤(测试 pod 申请设备 + 容器内 uverbs 注入)已跳过。"
    warn "  ⚠ 需真实验收: 装卡/加载驱动后清空 RDMA_PLACEHOLDER_HCAS, 用 --steps rdma_shared_dev_plugin --fresh 重跑 10_rdma, 再跑本验证。"
    echo "  清理: 测试命名空间 ${TEST_NS} 未创建(占位模式跳过 ④), trap 无副作用"
else
    err "RDMA 插件验证未通过: 无节点注册扩展资源(检查节点驱动与 RDMA_* 配置); 见上方排查指引"
    exit 1
fi
unset _NRUN _NTOT _CM _PH_CM _PLACEHOLDER _CM_JSON _RES_LIST _RES_OK _RES_MISS _FOUND _NODES_WITH _NODES_TOTAL _NODES _n _node _alloc _block _p 2>/dev/null || true
unset _RES_PICK _DEV_OK _POD_RUNNING _POD_NODE _DEVS _UVERB _WHY _st _cst _i LOCAL_YAML 2>/dev/null || true
