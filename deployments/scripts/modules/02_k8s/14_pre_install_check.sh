#!/bin/bash
# ============================================================
# MODULE: pre_install_check
# DESC: 安装前环境检查(master/worker: SSH/sudo/chronyd/资源容量/前置包; 关键项失败即中止)
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# REQUIRES: k8s_passwordless
# 说明:
#   · 只读检查, 不改动节点; 逻辑全在 tools/node/pre-install-check.sh(可单独跑:
#     `bash tools/node/pre-install-check.sh --check [--only <host>]`)。
#   · 检查项: SSH 免密/密码可达、sudo、chronyd 运行与偏差、CPU/内存//var/lib 空间、
#     节点前置包存在性(warn-only)。关键项任一失败 → 非零退出, 部署在 kubespray 之前中止;
#     建议项只告警。
#   · 前置包默认**只检查不安装**; 通用 OS 包缺失时按提示运行
#     tools/manual/install-os-packages.sh。node_pkgs(NODE_PKGS_ENABLED=true)
#     只负责 helm/nodejs; k8s_workerbm(WORKER_PKGS_ENABLED=true) 负责 worker 离线包。
#   · 定序: k8s_deploy 的 REQUIRES 显式声明本模块, 保证在真正安装之前执行
#     (14 > 06, 与 node_pkgs 同一手法: 序号不足以定序, 补 REQUIRES)。
#   · 2026-11-17(CodeRabbit): deploy-cluster 在**优雅卸载/覆盖安装之前**提前执行本模块
#     (若在计划中); 关键项失败会中止, 现有组件不会被 cluster-teardown 拆除。
#     模块循环会跳过重复执行。只读检查, 节点已运行集群时结果与循环内一致。
#   · 阈值: PRE_INSTALL_MIN_CPU / PRE_INSTALL_MIN_MEM_MB / PRE_INSTALL_MASTER_MIN_MEM_MB /
#     PRE_INSTALL_MIN_DISK_GB / PRE_INSTALL_RECOMMENDED_DISK_GB(见 cluster.defaults.conf §2.2b)。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

say "安装前环境检查(SSH/sudo/chronyd/资源容量; 关键项失败将中止部署) ..."
bash "${SCRIPT_DIR}/tools/node/pre-install-check.sh" --check

# 节点前置包存在性检查(warn-only; 通用 OS 包默认由 OS 镜像提供, 不自动安装)。
# 缺失时按输出提示运行 tools/manual/install-os-packages.sh 手动安装;
# node_pkgs(NODE_PKGS_ENABLED=true)只负责 helm/nodejs(os/helm-nodejs)。
if [ "${CUBESTACK_OS_CHECK_DONE:-0}" = "1" ]; then
    say "节点前置包已由在线安装预检，跳过复检"
else
    hosts=()
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        node_matches "${NODE_HOSTNAME}" || continue
        hosts+=("${NODE_USER}@${NODE_IP}")
    done
    if [ "${#hosts[@]}" -gt 0 ]; then
        HOSTS_CSV="$(IFS=,; echo "${hosts[*]}")"
        SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
        check_args=(--baseline "${REPO_ROOT}/versions/base.yaml" --hosts "${HOSTS_CSV}"
            --key "${SSH_KEY}" --warn-only)
        if [ -n "${SSH_DEFAULT_PASSWORD:-}" ]; then
            check_args+=(--password "${SSH_DEFAULT_PASSWORD}")
        fi
        say "节点前置包检查(warn-only; 通用 OS 包不自动安装, 缺失时用手动脚本)..."
        bash "${SCRIPT_DIR}/tools/online/check-os-packages.sh" "${check_args[@]}"
    fi
fi
ok "安装前环境检查通过"
