#!/bin/bash
# ============================================================
# lib-module.sh — 部署模块框架(自动发现 + 元数据 + 调度)
# 取代旧 lib-deploy.sh 手工注册表: 模块 = modules/<NN_phase>/<NN>_<category>_<action>.sh
# 新增/删除/修改模块只需操作 modules/ 下的单个文件, 无需改任何注册表/入口。
#
# 目录组织(按部署环境准备的阶段划分子目录):
#   modules/01_env/    阶段一: 环境准备(VM/SSH/HAProxy/Keepalived — 发生在部署 kubespray 之前)
#   modules/02_k8s/    阶段二: 离线部署 kubespray(不依赖 VM 还是裸金属)
#   modules/03_addon/  阶段三: 附加组件(集群部署后的扩展组件)
#
# 模块命名规范: <NN>_<category>_<action>.sh
#   NN       两位序号, 决定执行顺序(01 最早, 与子目录 NN_ 前缀共同决定全局顺序)
#   category 模块分类: vm / env / k8s / gpu / lb / registry ...
#   action   模块动作: 如 network / create / deploy / scale
#
# 模块头部元数据注释(标准格式, 框架自动解析):
#   # MODULE: <key>            模块唯一标识(缺省 = 文件名去掉 NN_ 前缀)
#   # DESC: <一句话描述>
#   # PHASE: <env|k8s|addon>   阶段: env=环境准备 k8s=离线部署 addon=附加组件
#   # DEFAULT: <0|1>           是否默认启用(0=需 --enable / TOGGLE / --steps)
#   # REPEAT: <0|1>            1=可重复执行(每次执行且不写断点状态)
#   # TOGGLE: <VAR>            (可选) cluster.conf 变量名, 值为 true 时自动启用
# 示例:
#   # MODULE: k8s_deploy
#   # DESC: 部署 kubespray 集群(离线)
#   # PHASE: k8s
#   # DEFAULT: 0
#   # REPEAT: 0
#   # TOGGLE: K8S_ENABLED
#
# 旧 key 别名(向后兼容, 旧用法 --steps vm,k8s 等仍然有效):
#   net→vm_network ssh_key→vm_sshkey vm→vm_create ssh_passwordless→k8s_passwordless
#   worker_bm→k8s_workerbm hosts→k8s_hosts inventory→k8s_inventory ntp→k8s_ntp
#   k8s→k8s_deploy scale→k8s_scale lws→gpu_lws
# ============================================================

MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/modules"

# ---------------- 旧 key → 新 key 别名(向后兼容) ----------------
declare -A MODULE_ALIAS=(
    [net]=vm_network
    [ssh_key]=vm_sshkey
    [vm]=vm_create
    [ssh_passwordless]=k8s_passwordless
    [worker_bm]=k8s_workerbm
    [hosts]=k8s_hosts
    [inventory]=k8s_inventory
    [ntp]=k8s_ntp
    [k8s]=k8s_deploy
    [scale]=k8s_scale
    [gpu_operator]=gpu_operator
    [lws]=gpu_lws
)

# 归一化模块 key(旧别名 → 新 key; 未知 key 原样返回)
normalize_key() {
    local k="$1"
    [ -n "${MODULE_ALIAS[$k]:-}" ] && echo "${MODULE_ALIAS[$k]}" || echo "$k"
}

# ---------------- operator 模块(显式调度用) ----------------
# --steps 显式命名了任一 operator 时, 只部署被指定的 operator(+基座 env/k8s/metallb/local_path/k8s_registry),
# 剔除"默认启用但未显式指定"的 operator(如 GPU_OPERATOR_ENABLED=true 但 --steps lws 时不部署 gpu_operator);
# 未命名任何 operator(纯默认 / --with-k8s / --with-cubestack)时, 全部默认启用的 operator 照常部署。
# (--enable 只写 cluster.conf, 不经过本处; 见 deploy-cluster.sh)
# 新增 operator 模块时把其 key 加入本列表(基座 metallb/local_path/k8s_registry 与 k8s_deploy/k8s_scale/verify_* 不属于 operator)。
OPERATOR_MODULES=(
    gpu_operator gpu_lws prometheus ceph ceph_csi envoy_gateway keycloak kueue kubevirt lustre_csi
    cubestack_apps harbor lb_haproxy lb_keepalived
)

# ---------------- 元模块展开(verify → 全部 verify_* 模块) ----------------
# 每次新增一个 verify_<组件>.sh 模块, 这里自动把它纳入 "verify" 集合;
# 帮助(--help / --list-steps)随之自动更新, 无需手工维护列表。
expand_meta() {
    local tok="$1" i out=""
    if [ "${tok}" = "verify" ]; then
        for i in "${!MODULE_KEY[@]}"; do
            [[ "${MODULE_KEY[$i]}" == verify_* ]] && out="${out},${MODULE_KEY[$i]}"
        done
        echo "${out#,}"
    else
        echo "${tok}"
    fi
}

# 展开逗号分隔的模块参数: 每个 token 过 expand_meta; verify 无匹配时报错(防止误入默认模式)
expand_args() {
    local t out="" e
    for t in ${1//,/ }; do
        [ -z "${t}" ] && continue
        e="$(expand_meta "${t}")"
        if [ "${t}" = "verify" ] && [ -z "${e}" ]; then
            err "未发现任何 verify_* 验证模块(modules/03_addon/2[0-9]_verify_*.sh), 无法展开 --steps verify"
            return 1
        fi
        out="${out},${e}"
    done
    echo "${out#,}"
}

# 读取模块头部元数据字段
# 用法: module_meta <file> <FIELD>
module_meta() {
    sed -nE "s/^#[[:space:]]*${2}:[[:space:]]*(.*)$/\1/p" "$1" | head -1
}

# ---------------- 模块自动发现(子目录递归, 按 目录序号+文件序号 排序) ----------------
# 结果写入并行数组: MODULE_KEY / MODULE_DESC / MODULE_SCRIPT(相对 modules/ 的路径) /
#   MODULE_DEFAULT / MODULE_REPEAT / MODULE_PHASE / MODULE_TOGGLE
discover_modules() {
    MODULE_KEY=(); MODULE_DESC=(); MODULE_SCRIPT=(); MODULE_DEFAULT=(); MODULE_REPEAT=(); MODULE_PHASE=(); MODULE_TOGGLE=()
    local f dir base key rel
    # 遍历 modules/NN_*/NN_*.sh(两级), 按路径字典序 = 目录序号+文件序号 排序
    for f in "${MODULES_DIR}"/[0-9][0-9]_*/[0-9][0-9]_*.sh; do
        [ -f "${f}" ] || continue
        dir="$(basename "$(dirname "${f}")")"
        base="$(basename "${f}" .sh)"
        rel="${dir}/${base}.sh"
        key="$(module_meta "${f}" MODULE)"
        [ -z "${key}" ] && key="${base#*_}"          # 缺省: 去掉 NN_ 前缀
        MODULE_KEY+=("${key}")
        MODULE_DESC+=("$(module_meta "${f}" DESC)")
        MODULE_SCRIPT+=("${rel}")
        MODULE_DEFAULT+=("$(module_meta "${f}" DEFAULT)")
        MODULE_REPEAT+=("$(module_meta "${f}" REPEAT)")
        MODULE_PHASE+=("$(module_meta "${f}" PHASE)")
        MODULE_TOGGLE+=("$(module_meta "${f}" TOGGLE)")
    done
}

# 模块索引(-1=不存在)
module_index() {
    local key="$1" i
    for i in "${!MODULE_KEY[@]}"; do
        [ "${MODULE_KEY[$i]}" = "${key}" ] && { echo "$i"; return 0; }
    done
    echo -1
    return 1
}

# 模块是否应默认启用: DEFAULT=1 或 TOGGLE 变量为 true/1/yes/on
module_default_on() {
    local i="$1" tgl val
    [ "${MODULE_DEFAULT[$i]:-0}" = "1" ] && return 0
    tgl="${MODULE_TOGGLE[$i]:-}"
    [ -n "${tgl}" ] || return 1
    val="${!tgl:-false}"
    case "${val,,}" in
        true|1|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------- 运行步骤解析 ----------------
# 优先级: --steps(立即部署, 自动带基座) > 默认启用 + --with-xxx - --skip
# 注意: --steps 显式命名 operator 时只部署被指定的 operator(+基座), 见 OPERATOR_MODULES 说明。
#       --steps verify 保持精确: 只跑全部验证模块, 不拉基座。
#       --enable 不在本函数生效(只写 cluster.conf, 见 deploy-cluster.sh)。
# 结果写入全局 RUN_STEPS(按模块文件顺序)
# 用法: resolve_run_steps <steps> <skip> <enable> [phase_filter]
resolve_run_steps() {
    local steps_arg="$1" skip_arg="$2" enable_arg="$3" phase_filter="$4"
    local s k nk i found=0
    RUN_STEPS=()

    # 元模块展开: --steps/--skip/--enable 中的 "verify" → 全部 verify_* 模块
    # (新增 verify_<组件>.sh 自动纳入, 无需指定 operator 名即可验证全部组件)
    steps_arg="$(expand_args "${steps_arg}")" || return 1
    skip_arg="$(expand_args "${skip_arg}")" || return 1
    enable_arg="$(expand_args "${enable_arg}")" || return 1

    # 阶段过滤: 只保留该阶段模块
    _phase_ok() {
        [ -z "${phase_filter}" ] && return 0
        local p
        for p in ${phase_filter//,/ }; do
            [ "${MODULE_PHASE[$1]:-}" = "${p}" ] && return 0
        done
        return 1
    }

    if [ -n "${steps_arg}" ]; then
        # 全部为 verify_* 模块 → 保持"精确模式": 只跑验证模块, 不拉基座(verify 模块 REPEAT:1, 每次执行)。
        local _all_verify=1 _tok
        for _tok in ${steps_arg//,/ }; do
            [[ "$(normalize_key "${_tok}")" == verify_* ]] || { _all_verify=0; break; }
        done
        if [ "${_all_verify}" = "1" ]; then
            for s in ${steps_arg//,/ }; do
                nk="$(normalize_key "${s}")"
                module_index "${nk}" >/dev/null 2>&1 || { err "未知模块: ${s}(可用 --list-steps 查看)"; return 1; }
            done
            for i in "${!MODULE_KEY[@]}"; do
                _phase_ok "$i" || continue
                for s in ${steps_arg//,/ }; do
                    [ "$(normalize_key "${s}")" = "${MODULE_KEY[$i]}" ] && RUN_STEPS+=("${MODULE_KEY[$i]}")
                done
            done
            return 0
        fi
        # 非 verify 模块: --steps 与 --enable 等价 = 自动带基座 + 只部署指定的 operator + 执行部署,
        # 落入默认模式(base + enable - skip + operator 显式调度)。断点续跑感知, 重跑用 --fresh。
        enable_arg="${enable_arg},${steps_arg}"
    fi

    # 默认模式: 默认启用 + 显式启用 - 显式跳过
    for i in "${!MODULE_KEY[@]}"; do
        _phase_ok "$i" || continue
        module_default_on "$i" && RUN_STEPS+=("${MODULE_KEY[$i]}")
    done
    for s in ${enable_arg//,/ }; do
        [ -z "${s}" ] && continue
        nk="$(normalize_key "${s}")"
        module_index "${nk}" >/dev/null 2>&1 || { err "未知模块: ${s}"; return 1; }
        found=0
        for k in "${RUN_STEPS[@]:-}"; do [ "${k}" = "${nk}" ] && found=1; done
        [ "${found}" = "0" ] && RUN_STEPS+=("${nk}")
    done
    for s in ${skip_arg//,/ }; do
        [ -z "${s}" ] && continue
        nk="$(normalize_key "${s}")"
        local comp=() k2
        for k2 in "${RUN_STEPS[@]}"; do [ "${k2}" != "${nk}" ] && comp+=("${k2}"); done
        RUN_STEPS=("${comp[@]}")
    done

    # ★ operator 显式调度: --steps 显式命名了 operator 时, 只保留被指定的 operator(+基座),
    #   剔除"默认启用但未显式指定"的 operator(如 GPU_OPERATOR_ENABLED=true 但 --steps lws 时不部署 gpu_operator)。
    #   未命名任何 operator(纯默认 / --with-k8s / --with-cubestack)时保持原行为: 全部默认启用的 operator 照常部署。
    declare -A _op_keep=()
    for s in ${enable_arg//,/ }; do
        [ -z "${s}" ] && continue
        nk="$(normalize_key "${s}")"
        for _op in "${OPERATOR_MODULES[@]}"; do [ "${nk}" = "${_op}" ] && _op_keep["${_op}"]=1; done
    done
    if [ "${#_op_keep[@]}" -gt 0 ]; then
        local _kept=() _k2 _is_op=0
        for _k2 in "${RUN_STEPS[@]}"; do
            _is_op=0
            for _op in "${OPERATOR_MODULES[@]}"; do [ "${_k2}" = "${_op}" ] && _is_op=1; done
            if [ "${_is_op}" = "1" ] && [ -z "${_op_keep[${_k2}]:-}" ]; then
                :   # operator 且未显式指定 → 剔除
            else
                _kept+=("${_k2}")
            fi
        done
        RUN_STEPS=("${_kept[@]}")
        unset _kept _k2 _is_op
    fi
    unset _op_keep

    # ★ 关键: 最终按"模块文件顺序(阶段目录 + NN 序号)"重排 RUN_STEPS。
    # 否则 --enable/--with-xxx 加入的模块(如 k8s_deploy)会被 append 到末尾,
    # 排到 addon 阶段模块之后 → addon(k8s_registry 等)会在 k8s_deploy 前执行 → 集群未部署就配置 addon → 失败。
    local _ordered=() _k2
    for _i in "${!MODULE_KEY[@]}"; do
        for _k2 in "${RUN_STEPS[@]}"; do
            [ "${_k2}" = "${MODULE_KEY[$_i]}" ] && _ordered+=("${_k2}")
        done
    done
    RUN_STEPS=("${_ordered[@]}")
}

# ---------------- 调度: 执行单个模块(断点续跑感知) ----------------
# run_module <key>  成功/跳过返回 0; 失败返回 1
run_module() {
    local key="$1" idx script repeat
    idx="$(module_index "${key}")"
    [ "${idx}" -ge 0 ] || { err "未知模块: ${key}"; return 1; }
    repeat="${MODULE_REPEAT[$idx]:-0}"

    # 断点续跑: 已完成则跳过(可重复执行模块除外)
    if [ "${repeat}" != "1" ] && [ "$(get_state "${key}")" = "done" ]; then
        say "[${key}] 已完成,跳过(--fresh 清状态可重跑)"
        return 0
    fi

    script="${MODULES_DIR}/${MODULE_SCRIPT[$idx]}"
    [ -f "${script}" ] || { err "模块脚本缺失: ${script}"; return 1; }
    say "[${key}] ${MODULE_DESC[$idx]:-${MODULE_SCRIPT[$idx]}} ..."
    say "  执行: ${script}"
    if bash "${script}"; then
        [ "${repeat}" = "1" ] || save_state "${key}" "done"
        ok "模块 [${key}] 完成"
        return 0
    else
        err "模块 [${key}] 执行失败(${script}),退出码 $?"
        return 1
    fi
}

# ---------------- 打印 ----------------
print_steps() {
    say "==== 部署模块列表(modules/, 自动发现) ===="
    for i in "${!MODULE_KEY[@]}"; do
        local flag="[${MODULE_DEFAULT[$i]:-0}]"
        local desc="${MODULE_DESC[$i]:-}"
        local phase="${MODULE_PHASE[$i]:-?}"
        local tgl="${MODULE_TOGGLE[$i]:-}"
        [ "${MODULE_REPEAT[$i]:-0}" = "1" ] && desc="${desc} [可重复执行]"
        [ -n "${tgl}" ] && flag="[${tgl}]"
        printf "  %-18s %-6s 启用:%-8s %s\n" "${MODULE_KEY[$i]}" "(${MODULE_SCRIPT[$i]})" "${phase}/${flag}" "${desc}"
    done
    echo "---------------------------------------------"
    echo "  --steps k1,k2  只运行指定模块    --skip k1,k2  跳过模块"
    echo "  --phase env|k8s|addon  仅运行指定阶段"
    echo "  --enable k     启用默认关闭模块(如 gpu_operator/lws)   --with-k8s = --enable k8s"
    echo "  --steps verify 默认执行全部 verify_* 验证模块(新增 verify step 后自动纳入):"
    echo "                 $(_verify_meta_list)"
    echo "  --list-steps   查看本列表"
}

# 输出全部 verify_* 模块名(逗号分隔; 供 help/list 动态展示)
_verify_meta_list() {
    local out="" i
    for i in "${!MODULE_KEY[@]}"; do
        [[ "${MODULE_KEY[$i]}" == verify_* ]] && out="${out} ${MODULE_KEY[$i]}"
    done
    echo "${out# }"
}

print_plan() {
    say "==== 集群规划(配置: ${CLUSTER_CONF}) ===="
    echo "  网络模式: ${NET_MODE:-bridge}   虚拟机网段: ${VM_SUBNET:-10.244.0.0/16}   物理Worker: ${PHYS_WORKER_NET:-10.66.1.0/24}"
    echo "  SSH密钥: ${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}   默认密码: ${SSH_DEFAULT_PASSWORD:-<未配置>}"
    echo "  本次执行模块: ${RUN_STEPS[*]:-<空>}"
    echo "  节点规划(类型由 NODES 第10字段 node_type 决定: vm=虚拟机 / bm=裸金属):"
    local line
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        IFS=, read -r role hostname ip mac mem cpu disk user pw node_type <<<"${line}"
        if node_is_vm "${role}" "${mac}" "${mem}" "${node_type:-}"; then
            echo "    [${role}] ${hostname}  ${ip}  (vm, ${mem}G/${cpu}C/${disk}G, user=${user})"
        else
            echo "    [${role}] ${hostname}  ${ip}  (bm 裸金属, user=${user})"
        fi
    done
    echo "---------------------------------------------"
}
