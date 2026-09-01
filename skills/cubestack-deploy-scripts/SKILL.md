---
name: cubestack-deploy-scripts
description: CubeStack 部署脚本开发规范技能。当需要编写、修改、新增或重构 deployments/scripts 下的部署脚本(模块 modules/、工具 tools/、统一配置 cluster.conf)时使用本技能。适用于:新增部署模块、实现占位组件、修改模块而不影响其他模块、按规范审查脚本。
---

# CubeStack 部署脚本开发规范(Skill)

本技能指导在 **CubeStackInstaller 仓库** 的 `deployments/scripts/` 下编写、修改、新增部署脚本。遵循本规范可保证:**模块化、可插拔、单一配置源、修改一个模块不影响其他模块、无需重写全部脚本**。

## 何时使用本技能

- 新增一个部署模块(如新的中间件/自研组件)
- 把一个"伪代码占位模块"(addon_stub)实现为真实逻辑
- 修改既有模块或工具脚本,且需要保证不影响其他模块
- 审查脚本是否符合项目规范
- 需要了解 cluster.conf 组件开关、模块命名、目录组织规则
- **排查部署/运行问题**(见下方"问题解决 → 沉淀到 troubleshooting")

## 问题解决 → 沉淀到 troubleshooting(强制)

每次解决完一个部署/运行问题,**找到真正的 root cause 后必须**:

1. 按 `docs/troubleshooting.md` 的模板新增一条:`### 症状 → 根因 → 解法(根治) → 验证 → 相关命令`;
2. 根因要以**证据**为准(日志、抓包、计数器),不要停留在表象(如"webhook 超时"其实是 CNI 数据面断裂);
3. 若产生了新知识点/新命令,同步更新本 SKILL 的对应章节(或新增小节);
4. 相关修复脚本/配置一并落地(如 `calico_mtu`、controller pin),而不是只留口头结论。

> ⚠ **最重要的一条:只有「真正验证过能解决问题」的方案,才允许写入文档作为「解法」。**
> 未验证 / 只验证了一部分(如只解决了部署、没解决数据面)的方案,必须在文档里**如实标注已验证的边界**,绝不能写成"能解决问题"。
> 否则文档会留下一个看似解决、实则解决不了的方案,误导后续排查。
> 验证闭环:问题复现 → 修复 → **端到端验证通过(能跑通完整功能)** → 才更新文档。

## 关键文件位置(先读再改)

| 文件 | 用途 |
|---|---|
| `config/cluster.conf.example` | 唯一配置源模板(所有变量在此声明, 含组件开关) |
| `deployments/scripts/lib-common.sh` | 公共库(配置加载/工具函数, 所有脚本 source) |
| `deployments/scripts/lib-module.sh` | 模块框架(自动发现/元数据解析/调度/旧名别名) |
| `deployments/scripts/deploy-cluster.sh` | 统一入口(薄壳: 参数解析 + 调度) |
| `deployments/scripts/modules/<阶段>/NN_category_action.sh` | 部署模块(自动发现) |
| `deployments/scripts/tools/<领域>/xxx.sh` | 工具脚本(模块的底层实现) |
| `docs/scripts-development-spec.md` | 完整开发规范(本技能的详细版) |
| `docs/cluster-components-plan.md` | P1/P2/P3 组件规划与进度追踪 |

> 参考文件: `reference/scripts-development-spec.md`(完整规范)、`reference/cluster-components-plan.md`(组件规划)。

## 目录结构与阶段划分

```
deployments/scripts/
├── deploy-cluster.sh / lib-common.sh / lib-module.sh   # 框架(不要移动)
├── modules/
│   ├── 01_env/    # 阶段一 env: 环境准备(部署 kubespray 之前)
│   ├── 02_k8s/    # 阶段二 k8s: 离线部署 kubespray(VM/裸金属无关)
│   └── 03_addon/  # 阶段三 addon: 附加组件(01~19 中间件, 20 起自研)
└── tools/
    ├── vm/  net/  node/  k8s/  lb/   # 工具脚本按领域分目录
```

- **模块** = `modules/<阶段>/NN_category_action.sh`,一个文件一个可调度部署步骤
- **工具** = `tools/<领域>/xxx.sh`,模块的底层实现,被模块按需调用
- **阶段(PHASE)**: `env`(环境准备) / `k8s`(离线部署) / `addon`(附加组件)

## 模块命名与元数据头(强制)

命名:`<NN>_<category>_<action>.sh`(NN=两位序号, category=vm/env/k8s/gpu/lb 或组件名, action=动词)

每个模块文件头部**必须**用注释声明元数据,框架自动解析:

```bash
#!/bin/bash
# ============================================================
# MODULE: k8s_deploy          # 模块 key(缺省=文件名去掉 NN_ 前缀)
# DESC: 部署 kubespray 集群   # 一句话描述
# PHASE: k8s                  # 阶段: env | k8s | addon
# DEFAULT: 0                  # 1=默认启用; 0=需 --enable / TOGGLE / --steps
# REPEAT: 0                   # 1=可重复执行(不写断点状态)
# TOGGLE: K8S_ENABLED         # (可选) cluster.conf 变量名, true/1/yes/on 时自动启用
# 说明: <详细说明, 可选>
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config
```

注意:模块在 `modules/<阶段>/` 二级目录,`lib-common.sh` 相对路径是 `../../lib-common.sh`(不是 `../lib-common.sh`)。

## 新增模块标准流程(5 步)

1. **建文件**: `modules/<阶段>/NN_category_action.sh`(序号取当前阶段最大 +1; 03_addon 自研组件从 20 起)
2. **写元数据头**: 按上面模板填写 MODULE/DESC/PHASE/DEFAULT/REPEAT/TOGGLE
3. **实现逻辑**: 复用 `tools/` 工具脚本(`bash "${SCRIPT_DIR}/tools/<领域>/xxx.sh"`)或写新逻辑
4. **加开关**(可选): 在 `config/cluster.conf.example` 加 `XXX_ENABLED` 变量, TOGGLE 指向它
5. **完成**: 无需修改 `deploy-cluster.sh` / `lib-module.sh` / 任何注册表

验证: `sudo ./deploy-cluster.sh --list-steps` 应出现新模块; `sudo ./deploy-cluster.sh --steps <key>` 可单独执行。

> ⚠ **新增模块/功能后必须同步更新 `deploy-cluster.sh` 的 help(usage)**: 在"阶段目录与模块"列表与"示例"中补充新模块/命令(如 verify 模块加 `--steps verify_<组件>` 示例)。
> 原则:**每次增加新功能,及时更新 help**(以及必要的 README/文档),保证 `--help` 始终与代码一致,避免文档与实现脱节。

## 未实现组件的伪代码占位(addon_stub)

尚未实现真实逻辑的组件,统一用 `lib-common.sh` 的 **`addon_stub`** 框架写伪代码占位(一键流程可跑通,不真正执行; `ADDON_STUB_EXEC=1` 时试执行):

```bash
FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH="ssh -i ${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s} -o StrictHostKeyChecking=no ubuntu@${FIRST_MASTER}"
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

# ── 伪代码步骤(占位): 替换为真实实现 ──
MY_COMPONENT_STEPS=(
  "创建命名空间|${SSH} \"${K} create ns my-component 2>/dev/null || true\""
  "部署组件(离线 manifest)|${SSH} \"${K} apply -f /opt/cubestack/addons/my-component.yaml 2>/dev/null || true\""
  "验证就绪|${SSH} \"${K} -n my-component get pods -o wide 2>/dev/null || true\""
)
addon_stub "my_component" MY_COMPONENT_STEPS
```

实现真实逻辑时:把 `addon_stub "key" XXX_STEPS` 替换为真实命令即可,其余结构不变。

## 组件功能验证模块模板(verify_<组件>.sh)

部署完某个 operator/组件后,用它**真正验证工作正常**(而非仅 pod Running)。参考实现:`modules/03_addon/21_verify_metallb.sh`。

```bash
# ============================================================
# MODULE: verify_<组件>        # 文件 modules/03_addon/2N_verify_<组件>.sh
# DESC: 端到端验证 <组件> 真正工作(非仅 pod running): <一句话: 如 "LB Service 分配到池内 VIP 且节点可访问">
# PHASE: addon
# DEFAULT: 0                    # ⚠ 不要设 TOGGLE!否则组件开关为 true 时会在安装流程中被自动启用
# REPEAT: 1                     # 验证可重复执行
# 用法:   sudo ./deploy-cluster.sh --steps verify_<组件>
```
⚠ **不要设 `TOGGLE`**:`module_default_on` 会对 TOGGLE=true 的模块自动启用,导致 verify 模块在安装时被带上。verify 模块应保持 `DEFAULT:0`、无 TOGGLE,安装后单独 `--steps` 执行。
# ============================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

[ "${<TOGGLE>:-true}" = "true" ] || { say "跳过(未启用)"; exit 0; }
FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "$@"; }
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"
trap '清理测试资源' EXIT
# ① 组件 pod Ready → ② 核心 CR/资源存在 → ③ 建测试资源(用已预加载的离线镜像如 busybox/nginx)
# ④ 等待关键状态(分配 VIP / Ready) → ⑤ 真实功能访问(curl VIP / 调 API / 查数据) → ⑥ trap 清理
```

要点:
- **核心是第 ⑤ 步的真实功能验证**(访问/调用/查询能通才算过),不是 `get pods` 就完事;
- 测试后端用已预加载的离线镜像(`busybox:latest` httpd / `nginx`),避免离线拉镜像失败;
- 测试命名空间固定前缀 `verify-` 便于清理;`trap cleanup EXIT` 保证失败也清理;
- VIP 在池内校验、HTTP 状态码判定等边界,可加独立小函数(`_ip_in_pool` 等)便于复用;
- 每个 operator 一个 `verify_<组件>.sh`,本文件就是模板,复制改 MODULE/DESC/TOGGLE 与 ③⑤ 步。

## 修改模块的约束(不影响其他模块)

- 模块之间**不允许**互相 source(只允许调用 `tools/` 工具脚本);公共逻辑下沉到 `lib-common.sh` 或独立工具脚本
- 模块内变量用 `local`;全局临时变量加前缀(如 `_tmp_xxx`)
- 修改模块 A 时不改变模块 B 的元数据/文件名/TOGGLE 变量
- 删除模块 = 删除文件即可;序号空隙不影响(框架按文件名排序)
- 旧模块名由 `lib-module.sh` 的 `MODULE_ALIAS` 自动映射,旧 CLI 用法(`--steps vm,k8s`)不失效

## cluster.conf 组件开关(单一配置源)

- `config/cluster.conf` 是**唯一**配置入口,所有脚本只从它读取(环境变量可覆盖)
- 变量写法一律 `VAR="${VAR:-default}"`
- **`cluster.conf` 为主, 职责三分**(所有 operator 统一遵守):
  - **全量部署**: `--with-cubestack`/默认 = 基座 + cluster.conf 中已启用的**全部** operator; `--with-k8s` = 仅基座(跳过全部 operator)。
  - **预启用(写配置)**: `--enable X` = 只把 `XXX_ENABLED=true` 写入 cluster.conf, **不部署**; 下次全量部署生效。
  - **立即部署单个**: `--steps X` = 部署被指定的 X(自动带基座, 只部署被指定的 operator); `--steps verify` = 只跑验证模块。
  - **排除**: `--skip X` = 全量部署时剔除。
  - 新增 operator 必须把 key 加进 `lib-module.sh` 的 `OPERATOR_MODULES` 列表, 否则无法被 --steps/--enable 调度。
  - lb_haproxy/lb_keepalived(API-HA)默认 false, 需要时用 `--enable` 预启用 或 `--steps` 立即部署。
- 常用开关(见 `config/cluster.conf.example` 完整列表): `SERVICE_EXPOSE_MODE`(**nodeport**=默认, NodePort, 自动关 MetalLB+registry/ingress 切 NodePort / **metallb**=生产, LoadBalancer VIP)、`REGISTRY_ENABLED`(默认0,集群内registry不部署)、`HARBOR_ENABLED`、`METALLB_ENABLED`、`LOCAL_PATH_ENABLED`(默认false)、`K8S_ENABLED`、`GPU_OPERATOR_ENABLED`(默认true,已实现)、`LWS_ENABLED`(默认false,已实现:默认官方 manifests.yaml bundle + kubectl apply --server-side; helm chart 保留于 lws/charts 供 cert-manager 用; 见 `docs/lws.md`)、`HAPROXY_ENABLED`(默认false)、`KEEPALIVED_ENABLED`(默认false)、`PROMETHEUS_ENABLED`、`CEPH_ENABLED`、`CEPH_CSI_ENABLED`、`ENVOY_GATEWAY_ENABLED`(**默认 false, 需显式启用**)、`ENVOY_AI_GATEWAY_ENABLED`(**默认 false, 依赖 EG**)、`KEYCLOAK_ENABLED`、`KUEUE_ENABLED`、`KUBEVIRT_ENABLED`、`LUSTRE_CSI_ENABLED`、`CUBESTACK_APPS_ENABLED`
- 新增配置项流程: ① cluster.conf.example 加带注释默认声明 → ② 脚本引用 → ③ 如需同步 kubespray group_vars, 在 `tools/k8s/sync-kubespray-config.sh` / `tools/k8s/sync-addons-config.sh` 加同步逻辑

## 模块体内规范

1. **必须** `set -euo pipefail`(少数 `|| true` 兜底处除外)
2. **必须** source `lib-common.sh` 并 `load_config`
3. 输出用 `say`(信息)/`ok`(成功)/`warn`(告警)/`err`(致命, exit 1),会同时写日志文件
4. 开关类模块先检查 TOGGLE 变量,未启用则 `say "跳过..."` + `exit 0`(不要报错)
5. 复用逻辑: `bash "${SCRIPT_DIR}/tools/<领域>/xxx.sh"`
6. 支持 `--only` 过滤的模块: 用 `node_matches "${hostname}"` 判断
7. 退出码: 0=成功/跳过, 非0=失败(调度器中断部署)
8. 头部注释保留"数据源: cluster.conf 的哪些变量"

## 常用调度命令

```bash
sudo ./deployments/scripts/deploy-cluster.sh                    # 默认 = --with-cubestack(全量: 基座 + cluster.conf 启用的全部 operator)
sudo ./deployments/scripts/deploy-cluster.sh --with-k8s --fresh # 仅 kubespray 基座(k8s+metallb+local-path+registry), 不含 operator
sudo ./deployments/scripts/deploy-cluster.sh --skip gpu_operator   # 全量但排除某个 operator
sudo ./deployments/scripts/deploy-cluster.sh --steps gpu_operator  # 立即部署单个 operator(自动带基座, 只部署指定的)
sudo ./deployments/scripts/deploy-cluster.sh --enable gpu_operator # 只写 cluster.conf 预启用(不部署, 下次全量生效)
sudo ./deployments/scripts/deploy-cluster.sh --phase addon          # 仅 addon 阶段
sudo ./deployments/scripts/deploy-cluster.sh --list-steps           # 查看全部模块
```

## NODES 节点格式(5字段, 不区分虚拟机/裸金属)

- **cluster.conf NODES(5字段)**: `role,hostname,ip,ssh_user,ssh_password`
  - `ssh_password` 为 `-` → 用默认密码 `SSH_DEFAULT_PASSWORD`(全节点默认一致);
    显式密码 → 该节点独立密码(**支持裸金属不同密码场景**)。
  - 解析统一走 `lib-common.sh` 的 `node_parse`(输出 NODE_ROLE/NODE_HOSTNAME/NODE_IP/NODE_USER/NODE_PW 等全局变量),
    旧 10 字段格式(含 mac/mem/cpu/disk/node_type)向后兼容。
- **虚拟机创建独立执行, 主程序不判断节点类型**:
  - 需要创建虚拟机的节点在 `tools/vm/vm-nodes.conf`(10字段)定义;
    **`sudo ./deployments/scripts/tools/vm/create-vms.sh` 单独执行**(创建/启动 + 自动注入 5 字段到 NODES);
    主程序默认不调度 vm_create 模块(`DEFAULT:0`, 手动 `--steps vm_create` 等价于直接执行该脚本)。
  - 主程序模块(k8s_passwordless 全部节点 / k8s_workerbm 全部 worker 装包)**不引用 vm/bm 判断**。
  - "是否含 VM / 全裸金属"判定 `vm_conf_has_nodes`(lib-common)仅用于 **API 入口派生**
    (含 VM=宿主机物理 IP / 全裸金属=第一个 master IP, load_config + sync-kubespray-config), 不是节点处理判断。
- 新增脚本解析 NODES 一律用 `node_parse "${line}"`, 不要再用 `IFS=, read -r role hostname ip mac ...`。

## 离线部署容器(Dockerfile-cli)与离线文件

- **Dockerfile-cli**: 打包 kubespray 源码 + deployments 目录 + 工具链(ansible/helm/skopeo/mc/kubectl/sshpass/virsh),
  **不含离线镜像与 binary**(`.dockerignore` 排除 offline-files(含 virtual-machine)/inventory)。构建运行:
  ```bash
  docker build -f Dockerfile-cli -t cubestack-cli .
  docker run --rm -it --network host \
    -v $PWD/deployments/offline-files:/opt/cubestack-installer/deployments/offline-files \
    -v $PWD/deployments/config/cluster.conf:/opt/cubestack-installer/deployments/config/cluster.conf \
    -v $HOME/.ssh:/root/.ssh cubestack-cli
  # 容器内: cd /opt/cubestack-installer && sudo ./deployments/scripts/deploy-cluster.sh
  ```
- **离线文件下载**: `tools/offline/fetch-offline-files.sh` 用 mc 从 MinIO 同步到 `OFFLINE_FILES_DIR`
  (默认 `deployments/offline-files`); 配置 `MINIO_ENDPOINT/ACCESS_KEY/SECRET_KEY/BUCKET/REMOTE_DIR`。
- **离线文件缺失检查**: `lib-common.sh` 的 `check_offline_files`(deploy-cluster.sh 启动时调用), 缺失时输出
  **红底醒目提示**并给出准备指引(不阻断)。部署前务必保证 `${LOCAL_REPO_DIR}` 下有
  `images/`(镜像 tar)+ 二进制 + `packages/`(系统包)。

## 断点续跑(REPEAT 语义, 重要)

- **`REPEAT: 0`(可断点续跑)**: 安装成功后写状态文件, 重跑部署自动**跳过已完成模块**(断点继续, 不从头开始);
  用 **`--fresh` 清空所有状态**后从零重装。适用:**重型安装模块**(k8s_deploy / gpu_operator 等)。
- **`REPEAT: 1`(每次执行)**: 不写状态, 每次部署都执行。适用:**幂等快速检查**(metallb / local_path /
  k8s_registry / verify_* 等)。
- 状态文件: `deployments/config/.deploy.state`; 命令 `--fresh` / `--refresh` = `clear_state`。
- 新增重型 operator 一律 `REPEAT: 0`(支持断点), 幂等就绪检查类才用 `REPEAT: 1`。

## MetalLB 常见故障速查(环境切换残留 / memberlist)

> 详见 `docs/troubleshooting.md` 三.1(症状→根因→解法→验证全记录)。此处只沉淀关键知识点:

- **controller 永久 Pending + speaker 全报 `secret "memberlist" not found`** → 先看 `describe pod` 的
  `Node-Selectors`: 残留了**旧环境(裸金属)主机名**(如 `kubernetes.io/hostname: mxgpu-1-232`), 本环境无此节点
  → controller 调度不上 → 从不启动 → **不会自动创建 memberlist secret** → speaker 连锁失败。
  `memberlist` secret 缺失是**结果不是根因**, 模板无需加该 Secret(v0.13.x 由 controller 启动时自建)。
- **快速恢复/验证**(无需重跑部署):
  ```bash
  kubectl -n metallb-system patch deployment controller --type=json \
    -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector/kubernetes.io~1hostname"}]'
  ```
- **根治**: 删 addons.yml 里 controller.nodeselector 残留 hostname。**该 pin workaround 已移除(2026-08-22)**:
  改用 Calico IPIP 后跨节点 webhook 可达, 无需再钉 controller(见 `docs/cluster-architecture.md` §5.1)。

## MetalLB / 跨节点故障速查(proxy-ARP fabric + 封装选择)

> 详见 `docs/troubleshooting.md` 一.3(症状→根因→解法→验证全记录)。关键知识点:

- **节点同网段但跨节点 pod 全断 / webhook 超时**: 先 `ip neigh` 看是否**所有 IP 解析到同一 MAC**
  (如 `00:01:00:01:00:01`) → 这是 **proxy-ARP / 按 IP 转发的虚拟化 fabric**, 不是真实 L2。
- 该类 fabric 通常: 只转发**节点 IP**(SSH / 非 4789 的 UDP / IPIP-proto4), **不路由 pod CIDR**,
  **丢 UDP 4789**(VXLAN 端口)。→ **direct/native 无封装路由不可行**; VXLAN 用 4789 也不可行。
- **最优解 = IPIP 封装**(默认): `CALICO_DATA_PATH=ipip` → `calico_ipip_mode=Always` +
  `calico_network_backend=bird` + `mtu=1480`(物理-20)。外层=节点 IP, 不依赖任何 UDP 端口,
  实测跨节点 webhook/metallb 全通且 **pin workaround 可关**。
- VXLAN 在该 fabric 需换端口: `CALICO_DATA_PATH=vxlan` + `CALICO_VXLAN_PORT=8472`。
- **calico_network_backend 必须与数据面一致**(direct/ipip→bird, vxlan→vxlan), 漏配会无数据面。

## MetaX GPU Operator 部署速查(沐曦)

> 完整部署/镜像准备/故障见 `docs/metax-gpu-operator.md` 与 `docs/troubleshooting.md` §三.3。

- **镜像来源**: 驱动与 maca **不在** `.run` 包内, 需单独推送; 离线 tar 用 `tools/images/metax-save-images.sh`
  在已有镜像的机器上生成到 `METAX_OFFLINE_DIR`(默认 `deployments/offline-files/metax-gpu`, gitignore)。
- **默认 tar 加载**: `METAX_IMAGE_MODE=tar` → 模块从 offline 目录逐 tar `skopeo docker-archive` 推送
  到集群内置 registry; 核心组件去架构后缀(`0.15.3-amd64 → 0.15.3`), maca/driver 原样。
- **helm 原生安装**(不是 kubectl apply): 官方 chart 有 3 处 bug 需修(deployment 缺 namespace /
  openshift.deploy 无默认 / vendor 字段未加引号), 修复版 chart 放在 `deployments/cubestack-addon/metax-gpu-operator/metax-operator`。
- **`.run` push 有 flag 顺序 bug**(`--plain-http` 置于 ref 后): 用 `.run ctr load` + 自行 `ctr tag`+`ctr push --plain-http`。
- **master 有 GPU 时**: 用 `sudo mx-smi | grep "Attached GPUs"` 检测, 检测到的 master 自动移除 control-plane 污点并 uncordon。
- **常用命令**:
  ```bash
  sudo ./deploy-cluster.sh --steps gpu_operator            # 立即部署(自动带基座, 只部署指定的)
  sudo ./deploy-cluster.sh --steps verify_metax_gpu          # 验证 GPU 识别(或 --steps verify)
  sudo ./deployments/scripts/tools/images/metax-save-images.sh   # 保存镜像 → 离线 tar
  sudo ./deployments/scripts/tools/images/metax-load-images.sh   # 加载 tar → 集群 registry(手动)
  METAX_LIST_IMAGES=true bash modules/03_addon/04_gpu_operator.sh   # 打印所需镜像 pull/save 命令
  ```

## Envoy Gateway / Envoy AI Gateway 部署速查(统一流量入口)

> 完整分析/部署/使用/故障见 `docs/envoy-gateway.md` 与 `docs/troubleshooting.md` §三.5。

- **两者关系**: Envoy Gateway(EG)= 通用 K8s API 网关基座(Gateway API 标准实现); Envoy AI Gateway(AIG)
  = **不是独立二进制**, = 标准 EG 基座 + AI 控制器(内嵌 EG 扩展服务器, gRPC 1063)+ AI CRD
  (`aigateway.envoyproxy.io`), 经 EG 的 `extensionManager` 机制接线(见下)。**AIG 依赖 EG 先装**。
- **离线备料(联网机, 两件套)**: chart 用 `tools/images/envoy-fetch-charts.sh`(helm pull 解包到
  `deployments/cubestack-addon/envoy-gateway/{eg,ai}`); 镜像用 `tools/images/envoy-save-images.sh`
  (默认 `deployments/offline-files/envoy`): EG 控制面 `envoyproxy/gateway:<v>` + **数据面
  `envoyproxy/envoy:<v>`**(tag 与 EG 版本不同, 见 ENVOY_PROXY_VERSION)+ AIG 控制器
  `envoyproxy/ai-gateway-controller:<v>`(docker.io 源, 非 ghcr)+ **extProc sidecar
  `envoyproxy/ai-gateway-extproc:<v>`**(⚠ 必收: 漏收则数据面 pod 2/3 ImagePullBackOff, AI 路由 404)。
- **离线关键点(镜像改写)**: 创建 Gateway 后控制器动态创建的数据面 Deployment 默认用 docker.io 镜像,
  离线必 ImagePullBackOff → helm 必须改写: EG `envoyGateway.image.repository/tag` + 数据面
  `global.images.envoyProxy.image`(09 模块已做); AI 同理 `controller.image.repository/tag` +
  **`extProc.image.repository/tag`**(控制器 --extProcImage, 决定注入数据面的 extProc sidecar 镜像, 10 模块已做)。
- **EG Backend API(必须启用)**: AIG v1.1+ 的 AIServiceBackend 必须引用 EG `Backend` 资源, 该 API 默认禁用
  (安全原因, 参考 CVE-2021-25740) → 09 模块 helm 已默认 `config.envoyGateway.extensionApis.enableBackend=true`;
  不启用则 HTTPRoute 报 "Backend is disabled in Envoy Gateway configuration" (ResolvedRefs=False)。
- **EG extensionManager 接线(核心, 10 模块自动完成)**: AI 控制器内嵌 gRPC 扩展服务器(端口 1063);
  模块 10 [5/6] 把 `extensionManager.hooks.xdsTranslator`(post=[Translation,Cluster,Route],
  translation includeAll listener/route/cluster/secret)+ `service.fqdn` 指向
  `ai-gateway-controller.<AI ns>.svc.cluster.local:1063` 写入 EG 的 `envoy-gateway-config` ConfigMap,
  并重启 EG 控制面(明文 gRPC, 无需证书)。**漏配 → 数据面无 AI 过滤器, AI 请求 404
  "No matching route found"**(历史调试曾误判为 extProc 镜像问题)。模块 09 **故意不配**
  (EG 连不上扩展服务器 → 所有 Gateway xDS 翻译失败, 独立 EG 验证会挂)。
- **默认版本**: `ENVOY_EG_VERSION=v1.9.1`(GA)、`ENVOY_AI_VERSION=v1.1.0`(GA, API `v1beta1`, `ENVOY_AI_API_VERSION`)。
- **常用命令**:
  ```bash
  sudo ./deploy-cluster.sh --enable envoy_gateway                 # 只装 EG 基座
  sudo ./deploy-cluster.sh --enable envoy_gateway,envoy_ai_gateway  # EG + AI 二件套(AI 依赖 EG)
  sudo ./deploy-cluster.sh --steps verify_envoy_gateway            # 端到端: GatewayClass+VIP+真实 HTTP 转发
  sudo ./deploy-cluster.sh --steps verify_envoy_ai_gateway         # 端到端: AIGateway→Gateway 调和(+mock 边界)
  kubectl get gatewayclass,gateway,httproute -A; kubectl get aigateway,backend -A
  ```
- **AI 与 EG 版本兼容**: 升级 AIG 版本时核对官方兼容矩阵; `extensionManager` 结构/CRD 字段随版本变化,
  全部走 cluster.conf `ENVOY_AI_*` 变量, 不硬编码。

## 审查清单(写完脚本后自检)

- [ ] 文件名符合 `NN_category_action.sh`,序号不冲突
- [ ] 元数据头完整且格式正确(MODULE/DESC/PHASE/DEFAULT/REPEAT/TOGGLE)
- [ ] `set -euo pipefail` + source lib-common + load_config
- [ ] 未硬编码 IP/密码/路径(全部来自 cluster.conf 变量)
- [ ] 开关类模块有 TOGGLE 检查
- [ ] 引用的工具脚本存在于 `tools/<领域>/` 且路径正确
- [ ] `deploy-cluster.sh --list-steps` 能看到新模块
- [ ] 不影响其他模块(未改他人元数据/文件名)
