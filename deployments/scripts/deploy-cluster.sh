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
#   03_addon/  阶段三: 附加组件(集群部署后: GPU/Harbor/Ceph/P2/P3)
#
# 模块(stages):
#   env 阶段:  vm_network vm_sshkey vm_create harbor
#   k8s 阶段:  k8s_passwordless k8s_workerbm k8s_hosts k8s_inventory k8s_ntp
#              k8s_deploy(默认关) k8s_scale(默认关)
#   addon 阶段: gpu_operator k8s_registry ceph ceph_csi ceph_backup
#              keycloak kueue kubevirt lustre_csi   (01~19 中间件, 默认关)
#              20 起为自研模块(cubestack_operator 25_…, 见 4.6b)
#   验证:      verify_<组件>(自动发现; --steps verify 不指定 operator 默认执行全部 verify_*)
#   运维:      ceph_backup(Ceph 备份/恢复, 默认关, --steps ceph_backup 单独执行)
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
#   sudo ./deploy-cluster.sh --enable gpu_operator,ceph     # 只把开关写入 cluster.conf 预启用(不部署)
# #   sudo ./deploy-cluster.sh --phase k8s                    # 仅运行 k8s 阶段
#   sudo ./deploy-cluster.sh --only <host> --with-k8s       # 仅处理指定节点
#   sudo ./deploy-cluster.sh --with-scale                   # 扩容(仅 k8s_scale; 先登录 master 核对后 diff 新节点, 填入 cluster.conf)
#   sudo ./deploy-cluster.sh --list / --list-steps / --fresh
# 数据源: config/cluster.conf(必改项+开关+高频) + config/cluster.defaults.conf(高级/默认值层, 自动加载)
#
# 兼容: 旧模块名(net/ssh_key/vm/ssh_passwordless/worker_bm/hosts/inventory/ntp/k8s/scale)自动映射到新名
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
  01_env  vm_network vm_sshkey vm_create harbor
          (默认执行 vm_sshkey; vm_network 默认关 — 宿主网络初始化改由 tools/vm/create-vms.sh 创建 VM 时自动执行; vm_create 默认关 — 虚拟机创建由 tools/vm/create-vms.sh 独立执行)
  02_k8s  k8s_passwordless k8s_workerbm k8s_hosts k8s_inventory k8s_ntp node_pkgs node_net_guard  (默认执行)
          k8s_deploy(基座, 恒随全量部署)  k8s_scale(默认关, --with-scale)
  03_addon 依赖顺序: metallb ceph ceph_csi(存储底座, 供 registry 等用 ceph 后端)
          cephfs_mount(CephFS → 每台节点 /mnt/cephfs/models, 默认随 CEPHFS_ENABLED)
          local_path(可选) k8s_registry 组件(全部可单独部署的组件见下方"组件单独部署"清单)
          自研: cubestack_operator(平台 Operator, 见 4.6b); model_images(模型推理镜像 sglang/vllm-metax, 排最后; 见 offline-files/model-collection/README.md)
          组件级更新(operator 已就绪后单独更新某个平台组件, 不重跑 cubestack_operator):
            lws / envoy_gateway / ai_gateway / cubestack_controller_manager / model_bundles /
            prometheus / perses / bmc / metax / cuberouter / cubepilot / cubestack_portal / observability
  验证(自动发现, 新增 verify step 后本段自动更新):
          --steps verify = 执行全部验证模块: $(_verify_meta_list)
          --steps verify_<组件> = 只验证指定组件(如 verify_metallb / verify_registry_storage)

单独安装某个组件(本段自动生成, 新增组件模块自动出现):
  · 命令: sudo ./deploy-cluster.sh --steps <组件>          # 例: --steps ceph
  · 只装该组件: 不跑基座(k8s_deploy/metallb/local_path/k8s_registry)与环境准备模块;
    组件自身依赖仍会带上(如 ceph_csi → ceph)。
  · 集群接入自动处理: 本地 kubeconfig 能用(kubectl get nodes 通)→ 直接用, 不动集群;
    否则用 cluster.conf NODES 的 IP/用户名/密码引导: 生成密钥对 → 注入公钥 →
    从首个 master 取 admin.conf 到本地 ~/.kube/config。之后组件模块自己完成
    推送离线镜像进内置 registry(skopeo) → helm 部署。
  · 组件 → cluster.conf 开关(已实现, 可直接部署):
$(_component_meta_list)
  · 规划中未实现(伪代码占位, 打开开关也只有伪代码流程):
$(_component_meta_list stub)
  · 重跑已装过的组件(REPEAT:0 会被断点续跑跳过): --steps <组件> --fresh
  · 部署后验证: sudo ./deploy-cluster.sh --steps verify_<组件>

三种使用方式(按场景选):
  ① 全新集群/覆盖重装: sudo ./deploy-cluster.sh               # 默认 = 覆盖安装: k8s + cluster.conf 中启用的全部组件
                                                            # (目标集群**已存在**时同样是覆盖重装; 支持断点续跑)
  ② 清状态重来:        sudo ./deploy-cluster.sh --fresh        # = ① 且**先清断点状态**(REPEAT:0 的模块强制重跑)
     · 覆盖安装遇到节点上的**旧集群残留**(跨小版本 / 旧 etcd 二进制)时, k8s_deploy 前置会自动清除它
       (交互 15s 倒计时可中止; 加 --yes 免交互 —— 无人值守务必显式给)。原地升级未实现, 见 docs/cluster-upgrade-path.md
     · **优雅覆盖**(2026-10-11): K8s 覆盖实际将执行且集群可达时, 会先读集群内安装登记
       (ConfigMap cubestack-install-record)按首装序**反序优雅卸载**已装组件(先停消费者/CR 级联/
       helm uninstall, 再动 Ceph, 最后 K8s 覆盖) —— 非暴力重置。倒计时 TEARDOWN_CONFIRM_SLEEP
       (默认 30s)可 Ctrl-C; --yes 免交互。手动查看: tools/k8s/cluster-teardown.sh --list
       设计: docs/graceful-overwrite/design.md
  ③ 单独装组件:        sudo ./deploy-cluster.sh --steps ceph         # 只装该组件(不动基座; 集群接入自动处理)
  · state 文件 deployments/config/.deploy.state 只记录"本机装到哪一步": 全新容器没有它是正常的(等价①)。
  · ⚠ ①/② 是**重装集群**的路: 节点上已有的旧 K8s 会被 kubeadm reset(既有防线: kubespray 侧检测到残留时
    醒目警告 + 60s 倒计时, 期间 Ctrl-C 可中止; 集群已存在时部署也会打印醒目提示)。
    只想装组件、**不动集群** → 用 ③(--steps <组件> 的计划里不含 k8s_deploy/metallb/registry 等基座)。
  · 前提: 容器里挂载 cluster.conf(含 NODES 的 IP/用户/密码)与 deployments/offline-files
    (镜像 tar 不入镜像; 见 README §容器化 CLI 的 docker run 挂载示例)。

注:
  · 镜像统一镜像源(Harbor): 全部上游镜像声明在 deployments/config/images.manifest,
    先经 CI 同步到 harbor.isuanova.com/mirrors/**, 再由工具拉成离线 tar 供各模块推入内置
    registry(集群无需访问公网)。三个工具(tools/images/):
      harbor-sync-images.sh      上游 → Harbor(CI/联网机; 项目不存在自动创建)
      harbor-save-images.sh      Harbor → offline-files/<group>/*.tar(联网机)
      check-image-manifest.sh    清单静态校验(+ --kubespray 交叉核对 / --harbor 漂移报告)
    升级组件版本只改 cluster.defaults.conf 的「镜像版本」节一处, 全链自动跟随。详见 docs/harbor-mirror.md。
  · cluster.conf 的 NODES(5字段: role,hostname,ip,ssh_user,ssh_password)不区分虚拟机/裸金属;
    ssh_user 写 "-" = 跟随全局 SSH_USER(cluster.conf, root|ubuntu, 默认 ubuntu —— 切换安装用户
    只改 SSH_USER 一处); 显式写用户名 = 该节点覆盖(与全局不一致时部署启动会点名告警)。
    主程序不判断节点类型 — 需要创建虚拟机的节点在 tools/vm/vm-nodes.conf(10字段)定义,
    由 sudo ./deployments/scripts/tools/vm/create-vms.sh 独立执行(创建后自动注入 NODES)。
  · --only/--skip 均支持; 宿主网络初始化(vm_network)默认不再执行, 改由创建虚拟机时
    (tools/vm/create-vms.sh)自动初始化; 需要手动单独跑用 --steps vm_network。

选项:
  --with-k8s            仅部署 kubespray 基座: k8s_deploy + kubespray 内置 addon(metallb/local-path/registry)
                        不含任何 operator(跳过全部 operator)
  --with-cubestack      全量部署: = 基座 + cluster.conf 中 XXX_ENABLED=true 的 operator(以 cluster.conf 为主)
                        (如设 GPU_OPERATOR_ENABLED=true 即部署 gpu_operator)
  --with-scale          仅执行 k8s_scale 扩容模块(不连带 operator/已部署组件): 登录首个 master 核对
                        实际集群节点 → 自动 diff 新节点(新节点先写入 cluster.conf)→ 仅对新节点
                        环境准备/装包/NTP/registry → 更新 inventory(new_node 组)→ cubestack-offline scale
  --steps k1,k2         单独安装指定组件(只跑该组件 + 其非基座依赖; 集群接入自动处理)
                        verify=只跑验证模块; verify_<组件>=只验证该组件
  --skip k1,k2          跳过模块(verify=跳过全部验证模块)
  --enable k1,k2        只把模块开关写入 cluster.conf(持久化, 不部署); 下次 --with-cubestack / 默认部署生效
  --phase env|k8s|addon 仅运行指定阶段(可逗号分隔)
  --only HOST           仅处理指定节点(可多次; 支持 hostname 或 group 名)
  --profile <版本>      指定要部署的 kubespray 版本(版本面变量以该版本档案为准, 不写回 cluster.conf)
                        例: --profile v2.32.0; none = 不用档案(全部按 cluster.conf)
                        **不指定 = 部署最新版本**(max(仓库树, 有档案的版本目录); 本地临时版本须显式选)
                        见 docs/kubespray-versioning/
  --release <版本>      使用离线发布版本目录(<CUBESTACK_RELEASE_ROOT>/<版本>/offline-files);
                        版本变量以目录内 release.env 为准; 取件见 fetch-offline-from-minio.sh --release
                        例: --release 2.0.0; 等价于 cluster.conf 的 CUBESTACK_RELEASE="2.0.0"
  --fresh, --refresh    默认流程 + **先清断点状态**(REPEAT:0 的模块强制重跑; 见"三种使用方式"②)
  --list                仅打印集群规划(只读)
  --list-steps          列出全部模块(分组紧凑展示; 加 --verbose 看完整 DESC/文件/依赖)
  --help, -h            显示本帮助

示例:
  sudo ./deploy-cluster.sh                          # 默认 = --with-cubestack(全量部署)
  sudo ./deploy-cluster.sh --with-k8s              # 仅部署 kubespray 基座(k8s+metallb+local-path+registry)
  sudo ./deploy-cluster.sh --skip gpu_operator --fresh   # 覆盖安装但排除 gpu_operator(--fresh 清状态)
  sudo ./deploy-cluster.sh --enable ceph            # 只把 CEPH_ENABLED=true 写入 cluster.conf(不部署)
  sudo ./deploy-cluster.sh --steps ceph            # 单独装/重跑 Ceph(不动基座; 接入自动处理)
  sudo ./deploy-cluster.sh --steps cephfs_mount    # 把 CephFS models 挂到每台节点 /mnt/cephfs/models
  sudo ./deploy-cluster.sh --steps lws             # 只更新平台组件 lws(operator 已就绪; 不重跑 cubestack_operator)
  sudo ./deploy-cluster.sh --steps cube-pilot      # 只更新 cubepilot(连字符别名)
  sudo ./deploy-cluster.sh --steps ceph --fresh     # 同上, 且清断点状态(REPEAT:0 模块重跑用)
  sudo ./deploy-cluster.sh --release 2.0.0          # 使用 2.0.0 离线发布版本目录(<root>/2.0.0/offline-files)
  sudo ./deploy-cluster.sh --steps verify_ceph      # 只验证 Ceph(operator/CSI + ceph -s + RBD 块 I/O)
  sudo ./deploy-cluster.sh --with-scale             # 扩容: 仅 k8s_scale(先登录 master 核对集群→diff 新节点→只动新节点)
  sudo ./deploy-cluster.sh --with-scale --only worker02   # 扩容指定节点(--only 也先经集群核对)
  sudo ./deploy-cluster.sh --only worker02 --with-scale
  sudo ./deploy-cluster.sh --steps verify           # 只跑全部验证模块(端到端验证, 不拉基座)
  sudo ./deploy-cluster.sh --steps verify_metallb   # 只验证某个组件(验后自动清理)
  sudo ./deploy-cluster.sh --steps ceph_backup      # Ceph 备份(CR+secret+mon store → master 根盘)
  sudo CEPH_BACKUP_ACTION=restore ./deploy-cluster.sh --steps ceph_backup  # Ceph 恢复(认领旧 OSD 数据)
  sudo ./deploy-cluster.sh --steps multus              # 单个组件(自动带基座; 见上方"单独安装某个组件"清单)
  sudo ./deploy-cluster.sh --list-steps                # 查看全部模块(分组紧凑)
  sudo ./deploy-cluster.sh --list-steps --verbose      # 完整 DESC / 文件 / 依赖

★ 提示: sudo ./deployments/scripts/deploy-cluster.sh --list-steps
        模块全清单(启用状态/依赖/序号/执行阶段) —— 选模块、看开关、排依赖, 都从这条命令开始
EOF
    exit 0
}

# ---------------- 参数解析 ----------------
FRESH=0; LIST=0; LIST_STEPS=0; LIST_VERBOSE=0; ASSUME_YES=0
STEPS_ARG=""; SKIP_ARG=""; ENABLE_ARG=""; PHASE_ARG=""; ENABLE_PERSIST_ARG=""
SCALE_ONLY=0
ONLY_HOSTS=""
RELEASE_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --fresh|--refresh) FRESH=1; shift ;;
        # --yes = 覆盖安装时免交互确认(透传给"旧集群残留 → 自动 reset"那一步; 见 k8s_deploy 前置)。
        #   不给 --yes 时: 交互终端仍有 15s 倒计时; 非交互环境**拒绝自动 reset**(避免无人值守误清集群)。
        --yes|-y) ASSUME_YES=1; shift ;;
        --list)     LIST=1; shift ;;
        --list-steps) LIST_STEPS=1; shift ;;
        # --verbose 仅配合 --list-steps/--list: 显示完整 DESC/文件/依赖(默认紧凑)
        --verbose|-v) LIST_VERBOSE=1; shift ;;
        # --with-k8s: 仅 kubespray 基座(k8s + metallb/local-path/registry), 不含任何 operator
        --with-k8s) ENABLE_ARG="${ENABLE_ARG},k8s"; SKIP_ARG="${SKIP_ARG},gpu_operator,ceph,ceph_csi,keycloak,kueue,kubevirt,lustre_csi"; shift ;;
        # --with-scale: 仅扩容模块(k8s_scale), 不连带 operator/外层重复模块 —— 见下方 SCALE_ONLY 过滤
        --with-scale) ENABLE_ARG="${ENABLE_ARG},scale"; SCALE_ONLY=1; shift ;;
        # --with-cubestack = 基座 + cluster.conf 中 XXX_ENABLED=true 的 operator(以 cluster.conf 为主, 不强制启用)
        --with-cubestack) ENABLE_ARG="${ENABLE_ARG},k8s"; shift ;;
        --steps)    STEPS_ARG="${2:?--steps 需要模块列表, 逗号分隔}"; shift 2 ;;
        --skip)     SKIP_ARG="${2:?--skip 需要模块列表, 逗号分隔}"; shift 2 ;;
        # --enable = 只把模块开关写入 cluster.conf(持久化), 不立即部署; 立即部署用 --steps
        --enable)   ENABLE_PERSIST_ARG="${ENABLE_PERSIST_ARG},${2:?--enable 需要模块列表, 逗号分隔}"; shift 2 ;;
        --phase)    PHASE_ARG="${2:?--phase 需要阶段名 env|k8s|addon}"; shift 2 ;;
        --only)     ONLY_HOSTS="${ONLY_HOSTS},${2:?--only 需要节点名}"; shift 2 ;;
        # --profile = 本次使用该版本套装档案(版本面变量以档案为准; 不写回 cluster.conf)。
        #   须在 load_config 之前 export —— load_config 读的是环境变量
        #   (none = 禁用档案, 全部按 cluster.conf)
        --profile)  PROFILE_ARG="${2:?--profile 需要版本名(如 v2.32.0; none=禁用档案)}"; shift 2 ;;
        # --release = 本次使用离线发布版本目录(<CUBESTACK_RELEASE_ROOT>/<版本>/offline-files);
        #   须在 load_config 之前 export(load_config 读的是环境变量)
        --release)  RELEASE_ARG="${2:?--release 需要版本号(如 2.0.0)}"; shift 2 ;;
        --help|-h)  usage ;;
        *)          err "未知参数: $1(用 --help 查看)"; exit 1 ;;
    esac
done
ONLY_HOSTS="${ONLY_HOSTS#,}"
# --list/--list-steps 是只读展示: 从这里开始抑制 vlog [DEBUG] 噪音(含 --profile/--only 的调试行)
if [ "${LIST_STEPS}" = "1" ] || [ "${LIST}" = "1" ]; then
    LOG_VERBOSE=0
fi
# --profile: 在 load_config 之前 export(load_config 以环境变量优先读 KUBESPRAY_PROFILE)
if [ -n "${PROFILE_ARG:-}" ]; then
    export KUBESPRAY_PROFILE="${PROFILE_ARG}"
    vlog "  --profile ${PROFILE_ARG} → KUBESPRAY_PROFILE(本机 cluster.conf 不变)"
fi
# --release: 在 load_config 之前 export(load_config 以环境变量优先读 CUBESTACK_RELEASE)
if [ -n "${RELEASE_ARG:-}" ]; then
    export CUBESTACK_RELEASE="${RELEASE_ARG}"
    vlog "  --release ${RELEASE_ARG} → CUBESTACK_RELEASE(本机 cluster.conf 不变)"
fi
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

# 离线文件就绪检查(缺失 → 醒目提示, 不阻断; 部署前请先准备, 见 tools/offline/fetch-offline-from-minio.sh --help 全部子目录)
# 只读列表/计划不检查(否则列表里会混入与展示无关的离线文件告警)
if [ "${LIST_STEPS}" != "1" ] && [ "${LIST}" != "1" ]; then
    check_offline_files
fi

# SSH 用户一致性点名(2026-10-15): NODES 逐行显式 ssh_user 与全局 SSH_USER(root|ubuntu 单一
# 旋钮)不一致时告警 —— 只在本统一入口打一次, 模块进程不再各自刷屏。
if [ "${LIST_STEPS}" != "1" ] && [ "${LIST}" != "1" ]; then
    warn_ssh_user_mismatch
fi

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
        tgl="${tgl%% *}"   # TOGGLE 多变量(空格分隔=OR)时持久化第一个(如 ceph → CEPH_ENABLED)
        if [ -z "${tgl}" ]; then
            # 无 TOGGLE 的模块: DEFAULT:1(如 k8s_deploy 基座)恒随全量部署, 本就没有可写开关;
            #   其余(verify_*/运维模块)只能 --steps 立即执行, 无开关可持久化。
            if [ "${MODULE_DEFAULT[$idx]:-0}" = "1" ]; then
                ok "模块 ${nk} 已是默认启用(DEFAULT:1), 恒随全量部署, 无需写入配置"
            else
                warn "模块 ${nk} 无 cluster.conf 开关(TOGGLE 未定义, 如 verify 模块), 无法持久化; 请用 --steps ${s} 直接执行"
            fi
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
        _ENABLE_PERSIST_WROTE=1
    done
}
if [ -n "${ENABLE_PERSIST_ARG}" ]; then
    _ENABLE_PERSIST_WROTE=0
    _enable_persist "${ENABLE_PERSIST_ARG}"
    # 仅 --enable 且无其它部署触发(--steps/--with-*/--skip/--phase/--only) → 只写配置后退出, 不部署
    if [ -z "${STEPS_ARG}" ] && [ -z "${ENABLE_ARG}" ] && [ -z "${SKIP_ARG}" ] && [ -z "${PHASE_ARG}" ] && [ -z "${ONLY_HOSTS}" ]; then
        if [ "${_ENABLE_PERSIST_WROTE}" = "1" ]; then
            say "已写入 cluster.conf(本次不部署)。下次执行 --with-cubestack / 默认部署即生效; 立即部署用 --steps ${ENABLE_PERSIST_ARG#,}"
        else
            say "无 cluster.conf 变更(见上方说明)。立即部署用 --steps ${ENABLE_PERSIST_ARG#,}"
        fi
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
    # 只读列表/计划不打印默认模式提示(避免混入 --list-steps 输出)
    if [ "${LIST_STEPS}" != "1" ] && [ "${LIST}" != "1" ]; then
        say "默认模式: 等价于 --with-cubestack — 基座 + cluster.conf 中启用的全部 operator"
    fi
fi

if ! resolve_run_steps "${STEPS_ARG}" "${SKIP_ARG}" "${ENABLE_ARG}" "${PHASE_ARG}"; then
    exit 1
fi

# ★ 扩容专用模式(--with-scale): 只执行 k8s_scale 模块(内部自包含: 登录首 master 核对集群 →
#   自动 diff 新节点 → 仅对新节点环境准备/装包/NTP/registry → 重生成 inventory(new_node 组)
#   → cubestack-offline.sh scale)。
#   过滤掉外层默认模块(metallb/local_path/k8s_registry 等)与 operator —— 扩容不重跑已部署组件,
#   更不连带 gpu_operator/ceph 等 operator(历史事故: --with-scale 连带全部 TOGGLE=true 的
#   operator, 扩容变成"全量部署 + 扩容")。--steps 显式指定时以用户为准(不覆盖)。
if [ "${SCALE_ONLY}" = "1" ] && [ -z "${STEPS_ARG}" ]; then
    RUN_STEPS=(k8s_scale)
    say "扩容模式(--with-scale): 仅执行 k8s_scale(不连带 operator/已部署组件)"
fi

# 让显式启用的模块真正生效: 为 RUN_STEPS 中带 TOGGLE 的模块导出 TOGGLE=true。
# 否则 --enable gpu_operator / --with-cubestack 只把模块加入执行列表, 模块内部 `[ "${TOGGLE}" = true ]`
# 自检读的是 cluster.conf 默认 false → 会跳过。导出后子进程模块脚本自检通过。
# ⚠ 只对**非默认启用**的模块导出。默认启用的模块其 TOGGLE 本来就已是 true, 导出是空操作;
#   而 DEFAULT: 1 + TOGGLE 的模块(kube_vip)恰恰**要靠开关为 false 才走清理分支** ——
#   无条件导出会把用户在 cluster.conf 里写的 false 冲成 true, 于是"关掉开关"永远清不掉残留。
#   显式 --enable <模块> 仍然有效: 那条路径会把开关**持久化写回 cluster.conf**(见上文 --enable 处理)。
for i in "${!MODULE_KEY[@]}"; do
    tgl="${MODULE_TOGGLE[$i]:-}"
    [ -n "${tgl}" ] || continue
    module_default_on "${i}" && continue
    tgl="${tgl%% *}"   # TOGGLE 多变量(空格分隔=OR)时取第一个导出(如 ceph → CEPH_ENABLED; external 模式 ceph 的 CEPH_CSI_ENABLED 由 ceph_csi 导出)
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

# ---------------- 输出(只读路径) ----------------
# ⚠ 必须在 --fresh 清状态**之前**: --list/--list-steps 是只读命令, 不能因为顺手带了 --fresh
#   就把断点状态清掉(否则"只看一眼计划"会毁掉断点续跑信息)。
if [ "${LIST_STEPS}" = "1" ]; then print_steps; exit 0; fi
if [ "${LIST}" = "1" ]; then print_plan; exit 0; fi

[ "${FRESH}" = "1" ] && { clear_state; say "已清除断点续跑状态(--fresh)" ; }
# --yes 透传给下游(k8s_deploy 前置的"旧集群残留 → 自动 reset"); 见 tools/k8s/reset-old-cluster.sh
[ "${ASSUME_YES}" = "1" ] && { export CUBESTACK_ASSUME_YES=1; say "已开启免交互确认(--yes): 覆盖安装时旧集群残留将**自动**清除"; }

need_root() { [ "$(id -u)" -eq 0 ] || { err "需要 root 权限,请执行: sudo $0"; exit 1; }; }
need_root

# ★ 覆盖安装可见化(实现见 lib-module.sh notify_base_redeploy; --list/--list-steps 只读路径不探测集群,
#   改由 print_plan 打印提示行)。**只提示、不拦停** —— 默认全量运行 = 覆盖安装(2026-09-17 定案):
#   目标集群已存在时照常重装, 只把"会发生什么"打出来(节点旧 K8s 会被 kubeadm reset; 该步骤自带 60s
#   倒计时可 Ctrl-C)。只想装组件不动集群 → --steps <组件>(计划里不含基座)。
#   ⚠ 可靠判定点在 run_module(执行 k8s_deploy 之前): 新容器此处可能**还没有 SSH 密钥** →
#   cluster_exists 判不出集群; 而 vm_sshkey/k8s_passwordless 恰好排在 k8s_deploy 之前, 到那时才可探测。
notify_base_redeploy

# ★ Ceph 消费者异常退出兜底(2026-10-13, CodeRabbit): 覆盖预检/优雅卸载把 registry(kubespray
#   裸 RS)与 cubestack-operator 停机(scale 0 + 标注原副本数)后, 若整轮部署**异常退出**
#   (模块失败/超时/Ctrl-C), 成功路径的 02_ceph.sh 7.9 不会执行 → 消费者会停在 0。
#   此处按停机标记契约恢复(见 lib-common.sh stop_restore_known_consumers): 只恢复带
#   cubestack.io/pre-stop-replicas 标注的对象; 无标记 = 无事可做(静默 no-op —— 成功路径
#   7.9 已恢复并清标, 钩子天然跳过, **不改成功路径行为**)。
#   停机只可能由"本次计划含 ceph"(预检 stop_consumers / ceph 模块自清理)或"含 k8s_deploy"
#   (优雅覆盖链: ceph 卸载 / 05 registry 卸载分支)的运行造成 → 仅这两种计划挂钩子,
#   组件 --steps(如 verify_*)运行不触碰停机标记。集群不可达(早段失败/首装)时静默跳过。
_restore_marked_consumers_on_fail() {   # EXIT 钩子: 仅非 0 退出(含 Ctrl-C)执行
    local _rc="$?"
    [ "${_rc}" = "0" ] && return 0
    init_remote_kubectl >/dev/null 2>&1 || return 0
    # SSH 都不通时不要再去 get/annotate —— 否则失败日志末尾会刷出两条
    # "Permission denied"(2026-10-22 实机: 密码错误时比真因更抢眼)。
    if ! SSH true >/dev/null 2>&1; then
        say "  集群 SSH 不可达 → 跳过 Ceph 消费者恢复(无标记=无操作)"
        return 0
    fi
    say "  异常退出(rc=${_rc}) → 恢复本次停机登记的 Ceph 消费者(无标记=无操作)..."
    stop_restore_known_consumers || true
    return 0
}
_has_ceph_step=0; _has_k8s_step=0
for _hc_k in "${RUN_STEPS[@]:-}"; do
    [ "${_hc_k}" = "ceph" ] && _has_ceph_step=1
    [ "${_hc_k}" = "k8s_deploy" ] && _has_k8s_step=1
done
unset _hc_k
if [ "${_has_ceph_step}" = "1" ] || [ "${_has_k8s_step}" = "1" ]; then
    trap '_restore_marked_consumers_on_fail' EXIT
    # ⚠ 必须同时转发 INT/TERM: bash 被 SIGINT/SIGTERM **杀死时不执行 EXIT trap**(2026-10-13
    #   独立实测), 否则 Ctrl-C / kill 会绕过兜底; 转发成 exit → EXIT trap 可靠执行
    #   (实测 Ctrl-C 语义 rc=130, kill 语义 rc=143)。
    trap 'exit 130' INT
    trap 'exit 143' TERM
fi
unset _has_ceph_step _has_k8s_step

# ★ 集群接入预检(仅 --steps 精确模式: 单独装组件 / 跑验证):
#   本地 kubeconfig 可用则直接用; 否则用 cluster.conf NODES 的密码引导(生成密钥 → 注入公钥 →
#   取 admin.conf 到本地)。全量部署/覆盖安装由各自的基座模块处理接入, 不走这里。
#   ⚠ 例外 —— **"集群存在之前就该跑"的模块**(PRE_CLUSTER_STEPS): 它们的用途正是"集群还没起来时
#     先把节点修好"(node_pkgs 修 apt 依赖图, 否则 kubespray 的 bootstrap_os → system_packages 必失败;
#     其余是建集群本身的前置)。对**全部请求步骤都属于这一类**的情形, 接入改为**尽力而为**: 能接上就接,
#     接不上只提示不拦停 —— 否则 `--steps node_pkgs` 在一台集群尚未起来的机器上永远跑不动(实机 2026-09-29)。
#     只要请求里**有任何一个**需要集群的步骤, 仍走原来的硬门(exit 1)。
PRE_CLUSTER_STEPS="node_pkgs k8s_passwordless k8s_workerbm k8s_hosts k8s_inventory k8s_ntp"
if [ -n "${STEPS_ARG}" ]; then
    _all_pre=1
    for _s in ${STEPS_ARG//,/ }; do
        case " ${PRE_CLUSTER_STEPS} " in
            *" ${_s} "*) ;;
            *) _all_pre=0 ;;
        esac
    done
    if [ "${_all_pre}" = "1" ]; then
        say "本次 --steps 只含\"集群存在前\"的节点前置模块 → 集群接入改为尽力而为(失败不拦停)"
        ensure_cluster_access || warn "  集群暂不可达(这些步骤不依赖集群 API, 继续执行)"
    else
        ensure_cluster_access || exit 1
    fi
fi

# 启动全量日志
LOG_FILE="/tmp/cubestack-cluster-install.log"
rm -f "${LOG_FILE}" 2>/dev/null || true
export LOG_FILE
say "完整部署日志: ${LOG_FILE}"

print_plan

# ★ 优雅覆盖(2026-10-11 用户口径, 设计 docs/graceful-overwrite/): K8s 覆盖**实际将发生**时
#   (RUN_STEPS 含 k8s_deploy 且实际状态非 done —— --fresh 清状态后天然成立), 且集群可达时:
#   先读安装登记 → 按首装序反序优雅卸载已装组件(卸载段在各自模块内), 之后 ceph 预检块
#   自然看到"无 CephCluster"(其删除分支空转)。⚠ 新容器此刻可能还没有 SSH 密钥 →
#   cluster_exists 判不出集群 → 由挂点 B(执行 k8s_deploy 前, lib-module.sh)兜底。
if [ "$(get_state k8s_deploy)" != "done" ]; then
    _OVERWRITE_PENDING=0
    for _ok_k in "${RUN_STEPS[@]:-}"; do
        [ "${_ok_k}" = "k8s_deploy" ] && _OVERWRITE_PENDING=1
    done
    unset _ok_k
    if [ "${_OVERWRITE_PENDING}" = "1" ] && cluster_exists; then
        _te_args=()
        [ "${ASSUME_YES}" = "1" ] && _te_args=(--yes)
        say "检测到集群已存在且本次将覆盖重装 → 先执行「优雅覆盖」: 按安装登记反序卸载已装组件"
        say "  (设计顺序: 优雅卸载先于下方 Ceph 确认倒计时执行)"
        # 计划感知(I1): 引擎据此跳过"非本次计划"的拆除(尤其不含 ceph 时保留 Ceph 集群/OSD 数据)
        export CUBESTACK_TEARDOWN_PLAN_STEPS="${RUN_STEPS[*]:-}"
        bash "${SCRIPT_DIR}/tools/k8s/cluster-teardown.sh" --uninstall "${_te_args[@]}" \
            || warn "优雅卸载未完成(继续; ceph 安全序与 k8s 覆盖流程兜底)"
        export CUBESTACK_TEARDOWN_DONE=1
    fi
    unset _OVERWRITE_PENDING
fi

# ⚠ Ceph 部署前强制确认(倒计时, 防覆盖磁盘 double-check 的兜底):
#   print_plan 的红底提醒无倒计时(纯提示); 02_ceph 模块内部的倒计时在 k8s 部署之后,
#   k8s_deploy 已被断点标记 done 跳过时会丢失 —— 这里在**真正开始部署前**再打断一次:
#   Ceph 启用(CEPH_ENABLED 或 CEPH_CSI_ENABLED)且本次会执行 ceph 相关模块(k8s_deploy 或 ceph)时,
#   sleep 倒计时 CEPH_CONFIRM_SLEEP(默认 60s, 设 0 跳过)供人工 double-check 存储节点/裸盘。
if [ "${CEPH_ENABLED:-false}" = "true" ] || [ "${CEPH_CSI_ENABLED:-false}" = "true" ]; then
    # ★ CEPH_FALLBACK_TO_LOCALPATH=true 时, 先检测 ceph 安装条件; 不足 → 自动回退 local-path
    #   (REGISTRY_STORAGE_CLASS=local-path + LOCAL_PATH_ENABLED=true + 跳过 ceph 模块)。
    #   仅显式启用才回退(防掩盖配置错误); 默认 false = 保持硬失败并给出指引。
    if [ "${CEPH_FALLBACK_TO_LOCALPATH:-false}" = "true" ]; then
        _CEPH_MISS="$(ceph_installable_check)"
        if [ -n "${_CEPH_MISS}" ]; then
            echo -e "\033[41m\033[97m================================================================================\033[0m"
            echo -e "\033[41m\033[97m ⚠⚠⚠  CEPH_FALLBACK_TO_LOCALPATH=true 且 Ceph 安装条件不足 → 自动回退 local-path ⚠⚠⚠\033[0m"
            echo -e "\033[41m\033[97m   不满足项: ${_CEPH_MISS}\033[0m"
            echo -e "\033[41m\033[97m   registry 后端改为 local-path(REGISTRY_STORAGE_CLASS=local-path), 启用 local-path-provisioner\033[0m"
            echo -e "\033[41m\033[97m   ceph/ceph_csi 模块本次跳过; 条件备齐后设 CEPH_ENABLED=true + CEPH_FALLBACK_TO_LOCALPATH=false 重跑\033[0m"
            echo -e "\033[41m\033[97m================================================================================\033[0m"
            CEPH_ENABLED="false"
            CEPH_CSI_ENABLED="false"
            REGISTRY_STORAGE_CLASS="local-path"
            LOCAL_PATH_ENABLED="true"
            export CEPH_ENABLED CEPH_CSI_ENABLED REGISTRY_STORAGE_CLASS LOCAL_PATH_ENABLED
        fi
        unset _CEPH_MISS
    fi
    # ★ 2026-09-09(用户要求): internal 模式存储节点数 < CEPH_MIN_NODES(默认 3)时,
    #   跳过 Ceph 集群部署 —— mon 法定人数不足, 02_ceph 本就不会创建 CephCluster;
    #   此处提前跳过裸盘确认横幅/倒计时/已有集群清理, registry 后端回退 local-path
    #   (与 CEPH_FALLBACK_TO_LOCALPATH 同款翻转), ceph/ceph_csi 模块运行时按
    #   TOGGLE=false 自行跳过, 部署不中断。
    if [ "${CEPH_MODE:-internal}" != "external" ]; then
        _CN="$(ceph_storage_host_count)"
        if [ "${_CN}" -lt "${CEPH_MIN_NODES:-3}" ]; then
            echo ""
            echo -e "\033[43m\033[30m================================================================================\033[0m"
            echo -e "\033[43m\033[30m ⚠⚠⚠  存储节点 ${_CN} 台 < CEPH_MIN_NODES=${CEPH_MIN_NODES:-3} → 跳过 Ceph 集群部署 ⚠⚠⚠\033[0m"
            echo -e "\033[43m\033[30m   mon 法定人数不足, 不创建 CephCluster(无裸盘覆盖风险, 跳过确认倒计时)   \033[0m"
            echo -e "\033[43m\033[30m   registry 后端回退 local-path; ceph/ceph_csi 模块本次跳过               \033[0m"
            echo -e "\033[43m\033[30m   如需 Ceph: ① 存储节点增至 ≥${CEPH_MIN_NODES:-3} 台; 或 ② CEPH_MODE=external 接入外部 Ceph\033[0m"
            echo -e "\033[43m\033[30m================================================================================\033[0m"
            CEPH_ENABLED="false"
            CEPH_CSI_ENABLED="false"
            REGISTRY_STORAGE_CLASS="local-path"
            LOCAL_PATH_ENABLED="true"
            export CEPH_ENABLED CEPH_CSI_ENABLED REGISTRY_STORAGE_CLASS LOCAL_PATH_ENABLED
            _CEPH_SKIP_SMALL=1
        fi
        unset _CN
    fi
    # ★ CEPH_MODE=external(由 load_config 归一化): 接入外部已有 Ceph, 不涉及本地裸盘/
    #   覆盖确认 —— 跳过存储节点/裸盘检测、已有 CephCluster 清理, 仅提示外部连接。
    # ★ 2026-09-11(用户要求): external 模式部署前**倒计时确认**(与 internal 裸盘确认对称)——
    #   在 K8s 集群部署**开始前**检查 external-ceph.env / CEPH_MONITORS 并供人工核对;
    #   02_ceph 模块内的倒计时在 k8s_deploy 之后(太晚), 未配置时等整个集群装完才发现
    #   ceph_csi 报错, 浪费整轮部署。此处未配置 → 红底强调"将报错", 供用户 Ctrl-C 修正。
    if [ "${CEPH_MODE:-internal}" = "external" ]; then
        _EXT_ENV_FILE="${CEPH_EXTERNAL_ENV_FILE:-${REPO_ROOT}/deployments/config/external-ceph.env}"
        _EXT_MONS="${CEPH_MONITORS:-}"
        _EXT_USER="${CEPH_USER:-admin}"
        echo -e "\033[41m\033[97m================================================================================\033[0m"
        echo -e "\033[41m\033[97m ⚠⚠⚠  CEPH_MODE=external — 接入外部已有 Ceph 集群(不创建集群内 CephCluster) ⚠⚠⚠\033[0m"
        if [ -f "${_EXT_ENV_FILE}" ]; then
            # 官方导入路径文件已就绪 → 展示其真实连接参数(mon 端点/用户名, 供人工核对)
            _EXT_ENV_MONS="$( (source "${_EXT_ENV_FILE}" 2>/dev/null && printf '%s' "${ROOK_EXTERNAL_CEPH_MON_DATA:-}") )"
            _EXT_ENV_USER="$( (source "${_EXT_ENV_FILE}" 2>/dev/null && printf '%s' "${ROOK_EXTERNAL_USERNAME:-}") )"
            [ -n "${_EXT_MONS}" ] || _EXT_MONS="${_EXT_ENV_MONS}"
            [ -n "${_EXT_ENV_USER}" ] && _EXT_USER="${_EXT_ENV_USER}"
            echo -e "\033[41m\033[97m   ✅ 官方 external-ceph.env 已就绪: ${_EXT_ENV_FILE}\033[0m"
        else
            echo -e "\033[41m\033[97m   ⚠ 未检测到 external-ceph.env(默认路径: ${_EXT_ENV_FILE})\033[0m"
        fi
        echo -e "\033[41m\033[97m   monitors: ${_EXT_MONS:-<未配置, ceph_csi 模块将报错>}\033[0m"
        echo -e "\033[41m\033[97m   pool: ${CEPH_POOL:-rbd}   user: ${_EXT_USER:-admin}\033[0m"
        if [ -f "${_EXT_ENV_FILE}" ]; then
            echo -e "\033[41m\033[97m   ceph_csi 将走官方导入路径读取 env 文件(优先于手填 CEPH_MONITORS); 不执行裸盘检测/覆盖确认\033[0m"
        else
            echo -e "\033[41m\033[97m   未放文件时请 cluster.conf 设 CEPH_MONITORS/CEPH_KEYRING(手填路径可用, 但无健康上报)      \033[0m"
            echo -e "\033[41m\033[97m   不执行裸盘检测/覆盖确认; 由 ceph_csi 模块经 CephConnection 连外部集群  \033[0m"
        fi
        echo -e "\033[41m\033[97m================================================================================\033[0m"
        # ★ 倒计时确认(与 internal 裸盘确认对称): 部署前供人工核对外部连接参数;
        #   CEPH_ENV_CONFIRM_SLEEP(默认 60s, 设 0 跳过)。monitors 未配置 → 红底强调"将失败"。
        _env_cs="${CEPH_ENV_CONFIRM_SLEEP:-60}"
        if [ -z "${_EXT_MONS}" ]; then
            say "⚠ external-ceph.env / CEPH_MONITORS 未配置 → ceph_csi 模块将报错; 建议 Ctrl-C 修正连接配置后重跑(或等待倒计时继续)"
        else
            say "Ceph(external)已启用: sleep ${_env_cs}s 供核对上方外部连接参数(CEPH_ENV_CONFIRM_SLEEP=0 可跳过)..."
        fi
        if [ "${_env_cs}" -gt 0 ] 2>/dev/null; then
            for _c in $(seq "${_env_cs}" -1 1); do
                printf "\r%s" "$(printf '\033[41m\033[97m  ⏳ 倒计时 %d 秒继续(请核对上方外部 Ceph 连接参数, 有误 Ctrl-C)      \033[0m' "${_c}")"
                sleep 1
            done
            printf "\r%s\n" "$(printf '\033[0m  %s             ')"
        else
            say "CEPH_ENV_CONFIRM_SLEEP=0, 跳过等待(请务必已人工核对上方外部连接参数)"
        fi
        unset _c _env_cs
        export CEPH_EXT_ENV_CONFIRMED=1   # 02_ceph 模块识别"deploy-cluster 已确认过" → 跳过其重复倒计时
        unset _EXT_ENV_FILE _EXT_MONS _EXT_USER _EXT_ENV_MONS _EXT_ENV_USER
    elif [ "${_CEPH_SKIP_SMALL:-0}" = "1" ]; then
        :   # 存储节点数 < CEPH_MIN_NODES: 上方已打印跳过横幅, 不弹确认/不做已有集群清理
    else
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
        # 候选存储节点(hostname): 统一走 ceph_storage_hosts(CEPH_NODES 显式 > CEPH_NODE_ROLE)
        declare -A _CEPH_CONFIRM_DISKS
        # 分类原始 TSV(<设备>\t<分类>\t<证据>): 确认框按类分组显示, 让"上次 Ceph 占用的盘"
        # 与"空闲盘"分开列出 —— 旧版只有一个裸盘列表, Ceph 存量盘被判为"在用"后只显示
        # <未检测到>, 人工看不出到底是"没有盘"还是"盘被上次部署占着"。
        declare -A _CEPH_CONFIRM_TSV
        _CEPH_CONFIRM_HOSTS=()
        while IFS= read -r _h; do
            [ -n "${_h}" ] && _CEPH_CONFIRM_HOSTS+=("${_h}")
        done < <(ceph_storage_hosts)
        unset _h
        _CEPH_CONFIRM_DETECT_FAIL=0
        # 显式 CEPH_NODES/CEPH_DATA_DISKS 先校验: 节点之间必须用分号, 不能误用逗号把
        # 三块盘都解析到第一个节点(2026-10-26 实机)。
        ceph_validate_explicit_config \
            || { err "Ceph 节点/裸盘配置非法, 请修正 deployments/config/cluster.conf 后重跑"; exit 1; }
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
            _DETECT_OUT="$(bash "${SCRIPT_DIR}/tools/k8s/ceph-detect-disks.sh" "${_DETECT_ARGS[@]}" -m --classify)" || true   # stderr 透传: 显示检测过程与失败原因(SSH 失败/无裸盘)
            if [ -n "${_DETECT_OUT}" ]; then
                while IFS=$'\t' read -r _hn _dev _cls _ev; do
                    [ -n "${_hn}" ] && [ -n "${_dev}" ] || continue
                    _CEPH_CONFIRM_TSV["${_hn}"]="${_CEPH_CONFIRM_TSV[${_hn}]:-}${_dev}"$'\t'"${_cls}"$'\t'"${_ev}"$'\n'
                    # 将写入 CR 的盘 = 空闲 + 上次 Ceph 占用(覆盖安装会先清空), 与 02_ceph.sh 同一口径
                    case "${_cls}" in
                        free|ceph) _CEPH_CONFIRM_DISKS["${_hn}"]="${_CEPH_CONFIRM_DISKS[${_hn}]:-}${_CEPH_CONFIRM_DISKS[${_hn}]:+,}${_dev}" ;;
                    esac
                done <<< "${_DETECT_OUT}"
            else
                _CEPH_CONFIRM_DETECT_FAIL=1
            fi
            unset _DETECT_ARGS _DETECT_OUT
        fi
        # 按分类分组显示各节点磁盘(含判定证据); 显式 CEPH_DATA_DISKS 路径没有分类数据,
        # 退回单行显示(那条路径盘名是人指定的, 本来就不需要分类)
        _ceph_show_cls() {   # <hostname> <分类> <标题>
            local _sh="$1" _sw="$2" _st="$3" _sd _sc _se _slist=""
            [ -n "${_CEPH_CONFIRM_TSV[${_sh}]:-}" ] || return 0
            while IFS=$'\t' read -r _sd _sc _se; do
                [ -n "${_sd}" ] || continue
                [ "${_sc}" = "${_sw}" ] || continue
                _slist="${_slist:+${_slist},}${_sd}"
            done <<< "${_CEPH_CONFIRM_TSV[${_sh}]}"
            [ -n "${_slist}" ] || return 0
            echo -e "\033[41m\033[97m   · ${_sh}  ${_st}: ${_slist}\033[0m"
            while IFS=$'\t' read -r _sd _sc _se; do
                [ -n "${_sd}" ] || continue
                [ "${_sc}" = "${_sw}" ] || continue
                echo -e "\033[41m\033[97m        ${_sd} ← ${_se}\033[0m"
            done <<< "${_CEPH_CONFIRM_TSV[${_sh}]}"
        }
        for _h in "${_CEPH_CONFIRM_HOSTS[@]:-}"; do
            _ip=""
            for _line in "${NODES[@]:-}"; do
                [ -z "${_line}" ] && continue
                node_parse "${_line}"
                [ "${NODE_HOSTNAME}" = "${_h}" ] && { _ip="${NODE_IP}"; break; }
            done
            if [ -n "${_CEPH_CONFIRM_TSV[${_h}]:-}" ]; then
                echo -e "\033[41m\033[97m  ── ${_h}${_ip:+(${_ip})} ──\033[0m"
                _ceph_show_cls "${_h}" free  "空闲裸盘(将作新 OSD)"
                _ceph_show_cls "${_h}" ceph  "上次 Ceph 占用(覆盖安装将清空复用)"
                _ceph_show_cls "${_h}" mixed "混合盘(不清理, 需人工判断)"
                _ceph_show_cls "${_h}" inuse "在用盘(不会触碰)"
                [ -n "${_CEPH_CONFIRM_DISKS[${_h}]:-}" ] \
                    || echo -e "\033[41m\033[97m     <无可用盘! 该节点不会创建 OSD>\033[0m"
            else
                echo -e "\033[41m\033[97m   · ${_h}${_ip:+(${_ip})}  →  裸盘(显式): ${_CEPH_CONFIRM_DISKS[${_h}]:-<未检测到>}\033[0m"
            fi
        done
        unset -f _ceph_show_cls
        if [ "${_CEPH_CONFIRM_DETECT_FAIL}" = "1" ]; then
            echo -e "\033[41m\033[97m   ⚠ 自动检测未返回(节点 SSH 免密可能未配置); 将在 ceph 模块部署时(SSH 就绪后)再确认盘名\033[0m"
        fi
        if [ -n "${REGISTRY_STORAGE_CLASS:-}" ] && [ "${REGISTRY_STORAGE_CLASS}" != "local-path" ]; then
            echo -e "\033[41m\033[97m   registry 后端: REGISTRY_STORAGE_CLASS=${REGISTRY_STORAGE_CLASS}(PVC 等 ceph 就绪后自动绑定)\033[0m"
        fi
        echo -e "\033[41m\033[97m   auto 自动分类磁盘 = 空闲裸盘 + 上次 Ceph 占用盘(后者覆盖安装会清空复用)\033[0m"
        echo -e "\033[41m\033[97m   在用盘(挂载中/非 ceph 文件系统/非 ceph LVM/系统盘)与混合盘一律不选不清理\033[0m"
        echo -e "\033[41m\033[97m   判定证据见各盘下方(判定按强证据, 不做猜测); 显式用 CEPH_DATA_DISKS 可指定盘\033[0m"
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
            _CEPH_EXIST="$(ssh -i "${_CEPH_SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "$(ssh_user_for_ip "${_FM_IP}")@${_FM_IP}" "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf -n rook-ceph get cephcluster --no-headers 2>/dev/null" 2>/dev/null || true)"
        fi
        if [ -n "${_CEPH_EXIST}" ]; then
            _CEPH_STATE="$(get_state "ceph")"
            echo ""
            echo -e "\033[41m\033[97m================================================================================\033[0m"
            echo -e "\033[41m\033[97m ⚠⚠⚠  检测到已有 CephCluster: $(echo "${_CEPH_EXIST}" | awk '{print $1}') ⚠⚠⚠\033[0m"
            if [ "${_CEPH_STATE}" = "done" ]; then
                # ★ 断点续跑保护: ceph 上次已成功(done) → 不清理不覆盖, 保留现有数据
                echo -e "\033[41m\033[97m   ✅ ceph 已部署成功(done) → 断点续跑: 跳过清理/覆盖, 保留现有 Ceph 数据  \033[0m"
                echo -e "\033[41m\033[97m   如需重装 Ceph: --fresh(全量) 或 CEPH_PRE_CLEANUP_EXISTING=true + 清状态    \033[0m"
            elif [ "${CEPH_PRE_CLEANUP_EXISTING:-true}" = "true" ]; then                echo -e "\033[41m\033[97m   覆盖 K8s 前将清理旧 Ceph(mon/osd/池, OSD 数据将销毁) —— 仅显式启用时  \033[0m"
            else
                echo -e "\033[41m\033[97m   默认【全新部署】: 重装生成新 fsid, 不认领旧 OSD 数据(盘上残留旧数据会被拒绝用) \033[0m"
                echo -e "\033[41m\033[97m   销毁旧数据: CEPH_PRE_CLEANUP_EXISTING=true(覆盖安装); 备份/恢复: --steps ceph_backup \033[0m"
            fi
            echo -e "\033[41m\033[97m   保留 csi-operator(重装不再重复安装); 检测不影响其他 operator 部署    \033[0m"
            echo -e "\033[41m\033[97m================================================================================\033[0m"
            # ★ 断点续跑保护: ceph 已 done 时不清理不覆盖(备份/恢复已拆出为独立模块 ceph_backup,
            #   部署预检不再自动备份 —— 需要时单独执行 --steps ceph_backup, 见 15_ceph_backup.sh)
            if [ "${_CEPH_STATE}" != "done" ]; then
                say "Ceph 备份/恢复已独立: 重装前如需保留旧数据, 先执行 --steps ceph_backup(CEPH_BACKUP_ACTION=save)"
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
        # ★ 2026-09-06 事故: `--steps ceph_csi` 的 REQUIRES 闭包会把 ceph 加回 RUN_STEPS,
        #   导致按 RUN_STEPS 判断"含 ceph"误删现有集群。改为判断**显式指定**:
        #   · --steps 模式: 仅当 STEPS_ARG 显式含 ceph 时才清理(补建类 --steps ceph_csi 不删);
        #   · 默认/全量模式(非 --steps): RUN_STEPS 含 ceph(真正重装)时清理。
        _RUN_CEPH=0
        if [ -n "${STEPS_ARG}" ]; then
            for _rk in ${STEPS_ARG//,/ }; do
                _rk="$(normalize_key "${_rk}")"
                [ "${_rk}" = "ceph" ] && _RUN_CEPH=1
            done
        else
            for _rk in "${RUN_STEPS[@]:-}"; do [ "${_rk}" = "ceph" ] && _RUN_CEPH=1; done
        fi
        # ★ 断点续跑保护(2026-09-06): ceph 上次已成功(状态 done)时**绝不清理覆盖**。
        #   断点重跑(其他模块失败续跑)时 ceph 模块会被 run_module 按状态跳过,
        #   预检块若照常清理会把已就绪的 Ceph 删掉 → 数据丢失事故。
        #   仅当 ceph 未完成/失败(状态非 done; --fresh 清状态后为空, 同样满足)时才覆盖清理。
        _CEPH_STATE="$(get_state "ceph")"
        if [ -n "${_CEPH_EXIST}" ] && [ "${_RUN_CEPH}" = "1" ] \
            && [ "${CEPH_PRE_CLEANUP_EXISTING:-true}" = "true" ] \
            && [ "${_CEPH_STATE}" != "done" ]; then
            # ★ 2026-10-10 修复(顺序按官方推荐; 用户口径): 旧实现此处是**内联三连删**(patch
            #   cleanupPolicy → delete cephblockpool → delete cephcluster), 缺"先把 Bound 的
            #   ceph PVC 删掉触发 CSI 正常 unmap、再删 rbd nodeplugin 让节点内核 rbd unmap"
            #   这两个前置 —— 正是 ceph-cleanup.sh 里记录的 09-05 事故路径(直接删集群 →
            #   节点上内核 rbd 映射无人 unmap → 持锁残留 / 把在飞 IO 写死在死设备上, **只能重启**;
            #   10-09 覆盖安装挂死事故的起点). 现改调 ceph-cleanup.sh --delete-cluster
            #   (同一套官方安全序: PVC → nodeplugin → pool/cluster; 含 registry-pvc 保护与
            #   300s 等待; Rook 擦盘兜底仍由模块 7a 物理清盘承担).
            say "清理已有 Ceph(官方安全序: 删 ceph PVC → CSI 正常 unmap → 删 rbd nodeplugin → 删 pool/cluster)..."
            bash "${REPO_ROOT}/deployments/scripts/tools/k8s/ceph-cleanup.sh" --delete-cluster \
                || warn "旧 Ceph 删除失败/超时(继续; 模块 7a 将物理清盘兜底)"
            ok "旧 Ceph 资源清理流程完成(物理清盘见模块 7a)"
        fi
        unset _CEPH_EXIST _FM_IP _CEPH_SSH_KEY _CEPH_GONE _CEPH_STATE
        unset _ceph_cs _CEPH_CONFIRM_HOSTS _CEPH_CONFIRM_DISKS _CEPH_CONFIRM_TSV _CEPH_CONFIRM_DETECT_FAIL _h _ip _line _l _ds _hn _g _grp _norm _h2 _d
        fi   # if [ -n "${_ceph_confirm_in}" ](internal 模式确认块)
    fi   # else(external 模式跳过确认)
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
    warn_unhealthy_pods   # 2026-10-12: 失败也巡检一眼(仅告警; 不可达静默跳过)
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
_NIP="$(first_node_ip 2>/dev/null || echo '<节点IP>')"
if [ "${SERVICE_EXPOSE_MODE:-metallb}" = "nodeport" ]; then
    echo -e "${_C_BOLD}${_C_YELLOW}⚠ 服务暴露方式: 当前为 NodePort 模式(SERVICE_EXPOSE_MODE=nodeport, 未部署 MetalLB)${_C_OFF}"
    echo "  访问入口 = 任意节点 IP + NodePort(自动取集群第一个节点 IP: ${_NIP}, 跨节点自动转发):"
    echo "  ⚠ NodePort 注意事项:"
    echo "               · 端口默认 30000-32767, 超出需改 kube-apiserver --service-node-port-range"
    echo "               · 无固定 VIP, 入口=单节点 IP, 节点重启/换 IP 后入口会变(部署时自动取新 IP)"
    echo "               · 对外服务用单节点 IP 有单点风险; 需要固定入口或生产环境请改用 MetalLB"
    echo "                 (SERVICE_EXPOSE_MODE=metallb, 需提供同网段空闲的 METALLB_POOL)"
else
    echo -e "${_C_BOLD}${_C_GREEN}✅ 服务暴露方式: 当前为 MetalLB LoadBalancer 模式(SERVICE_EXPOSE_MODE=metallb, 生产默认)${_C_OFF}"
    echo "  访问入口 = LoadBalancer VIP(ingress 经各自 LoadBalancer VIP)"
    echo "  ⚠ MetalLB 注意事项:"
    echo "               · METALLB_POOL 必须与节点同网段、不含网络/广播地址(.0/.255), 且地址空闲"
    echo "               · 地址池建议 >1 个地址, 否则新建 LoadBalancer 可能无 VIP 可分配(verify_metallb 会校验)"
    echo "               · 改池后需重跑 tools/k8s/sync-kubespray-config.sh 并重新 apply 池 CR 再验证"
    echo "               · 测试环境无空闲地址时可用 nodeport(SERVICE_EXPOSE_MODE=nodeport)"
fi
# registry 入口独立于全局暴露模式(默认 NodePort, 不占 MetalLB VIP)
if [ "${REGISTRY_SERVICE_TYPE:-nodeport}" = "nodeport" ]; then
    echo "  registry 入口: http://${_NIP}:${REGISTRY_NODEPORT:-31148}/ (NodePort, 默认; 与 SERVICE_EXPOSE_MODE 解耦)"
else
    echo "  registry 入口: http://${REGISTRY_IP:-<自动派生>}:${REGISTRY_PORT:-5000}/ (${REGISTRY_SERVICE_TYPE})"
fi
# CubeStack Web UI(Envoy Gateway; 所有模块/镜像推送完成后动态发现)
if [ "${CUBESTACK_OPERATOR_ENABLED:-false}" = "true" ] \
   && [[ " ${RUN_STEPS[*]:-} " == *" cubestack_operator "* ]]; then
    _ui_out="$(KUBESPRAY_INV_DIR="${KUBESPRAY_INV_DIR:-}" bash "${SCRIPT_DIR}/tools/k8s/cubestack-ui-url.sh" --wait 30 2>/dev/null || true)"
    if [ -n "${_ui_out}" ]; then
        echo "${_ui_out}"
    else
        echo "  CubeStack Web UI: 尚未发现(Envoy Gateway/HTTPRoute 可能尚未就绪; 稍后重跑: bash ${SCRIPT_DIR}/tools/k8s/cubestack-ui-url.sh)"
    fi
fi
echo "  下一步: 扩容用 --with-scale; 立即部署单个用 --steps gpu_operator,ceph(...)(自动带基座); 预启用写入配置用 --enable ...(下次全量生效); 验证用 --steps verify"

# ★ 外部 Ceph 接入信息(用户要求: 放安装末尾总结; 仅集群内 Ceph 且本次执行过暴露时提示)
#   03_ceph_csi 已打印/导出, 此处收敛到"文件路径 + 单行入口", 不再重复打印含 key 的全文。
#   ⚠ 2026-09-11(用户要求): CEPH_MODE=external 时是**消费方**, 不导出自身接入配置 ——
#   跳过整段(否则会误导打印"已导出 external-ceph.env"; 该文件是提供方拷来的真实文件,
#   导出/覆盖会毁掉官方导入路径的输入)。
if [ "${CEPH_MODE:-internal}" != "external" ] && [ "${CEPH_ENABLED:-false}" = "true" ] && [ -f "${REPO_ROOT}/deployments/config/external-ceph-self-define-access.conf" ]; then
    echo -e "${_C_BOLD}${_C_GREEN}★ 外部 ceph-csi operator 接入信息(完整配置在文件里):${_C_OFF}"
    echo "  配置路径: ${REPO_ROOT}/deployments/config/external-ceph-self-define-access.conf"
    echo "              拷贝到目标集群 cluster.conf 设 CEPH_MODE=external 即可接入;"
    echo "              含 CEPH_MONITORS / CEPH_FSID / RBD(user+key+pool) / CephFS(user+key+fs) / RGW 端点"
    echo "              入口(模式=${SERVICE_EXPOSE_MODE:-metallb}: nodeport→IP+规律NodePort / metallb→VIP+Ceph原生端口6789):"
    echo "              $(grep '^CEPH_MONITORS=' "${REPO_ROOT}/deployments/config/external-ceph-self-define-access.conf" 2>/dev/null | cut -d= -f2- | tr -d '\"')"
    echo "  一键查看: cat ${REPO_ROOT}/deployments/config/external-ceph-self-define-access.conf"
    echo "  5 层自检(含外部客户端协议级测试): bash ${SCRIPT_DIR}/tools/k8s/ceph-expose-external.sh status"
    # ★ 官方导入路径(2026-09-10): env 文件导出成功时提示 —— 目标集群设 CEPH_EXTERNAL_ENV_FILE
    #   即走官方导入(health-check/STATE=Connected + 自动 RGW/S3 对象存储), 见 docs §3.4.2 路径一。
    if [ -f "${REPO_ROOT}/deployments/config/external-ceph.env" ]; then
        echo -e "${_C_BOLD}${_C_GREEN}★ 官方 external-ceph.env(推荐接入方式):${_C_OFF}"
        echo "  已导出: ${REPO_ROOT}/deployments/config/external-ceph.env"
        echo "              (含官方 CSI 双角色 secret / healthchecker / RGW admin 密钥; gitignore 勿提交)"
        echo "  目标集群用法: 把该文件拷到目标集群部署机, cluster.conf 设 CEPH_MODE=external +"
        echo "              CEPH_EXTERNAL_ENV_FILE=<路径>(或放默认目录 deployments/config/ 自动检测)→"
        echo "              全自动官方导入(STATE=Connected 健康上报 + 对象存储 S3 接入)"
    fi
fi
# ★ 2026-10-12(用户要求): 收尾健康巡检 —— 未成功运行的 Pod 仅告警(集群可达时; 不可达静默跳过)
warn_unhealthy_pods
# ★ 收尾再汇总一次"本次未部署的组件"(与计划开始时同一函数, 见 lib-module.sh):
#   防"部署全绿结束、但某组件资源根本不存在"被漏看 —— TOGGLE 关闭的模块全流程 0 行输出
#   (2026-09-17 实例: 某组件 TOGGLE=false → 模块不进计划, 事后才发现)。
print_undeployed_summary
echo "============================================="
