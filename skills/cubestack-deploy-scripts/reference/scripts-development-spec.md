# CubeStack 部署脚本开发规范(Skill / 编码规范)

> 本文档是 `deployments/scripts/` 下所有部署脚本的**唯一开发规范**。新增/修改脚本前必读。
> 核心目标:**模块化、可插拔、单一配置源、修改一个模块不影响其他模块、无需重写全部脚本**。

---

## 1. 总览

### 1.1 设计原则

| 原则 | 说明 |
|---|---|
| **单一配置源** | 所有脚本只从 `config/cluster.conf` 读取配置(环境变量可覆盖),**不硬编码** IP/用户名/密码/路径/版本 |
| **模块即文件** | 每个部署功能 = `modules/NN_category_action.sh` 一个文件;新增模块 = 放一个文件,无需改任何注册表/入口 |
| **自动发现** | `lib-module.sh` 扫描 `modules/*.sh`,按文件名序号排序、按头部元数据解析,`deploy-cluster.sh` 只做参数解析 + 调度 |
| **薄封装复用** | 模块是"薄封装",具体逻辑复用 `tools/` 下工具脚本(`tools/k8s/gen-inventory.sh` / `tools/*/sync-*.sh` / `tools/*/setup-*.sh` / `cubestack-offline.sh`),不重复实现 |
| **向后兼容** | 旧模块名(`net`/`vm`/`k8s`/`scale` 等)由 `lib-module.sh` 的 `MODULE_ALIAS` 自动映射,旧 CLI 用法不失效 |
| **幂等可重跑** | 模块尽可能幂等;可重复模块(REPEAT=1)每次执行且不写断点状态 |
| **断点续跑** | 每模块完成写状态(`config/.deploy.state`);失败后修复重跑自动跳过已完成模块(`--fresh` 清状态) |

### 1.2 目录结构

```
deployments/scripts/
├── deploy-cluster.sh          # ★ 统一入口(薄壳: 参数解析 + 调度, 不内联业务)
├── lib-common.sh              # ★ 公共库(配置加载/工具函数, 所有脚本 source)
├── lib-module.sh              # ★ 模块框架(递归自动发现/元数据/调度/旧名别名)
├── modules/                   # ★ 部署模块(按环境准备阶段组织子目录, 自动发现)
│   ├── 01_env/                #   阶段一: 环境准备(发生在部署 kubespray 之前)
│   │   ├── 01_vm_network.sh   #     格式: <序号>_<分类>_<动作>.sh
│   │   ├── 04_harbor.sh       #     Harbor(集群外私有仓库, 部署前就绪)
│   │   ├── 05_lb_haproxy.sh   #     HAProxy(集群部署前准备)
│   │   └── 06_lb_keepalived.sh#     Keepalived(集群部署前准备)
│   ├── 02_k8s/                #   阶段二: 离线部署 kubespray(不依赖 VM/裸金属)
│   └── 03_addon/              #   阶段三: 附加组件(01~19 中间件, 20 起自研模块)
├── tools/                     # ★ 工具脚本(模块的底层实现, 按领域分目录)
│   ├── vm/                    #   虚拟机: create-libvirt-vm.sh / create-vm-template.sh / register-vm.sh
│   ├── net/                   #   网络: setup-vm-network.sh / verify-vm-network.sh / teardown-vm-network.sh / setup-libvirt-nat.sh
│   ├── node/                  #   节点: gen-ssh-key.sh / setup-passwordless.sh / install-worker-packages.sh / setup-ntp.sh / sync-hosts.sh / sync-ca*.sh / rebootstrap*.sh / prepare-workers.sh
│   ├── k8s/                   #   inventory/配置: gen-inventory.sh / sync-kubespray-config.sh / sync-addons-config.sh
│   └── lb/                    #   负载均衡/registry: sync-haproxy.sh / deploy-registry.sh / setup-registry-expose.sh
└── README.md
```

阶段(`PHASE` / 目录)划分:

| 目录 / PHASE | 含义 | 依赖 |
|---|---|---|
| `01_env` / `env` | 部署环境准备(宿主网络/SSH密钥/创建VM/Harbor/HAProxy/Keepalived) | 宿主机 |
| `02_k8s` / `k8s` | 离线部署 kubespray(不依赖 VM 还是裸金属) | env 之后 |
| `03_addon` / `addon` | 附加组件(集群部署后; 01~19 第三方中间件, 20 起 CubeStack 自研模块) | k8s 之后 |

> 重要:Harbor(`04_harbor`)、HAProxy(`05_lb_haproxy`)、Keepalived(`06_lb_keepalived`)属于**环境准备阶段**,在部署 kubespray 之前完成——镜像仓库与 API 负载均衡/VIP 入口是集群部署的前置条件。
>
> 镜像仓库定位:集群外私有仓库 = **Harbor**(`01_env/04_harbor.sh`, 部署前于宿主机就绪);集群内 registry = kubespray addon(`03_addon/03_k8s_registry.sh`),**默认不部署**(`REGISTRY_ENABLED=0`)。原 `env_registry`(本地 docker registry)已移除,由 Harbor 承担。
>
> 序号约定:`03_addon/` 下 **01~19 为第三方中间件预留**(当前用到 01~11),**20 起为 CubeStack 自研模块**(起始 `20_cubestack_apps.sh`, 后续自研组件在 20 之后追加)。

全阶段组件规划(P1/P2/P3)与进度追踪见 `docs/cluster-components-plan.md`。

---

## 2. 模块规范

### 2.1 命名规范

```
modules/<NN_phase>/<NN>_<category>_<action>.sh
```

- `NN_phase/`:阶段目录(`01_env`/`02_k8s`/`03_addon`),决定阶段归属与全局顺序。
- `NN`:两位序号,决定阶段内执行顺序(01 最早)。与目录序号共同决定全局顺序。
- `category`:模块分类。约定值:
  - `vm` — 虚拟机相关(测试环境准备)
  - `env` — 环境准备(registry 等)
  - `k8s` — kubespray 部署相关(与 VM/裸金属无关)
  - `gpu` — GPU 组件
  - `lb` — 负载均衡/高可用(HAProxy/Keepalived)
  - 其他:P1/P2/P3 组件用组件名作分类(如 `prometheus`/`ceph`/`keycloak`)
- `action`:模块动作(动词,如 `network`/`create`/`deploy`/`scale`/`registry`)。

示例:`modules/01_env/01_vm_network.sh`、`modules/02_k8s/06_k8s_deploy.sh`、`modules/03_addon/04_prometheus.sh`。

### 2.2 模块元数据头(必填)

每个模块文件头部用注释声明元数据,框架自动解析:

```bash
#!/bin/bash
# ============================================================
# MODULE: k8s_deploy          # 模块 key(缺省=文件名去掉 NN_ 前缀)
# DESC: 部署 kubespray 集群   # 一句话描述(print_steps 显示)
# PHASE: k8s                  # 阶段: env | k8s | addon
# DEFAULT: 0                  # 1=默认启用; 0=需 --enable / TOGGLE / --steps
# REPEAT: 0                   # 1=可重复执行(每次执行且不写断点状态)
# TOGGLE: K8S_ENABLED         # (可选) cluster.conf 变量名, 值为 true/1 时自动启用
# 说明: <详细说明, 可选>
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib-common.sh"
load_config
```

字段说明:

| 字段 | 必填 | 说明 |
|---|---|---|
| `MODULE` | 否 | 模块唯一标识;缺省 = 文件名去掉 `NN_` 前缀(如 `01_vm_network.sh` → `vm_network`) |
| `DESC` | 推荐 | 一句话描述,`--list-steps` 展示 |
| `PHASE` | 推荐 | `env`/`k8s`/`addon`,支持 `--phase` 过滤 |
| `DEFAULT` | 推荐 | `1`=默认执行;`0`=需显式启用。缺省视为 `0` |
| `REPEAT` | 推荐 | `1`=可重复执行(不写断点状态,每次收敛);`0`=断点续跑跳过 |
| `TOGGLE` | 否 | cluster.conf 变量名;值为 `true/1/yes/on` 时自动默认启用(如 `TOGGLE: GPU_OPERATOR_ENABLED`) |

### 2.3 模块体内规范

1. **必须** `set -euo pipefail`(除少数 `|| true` 兜底处)。
2. **必须** source `lib-common.sh` 并 `load_config`(模块位于 `modules/`,相对路径为 `../lib-common.sh`)。
3. 输出用 `say`(信息)/`ok`(成功)/`warn`(告警)/`err`(致命,exit 1),会同时写日志文件。
4. 开关类模块先检查 TOGGLE 变量,未启用则 `say "跳过..."` + `exit 0`(不要报错)。
5. 复用逻辑:调用 `tools/` 下工具脚本 `bash "${SCRIPT_DIR}/tools/<领域>/xxx.sh"`(SCRIPT_DIR 由 lib-common 指向 scripts 目录)。
6. 支持 `--only` 过滤的模块:用 `node_matches "${hostname}"` 判断。
7. 模块退出码:0=成功/跳过,非 0=失败(调度器中断部署)。
8. 头部注释保留"数据源: cluster.conf 的哪些变量",便于排查。

---

## 3. cluster.conf 规范(单一配置源)

### 3.1 规则

- `config/cluster.conf` 是**唯一**配置入口,模板见 `config/cluster.conf.example`(真实配置含密码,已 gitignore)。
- 所有变量写法:`VAR="${VAR:-default}"`(环境变量 > 配置文件 > 内置默认)。
- 新增配置项流程:① 在 `cluster.conf.example`(及需要时 `.backup`)添加带注释的默认声明 → ② 相关脚本引用该变量 → ③ 如需同步到 kubespray group_vars,在 `sync-kubespray-config.sh` / `sync-addons-config.sh` 增加同步逻辑。

### 3.2 组件开关(推荐)

| 变量 | 默认 | 作用对象 | 说明 |
|---|---|---|---|
| `REGISTRY_ENABLED` | `0` | addons.yml `registry_enabled` / `k8s_registry` 模块 | 集群内 registry(kubespray addon),**默认不部署** |
| `HARBOR_ENABLED` | `false` | `harbor` 模块 | 集群外私有仓库(Harbor, P1-4),替代本地 docker registry |
| `METALLB_ENABLED` | `true` | addons.yml `metallb_enabled` | MetalLB |
| `LOCAL_PATH_ENABLED` | `false` | addons.yml `local_path_provisioner_enabled` | local-path-provisioner,**默认不启动**;需本地 PVC 持久化时启用 |
| `METRICS_SERVER_ENABLED` | `true` | addons.yml | metrics-server |
| `HELM_ENABLED` | `true` | addons.yml | Helm |
| `INGRESS_NGINX_ENABLED` | `false` | addons.yml | ingress-nginx |
| `DASHBOARD_ENABLED` | `false` | addons.yml | dashboard |
| `CERT_MANAGER_ENABLED` | `false` | addons.yml | cert-manager |
| `GATEWAY_API_ENABLED` | `false` | addons.yml | Gateway API |
| `K8S_ENABLED` | `false` | `k8s_deploy` 模块 | 一键部署是否默认执行 kubespray |
| `K8S_SCALE_ENABLED` | `false` | `k8s_scale` 模块 | 扩容 |
| `GPU_OPERATOR_ENABLED` | `false` | `gpu_operator` 模块 | 沐曦 GPU Operator |
| `LWS_ENABLED` | `false` | `gpu_lws` 模块 | LeaderWorkerSet |
| `HAPROXY_ENABLED` | `false` | `lb_haproxy` 模块 | API 四层负载均衡(部署前准备) |
| `KEEPALIVED_ENABLED` | `false` | `lb_keepalived` 模块 | API VIP 高可用(部署前准备) |

> 镜像仓库双定位:集群外 = Harbor(`HARBOR_ENABLED`,唯一方案);集群内 = kubespray registry addon(`REGISTRY_ENABLED`,默认不部署)。
> addons.yml 的组件开关由 `sync-addons-config.sh` 从上述变量生成(幂等),其余组件配置(地址池/存储类等)保留在 addons.yml 手工维护。

---

## 4. 新增模块的标准流程(5 步)

以新增"某某组件安装"为例:

1. **建文件**:`modules/NN_<category>_<action>.sh`(序号取当前阶段最大 +1)。
2. **写元数据头**:按 §2.2 模板填写 MODULE/DESC/PHASE/DEFAULT/REPEAT/TOGGLE。
3. **实现逻辑**:复用现有工具脚本或写新逻辑(§2.3)。
4. **加开关**(可选):在 `cluster.conf.example` 加 `XXX_ENABLED` 变量,TOGGLE 指向它。
5. **完成**:**非 operator 组件**无需改任何注册表;**operator 组件**需把 key 加进 `lib-module.sh` 的 `OPERATOR_MODULES` 列表(否则无法被 `--steps` / `--enable` 调度)。

> 验证:`sudo ./deploy-cluster.sh --list-steps` 应出现新模块;`sudo ./deploy-cluster.sh --steps <key>` 可单独执行。

### 4.1 未实现组件的伪代码占位(推荐)

尚未实现真实逻辑的组件模块,统一用 `lib-common.sh` 的 **`addon_stub`** 框架编写伪代码占位,保证:
- 一键流程可"跑通"(打印步骤,不真正执行);`ADDON_STUB_EXEC=1` 时试执行伪代码命令
- 实现真实逻辑时只需把 `addon_stub` 替换为真实命令,其余结构不变

模板:

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

> 现有占位模块(伪代码已实现):
> - `01_env/`: `harbor`(集群外仓库, 宿主机部署)
> - `03_addon/01~11`: `gpu_operator` / `gpu_lws` / `k8s_registry` / `prometheus` / `ceph` / `ceph_csi` / `envoy_gateway` / `keycloak` / `kueue` / `kubevirt` / `lustre_csi`
> - `03_addon/20`: `cubestack_apps`(CubeStack 自研模块占位, 20 起为自研序号)
> 每个模块头部 `TODO` 注释即实现指引。

---

## 5. 统一入口用法

```bash
sudo ./deploy-cluster.sh                                # 默认 env+k8s 基础模块
sudo ./deploy-cluster.sh --with-k8s                     # = --enable k8s(旧名兼容)
sudo ./deploy-cluster.sh --with-scale                   # 扩容
sudo ./deploy-cluster.sh --steps k8s_deploy,lb_haproxy  # 只跑指定模块(旧名自动映射)
sudo ./deploy-cluster.sh --skip k8s_hosts --with-k8s    # 跳过某模块
sudo ./deploy-cluster.sh --phase k8s                    # 仅 k8s 阶段
sudo ./deploy-cluster.sh --steps gpu_operator,lws      # 立即部署指定的 operator(自动带基座, 只部署指定的)
sudo ./deploy-cluster.sh --enable gpu_operator         # 只写 cluster.conf 预启用(不部署, 下次全量生效)
sudo ./deploy-cluster.sh --only <host> --with-scale     # 仅处理指定节点
sudo ./deploy-cluster.sh --list-steps | --list | --fresh
```

模块也可**独立执行**(绕过入口):`sudo bash modules/02_k8s/06_k8s_deploy.sh`(模块自含 load_config)。

---

## 6. 最佳实践

### 6.1 修改一个模块不影响其他模块

- 模块之间**不允许**互相 source(只允许调用工具脚本);如需复用,把公共逻辑下沉到 `lib-common.sh` 或独立工具脚本。
- 模块内变量用 `local`;全局临时变量加前缀(如 `_tmp_xxx`)避免污染。
- 修改模块 A 时,不改变模块 B 的元数据/文件名/TOGGLE 变量。
- 删除模块 = 删除文件即可;序号空隙不影响(框架按文件名排序)。

### 6.2 幂等性

- 创建类操作前先检查存在性(如 VM `virsh list`、registry 容器 `docker ps`)。
- 配置文件生成类操作可全量重写(如 hosts.yml/addons.yml),不必增量。
- 服务重启类操作尽量"仅首次"或"校验后再重启"。

### 6.3 错误处理与日志

- `set -euo pipefail`;预计可能失败且可容忍的命令用 `|| warn` / `|| true`。
- 模块失败应 `err "原因"` + 返回非 0,调度器会中断并提示 `--skip`/`--fresh`。
- 日志:所有 say/ok/warn/err 自动写入 `LOG_FILE`(`deploy-cluster.sh` 启动时设置)。

### 6.4 安全

- 不把密码写入日志;`sshpass` 场景用 `SSHPASS` 环境变量(`sshpass -e`)。
- 需要 root 的模块:开头 `[ "$(id -u)" -eq 0 ] || { err "需要 root: sudo $0"; exit 1; }`。

---

## 7. 常见问题

- **新增模块没出现在 `--list-steps`**:检查文件名是否匹配 `[0-9][0-9]_*.sh` 且元数据头格式正确。
- **旧命令失效**:检查模块 key 是否被 `MODULE_ALIAS` 覆盖;旧名(`net/vm/k8s/...`)应仍可用。
- **TOGGLE 不生效**:确认 cluster.conf 中变量值为 `true/1/yes/on` 且模块头 `TOGGLE:` 拼写一致。
- **模块重复执行**:确认 `REPEAT: 1`,否则断点状态会跳过。
