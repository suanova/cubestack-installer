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

## 修改模块的约束(不影响其他模块)

- 模块之间**不允许**互相 source(只允许调用 `tools/` 工具脚本);公共逻辑下沉到 `lib-common.sh` 或独立工具脚本
- 模块内变量用 `local`;全局临时变量加前缀(如 `_tmp_xxx`)
- 修改模块 A 时不改变模块 B 的元数据/文件名/TOGGLE 变量
- 删除模块 = 删除文件即可;序号空隙不影响(框架按文件名排序)
- 旧模块名由 `lib-module.sh` 的 `MODULE_ALIAS` 自动映射,旧 CLI 用法(`--steps vm,k8s`)不失效

## cluster.conf 组件开关(单一配置源)

- `config/cluster.conf` 是**唯一**配置入口,所有脚本只从它读取(环境变量可覆盖)
- 变量写法一律 `VAR="${VAR:-default}"`
- 常用开关(见 `config/cluster.conf.example` 完整列表): `REGISTRY_ENABLED`(默认0,集群内registry不部署)、`HARBOR_ENABLED`、`METALLB_ENABLED`、`LOCAL_PATH_ENABLED`(默认false)、`K8S_ENABLED`、`GPU_OPERATOR_ENABLED`、`LWS_ENABLED`、`HAPROXY_ENABLED`、`KEEPALIVED_ENABLED`、`PROMETHEUS_ENABLED`、`CEPH_ENABLED`、`CEPH_CSI_ENABLED`、`ENVOY_GATEWAY_ENABLED`、`KEYCLOAK_ENABLED`、`KUEUE_ENABLED`、`KUBEVIRT_ENABLED`、`LUSTRE_CSI_ENABLED`、`CUBESTACK_APPS_ENABLED`
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
sudo ./deployments/scripts/deploy-cluster.sh --with-k8s          # 一键部署
sudo ./deployments/scripts/deploy-cluster.sh --steps k8s_deploy  # 只跑指定模块
sudo ./deployments/scripts/deploy-cluster.sh --phase addon       # 仅 addon 阶段
sudo ./deployments/scripts/deploy-cluster.sh --enable harbor,prometheus  # 启用组件
sudo ./deployments/scripts/deploy-cluster.sh --list-steps        # 查看全部模块
```

## 审查清单(写完脚本后自检)

- [ ] 文件名符合 `NN_category_action.sh`,序号不冲突
- [ ] 元数据头完整且格式正确(MODULE/DESC/PHASE/DEFAULT/REPEAT/TOGGLE)
- [ ] `set -euo pipefail` + source lib-common + load_config
- [ ] 未硬编码 IP/密码/路径(全部来自 cluster.conf 变量)
- [ ] 开关类模块有 TOGGLE 检查
- [ ] 引用的工具脚本存在于 `tools/<领域>/` 且路径正确
- [ ] `deploy-cluster.sh --list-steps` 能看到新模块
- [ ] 不影响其他模块(未改他人元数据/文件名)
