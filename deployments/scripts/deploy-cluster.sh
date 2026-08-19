#!/bin/bash
# ============================================================
# CubeStack 一键部署统一入口(模块化编排)
# 职责: 参数解析 + 按模块注册表(lib-deploy.sh)调度 steps/*.sh, 不做任何业务逻辑
# 每个部署功能 = steps/ 下一个独立脚本, 在 DEPLOY_STEPS 注册一行即可接入
#
# 模块(steps/):
#   net            初始化宿主网络          ssh_key       生成 SSH 密钥
#   vm             创建虚拟机并确保 running ssh_passwordless 配置 SSH 免密
#   worker_bm      裸金属 worker 装包      hosts         更新 /etc/hosts
#   inventory      生成 inventory          k8s           部署 kubespray(默认关闭)
#   gpu_operator   沐曦 GPU Operator(占位, 默认关闭)   lws  LWS(占位, 默认关闭)
#
# 断点续跑: 每模块完成后写入状态文件; 下次从断点继续; --fresh 清状态重跑
#
# 用法:
#   sudo ./deploy-cluster.sh                                # 默认基础设施模块
#   sudo ./deploy-cluster.sh --with-k8s                     # +部署 kubespray
#   sudo ./deploy-cluster.sh --steps vm,ssh_passwordless    # 只跑指定模块
#   sudo ./deploy-cluster.sh --skip hosts --with-k8s        # 跳过某模块
#   sudo ./deploy-cluster.sh --enable gpu_operator,lws      # 启用默认关闭模块
#   sudo ./deploy-cluster.sh --only <host> --with-k8s       # 仅处理指定节点
#   sudo ./deploy-cluster.sh --list / --list-steps / --fresh
# 数据源: config/cluster.conf
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"
# shellcheck source=lib-deploy.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-deploy.sh"

# ---------------- 帮助 ----------------
usage() {
    cat <<'EOF'
用法: sudo ./deploy-cluster.sh [选项]

统一入口,按 lib-deploy.sh 注册表调度 steps/*.sh 部署模块。

模块(steps/):
  net ssh_key vm ssh_passwordless worker_bm hosts inventory   (默认执行)
  k8s           部署 kubespray(默认关闭, --with-k8s / --enable k8s 启用)
  gpu_operator  沐曦 GPU Operator(占位, 默认关闭)
  lws           LeaderWorkerSet(占位, 默认关闭)

选项:
  --with-k8s            启用 k8s 部署模块(= --enable k8s)
  --steps k1,k2         只运行指定模块
  --skip k1,k2          跳过模块
  --enable k1,k2        启用默认关闭模块(gpu_operator,lws...)
  --only HOST           仅处理指定节点(可多次)
  --fresh, --refresh    清断点续跑状态重新执行
  --skip-net            跳过网络模块
  --list                仅打印集群规划(只读)
  --list-steps          列出全部模块
  --help, -h            显示本帮助

示例:
  sudo ./deploy-cluster.sh --with-k8s
  sudo ./deploy-cluster.sh --steps vm,k8s
  sudo ./deploy-cluster.sh --skip hosts --with-k8s
  sudo ./deploy-cluster.sh --enable gpu_operator,lws
EOF
    exit 0
}

# ---------------- 参数解析 ----------------
FRESH=0; LIST=0; LIST_STEPS=0
STEPS_ARG=""; SKIP_ARG=""; ENABLE_ARG=""
ONLY_HOSTS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --fresh|--refresh) FRESH=1; shift ;;
        --list)     LIST=1; shift ;;
        --list-steps) LIST_STEPS=1; shift ;;
        --with-k8s) ENABLE_ARG="${ENABLE_ARG},k8s"; shift ;;
        --steps)    STEPS_ARG="${2:?--steps 需要模块列表, 逗号分隔}"; shift 2 ;;
        --skip)     SKIP_ARG="${2:?--skip 需要模块列表, 逗号分隔}"; shift 2 ;;
        --enable)   ENABLE_ARG="${ENABLE_ARG},${2:?--enable 需要模块列表, 逗号分隔}"; shift 2 ;;
        --only)     ONLY_HOSTS="${ONLY_HOSTS},${2:?--only 需要节点名}"; shift 2 ;;
        --skip-net) SKIP_ARG="${SKIP_ARG},net"; shift ;;
        --help|-h)  usage ;;
        *)          err "未知参数: $1(用 --help 查看)"; exit 1 ;;
    esac
done
ONLY_HOSTS="${ONLY_HOSTS#,}"
export ONLY_HOSTS

# ---------------- 配置加载 + 模块解析 ----------------
# 统一读取 lib-common 解析出的 config/cluster.conf
load_config

init_deploy_steps
resolve_run_steps "${STEPS_ARG}" "${SKIP_ARG}" "${ENABLE_ARG}"

[ "${FRESH}" = "1" ] && { clear_state; say "已清除断点续跑状态(--fresh)" ; }

# ---------------- 输出 ----------------
if [ "${LIST_STEPS}" = "1" ]; then print_steps; exit 0; fi
if [ "${LIST}" = "1" ]; then print_plan; exit 0; fi

need_root() { [ "$(id -u)" -eq 0 ] || { err "需要 root 权限,请执行: sudo $0"; exit 1; }; }
need_root

# ---------------- 启动全量日志: 同时输出终端 + 写入 /tmp/cubestack-cluster-install.log ----------------
LOG_FILE="/tmp/cubestack-cluster-install.log"
rm -f "${LOG_FILE}" 2>/dev/null || true
# exec 重定向: 所有 stdout/stderr 通过 tee 分流到终端 + 日志文件
exec > >(tee -a "${LOG_FILE}") 2>&1
say "完整部署日志: ${LOG_FILE}"

print_plan

# ---------------- 调度: 按注册表顺序执行选中的模块 ----------------
say "==== 开始一键部署(共 ${#RUN_STEPS[@]} 个模块) ===="
FAILED=0
for key in "${RUN_STEPS[@]:-}"; do
    run_deploy_step "${key}" || { FAILED=1; break; }
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
echo "  完整日志: ${LOG_FILE}"
echo "  下一步: 用 --enable gpu_operator,lws 安装 GPU Operator / LWS(需先实现 steps/ 对应脚本)"
echo "============================================="
