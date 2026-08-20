#!/bin/bash
# ============================================================
# lib-deploy.sh — 部署模块注册表 + 调度(供 deploy-cluster.sh 统一入口使用)
# 设计目标: deploy-cluster.sh 只做参数解析 + 按注册表调度, 不内联任何业务逻辑
# 每个部署模块 = steps/ 目录下一个独立脚本, 在 DEPLOY_STEPS 注册一行即可被调度
#
# 注册表格式(每行): "key|描述|脚本文件名|默认启用(1/0)|可重复执行(1/0)"
#   key        状态文件/steps 参数中使用的模块标识
#   脚本文件名 相对 STEPS_DIR 的脚本(独立可执行, source lib-common.sh)
#   默认启用   1=默认执行; 0=需 --with-xxx / --enable / --steps 显式启用
#   可重复执行 1=每次执行且不写状态(如 scale 扩容, 可反复加节点); 0=断点续跑
#
# 新增模块步骤(未来如 gpu-operator / lws 等):
#   1. 在 steps/ 新建 <NN>-<name>.sh(实现具体逻辑)
#   2. 在 DEPLOY_STEPS 追加一行(默认 0 表示按需启用)
#   无需修改 deploy-cluster.sh
# ============================================================

# steps/ 目录: lib-deploy.sh 同目录下
STEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/steps"

# ---------------- 模块注册表(按执行顺序排列) ----------------
DEPLOY_STEPS=(
  "net|初始化宿主网络(bridge/nat)|01-network.sh|1|0"
  "ssh_key|生成 SSH 密钥对|02-ssh-key.sh|1|0"
  "vm|创建虚拟机并确保 running|03-vm.sh|1|0"
  "ssh_passwordless|配置 SSH 免密登录|04-ssh-passwordless.sh|1|0"
  "worker_bm|裸金属 worker 连通性+离线装包|05-worker-bm.sh|1|0"
  "hosts|更新 /etc/hosts 节点解析|06-hosts.sh|1|0"
  "inventory|生成 inventory + 同步 kubespray 配置|07-inventory.sh|1|0"
  "k8s|部署 kubespray 集群(离线)|08-k8s.sh|0|0"
  "gpu_operator|安装沐曦 Muxi GPU Operator|09-gpu-operator.sh|0|0"
  "lws|安装 LeaderWorkerSet(LWS)|10-lws.sh|0|0"
  "scale|扩容集群(缺 VM 自动创建, 可重复)|11-scale.sh|0|1"
)

# ---------------- 注册表解析为并行数组 ----------------
DEPLOY_KEY=() DEPLOY_DESC=() DEPLOY_SCRIPT=() DEPLOY_DEFAULT=() DEPLOY_REPEAT=()
init_deploy_steps() {
    local line
    DEPLOY_KEY=(); DEPLOY_DESC=(); DEPLOY_SCRIPT=(); DEPLOY_DEFAULT=(); DEPLOY_REPEAT=()
    for line in "${DEPLOY_STEPS[@]}"; do
        IFS='|' read -r k d s e r <<<"${line}"
        DEPLOY_KEY+=("${k}"); DEPLOY_DESC+=("${d}"); DEPLOY_SCRIPT+=("${s}"); DEPLOY_DEFAULT+=("${e}"); DEPLOY_REPEAT+=("${r:-0}")
    done
}

# 返回步骤在注册表中的索引(-1=不存在)
deploy_step_index() {
    local key="$1" i
    for i in "${!DEPLOY_KEY[@]}"; do
        [ "${DEPLOY_KEY[$i]}" = "${key}" ] && { echo "$i"; return 0; }
    done
    echo -1
    return 1
}

# 返回步骤脚本绝对路径
deploy_step_script() {
    local idx
    idx="$(deploy_step_index "$1")"
    [ "${idx}" -ge 0 ] || return 1
    echo "${STEPS_DIR}/${DEPLOY_SCRIPT[$idx]}"
}

# ---------------- 步骤解析: 决定本次要执行哪些模块 ----------------
# 优先级: --steps(精确指定) > 默认启用集合 + --enable/--with-xxx - --skip
# 结果写入全局 RUN_STEPS(按注册表顺序的 key 列表)
# 传入参数: 依次是 --steps 值, --skip 值, --enable 值(逗号分隔, 可为空)
resolve_run_steps() {
    local steps_arg="$1" skip_arg="$2" enable_arg="$3"
    local s k
    RUN_STEPS=()
    if [ -n "${steps_arg}" ]; then
        # 精确模式: 只运行指定的(按注册表顺序)
        for s in ${steps_arg//,/ }; do
            deploy_step_index "${s}" >/dev/null 2>&1 || err "未知步骤: ${s}(可用 --list-steps 查看)"
        done
        for k in "${DEPLOY_KEY[@]}"; do
            for s in ${steps_arg//,/ }; do
                [ "${s}" = "${k}" ] && RUN_STEPS+=("${k}")
            done
        done
        return 0
    fi
    # 默认模式: 默认启用 + 显式启用 - 显式跳过
    for i in "${!DEPLOY_KEY[@]}"; do
        [ "${DEPLOY_DEFAULT[$i]}" = "1" ] && RUN_STEPS+=("${DEPLOY_KEY[$i]}")
    done
    for s in ${enable_arg//,/ }; do
        [ -z "${s}" ] && continue
        deploy_step_index "${s}" >/dev/null 2>&1 || err "未知步骤: ${s}"
        # 去重添加
        local found=0 k2
        for k2 in "${RUN_STEPS[@]:-}"; do [ "${k2}" = "${s}" ] && found=1; done
        [ "${found}" = "0" ] && RUN_STEPS+=("${s}")
    done
    for s in ${skip_arg//,/ }; do
        [ -z "${s}" ] && continue
        local comp=() k3
        for k3 in "${RUN_STEPS[@]}"; do
            [ "${k3}" != "${s}" ] && comp+=("${k3}")
        done
        RUN_STEPS=("${comp[@]}")
    done
}

# ---------------- 调度: 执行单个步骤(断点续跑感知) ----------------
# run_deploy_step <key>  成功/跳过返回 0; 失败返回 1(调用方决定是否中断)
run_deploy_step() {
    local key="$1" script idx repeat
    idx="$(deploy_step_index "${key}")"
    [ "${idx}" -ge 0 ] || { err "未知步骤: ${key}"; return 1; }
    repeat="${DEPLOY_REPEAT[$idx]:-0}"

    # 断点续跑: 已完成则跳过(可重复执行的模块除外, 如 scale)
    if [ "${repeat}" != "1" ] && [ "$(get_state "${key}")" = "done" ]; then
        say "[${key}] 已完成,跳过(--fresh 清状态可重跑)"
        return 0
    fi

    script="${STEPS_DIR}/${DEPLOY_SCRIPT[$idx]}"
    [ -f "${script}" ] || { err "步骤脚本缺失: ${script}"; return 1; }
    say "[${key}] ${DEPLOY_DESC[$idx]} ..."
    say "  执行: ${script}"
    if bash "${script}"; then
        [ "${repeat}" = "1" ] || save_state "${key}" "done"
        ok "模块 [${key}] 完成"
    else
        err "模块 [${key}] 执行失败(${script}),退出码 $?"
        return 1
    fi
}

# ---------------- 打印 ----------------
print_steps() {
    say "==== 部署模块列表(steps/) ===="
    for i in "${!DEPLOY_KEY[@]}"; do
        local flag="[${DEPLOY_DEFAULT[$i]}]"
        local desc="${DEPLOY_DESC[$i]}"
        [ "${DEPLOY_REPEAT[$i]}" = "1" ] && desc="${desc} [可重复执行]"
        printf "  %-4s %-18s 默认启用:%-3s  %s\n" "${DEPLOY_KEY[$i]}" "(${DEPLOY_SCRIPT[$i]})" "${flag}" "${desc}"
    done
    echo "---------------------------------------------"
    echo "  --steps k1,k2  只运行指定模块    --skip k1,k2  跳过模块"
    echo "  --enable k     启用默认关闭模块(gpu_operator/lws 等)   --with-k8s = --enable k8s"
    echo "  --list-steps   查看本列表"
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
