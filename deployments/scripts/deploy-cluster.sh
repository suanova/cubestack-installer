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
#              envoy_gateway keycloak kueue kubevirt lustre_csi   (01~19 中间件, 默认关)
#              cubestack_apps(20 起自研模块占位, 默认关)
#   验证:      verify_<组件>(自动发现; --steps verify 不指定 operator 默认执行全部 verify_*)
#
# vm / k8s_passwordless / k8s_workerbm / k8s_hosts / k8s_inventory 为可重复(幂等)模块。
# 断点续跑: 每模块完成后写入状态文件; --fresh 清状态重跑。
#
# 用法:
#   sudo ./deploy-cluster.sh                                # 默认基础设施模块
#   sudo ./deploy-cluster.sh --with-k8s                     # +部署 kubespray
#   sudo ./deploy-cluster.sh --steps vm_create,k8s_deploy   # 只跑指定模块
#   sudo ./deploy-cluster.sh --skip k8s_hosts --with-k8s    # 跳过某模块
#   sudo ./deploy-cluster.sh --enable gpu_operator,lws      # 启用默认关闭模块
#   sudo ./deploy-cluster.sh --phase k8s                    # 仅运行 k8s 阶段
#   sudo ./deploy-cluster.sh --only <host> --with-k8s       # 仅处理指定节点
#   sudo ./deploy-cluster.sh --with-scale                   # 扩容(新节点已在 cluster.conf)
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

阶段目录与模块(自动发现):
  01_env  vm_network vm_sshkey vm_create harbor lb_haproxy lb_keepalived   (默认执行前3项)
  02_k8s  k8s_passwordless k8s_workerbm k8s_hosts k8s_inventory k8s_ntp           (默认执行)
          k8s_deploy(默认关, --with-k8s)  k8s_scale(默认关, --with-scale)
  03_addon 依赖顺序: metallb local_path k8s_registry(基础) 中间件: gpu_operator gpu_lws prometheus ceph
          ceph_csi envoy_gateway keycloak kueue kubevirt lustre_csi        (默认关, --enable)
          20 起自研: cubestack_apps(CUBESTACK_APPS_ENABLED, 默认关)
  验证(自动发现, 新增 verify step 后本段自动更新):
          --steps verify = 执行全部验证模块: $(_verify_meta_list)
          --steps verify_<组件> = 只验证指定组件(如 verify_metallb / verify_registry_storage)

选项:
  --with-k8s            启用 k8s_deploy 部署模块(= --enable k8s)
  --with-scale          启用 k8s_scale 扩容模块(= --enable scale)
  --steps k1,k2         只运行指定模块(兼容旧名 net/vm/k8s/...; verify=全部验证模块)
  --skip k1,k2          跳过模块(verify=跳过全部验证模块)
  --enable k1,k2        启用默认关闭模块
  --phase env|k8s|addon 仅运行指定阶段(可逗号分隔)
  --only HOST           仅处理指定节点(可多次; 支持 hostname 或 group 名)
  --fresh, --refresh    清断点续跑状态重新执行
  --skip-net            跳过 vm_network 模块(裸金属集群需要 --skip-net, 虚拟机无需改参)
  --list                仅打印集群规划(只读)
  --list-steps          列出全部模块
  --help, -h            显示本帮助

示例:
  sudo ./deploy-cluster.sh --with-k8s --skip-net   # 裸金属集群加 --skip-net，虚拟机无需该参，去掉skip-net
  sudo ./deploy-cluster.sh --steps vm_create,k8s_deploy
  sudo ./deploy-cluster.sh --skip k8s_hosts --with-k8s
  sudo ./deploy-cluster.sh --enable gpu_operator,lws
  sudo ./deploy-cluster.sh --phase k8s
  sudo ./deploy-cluster.sh --with-scale   # 扩容: 新节点先写入 cluster.conf
  sudo ./deploy-cluster.sh --only worker02 --with-scale
  sudo ./deploy-cluster.sh --steps verify              # 端到端验证全部组件(不指定 operator 默认全跑)
  sudo ./deploy-cluster.sh --steps verify_metallb      # 只验证某个组件(验后自动清理)
EOF
    exit 0
}

# ---------------- 参数解析 ----------------
FRESH=0; LIST=0; LIST_STEPS=0
STEPS_ARG=""; SKIP_ARG=""; ENABLE_ARG=""; PHASE_ARG=""
ONLY_HOSTS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --fresh|--refresh) FRESH=1; shift ;;
        --list)     LIST=1; shift ;;
        --list-steps) LIST_STEPS=1; shift ;;
        --with-k8s) ENABLE_ARG="${ENABLE_ARG},k8s"; shift ;;
        --with-scale) ENABLE_ARG="${ENABLE_ARG},scale"; shift ;;
        --steps)    STEPS_ARG="${2:?--steps 需要模块列表, 逗号分隔}"; shift 2 ;;
        --skip)     SKIP_ARG="${2:?--skip 需要模块列表, 逗号分隔}"; shift 2 ;;
        --enable)   ENABLE_ARG="${ENABLE_ARG},${2:?--enable 需要模块列表, 逗号分隔}"; shift 2 ;;
        --phase)    PHASE_ARG="${2:?--phase 需要阶段名 env|k8s|addon}"; shift 2 ;;
        --only)     ONLY_HOSTS="${ONLY_HOSTS},${2:?--only 需要节点名}"; shift 2 ;;
        --skip-net) SKIP_ARG="${SKIP_ARG},vm_network"; shift ;;
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
if ! resolve_run_steps "${STEPS_ARG}" "${SKIP_ARG}" "${ENABLE_ARG}" "${PHASE_ARG}"; then
    exit 1
fi

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
echo "  下一步: 扩容用 --with-scale; 组件用 --enable gpu_operator,lws,lb_haproxy,lb_keepalived"
echo "============================================="
