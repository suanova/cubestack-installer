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
  03_addon 依赖顺序: metallb ceph ceph_csi(存储底座, 供 registry 等用 ceph 后端)
          local_path(可选) k8s_registry 中间件: gpu_operator gpu_lws prometheus
          envoy_gateway envoy_ai_gateway keycloak kueue kubevirt lustre_csi (默认关, --enable)
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

# ★ 并发锁: 防两个 deploy-cluster.sh 实例同时运行 —— 状态文件 .deploy.state 是 grep+mv
#   非原子写, 曾出现并发实例互相覆盖状态。--list/--list-steps 只读, 不加锁。
#   锁文件常驻(.deploy.state.lock, 空文件), 由 fd 关闭自动释放, 不删除(删除会引入竞态)。
if [ "${LIST_STEPS}" != "1" ] && [ "${LIST}" != "1" ]; then
    exec 9>"${STATE_FILE}.lock"
    if ! flock -n 9; then
        err "检测到已有部署进程在运行(锁: ${STATE_FILE}.lock)"
        err "  请等待其完成; 若确认无残留进程(ps aux | grep deploy-cluster), 可手工删除锁文件后重试"
        exit 1
    fi
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

# ⚠ Ceph 部署前强制确认(倒计时, 防覆盖磁盘 double-check 的兜底):
#   print_plan 的红底提醒无倒计时(纯提示); 02_ceph 模块内部的倒计时在 k8s 部署之后,
#   k8s_deploy 已被断点标记 done 跳过时会丢失 —— 这里在**真正开始部署前**再打断一次:
#   CEPH_ENABLED=true 且本次会执行 ceph 相关模块(k8s_deploy 或 ceph)时, sleep 倒计时
#   CEPH_CONFIRM_SLEEP(默认 60s, 设 0 跳过)供人工 double-check 存储节点/裸盘。
if [ "${CEPH_ENABLED:-false}" = "true" ]; then
    _ceph_confirm_in=""
    for k in "${RUN_STEPS[@]:-}"; do
        case "${k}" in k8s_deploy|ceph) _ceph_confirm_in=1; break ;; esac
    done
    if [ -n "${_ceph_confirm_in}" ]; then
        _ceph_cs="${CEPH_CONFIRM_SLEEP:-60}"
        echo ""
        echo -e "\033[41m\033[97m================================================================================\033[0m"
        echo -e "\033[41m\033[97m ⚠⚠⚠  CEPH_ENABLED=true — 部署开始前最后确认存储节点/裸盘(避免覆盖磁盘) ⚠⚠⚠\033[0m"
        echo -e "\033[41m\033[97m   node label: ${CEPH_NODE_LABEL:-ceph-storage=rook-ceph}   裸盘策略: ${CEPH_DATA_DISK_POLICY:-auto}\033[0m"
        echo -e "\033[41m\033[97m   存储节点与将使用的裸盘(SSH 直连自动检测/或 CEPH_DATA_DISKS 显式):\033[0m"
        # 候选存储节点(hostname): CEPH_NODES 显式; 空=全部 NODES
        declare -A _CEPH_CONFIRM_DISKS
        _CEPH_CONFIRM_HOSTS=()
        if [ -n "${CEPH_NODES:-}" ]; then
            for _h in ${CEPH_NODES//,/ }; do [ -n "${_h}" ] && _CEPH_CONFIRM_HOSTS+=("${_h}"); done
        else
            for _line in "${NODES[@]:-}"; do
                [ -z "${_line}" ] && continue
                node_parse "${_line}"
                [ -n "${NODE_HOSTNAME}" ] && _CEPH_CONFIRM_HOSTS+=("${NODE_HOSTNAME}")
            done
        fi
        _CEPH_CONFIRM_DETECT_FAIL=0
        if [ -n "${CEPH_DATA_DISKS:-}" ]; then
            # 显式指定: 与 ceph 模块两轮解析一致(hostname 条目优先, 全节点条目仅填充未指定)
            while IFS=';' read -ra _grp; do
                for _g in "${_grp[@]}"; do
                    [ -z "${_g}" ] && continue
                    _hn="${_g%%:*}"; _ds="${_g#*:}"
                    [ -z "${_hn}" ] || [ "${_hn}" = "${_ds}" ] && continue
                    _norm=""
                    for _d in ${_ds//,/ }; do _norm="${_norm:+${_norm},}/dev/${_d#/dev/}"; done
                    _CEPH_CONFIRM_DISKS["${_hn}"]="${_norm}"
                done
            done <<< "${CEPH_DATA_DISKS}"
            while IFS=';' read -ra _grp; do
                for _g in "${_grp[@]}"; do
                    [ -z "${_g}" ] && continue
                    _hn="${_g%%:*}"; _ds="${_g#*:}"
                    [ -z "${_hn}" ] || [ "${_hn}" = "${_ds}" ] || continue
                    _norm=""
                    for _d in ${_ds//,/ }; do _norm="${_norm:+${_norm},}/dev/${_d#/dev/}"; done
                    for _h2 in "${_CEPH_CONFIRM_HOSTS[@]}"; do
                        [ -n "${_CEPH_CONFIRM_DISKS[${_h2}]:-}" ] || _CEPH_CONFIRM_DISKS["${_h2}"]="${_norm}"
                    done
                done
            done <<< "${CEPH_DATA_DISKS}"
        else
            # 自动检测(SSH 直连, 与 ceph 模块同工具); 节点免密未配置/无盘 → 降级提示
            _DETECT_ARGS=()
            for _h in "${_CEPH_CONFIRM_HOSTS[@]}"; do _DETECT_ARGS+=(--node "${_h}"); done
            _DETECT_OUT="$(bash "${SCRIPT_DIR}/tools/k8s/ceph-detect-disks.sh" "${_DETECT_ARGS[@]}" -m 2>/dev/null)" || true
            if [ -n "${_DETECT_OUT}" ]; then
                while IFS= read -r _l; do
                    [ -z "${_l}" ] && continue
                    [[ "${_l}" == *"/dev/"* ]] || continue
                    _hn="${_l%%:*}"; _ds="${_l#*:}"
                    _CEPH_CONFIRM_DISKS["${_hn}"]="${_ds%,}"
                done <<< "${_DETECT_OUT}"
            else
                _CEPH_CONFIRM_DETECT_FAIL=1
            fi
            unset _DETECT_ARGS _DETECT_OUT
        fi
        for _h in "${_CEPH_CONFIRM_HOSTS[@]:-}"; do
            _ip=""
            for _line in "${NODES[@]:-}"; do
                [ -z "${_line}" ] && continue
                node_parse "${_line}"
                [ "${NODE_HOSTNAME}" = "${_h}" ] && { _ip="${NODE_IP}"; break; }
            done
            echo -e "\033[41m\033[97m   · ${_h}${_ip:+(${_ip})}  →  裸盘: ${_CEPH_CONFIRM_DISKS[${_h}]:-<未检测到>}\033[0m"
        done
        if [ "${_CEPH_CONFIRM_DETECT_FAIL}" = "1" ]; then
            echo -e "\033[41m\033[97m   ⚠ 自动检测未返回(节点 SSH 免密可能未配置); 将在 ceph 模块部署时(SSH 就绪后)再确认盘名\033[0m"
        fi
        if [ -n "${REGISTRY_STORAGE_CLASS:-}" ] && [ "${REGISTRY_STORAGE_CLASS}" != "local-path" ]; then
            echo -e "\033[41m\033[97m   registry 后端: REGISTRY_STORAGE_CLASS=${REGISTRY_STORAGE_CLASS}(PVC 等 ceph 就绪后自动绑定)\033[0m"
        fi
        echo -e "\033[41m\033[97m   auto 自动检测"未使用裸盘"(挂载/分区/格式化/系统盘一律不选); 显式用 CEPH_DATA_DISKS\033[0m"
        echo -e "\033[41m\033[97m   有误请 Ctrl-C 中止, 修正 ${CLUSTER_CONF} 后重跑                    \033[0m"
        echo -e "\033[41m\033[97m================================================================================\033[0m"

        # ★ 检测已有 CephCluster(覆盖 K8s 重装时决定"清理销毁"还是"保留数据"):
        #   默认清理(CEPH_PRE_CLEANUP_EXISTING=true): 重装前完整清空上次 ceph 所用磁盘, 旧数据销毁;
        #   保留旧 OSD 数据用另一开关: CEPH_RESTORE_BACKUP=true(02_ceph 从备份 CR 提取 status.fsid
        #   注入新 CR 的 spec.fsid, Rook 凭 fsid 认领旧盘)。检测失败不阻断(SSH 免密未就绪/集群不可达 → 降级提示)。
        _CEPH_EXIST=""
        _FM_IP="$(first_master_ip 2>/dev/null || true)"
        _CEPH_SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
        if [ -n "${_FM_IP}" ] && [ -f "${_CEPH_SSH_KEY}" ]; then
            _CEPH_EXIST="$(ssh -i "${_CEPH_SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "${SSH_USER:-ubuntu}@${_FM_IP}" "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf -n rook-ceph get cephcluster --no-headers 2>/dev/null" 2>/dev/null || true)"
        fi
        if [ -n "${_CEPH_EXIST}" ]; then
            echo ""
            echo -e "\033[41m\033[97m================================================================================\033[0m"
            echo -e "\033[41m\033[97m ⚠⚠⚠  检测到已有 CephCluster: $(echo "${_CEPH_EXIST}" | awk '{print $1}') ⚠⚠⚠\033[0m"
            if [ "${CEPH_PRE_CLEANUP_EXISTING:-true}" = "true" ]; then                echo -e "\033[41m\033[97m   覆盖 K8s 前将清理旧 Ceph(mon/osd/池, OSD 数据将销毁) —— 仅显式启用时  \033[0m"
            else
                echo -e "\033[41m\033[97m   默认【全新部署】: 重装生成新 fsid, 不认领旧 OSD 数据(盘上残留旧数据会被拒绝用) \033[0m"
                echo -e "\033[41m\033[97m   销毁旧数据: CEPH_PRE_CLEANUP_EXISTING=true; 认领旧数据: CEPH_RESTORE_BACKUP=true \033[0m"
            fi
            echo -e "\033[41m\033[97m   保留 csi-operator(重装不再重复安装); 检测不影响其他 operator 部署    \033[0m"
            echo -e "\033[41m\033[97m================================================================================\033[0m"
            # ★ 备份旧 CephCluster CR(含 status.fsid): 供 02_ceph.sh 在 CEPH_RESTORE_BACKUP=true 时
            #   提取 fsid 注入新 CR 的 spec.fsid(Rook 凭 fsid 识别"同一个集群"并认领旧 OSD 数据)。
            #   只提取 fsid, 不整份恢复旧 CR —— 旧 CR 的 storage.nodes/devices 来自上一代环境,
            #   直接 apply 会导致盘名/节点过时(OSD 永不创建)与残留 mon store 死锁。
            CEPH_CR_BACKUP="${CEPH_CR_BACKUP:-${REPO_ROOT}/deployments/offline-files/cephcluster-backup.yaml}"
            mkdir -p "$(dirname "${CEPH_CR_BACKUP}")"
            if ssh -i "${_CEPH_SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${_FM_IP}" "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf -n rook-ceph get cephcluster rook-ceph -o yaml" 2>/dev/null > "${CEPH_CR_BACKUP}"; then
                [ -s "${CEPH_CR_BACKUP}" ] && ok "已备份旧 CephCluster CR → ${CEPH_CR_BACKUP}(认领旧数据用)" \
                    || warn "CephCluster CR 备份为空(请手工备份: kubectl -n rook-ceph get cephcluster rook-ceph -o yaml)"
            else
                warn "备份 CephCluster CR 失败(重装后如需认领旧 OSD 数据, 请手工备份原 CR 含 status.fsid)"
            fi
            # ★ 部署时手动备份: 把备份推送到节点根盘 /var/lib/ceph/backup/(防 wipe/防覆盖/防部署机丢失)。
            #   下次保留数据模式(PRE_CLEANUP=false)重装时 02_ceph 自动从该目录读取 fsid 注入新集群认领旧数据。
            if [ -s "${CEPH_CR_BACKUP}" ]; then
                bash "${SCRIPT_DIR}/tools/k8s/ceph-backup.sh" save "${CEPH_CR_BACKUP}" \
                    || warn "推送 Ceph 备份到节点失败(自动注入不可用; 可手工: tools/k8s/ceph-backup.sh save ${CEPH_CR_BACKUP})"
            fi
        fi

        if [ "${_ceph_cs}" -gt 0 ] 2>/dev/null; then
            say "Ceph 已启用: sleep ${_ceph_cs}s 供核对上方节点/裸盘(CEPH_CONFIRM_SLEEP=0 可跳过)..."
            for _c in $(seq "${_ceph_cs}" -1 1); do
                printf "\r%s" "$(printf '\033[41m\033[97m  ⏳ 倒计时 %d 秒继续(请核对上方 Ceph 存储节点/裸盘, 有误 Ctrl-C)      \033[0m' "${_c}")"
                sleep 1
            done
            printf "\r%s\n" "$(printf '\033[0m  %s             ')"
            printf "\r%s\n" "$(printf '\033[0m  %s             ')"
            unset _c
        else
            say "CEPH_CONFIRM_SLEEP=0, 跳过等待(请务必已人工核对上方节点/裸盘)"
        fi

        # 已有 CephCluster 且显式允许销毁 → 覆盖 k8s 前卸载旧 Ceph(OSD 数据销毁)
        if [ -n "${_CEPH_EXIST}" ] && [ "${CEPH_PRE_CLEANUP_EXISTING:-true}" = "true" ]; then
            say "清理已有 Ceph(cleanupPolicy yes-really-destroy-data → 删 cephblockpool/cephcluster)..."
            ssh -i "${_CEPH_SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${_FM_IP}" \
                "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf -n rook-ceph patch cephcluster rook-ceph --type merge -p '{\"spec\":{\"cleanupPolicy\":{\"confirmation\":\"yes-really-destroy-data\"}}}' >/dev/null 2>&1; sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf -n rook-ceph delete cephblockpool rbd-pool --wait=false >/dev/null 2>&1; sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf -n rook-ceph delete cephcluster rook-ceph --wait=false >/dev/null 2>&1; true"
            say "等待旧 Ceph 清理完成(最长 300s)..."
            _CEPH_GONE=0
            for _i in $(seq 1 60); do
                _still="$(ssh -i "${_CEPH_SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "${SSH_USER:-ubuntu}@${_FM_IP}" "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf -n rook-ceph get cephcluster --no-headers 2>/dev/null" 2>/dev/null || true)"
                [ -z "${_still}" ] && { _CEPH_GONE=1; break; }
                sleep 5
            done
            [ "${_CEPH_GONE}" = "1" ] && ok "旧 Ceph 已清理, 可重新部署" || warn "旧 Ceph 未完全清理(重装前请手工确认 cephcluster 已删除)"
        fi
        unset _CEPH_EXIST _FM_IP _CEPH_SSH_KEY _CEPH_GONE
        unset _ceph_cs _CEPH_CONFIRM_HOSTS _CEPH_CONFIRM_DISKS _CEPH_CONFIRM_DETECT_FAIL _h _ip _line _l _ds _hn _g _grp _norm _h2 _d
    fi
    unset _ceph_confirm_in
fi

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
# 服务暴露方式醒目提示: 当前模式(metallb / nodeport)+ 各自注意事项
_C_BOLD="\033[1m"; _C_YELLOW="\033[33m"; _C_GREEN="\033[32m"; _C_OFF="\033[0m"
if [ "${SERVICE_EXPOSE_MODE:-nodeport}" = "nodeport" ]; then
    _NIP="$(first_node_ip 2>/dev/null || echo '<节点IP>')"
    echo -e "${_C_BOLD}${_C_YELLOW}⚠ 服务暴露方式: 当前为 NodePort 模式(SERVICE_EXPOSE_MODE=nodeport, 未部署 MetalLB)${_C_OFF}"
    echo "  访问入口 = 任意节点 IP + NodePort(自动取集群第一个节点 IP: ${_NIP}, 跨节点自动转发):"
    echo "               · registry:      http://${_NIP}:${REGISTRY_NODEPORT:-31148}/"
    echo "               · Envoy Gateway(若启用): 数据面转 NodePort 后访问 —— tools/lb/gateway-nodeport.sh <gateway名>"
    echo "  ⚠ NodePort 注意事项:"
    echo "               · 端口默认 30000-32767, 超出需改 kube-apiserver --service-node-port-range"
    echo "               · 无固定 VIP, 入口=单节点 IP, 节点重启/换 IP 后入口会变(部署时自动取新 IP)"
    echo "               · 对外服务用单节点 IP 有单点风险; 需要固定入口或生产环境请改用 MetalLB"
    echo "                 (SERVICE_EXPOSE_MODE=metallb, 需提供同网段空闲的 METALLB_POOL)"
else
    echo -e "${_C_BOLD}${_C_GREEN}✅ 服务暴露方式: 当前为 MetalLB LoadBalancer 模式(SERVICE_EXPOSE_MODE=metallb, 生产默认)${_C_OFF}"
    echo "  访问入口 = LoadBalancer VIP(registry 固定 VIP ${REGISTRY_IP:-<自动派生>}:${REGISTRY_PORT:-5000};"
    echo "               ingress/Envoy Gateway 经各自 LoadBalancer VIP)"
    echo "  ⚠ MetalLB 注意事项:"
    echo "               · METALLB_POOL 必须与节点同网段、不含网络/广播地址(.0/.255), 且地址空闲"
    echo "               · 地址池建议 >1 个地址, 否则新建 LoadBalancer 可能无 VIP 可分配(verify_metallb 会校验)"
    echo "               · 改池后需重跑 tools/k8s/sync-kubespray-config.sh 并重新 apply 池 CR 再验证"
    echo "               · 测试环境无空闲地址时可用 nodeport(SERVICE_EXPOSE_MODE=nodeport)"
fi
echo "  下一步: 扩容用 --with-scale; 立即部署单个用 --steps gpu_operator,lws(...)(自动带基座); 预启用写入配置用 --enable ...(下次全量生效); 验证用 --steps verify"
echo "============================================="
