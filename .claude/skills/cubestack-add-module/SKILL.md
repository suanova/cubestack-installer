---
name: cubestack-add-module
description: CubeStackInstaller 新增部署模块的端到端标准流程技能。当用户要在 deployments/scripts/modules/ 下新增一个部署模块(中间件/自研组件/存储插件/verify 验证模块)、把 addon_stub 占位模块实现为真实逻辑、或修改模块元数据时使用。适用触发语:"新增模块"、"加一个 operator"、"新组件怎么接入"、"实现 XX 占位模块"、"模块报 unbound variable"、"模块没被调度"。本技能强制:init_remote_kubectl 统一初始化、REQUIRES 依赖声明、check-modules.sh 静态校验、--steps 精确模式验证、同步到部署容器。
---

# CubeStackInstaller 新增部署模块标准流程

在 **CubeStackInstaller 仓库**(`/home/supperadm/cubestack-installer`)的 `deployments/scripts/modules/` 下新增/修改部署模块时,严格按本流程执行。目标:**新模块不破坏既有功能** —— 每条规则都源自真实事故(见"历史事故警示")。

> 完整开发规范(模块设计/目录/工具脚本约定)见仓库内 `skills/cubestack-deploy-scripts/SKILL.md`,本技能是它的"新增模块"专项可执行流程,两者配合使用。

## 历史事故警示(为什么这些规则是强制的)

| 事故 | 根因 | 本技能的对应规则 |
|---|---|---|
| `05_k8s_registry.sh: K: unbound variable` 部署成功后崩溃 | 模块引用了远端 kubectl 变量 `K` 但没定义(旧规范让各模块自己复制 4 行初始化块,新模块少复制一行就崩) | **规则 2: 必须调用 `init_remote_kubectl || exit 1`** |
| `--steps local_path,k8s_registry` 意外带出 gpu_operator 部署 | OPERATOR_MODULES 手写列表漏配/语义不清,默认启用的 operator 被自动带出 | **规则 4: 依赖自动派生,用 `--list` 验证调度** |
| 新模块插错序号 → registry 在 local_path 前执行 | 模块顺序全靠文件名序号,无依赖声明 | **规则 3: REQUIRES 声明依赖,拓扑排序保证顺序** |
| 两个 deploy-cluster.sh 并发跑互相覆盖状态文件 | 无并发锁 | **规则 6: flock 已在入口生效,提醒用户不要并发** |

## 新增模块 6 步标准流程

### 步骤 0:确认模块归属与序号

```
modules/01_env/    阶段 env   (环境准备, 部署 kubespray 之前)
modules/02_k8s/    阶段 k8s   (离线部署 kubespray)
modules/03_addon/  阶段 addon (附加组件; 01~19 中间件, 20 起自研, 2x 起 verify)
```

- 序号 = 当前阶段目录下最大序号 + 1;中间件放 03_addon 的 01~19,自研组件 20+,验证模块 21+ 且文件名 `NN_verify_<组件>.sh`
- 阶段与目录必须一致(PHASE 元数据 = env|k8s|addon)

### 步骤 1:创建模块文件 + 元数据头(强制模板)

文件路径:`deployments/scripts/modules/<阶段>/NN_<category>_<action>.sh`

```bash
#!/bin/bash
# ============================================================
# MODULE: <key>                 # 模块唯一标识(小写字母/数字/下划线, 全局唯一)
# DESC: <一句话描述>            # 必填
# PHASE: <env|k8s|addon>        # 必填, 与目录一致
# DEFAULT: 0                    # 1=默认启用; 0=需 --enable/TOGGLE/--steps
# REPEAT: 0                     # 0=断点续跑(装完写状态, 重跑跳过); 1=每次执行(幂等检查/verify)
# TOGGLE: <VAR>                 # (可选) cluster.conf 变量名, true/1/yes/on 时自动启用
# REQUIRES: <key1> [key2...]    # (可选) 依赖模块: 执行前须已完成的模块 key 列表
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config
```

**REQUIRES 怎么写**:参考同阶段模块头部。示例:`k8s_registry` 是 `REQUIRES: k8s_deploy local_path metallb`;`ceph_csi` 是 `REQUIRES: ceph`。依赖只写**真正需要先完成**的模块;verify 模块 REQUIRES 其验证的组件(如 `verify_ceph` → `REQUIRES: ceph ceph_csi`)。

### 步骤 2:远端 kubectl 统一初始化(强制, 禁止复制旧写法)

凡是需要 SSH 到 master 执行 kubectl 的模块,**必须且只能**用:

```bash
init_remote_kubectl || exit 1
```

调用后自动获得:`FIRST_MASTER` / `SSH_KEY` / `SSH()` 函数 / `K`(远端 kubectl 简写)/ `SSH_CMD`(字符串式)。

- ✅ 正确用法:`SSH "${K} -n foo get pods"`(函数式)或 `${SSH_CMD} "..."`(字符串式, 如 addon_stub 步骤数组)
- ❌ **禁止**:在模块内复制 `FIRST_MASTER="$(first_master_ip)"...` `SSH() {...}` `K="sudo kubectl..."` 这 4 行 —— 这正是 `K: unbound variable` 事故的根源
- ⚠ `init_remote_kubectl` 幂等(同进程多次调用安全), 失败已 err 说明, 调用方 `|| exit 1` 即可

**占位模块(addon_stub)同样适用**:先 `init_remote_kubectl || exit 1`,再定义步骤数组,数组内用 `${SSH_CMD} "${K} ..."`(旧写法是 `${SSH}` 字符串变量,已废弃)。

### 步骤 3:实现逻辑

- 复用 `tools/` 工具脚本:`bash "${SCRIPT_DIR}/tools/<领域>/xxx.sh"`;公共逻辑下沉 lib-common.sh,模块间**不允许互相 source**
- 输出用 `say`(信息)/`ok`(成功)/`warn`(告警)/`err`(致命+exit 1)
- 开关类模块先检查 TOGGLE:`[ "${TOGGLE_VAR:-true}" = "true" ] || { say "跳过"; exit 0; }`(未启用不报错)
- 重型安装模块 `REPEAT: 0`(断点续跑);幂等就绪检查/verify `REPEAT: 1`
- 新增配置变量:① `deployments/config/cluster.conf.example` 加带注释默认声明(格式 `VAR="${VAR:-default}"`)→ ② 脚本引用 → ③ 如需同步 kubespray group_vars,在 `tools/k8s/sync-*-config.sh` 加同步逻辑

### 步骤 4:静态校验(合入前强制)

```bash
bash deployments/scripts/tools/check-modules.sh
```

检查项:bash -n 语法 / 元数据齐全(MODULE/DESC/PHASE/DEFAULT/REPEAT)/ key 唯一且合法 / PHASE 与目录一致 / REQUIRES 引用存在且全量无环 / 用了 K/SSH 的模块必须调用 init_remote_kubectl / TOGGLE 在 cluster.conf.example 有默认值 / 文件名 NN_ 前缀。

**全部通过(exit 0)才允许继续**;任何 ❌ 先修复。

### 步骤 5:调度与执行验证

```bash
# ① 模块被发现(列表出现新模块, 带 依赖:xxx 标注)
sudo ./deployments/scripts/deploy-cluster.sh --list-steps | grep <key>

# ② 调度精确: --steps 只跑指定的 + REQUIRES 依赖, 不带出默认 operator
sudo ./deployments/scripts/deploy-cluster.sh --list | grep "本次执行模块"

# ③ 单独执行(REPEAT:0 模块执行成功后写断点状态, 重跑会跳过; 重装用 --fresh)
sudo ./deployments/scripts/deploy-cluster.sh --steps <key>
```

**--steps 语义(架构规则, 不要违背)**:
- `--steps X` 精确模式:只跑指定的 X + 其 REQUIRES 闭包依赖 + 基座(env/k8s 阶段 + metallb/local_path/k8s_registry),**不带出**默认启用的其他 operator(如 gpu_operator)
- `--steps verify` = 全部 verify_* 模块,不拉基座
- operator 是**自动派生**的(有 TOGGLE 且不在 `BASE_MODULES=(k8s_deploy k8s_scale metallb local_path k8s_registry)`)= 新 operator 模块**无需**改 lib-module.sh 任何列表

### 步骤 6:同步到部署容器(如果部署在容器里跑)

```bash
# 容器名通常为 cubestack-install; 目录复制注意加尾部斜杠(防嵌套)
sudo docker cp deployments/scripts/modules/. cubestack-install:/opt/cubestack-installer/deployments/scripts/modules/
sudo docker cp deployments/scripts/lib-common.sh cubestack-install:/opt/cubestack-installer/deployments/scripts/lib-common.sh
sudo docker cp deployments/scripts/lib-module.sh cubestack-install:/opt/cubestack-installer/deployments/scripts/lib-module.sh
sudo docker cp deployments/scripts/deploy-cluster.sh cubestack-install:/opt/cubestack-installer/deployments/scripts/deploy-cluster.sh
# 容器内复检
sudo docker exec cubestack-install bash -lc 'bash /opt/cubestack-installer/deployments/scripts/tools/check-modules.sh --quiet'
```

⚠ 目录同步用 `modules/.`(尾部斜杠 = 复制内容),**不要** `docker cp modules/` 不带斜杠复制整个目录 —— 会生成 `modules/modules/` 嵌套副本导致模块重复发现。

## 修改既有模块的约束

- 模块之间不互相 source;公共逻辑下沉 lib-common.sh 或 tools/
- 不改变其他模块的元数据/文件名/TOGGLE 变量
- 修改后必须重跑 `check-modules.sh` + `--list-steps` 确认
- 删除模块 = 删文件即可,序号空隙不影响

## 审查清单(提交前逐项打勾)

- [ ] 文件在正确阶段目录,序号不冲突,`NN_category_action.sh` 命名
- [ ] 元数据头 5 字段齐全(MODULE/DESC/PHASE/DEFAULT/REPEAT),TOGGLE/REQUIRES 按需
- [ ] `set -euo pipefail` + source lib-common + load_config
- [ ] 使用 K/SSH 的地方已 `init_remote_kubectl || exit 1`(无手抄初始化块)
- [ ] REQUIRES 只列真依赖,引用存在,无循环
- [ ] 未硬编码 IP/密码/路径(全部 cluster.conf 变量)
- [ ] 新配置变量已在 cluster.conf.example 声明
- [ ] `bash deployments/scripts/tools/check-modules.sh` exit 0
- [ ] `--list-steps` 出现新模块;`--steps <key>` 调度正确(不带出多余 operator)
- [ ] 部署容器已同步(如适用)且容器内 check-modules 通过

## 测试用例(验证本技能自身是否有效)

以下提示词可用来验证本技能:
1. "我要给 cubestack-installer 新增一个 XX 组件部署模块,帮我做" → 应引导走 6 步流程而非直接写代码
2. "把 modules/03_addon/11_keycloak.sh 的占位实现改成真实逻辑" → 应替换 init 块为 init_remote_kubectl
3. "为什么我的新模块报 K: unbound variable" → 应指向 init_remote_kubectl 规则
4. "检查我新写的模块是否合规" → 应运行 check-modules.sh 并逐项核对清单
