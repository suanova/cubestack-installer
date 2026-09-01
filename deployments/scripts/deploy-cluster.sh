#!/bin/bash
# ============================================================
# CubeStack 一键部署统一入口(模块化编排, 自动发现)
# 职责: 参数解析 + 按模块框架(lib-module.sh)调度 modules/*.sh, 不做任何业务逻辑
# 每个部署功能 = modules/ 下一个独立脚本(自动发现, 无需注册表; 新增模块=放一个文件)
#
# 模块命名: modules/<NN_phase>/<NN>_<category>_<action>.sh
#   (头部注释声明元数据 MODULE/DESC/PHASE/DEFAULT/REPEAT/TOGGLE, 自动发现)
# 阶段目录(按部署环境准备的阶段组织):
#   01_env/    阶段一: 环境准备(VM/SSH/本地registry/HAProxy/Keepalived — 部署 kubespray 之前)
#   02_k8s/    阶段二: 离线部署 kubespray(不依赖 VM/裸金属)
#   03_addon/  阶段三: 附加组件(集群部署后: GPU/LWS/监控/Harbor/Ceph/Envoy/P2/P3)
#
# 模块(stages):
#   env 阶段:  vm_network vm_sshkey vm_create harbor lb_haproxy lb_keepalived
#   k8s 阶段:  k8s_passwordless k8s_workerbm k8s_hosts k8s_inventory k8s_ntp
#              k8s_deploy(默认关) k8s_scale(默认关)
#   addon 阶段: gpu_operator gpu_lws k8s_registry prometheus ceph ceph_csi
#              envoy_gateway envoy_ai_gateway keycloak kueue kubevirt lustre_csi   (01~19 中间件, 默认关)
#              cubestack_apps(20 起自研模块占位, 默认关)
#   验证:      verify_<组件>(自动发现; --steps verify 不指定 operator 默认执行全部 verify_*)
#
# vm / k8s_passwordless / k8s_workerbm / k8s_hosts / k8s_inventory 为可重复(幂等)模块。
# 断点续跑: 每模块完成后写入状态文件; --fresh 清状态重跑。
#
# 用法:
#   sudo ./deploy-cluster.sh                                # 默认 = --with-cubestack(全量: 基座 + cluster.conf 启用的全部 operator)
#   sudo ./deploy-cluster.sh --with-k8s                     # 仅部署 kubespray 基座(k8s + metallb/local-path/registry)
#   sudo ./deploy-cluster.sh --with-cubestack               # 全量: 基座 + cluster.conf 中已启用的 operator
#   sudo ./deploy-cluster.sh --steps vm_create,k8s_deploy   # 只跑指定模块
#   sudo ./deploy-cluster.sh --skip k8s_hosts --with-cubestack   # 跳过某模块的全量部署
#   sudo ./deploy-cluster.sh --enable gpu_operator,lws      # 只把开关写入 cluster.conf 预启用(不部署)
#   sudo ./deploy-cluster.sh --enable envoy_gateway,envoy_ai_gateway   # Envoy 网关二件套预启用(EG 基座 + AI 扩展, AI 依赖 EG 先装)
#   sudo ./deploy-cluster.sh --phase k8s                    # 仅运行 k8s 阶段
#   sudo ./deploy-cluster.sh --only <host> --with-k8s       # 仅处理指定节点
#   sudo ./deploy-cluster.sh --with-scale                   # 扩容(新节点先写入 cluster.conf / tools/vm/vm-nodes.conf)
#   sudo ./deploy-cluster.sh --list / --list-steps / --fresh
# 数据源: config/cluster.conf
#
# 兼容: 旧模块名(net/ssh_key/vm/ssh_passwordless/worker_bm/hosts/inventory/ntp/k8s/scale/lws)自动映射到新名
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"
# shellcheck source=lib-module.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-module.sh"

# 先发现模块(help 需动态展示 verify_* 列表, 新增 verify step 后 --help 自动更新)
discover_modules

# ---------------- 帮助 ----------------
usage() {
    cat <<EOF
用法: sudo ./deploy-cluster.sh [选项]

统一入口,按模块框架(lib-module.sh)自动发现并调度 modules/<阶段>/NN_*.sh 部署模块。

⚠ 默认(不加任何参数) = sudo ./deploy-cluster.sh --with-cubestack
   = 全量部署: 基座(k8s+metallb+local-path+registry)+ cluster.conf 中 XXX_ENABLED=true 的全部 operator。
   仅基座用 --with-k8s, 单个立即部署用 --steps。虚拟机创建由 tools/vm/create-vms.sh 独立执行。

阶段目录与模块(自动发现):
  01_env  vm_network vm_sshkey vm_create harbor lb_haproxy lb_keepalived
          (默认执行 vm_sshkey; vm_network 默认关 — 宿主网络初始化改由 tools/vm/create-vms.sh 创建 VM 时自动执行; vm_create 默认关 — 虚拟机创建由 tools/vm/create-vms.sh 独立执行)
  02_k8s  k8s_passwordless k8s_workerbm k8s_hosts k8s_inventory k8s_ntp           (默认执行)
          k8s_deploy(默认关, --with-k8s)  k8s_scale(默认关, --with-scale)
  03_addon 依赖顺序: metallb local_path k8s_registry(基础) 中间件: gpu_operator gpu_lws prometheus ceph
          ceph_csi envoy_gateway envoy_ai_gateway keycloak kueue kubevirt lustre_csi (默认关, --enable)
          20 起自研: cubestack_apps(CUBESTACK_APPS_ENABLED, 默认关)
  验证(自动发现, 新增 verify step 后本段自动更新):
          --steps verify = 执行全部验证模块: $(_verify_meta_list)
          --steps verify_<组件> = 只验证指定组件(如 verify_metallb / verify_registry_storage)

注:
  · cluster.conf 的 NODES(5字段: role,hostname,ip,ssh_user,ssh_password)不区分虚拟机/裸金属;
    主程序不判断节点类型 — 需要创建虚拟机的节点在 tools/vm/vm-nodes.conf(10字段)定义,
    由 sudo ./deployments/scripts/tools/vm/create-vms.sh 独立执行(创建后自动注入 NODES)。
  · --only/--skip 均支持; 宿主网络初始化(vm_network)默认不再执行, 改由创建虚拟机时
    (tools/vm/create-vms.sh)自动初始化; 需要手动单独跑用 --steps vm_network。

选项:
  --with-k8s            仅部署 kubespray 基座: k8s_deploy + kubespray 内置 addon(metallb/local-path/registry)
                        不含任何 operator(= --enable k8s, 并跳过全部 operator)
  --with-cubestack      全量部署: = 基座 + cluster.conf 中 XXX_ENABLED=true 的 operator(以 cluster.conf 为主)
                        (如设 GPU_OPERATOR_ENABLED=true 即部署 gpu_operator; lb_haproxy/lb_keepalived 默认 false)
  --with-scale          启用 k8s_scale 扩容模块(= --enable scale)
  --steps k1,k2         立即部署指定模块(自动带基座; verify=只跑验证模块, 不拉基座)
  --skip k1,k2          跳过模块(verify=跳过全部验证模块)
  --enable k1,k2        只把模块开关写入 cluster.conf(持久化, 不部署); 下次 --with-cubestack / 默认部署生效
  --phase env|k8s|addon 仅运行指定阶段(可逗号分隔)
  --only HOST           仅处理指定节点(可多次; 支持 hostname 或 group 名)
  --fresh, --refresh    清断点续跑状态重新执行
  --list                仅打印集群规划(只读)
  --list-steps          列出全部模块
  --help, -h            显示本帮助

示例:
  sudo ./deploy-cluster.sh                          # 默认 = --with-cubestack(全量部署)
  sudo ./deploy-cluster.sh --with-k8s              # 仅部署 kubespray 基座(k8s+metallb+local-path+registry)
  sudo ./deploy-cluster.sh --skip gpu_operator --fresh   # 全量重装但排除 gpu_operator(--fresh 清状态)
  sudo ./deploy-cluster.sh --enable lws             # 只把 LWS_ENABLED=true 写入 cluster.conf(不部署)
  sudo ./deploy-cluster.sh --steps gpu_operator     # 立即部署 gpu_operator(自动带基座, 只部署指定的)
  sudo ./deploy-cluster.sh --with-scale             # 扩容: 新节点先写入 cluster.conf / tools/vm/vm-nodes.conf
  sudo ./deploy-cluster.sh --only worker02 --with-scale
  sudo ./deploy-cluster.sh --steps verify           # 只跑全部验证模块(端到端验证, 不拉基座)
  sudo ./deploy-cluster.sh --steps verify_metallb   # 只验证某个组件(验后自动清理)
EOF
    exit 0
}

# ---------------- 参数解析 ----------------
FRESH=0; LIST=0; LIST_STEPS=0
STEPS_ARG=""; SKIP_ARG=""; ENABLE_ARG=""; PHASE_ARG=""; ENABLE_PERSIST_ARG=""
ONLY_HOSTS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --fresh|--refresh) FRESH=1; shift ;;
        --list)     LIST=1; shift ;;
        --list-steps) LIST_STEPS=1; shift ;;
        # --with-k8s: 仅 kubespray 基座(k8s + metallb/local-path/registry), 不含任何 operator
        --with-k8s) ENABLE_ARG="${ENABLE_ARG},k8s"; SKIP_ARG="${SKIP_ARG},gpu_operator,gpu_lws,lb_haproxy,lb_keepalived,prometheus,ceph,ceph_csi,envoy_gateway,envoy_ai_gateway,keycloak,kueue,kubevirt,lustre_csi,cubestack_apps"; shift ;;
        --with-scale) ENABLE_ARG="${ENABLE_ARG},scale"; shift ;;
        # --with-cubestack = 基座 + cluster.conf 中 XXX_ENABLED=true 的 operator(以 cluster.conf 为主, 不强制启用)
        #   lb_haproxy/lb_keepalived 默认 false, 需要时在 cluster.conf 设 true 或 --enable
        --with-cubestack) ENABLE_ARG="${ENABLE_ARG},k8s"; shift ;;
        --steps)    STEPS_ARG="${2:?--steps 需要模块列表, 逗号分隔}"; shift 2 ;;
        --skip)     SKIP_ARG="${2:?--skip 需要模块列表, 逗号分隔}"; shift 2 ;;
        # --enable = 只把模块开关写入 cluster.conf(持久化), 不立即部署; 立即部署用 --steps
        --enable)   ENABLE_PERSIST_ARG="${ENABLE_PERSIST_ARG},${2:?--enable 需要模块列表, 逗号分隔}"; shift 2 ;;
        --phase)    PHASE_ARG="${2:?--phase 需要阶段名 env|k8s|addon}"; shift 2 ;;
        --only)     ONLY_HOSTS="${ONLY_HOSTS},${2:?--only 需要节点名}"; shift 2 ;;
        --help|-h)  usage ;;
        *)          err "未知参数: $1(用 --help 查看)"; exit 1 ;;
    esac
done
ONLY_HOSTS="${ONLY_HOSTS#,}"
# 展开 --only 中的 group 名: NODE_GROUP_<name> 定义在 cluster.conf 中
if [ -n "${ONLY_HOSTS}" ]; then
    _resolved=""
    for _token in ${ONLY_HOSTS//,/ }; do
        _group_var="NODE_GROUP_${_token}"
        if [ -n "${!_group_var:-}" ]; then
            _resolved="${_resolved},${!_group_var}"
            vlog "  --only ${_token} → 展开为: ${!_group_var}"
        else
            _resolved="${_resolved},${_token}"
        fi
    done
    ONLY_HOSTS="${_resolved#,}"
    unset _resolved _token _group_var
fi
export ONLY_HOSTS

# ---------------- 配置加载 + 模块解析 ----------------
load_config

# 离线文件就绪检查(缺失 → 醒目提示, 不阻断; 部署前请先准备, 见 tools/offline/fetch-offline-files.sh)
check_offline_files

# --enable k1,k2 = 只把模块开关写入 cluster.conf(持久化), 不立即部署。
# 下次 --with-cubestack / 默认部署时按 cluster.conf 生效; 立即部署单个 operator 用 --steps k1,k2。
_enable_persist() {   # <key,...>
    local s nk idx tgl cur
    for s in ${1//,/ }; do
        [ -z "${s}" ] && continue
        nk="$(normalize_key "${s}")"
        idx="$(module_index "${nk}")"
        [ "${idx}" -ge 0 ] || { err "未知模块: ${s}(可用 --list-steps 查看)"; exit 1; }
        tgl="${MODULE_TOGGLE[$idx]:-}"
        if [ -z "${tgl}" ]; then
            warn "模块 ${nk} 无 cluster.conf 开关(TOGGLE 未定义, 如 verify 模块), 无法持久化; 请用 --steps ${s} 直接执行"
            continue
        fi
        # 当前生效值(load_config 已把 cluster.conf 读入环境; 兼容 ${VAR:-true} 默认写法)
        cur="${!tgl:-false}"
        case "${cur,,}" in
            true|1|yes|on) ok "${tgl} 已是 true(${CLUSTER_CONF})"; continue ;;
        esac
        if grep -qE "^${tgl}=" "${CLUSTER_CONF}" 2>/dev/null; then
            # 用 | 作 sed 分隔符(替换文本含 # 注释, 避开 # 分隔冲突)
            sed -i -E "s|^${tgl}=.*|${tgl}=true   # --enable ${nk} 持久化|" "${CLUSTER_CONF}"
        else
            printf '%s=true   # --enable %s 持久化\n' "${tgl}" "${nk}" >> "${CLUSTER_CONF}"
        fi
        export "${tgl}=true"   # 同步到当前环境(同一次调用内再 --enable 同一模块幂等跳过)
        ok "已写入 ${CLUSTER_CONF}: ${tgl}=true(${nk})"
    done
}
if [ -n "${ENABLE_PERSIST_ARG}" ]; then
    _enable_persist "${ENABLE_PERSIST_ARG}"
    # 仅 --enable 且无其它部署触发(--steps/--with-*/--skip/--phase/--only) → 只写配置后退出, 不部署
    if [ -z "${STEPS_ARG}" ] && [ -z "${ENABLE_ARG}" ] && [ -z "${SKIP_ARG}" ] && [ -z "${PHASE_ARG}" ] && [ -z "${ONLY_HOSTS}" ]; then
        say "已写入 cluster.conf(本次不部署)。下次执行 --with-cubestack / 默认部署即生效; 立即部署用 --steps ${ENABLE_PERSIST_ARG#,}"
        exit 0
    fi
fi

# 默认模式(未指定任何部署方式): 等价于 sudo ./deploy-cluster.sh --with-cubestack
#   = 全量部署: 基座(k8s+metallb+local-path+registry)+ cluster.conf 中 XXX_ENABLED=true 的全部 operator。
#   vm_network(VM 桥/NAT 网络初始化)已移出默认执行序列 —— 局域网初始化改为在
#   tools/vm/create-vms.sh 创建虚拟机时自动执行, 主程序不再初始化宿主网络(不区分 VM/裸金属)。
#   零参数、或仅带 --skip/--phase/--fresh/--list* 时生效
#     (--list/--list-steps 展示默认全量计划); --steps/--with-*/--enable/--only/--help 明确指定时不触发。
if [ -z "${STEPS_ARG}" ] && [ -z "${ENABLE_ARG}" ] && [ -z "${ONLY_HOSTS}" ]; then
    ENABLE_ARG="k8s"
    say "默认模式: 等价于 --with-cubestack — 基座 + cluster.conf 中启用的全部 operator"
fi

if ! resolve_run_steps "${STEPS_ARG}" "${SKIP_ARG}" "${ENABLE_ARG}" "${PHASE_ARG}"; then
    exit 1
fi

# 让显式启用的模块真正生效: 为 RUN_STEPS 中带 TOGGLE 的模块导出 TOGGLE=true。
# 否则 --enable gpu_operator / --with-cubestack 只把模块加入执行列表, 模块内部 `[ "${TOGGLE}" = true ]`
# 自检读的是 cluster.conf 默认 false → 会跳过。导出后子进程模块脚本自检通过。
for i in "${!MODULE_KEY[@]}"; do
    tgl="${MODULE_TOGGLE[$i]:-}"
    [ -n "${tgl}" ] || continue
    for k in "${RUN_STEPS[@]:-}"; do
        [ "${k}" = "${MODULE_KEY[$i]}" ] && { export "${tgl}=true"; break; }
    done
done

[ "${FRESH}" = "1" ] && { clear_state; say "已清除断点续跑状态(--fresh)" ; }

# ---------------- 输出 ----------------
if [ "${LIST_STEPS}" = "1" ]; then print_steps; exit 0; fi
if [ "${LIST}" = "1" ]; then print_plan; exit 0; fi

need_root() { [ "$(id -u)" -eq 0 ] || { err "需要 root 权限,请执行: sudo $0"; exit 1; }; }
need_root

# 启动全量日志
LOG_FILE="/tmp/cubestack-cluster-install.log"
rm -f "${LOG_FILE}" 2>/dev/null || true
export LOG_FILE
say "完整部署日志: ${LOG_FILE}"

print_plan

# ---------------- 调度: 按模块文件顺序执行选中的模块 ----------------
say "==== 开始一键部署(共 ${#RUN_STEPS[@]} 个模块) ===="
FAILED=0
for key in "${RUN_STEPS[@]:-}"; do
    run_module "${key}" || { FAILED=1; break; }
done

# ---------------- 汇总 ----------------
echo "============================================="
if [ "${FAILED}" = "1" ]; then
    err "部署中断: 模块 ${key} 失败(可用 --skip ${key} 跳过或修复后重跑, --fresh 清状态重跑)"
    exit 1
fi
echo -e "\033[32m✅ 一键部署流程完成(配置: ${CLUSTER_CONF})\033[0m"
echo "  配置: ${CLUSTER_CONF}"
echo "  本次执行: ${RUN_STEPS[*]}"
echo "  完整日志: ${LOG_FILE:-<未保存, 可用 pipe 保存>}"
echo "  SSH 私钥:   ${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
echo "  Kubeconfig: ${KUBESPRAY_INV_DIR}/artifacts/admin.conf"
echo "              用法: kubectl --kubeconfig=${KUBESPRAY_INV_DIR}/artifacts/admin.conf get nodes"
echo "  管理凭证:   无 kubeadmin 密码, 管理员权限=admin.conf(客户端证书); 节点 SSH 默认密码: ${SSH_DEFAULT_PASSWORD:-<未设置>}"
if [ "${SERVICE_EXPOSE_MODE:-nodeport}" = "nodeport" ]; then
    _NIP="$(first_node_ip 2>/dev/null || echo '<节点IP>')"
    echo "  服务暴露:   测试环境 NodePort 模式(SERVICE_EXPOSE_MODE=nodeport, 未部署 MetalLB)"
    echo "               · registry:      http://${_NIP}:${REGISTRY_NODEPORT:-31148}/"
    echo "               · ingress-nginx(若启用): http://${_NIP}:30080/  (https 30081)"
    echo "               · Envoy Gateway: 数据面转 NodePort 后访问 —— tools/lb/gateway-nodeport.sh <gateway名>"
else
    echo "  服务暴露:   MetalLB LoadBalancer(生产默认) —— registry VIP ${REGISTRY_IP:-<自动派生>}:${REGISTRY_PORT:-5000}; ingress/Envoy Gateway 经各自 LoadBalancer VIP"
fi
echo "  下一步: 扩容用 --with-scale; 立即部署单个用 --steps gpu_operator,lws(...)(自动带基座); 预启用写入配置用 --enable ...(下次全量生效); 验证用 --steps verify"
echo "============================================="
