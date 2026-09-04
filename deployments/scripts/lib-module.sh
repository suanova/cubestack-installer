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
#   # REQUIRES: <k1> [k2...]   (可选) 依赖模块: 执行前须已完成的模块 key 列表。
#                              框架在 resolve_run_steps 后做稳定拓扑排序(无依赖模块保持
#                              文件顺序), 保证新模块声明依赖即自动排对顺序, 无需改序号;
#                              循环依赖/引用未知模块会报错。--steps 精确模式还会自动
#                              把 REQUIRES 依赖加入执行列表(闭包)。
# 示例:
#   # MODULE: k8s_deploy
#   # DESC: 部署 kubespray 集群(离线)
#   # PHASE: k8s
#   # DEFAULT: 0
#   # REPEAT: 0
#   # TOGGLE: K8S_ENABLED
#   # REQUIRES: k8s_passwordless k8s_hosts k8s_inventory
#
# 模块内访问远端 kubectl 的统一入口(★ 必读):
#   · 需要 SSH 到 master 执行 kubectl 的模块, 在 load_config 之后调用
#     `init_remote_kubectl || exit 1`, 由 lib-common.sh 幂等定义
#     FIRST_MASTER / SSH_KEY / SSH() 函数 / K(远端 kubectl 简写)。
#   · **禁止**在模块内自行复制这段定义 —— 历史事故: 新模块少复制一行
#     `${K}` 就在 set -u 下 unbound(05_k8s_registry 部署成功后崩溃)。
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

# ---------------- operator 模块(显式调度用, 自动派生) ----------------
# --steps 显式命名了任一 operator 时, 只部署被指定的 operator(+基座 env/k8s/metallb/local_path/k8s_registry),
# 剔除"默认启用但未显式指定"的 operator(如 GPU_OPERATOR_ENABLED=true 但 --steps lws 时不部署 gpu_operator);
# 未命名任何 operator(纯默认 / --with-k8s / --with-cubestack)时, 全部默认启用的 operator 照常部署。
# (--enable 只写 cluster.conf, 不经过本处; 见 deploy-cluster.sh)
#
# ★ 自动派生规则(无需手工维护列表): operator = 有 TOGGLE 的模块 - 基座模块。
#   新增 operator 模块只需在头部写 # TOGGLE: XXX_ENABLED, 自动进入精确调度;
#   新增基座模块(集群底座, 如新的 kubespray addon)把 key 加进 BASE_MODULES 即可。
#   基座模块: k8s_deploy/k8s_scale(集群本体) + metallb/local_path/k8s_registry(kubespray 内置 addon,
#   由 k8s 阶段统一安装, 不属于可单独调度的 operator)。
BASE_MODULES=(k8s_deploy k8s_scale metallb local_path k8s_registry)
OPERATOR_MODULES=()   # discover_modules 时按规则派生

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
#   MODULE_DEFAULT / MODULE_REPEAT / MODULE_PHASE / MODULE_TOGGLE / MODULE_REQUIRES
discover_modules() {
    MODULE_KEY=(); MODULE_DESC=(); MODULE_SCRIPT=(); MODULE_DEFAULT=(); MODULE_REPEAT=(); MODULE_PHASE=(); MODULE_TOGGLE=(); MODULE_REQUIRES=()
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
        MODULE_REQUIRES+=("$(module_meta "${f}" REQUIRES)")
    done
    # ★ operator 自动派生: 有 TOGGLE 且不在基座集合(BASE_MODULES)即 operator。
    #   新增 operator 模块写 TOGGLE 即自动纳入 --steps 精确调度, 无需改本文件。
    OPERATOR_MODULES=()
    local _i _tgl _b _is_base
    for _i in "${!MODULE_KEY[@]}"; do
        _tgl="${MODULE_TOGGLE[$_i]:-}"
        [ -n "${_tgl}" ] || continue
        _is_base=0
        for _b in "${BASE_MODULES[@]}"; do
            [ "${MODULE_KEY[$_i]}" = "${_b}" ] && { _is_base=1; break; }
        done
        [ "${_is_base}" = "1" ] && continue
        OPERATOR_MODULES+=("${MODULE_KEY[$_i]}")
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
# 注意:
#   · --steps 精确模式: 只跑指定的模块 + 其 REQUIRES 闭包依赖, **不再带出默认启用的 operator**
#     (曾因 --steps local_path,k8s_registry 意外带出 gpu_operator 而误部署); 基座模块
#     (env/k8s 阶段 + metallb/local_path/k8s_registry)不受影响, 仍按默认启用参与。
#   · --steps 显式命名 operator 时, 同样只部署被指定的 operator(+基座), 见 OPERATOR_MODULES 说明。
#   · --steps verify 保持精确: 只跑全部验证模块, 不拉基座。
#   · --enable 不在本函数生效(只写 cluster.conf, 见 deploy-cluster.sh)。
# 结果写入全局 RUN_STEPS(先按模块文件顺序 + REQUIRES 闭包, 再做稳定拓扑排序)
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

    # --steps 精确模式标记: 显式指定了模块(非 verify)时, 只保留指定 operator, 不带默认 operator
    local _steps_precise=0
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
        # 非 verify 模块: --steps 精确模式, 只跑指定模块 + REQUIRES 闭包; 基座默认启用模块仍参与。
        # 断点续跑感知, 重跑用 --fresh。
        _steps_precise=1
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
    if [ "${#_op_keep[@]}" -gt 0 ] || [ "${_steps_precise}" = "1" ]; then
        # ★ --steps 精确模式且未命名任何 operator → 剔除全部默认启用的 operator(本次只跑指定的 + 基座)
        local _kept=() _k2 _is_op=0
        for _k2 in "${RUN_STEPS[@]}"; do
            _is_op=0
            for _op in "${OPERATOR_MODULES[@]}"; do [ "${_k2}" = "${_op}" ] && _is_op=1; done
            if [ "${_is_op}" = "1" ] && [ -z "${_op_keep[${_k2}]:-}" ]; then
                :   # operator 且未显式指定(或精确模式未指定) → 剔除
            else
                _kept+=("${_k2}")
            fi
        done
        RUN_STEPS=("${_kept[@]}")
        unset _kept _k2 _is_op
    fi
    unset _op_keep

    # ★ REQUIRES 闭包(--steps 精确模式): 在 operator 过滤**之后**执行 —— 闭包拉入的依赖
    #   (如 --steps ceph_csi → ceph)是本模块需要的组件, 不能再被"未显式指定 operator"剔除。
    #   递归加入显式指定模块的依赖链, 保证 --steps envoy_ai_gateway 自动带上 envoy_gateway。
    if [ "${_steps_precise}" = "1" ]; then
        local _added=1 _k3 _i3 _d3 _f3 _k4
        while [ "${_added}" = "1" ]; do
            _added=0
            for _k3 in "${RUN_STEPS[@]}"; do
                _i3="$(module_index "${_k3}")"
                [ "${_i3}" -ge 0 ] || continue
                for _d3 in ${MODULE_REQUIRES[$_i3]:-}; do
                    module_index "${_d3}" >/dev/null 2>&1 || { err "模块 ${_k3} 的 REQUIRES 引用了未知模块: ${_d3}"; return 1; }
                    _f3=0
                    for _k4 in "${RUN_STEPS[@]}"; do [ "${_k4}" = "${_d3}" ] && _f3=1; done
                    if [ "${_f3}" = "0" ]; then RUN_STEPS+=("${_d3}"); _added=1; fi
                done
            done
        done
    fi

    # ★ 稳定拓扑排序(REQUIRES): 依赖者排在被依赖者之后; 无依赖约束的模块保持原(文件)顺序。
    #   循环依赖 / 未知引用在此报错, 新模块声明 REQUIRES 后自动保证顺序, 无需改文件序号。
    if ! _topo_sort_requires; then
        return 1
    fi
}

# 按 REQUIRES 对 RUN_STEPS 做稳定拓扑排序(Kahn 式多轮扫描, 无约束模块保持原顺序)
# 成功返回 0; 循环依赖或引用未知模块返回 1(已 err 说明)
_topo_sort_requires() {
    local -A _remaining=() _done=()
    local _k _i _d _progress _out=() _cycle
    for _k in "${RUN_STEPS[@]:-}"; do _remaining["${_k}"]=1; done
    # 先校验全部 REQUIRES 引用存在(任何模块的 REQUIRES 都必须命中已知模块)
    for _i in "${!MODULE_KEY[@]}"; do
        for _d in ${MODULE_REQUIRES[$_i]:-}; do
            module_index "${_d}" >/dev/null 2>&1 || { err "模块 ${MODULE_KEY[$_i]} 的 REQUIRES 引用了未知模块: ${_d}(--list-steps 查看有效 key)"; return 1; }
        done
    done
    # 多轮扫描: 每轮把"依赖全部已输出"的模块按原 RUN_STEPS 顺序加入输出
    while [ "${#_remaining[@]}" -gt 0 ]; do
        _progress=0
        for _k in "${RUN_STEPS[@]}"; do
            [ -n "${_remaining[${_k}]:-}" ] || continue
            _i="$(module_index "${_k}")"
            local _ok=1 _d2
            for _d2 in ${MODULE_REQUIRES[$_i]:-}; do
                # 依赖不在本次 RUN_STEPS(如 verify 模块要求已部署的组件)或已输出 → 视为满足
                if [ -n "${_remaining[${_d2}]:-}" ] && [ -z "${_done[${_d2}]:-}" ]; then _ok=0; break; fi
            done
            if [ "${_ok}" = "1" ]; then
                _out+=("${_k}")
                unset _remaining["${_k}"]
                _done["${_k}"]=1
                _progress=1
            fi
        done
        if [ "${_progress}" = "0" ]; then
            _cycle="${!_remaining[*]}"
            err "模块依赖循环(REQUIRES 成环): ${_cycle}"
            err "  检查这些模块头部的 # REQUIRES: 声明, 删除/修正循环引用"
            return 1
        fi
    done
    RUN_STEPS=("${_out[@]}")
    return 0
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
        local reqs="${MODULE_REQUIRES[$i]:-}"
        [ "${MODULE_REPEAT[$i]:-0}" = "1" ] && desc="${desc} [可重复执行]"
        [ -n "${tgl}" ] && flag="[${tgl}]"
        [ -n "${reqs}" ] && desc="${desc} 依赖:${reqs}"
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
    echo "  节点规划(5字段: role,hostname,ip,ssh_user,ssh_password; 虚拟机创建由 tools/vm/create-vms.sh 独立执行):"
    local line
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        echo "    [${NODE_ROLE}] ${NODE_HOSTNAME}  ${NODE_IP}  (user=${NODE_USER})"
    done
    # Ceph 启用提示(精简一行; 部署开始前由 deploy-cluster.sh 红底列出 节点+裸盘 并倒计时确认,
    # 避免两处重复 —— 此处仅供 --list 只读场景知悉 ceph 将启用, 不执行检测/倒计时)
    if [ "${CEPH_ENABLED:-false}" = "true" ]; then
        echo "  ⚠ CEPH_ENABLED=true → Ceph(ceph/ceph_csi)将启用; 部署开始前会红底列出存储节点+裸盘并倒计时"
        echo "    ${CEPH_CONFIRM_SLEEP:-60}s 确认(防覆盖系统盘/在用盘; --list 仅提示, 部署时才有倒计时确认)"
    fi
    echo "---------------------------------------------"
}
