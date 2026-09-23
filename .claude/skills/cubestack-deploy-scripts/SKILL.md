---
name: cubestack-deploy-scripts
description: CubeStack 部署脚本开发规范技能。当需要编写、修改、新增或重构 deployments/scripts 下的部署脚本(模块 modules/、工具 tools/、统一配置 cluster.conf)时使用本技能。适用于:新增部署模块、实现占位组件、修改模块而不影响其他模块、按规范审查脚本。
---

# CubeStack 部署脚本开发规范(Skill)

本技能指导在 **CubeStackInstaller 仓库** 的 `deployments/scripts/` 下编写、修改、新增部署脚本。遵循本规范可保证:**模块化、可插拔、单一配置源、修改一个模块不影响其他模块、无需重写全部脚本**。

> ⭐ **新增部署模块的专项流程技能: `skills/cubestack-add-module/SKILL.md`**(6 步流程 + 历史事故警示 + 测试用例)。本技能 = 通用规范速查,两者配合使用,内容已同步(2026-09-04 架构重构)。

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

> 参考文件: `docs/scripts-development-spec.md`(完整规范, 唯一维护)、`docs/cluster-components-plan.md`(组件规划)。

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
# REQUIRES: k8s_deploy        # (可选) 依赖模块 key 列表(执行前须已完成); 框架自动拓扑排序
# 说明: <详细说明, 可选>
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config
```

注意:模块在 `modules/<阶段>/` 二级目录,`lib-common.sh` 相对路径是 `../../lib-common.sh`(不是 `../lib-common.sh`)。

## 新增模块标准流程(6 步)

> ⭐ **新增部署模块的专项可执行流程见 `skills/cubestack-add-module/SKILL.md`**(含历史事故警示与测试用例),本表为速览。

1. **建文件**: `modules/<阶段>/NN_category_action.sh`(序号取当前阶段最大 +1; 03_addon 自研组件从 20 起)
2. **写元数据头**: 按上面模板填写 MODULE/DESC/PHASE/DEFAULT/REPEAT/TOGGLE, 需要依赖顺序时加 `REQUIRES`(引用必须存在、不可成环)
3. **统一远端初始化**: 需要 SSH 到 master 执行 kubectl 的模块**必须**调用 `init_remote_kubectl || exit 1`(幂等, 提供 FIRST_MASTER/SSH_KEY/SSH()/K/SSH_CMD)。**禁止**在模块内手抄 `FIRST_MASTER=.../SSH() {...}/K="sudo kubectl..."` 初始化块 —— 曾致 `K: unbound variable` 部署成功后崩溃
4. **实现逻辑**: 复用 `tools/` 工具脚本(`bash "${SCRIPT_DIR}/tools/<领域>/xxx.sh"`)或写新逻辑
5. **加开关**(可选): 在 `config/cluster.conf.example` 加 `XXX_ENABLED` 变量, TOGGLE 指向它
6. **完成**: 无需修改 `deploy-cluster.sh` / `lib-module.sh` / 任何注册表(operator 自动派生)

验证: `bash deployments/scripts/tools/check-modules.sh`(静态校验, 必须 exit 0);
`sudo ./deploy-cluster.sh --list-steps` 应出现新模块(带 `依赖:xxx` 标注);
`sudo ./deploy-cluster.sh --steps <key>` 可单独执行(--steps 精确模式, 只跑指定模块+依赖)。

> ⚠ **新增模块/功能后必须同步更新 `deploy-cluster.sh` 的 help(usage)**: 在"阶段目录与模块"列表与"示例"中补充新模块/命令(如 verify 模块加 `--steps verify_<组件>` 示例)。
> 原则:**每次增加新功能,及时更新 help**(以及必要的 README/文档),保证 `--help` 始终与代码一致,避免文档与实现脱节。

## 未实现组件的伪代码占位(addon_stub)

尚未实现真实逻辑的组件,统一用 `lib-common.sh` 的 **`addon_stub`** 框架写伪代码占位(一键流程可跑通,不真正执行; `ADDON_STUB_EXEC=1` 时试执行):

```bash
init_remote_kubectl || exit 1   # ★ 统一远端初始化(幂等: FIRST_MASTER/SSH_KEY/SSH()/K/SSH_CMD)

# ── 伪代码步骤(占位): 替换为真实实现 ──
MY_COMPONENT_STEPS=(
  "创建命名空间|${SSH_CMD} \"${K} create ns my-component 2>/dev/null || true\""
  "部署组件(离线 manifest)|${SSH_CMD} \"${K} apply -f /opt/cubestack/addons/my-component.yaml 2>/dev/null || true\""
  "验证就绪|${SSH_CMD} \"${K} -n my-component get pods -o wide 2>/dev/null || true\""
)
addon_stub "my_component" MY_COMPONENT_STEPS
```

> ⚠ 旧写法 `SSH="ssh -i ... ubuntu@${FIRST_MASTER}"` + `K="sudo kubectl ..."` 已在 2026-09-04 架构重构中废弃:
> 统一改 `init_remote_kubectl`(字符串式用 `${SSH_CMD}`), 防止新模块少复制一行导致 `K: unbound variable` 崩溃。

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
init_remote_kubectl || exit 1   # ★ 统一远端初始化(幂等: FIRST_MASTER/SSH_KEY/SSH()/K)
trap '清理测试资源' EXIT
# ① 组件 pod Ready → ② 核心 CR/资源存在 → ③ 建测试资源(用已预加载的离线镜像如 busybox/nginx)
# ④ 等待关键状态(分配 VIP / Ready) → ⑤ 真实功能访问(curl VIP / 调 API / 查数据) → ⑥ trap 清理
```

要点:
- **核心是第 ⑤ 步的真实功能验证**(访问/调用/查询能通才算过),不是 `get pods` 就完事;
- 测试后端镜像**必须离线可用**:`TEST_IMAGE="$(ensure_registry_nginx)" || exit 1`(lib-common 助手,
  把 nginx 推进**集群内置 registry**,pod 从内置 registry 拉;来源 = 本地 docker → 离线 tar
  `offline-files/nginx/nginx.tar` → 仅 `VERIFY_IMAGE_ONLINE=true` 才走在线)。**不碰 docker.io、
  也不依赖节点 containerd 预载**;别再用 `docker.io/library/busybox` 这类 ref。用到它就把
  `k8s_registry` 加进 `REQUIRES`(见 21_verify_metallb);
- 测试命名空间固定前缀 `verify-<组件>-$$`(PID 后缀防残留 Terminating ns 冲突);`trap cleanup EXIT` 保证失败也清理;
- **验证边界要在文件头如实标注**:测到哪一步就写哪一步,够不到的(如需额外镜像的真实流量/吞吐测试)
  必须写明"不含",别让后续人误判已验收;
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
  - 新增 operator **无需改任何列表**: operator 由框架自动派生(有 `TOGGLE` 且不在 `BASE_MODULES`(k8s_deploy/k8s_scale/metallb/local_path/k8s_registry)= operator), 写 TOGGLE 即自动进入 --steps/--enable 调度。
  - lb_haproxy/lb_keepalived(API-HA)默认 false, 需要时用 `--enable` 预启用 或 `--steps` 立即部署。
- 常用开关(见 `config/cluster.conf.example` 完整列表): `SERVICE_EXPOSE_MODE`(**nodeport**=默认, NodePort, 自动关 MetalLB+registry/ingress 切 NodePort / **metallb**=生产, LoadBalancer VIP)、`REGISTRY_ENABLED`(默认0,集群内registry不部署)、`HARBOR_ENABLED`、`METALLB_ENABLED`、`LOCAL_PATH_ENABLED`(默认false)、`K8S_ENABLED`、`GPU_OPERATOR_ENABLED`(默认true,已实现)、`LWS_ENABLED`(默认false,已实现:默认官方 manifests.yaml bundle + kubectl apply --server-side; helm chart 保留于 lws/charts 供 cert-manager 用; 见 `docs/lws.md`)、`HAPROXY_ENABLED`(默认false)、`KEEPALIVED_ENABLED`(默认false)、`CEPH_ENABLED`、`CEPH_CSI_ENABLED`、`KEYCLOAK_ENABLED`、`KUEUE_ENABLED`、`KUBEVIRT_ENABLED`、`LUSTRE_CSI_ENABLED`、`CUBESTACK_APPS_ENABLED`
- 新增配置项流程: ① cluster.conf.example 加带注释默认声明 → ② 脚本引用 → ③ 如需同步 kubespray group_vars, 在 `tools/k8s/sync-kubespray-config.sh` / `tools/k8s/sync-addons-config.sh` 加同步逻辑

## 模块体内规范

1. **必须** `set -euo pipefail`(少数 `|| true` 兜底处除外)
2. **必须** source `lib-common.sh` 并 `load_config`
3. 输出用 `say`(信息)/`ok`(成功)/`warn`(告警)/`err`(致命),会同时写日志文件。
   ⚠ **`err()` 只打印、不退出** —— 每个错误分支必须显式跟 `exit 1`(漏了会静默继续往下跑)
4. 开关类模块先检查 TOGGLE 变量,未启用则 `say "跳过..."` + `exit 0`(不要报错)
5. 复用逻辑: `bash "${SCRIPT_DIR}/tools/<领域>/xxx.sh"`
6. 支持 `--only` 过滤的模块: 用 `node_matches "${hostname}"` 判断
7. 退出码: 0=成功/跳过, 非0=失败(调度器中断部署)
8. 头部注释保留"数据源: cluster.conf 的哪些变量"

## SSH 取回远端值的引号惯例(踩坑, 强制)

模块里大量"远端取一个值回来"的写法,**一行内的双引号总数必须是偶数**。少写一个引号 → bash 会一路
找闭合引号直到文件尾,报 `unexpected EOF while looking for matching ')'`,而且**行号指向无关行**,
极难定位(2026-09-16 实测)。两种正确写法:

```bash
# ① 内层参数整体带引号(推荐, 与 29_verify_multus 一致): "SSH "${K}" -n ..."
_st="$(SSH "${K}" -n ${NS} get pod x -o jsonpath='{.status.phase}' 2>/dev/null || true)"

# ② 引号在 2>/dev/null 后闭合, || true 落在引号外: 2>/dev/null" || true)
_alloc="$(SSH "${K} get node ${_node} -o jsonpath='{.status.x}' 2>/dev/null" || true)"
```

❌ 坏写法(`"${K} -n ... || true)"` 只有 3 个引号 = 奇数,整个文件语法崩):

```bash
_st="$(SSH "${K} -n ${NS} get pod x ... 2>/dev/null || true)"
```

**写完自检**(比 `bash -n` 更早定位;多行 `'...'` awk 块正常报奇数, 对照 git 原版确认):

```bash
python3 -c "print([i for i,l in enumerate(open('模块.sh'),1) if not l.strip().startswith('#') and l.strip() and l.count(chr(34))%2])"
```

然后 **`bash -n` + `tools/check-modules.sh` 双绿**才算过。

### 变体: `ssh host "sudo bash -c '...'"` 内嵌远端脚本 —— 注释里的 ASCII 引号会**静默拆散载荷**

同一条规则的另一面: 内嵌脚本外层 `"..."`、内层 `'...'`, 若**注释里出现未转义的 ASCII 双引号**,
本地 shell 会提前闭合外层引号 → 这次 ssh 调用的参数被**拆成多个**。bash/ssh 会把额外参数用
**一个空格**重新拼接成远端命令, 所以**多数时候看起来是好的**(只是注释里少俩引号、多几个空格),
直到引号奇偶性被带偏, 把后面**功能性代码**里的 `$()`、`[[:space:]]`、`)` 拖进错误的引用状态 ——
那时才炸, 且报错点离真因很远(2026-09-23 实测: `deployments/kubespray/cubestack-offline.sh` 的
内嵌清理脚本被拆成 2 个参数, 断点落在注释 `见 "Drain node" 报 ...`)。

**落地规则**: 内嵌远端脚本内的注释**不要用 ASCII 双引号**, 改用全角 `“ ”`(多字节, 对 shell 完全惰性)。

**自检(比肉眼可靠)**: 用 stub `ssh` 把真正发给远端的载荷打出来, 看**参数个数**:

```bash
cat > /tmp/pt.sh <<'OUTER'
#!/bin/bash
key=/tmp/k; user=ubuntu; host=10.0.0.1
ssh() { echo "### ssh 收到 $# 个参数 ###"; local i=1 a; for a in "$@"; do
    if [ $i -ge 10 ]; then echo "--- arg$i ---"; printf '%s\n' "$a"; fi; i=$((i+1)); done; }
OUTER
sed -n "${P1},${P2}p" 脚本.sh >> /tmp/pt.sh   # P1/P2 = 该 ssh 调用的行范围
printf '\nprintf "%%s\\n" "$probe"\n' >> /tmp/pt.sh
bash /tmp/pt.sh    # 期望: 除 ssh 选项外**只有 1 个参数**(即整段远端脚本)
```

⚠ 必须**逐字核对功能性行**是否原样送达(`$(...)`、`\"` 转义、`[[:space:]]`), 不能只看"跑通了"。

### 另一条同源坑: 同一条 `local` 里, 赋值右侧**先于**赋值求值

```bash
local rel="$1" src="${REPO_ROOT}/${rel}"   # ❌ ${rel} 取的是**外层**同名变量, 不是刚赋的 $1
local rel="$1"                             # ✅ 分行写
local src="${REPO_ROOT}/${rel}"
```

只在外层恰好存在同名变量且值相同时才"看起来正常" —— 2026-09-23 在 `sync-to-container.sh` 实测:
`sync_one` 仅从 `for rel in PATHS` 循环调用, 外层 `rel` 恰等于 `$1`, 所以一直没暴露;
一旦换调用方式, `src` 会退化成 `${REPO_ROOT}/` → `docker cp` 把**整个仓库根**(含 971M kubespray
源码树与 `.git`)灌进容器。

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

## helm chart 离线副本(全仓库强制约定)

**凡安装 helm chart 的模块,其 chart 必须有一份 vendored 在 `deployments/cubestack-addon/<组件>/`
下并随 git 分发;模块安装时恒用这份本地副本,在线只用于比对刷新。**

- **放哪**:`deployments/cubestack-addon/<组件>/`(一个 chart 一个子目录)。`.gitignore` 只挡
  `offline-files/*`,不挡 `cubestack-addon/`,所以 `.tgz` 直接 `git add` 即可(如 lws / rook 的 chart 已在库里)。
- **什么形态**:小 chart 放 `.tgz` + **同时提交 `<tgz>.digest` 边车**;大 chart(带几十个子 chart)
  放解包源码目录(含 `Chart.yaml`)。
- **怎么装**:走共享助手,**不要手抄 pull/回退逻辑**:
  ```bash
  helm_chart_ensure "<组件名>" "$XXX_CHART_TGZ" "$XXX_CHART_VERSION" \
      "$XXX_MODE" "$XXX_CHART_REF" "$XXX_CHART_REPO" || exit 1
  ```
  语义:online 拉远端 → 比 `Digest:` 与边车 → **未变继续用本地**(仓库保持干净)、有更新才覆盖本地
  并提示 commit、拉取失败降级回退本地;offline 完全不联网;最后判一次本地副本在不在,不在就 `err`。
- **怎么刷新**:目前**没有**脚本化刷新工具 —— 手工 `helm pull` 覆盖 vendored 副本
  (示例见 `deployments/cubestack-addon/lws/CUBESTACK.md` 的"升级到新版本"),`.tgz` 形态要一并更新
  `<tgz>.digest` 边车。跑完**必须 commit** —— 不提交等于没刷新。
- **为什么是"恒用本地"而不是"线上优先"**:曾有模块写了"拉取失败回退本地 chart",
  但仓库里压根没有那份文件 —— 私服一抖动回退就是空转。回退只有在本地确实有一份时才有意义。
- **强制校验**:`tools/check-modules.sh` 第 ⑩ 项。行首是 helm 安装命令的模块,其引用的
  `cubestack-addon/**` 下必须能定位到 `.tgz` 或 `Chart.yaml`,否则报错。

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

## Ceph / Rook 部署速查(Rook v1.20.2 + Ceph v20.2.2, 详见 docs/ceph-rook.md)

- **定位**: 高可用分布式存储(块 RBD; 可选 CephFS/RGW)。生产设计 `size=3 + failureDomain=host + min_size=2 + mon=3`。
- **离线三件套(联网机)**: `tools/k8s/rook-fetch-manifests.sh`(rook manifest → `cubestack-addon/rook/`)、
  `tools/images/ceph-save-images.sh`(镜像 → `offline-files/ceph`, **每镜像独立 tar + --platform linux/amd64**,
  多架构 tar 会让 `ctr import` 报 "content digest not found")、`tools/offline/fetch-lvm-packages.sh`
  (lvm2 .deb → `offline-files/kubespray/packages`, OSD 重启需 lvm 激活逻辑卷)。
- **节点选择**: `CEPH_NODES`(显式, 优先)或 `CEPH_NODE_ROLE`(**默认 master**)→ 唯一实现为 lib-common 的 `ceph_storage_hosts()`; 模块自动打 label `CEPH_NODE_LABEL`(默认 `ceph-storage=rook-ceph`)。
- **裸盘自动检测(防覆盖)**: `tools/k8s/ceph-detect-disks.sh` 判定"未使用裸盘"(无分区/格式化/挂载/LVM 且非系统盘)
  → 生成 CephCluster CR 的 per-node devices(精确盘名)。部署前**红底列出节点+盘并 sleep CEPH_CONFIRM_SLEEP(60s)**
  double-check; CI 可 `CEPH_CONFIRM_SLEEP=0`。
- **镜像同步**: `tools/images/ceph-sync-images.sh`(复制 tar 到全部节点 + `ctr -n k8s.io images import --no-unpack`)。
- **VM 测试盘**: `vm-nodes.conf` 的 `VM_DATA_DISKS=3/VM_DATA_DISK_SIZE=200` → 每台 VM 附加 3×200GB 裸盘(Guest `/dev/vdb~`),
  由 `tools/vm/create-vms.sh` 创建时自动附加。
- **部署顺序(03_addon 已重排)**: `01_metallb → 02_ceph → 03_ceph_csi → 04_local_path → 05_k8s_registry → …`;
  registry 后端设 `REGISTRY_STORAGE_CLASS=ceph-block` 即走 ceph(替代 local-path)。
- **常用命令**:
  ```bash
  sudo ./deploy-cluster.sh --steps ceph,ceph_csi          # 部署(或 CEPH_ENABLED=true+CEPH_CSI_ENABLED=true 随全量)
  sudo ./deploy-cluster.sh --steps verify_ceph            # 端到端: operator/CSI+Ready+ceph -s+RBD 块 I/O
  kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
  ```

## Harbor 统一镜像源(镜像清单 / 同步 / 备料, 详见 docs/harbor-mirror.md)

- **唯一数据源**: `deployments/config/images.manifest`, 格式 `<group> <上游ref> [tar文件名覆盖]`;
  ref 用 `${VAR}` 引用 **cluster.conf** 的版本变量(CI 上回退 cluster.conf.example 默认值)
  ⇒ **升级只改 cluster.conf §3.3 一处**, 全链跟随。
- **group → 目录**: 默认 `offline-files/<group>/`; 例外 `k8s-base`/`ceph` → `offline-files/kubespray/images/`
  (节点预加载走 kubespray)。
- **Harbor 路径规则**(唯一): `mirrors/<上游注册域>/<仓库路径>:<tag>`; 上游就是本 Harbor 时去掉域名前缀
  (`harbor.isuanova.com/metax/x` → `mirrors/metax/x`)。**保留注册域是有意的** —— 上游 ref 是 Harbor 路径的
  后缀, 因此 tar 按上游 ref 命名(`<repo>_<tag>.tar`)可与既有模块的通配查找**零改动**兼容。
- **三个工具**(`tools/images/`):
  ```bash
  harbor-sync-images.sh          # 上游 → Harbor(CI/联网机; 自动建项目; 增量比 digest)
  harbor-save-images.sh          # Harbor → offline-files/<group>/*.tar(联网机)
  check-image-manifest.sh        # 静态校验; --kubespray 交叉核对; --harbor 漂移报告
  ```
- **默认不镜像"上游就是本台 Harbor"的组**(metax-gpu 12): 它们本就在本台 Harbor 上,
  部署模块直接从 `metax/` 项目拉, 再镜像只多占 8.4 GB 且升级要重跑。
  判据是**推导**的(注册域 == HARBOR_MIRROR_REGISTRY), 不是硬编码名单; 要副本用 `--include-same-harbor`。
- **CI**: `.github/workflows/sync-images-to-harbor.yml`(push 清单 / 手动 / 每周定时);
  凭据走 GitHub **Secrets**(`HARBOR_MIRROR_USER` / `HARBOR_MIRROR_PASSWORD`, 密码必须放 Secret)。
  ⚠ 设密钥: `gh secret set NAME`(**省略 `--body`** 才读 stdin); `--body -` 会把字面量 `-` 存进去。
  ⚠ 凭证自检**别回显密码长度** —— public 仓库的 Actions 日志公开可见。
- 实测(2026-09-18): 全量同步 43min → 新同步 43 / digest 未变跳过 4 / 失败 0; 47 个镜像零漂移。
- ⚠ **5 个静默坑**(详见 troubleshooting §四.3): skopeo 默认 auth 文件路径不可读(显式设 `REGISTRY_AUTH_FILE`);
  `inspect` 用 `--tls-verify` 而 `copy` 用 `--src-tls-verify`(传错被 `2>/dev/null` 吞成"幂等失效");
  Harbor API repository 名要**双重 URL 编码** `%252F` 且不含项目前缀;
  `docker-archive:<file>` 末尾**必须带 `:<ref>`** 否则 RepoTags 为空;
  Harbor **项目**必须预建(仓库才自动建), 建项目需登录。
- ⚠ **加镜像时别忘了同步 `tools/offline/trim-offline-files.sh` 的 `PRELOAD_IMAGE_PATTERNS`**
  (k8s-base 组), 否则备料后被 trim 静默删掉 —— 用 `check-image-manifest.sh --kubespray` 兜底。
## 审查清单(写完脚本后自检)

- [ ] 文件名符合 `NN_category_action.sh`,序号不冲突
- [ ] 元数据头完整且格式正确(MODULE/DESC/PHASE/DEFAULT/REPEAT/TOGGLE/REQUIRES)
- [ ] `set -euo pipefail` + source lib-common + load_config
- [ ] 需要远端 kubectl 时已调用 `init_remote_kubectl || exit 1`(未手抄初始化块)
- [ ] REQUIRES 引用存在且无循环依赖
- [ ] 未硬编码 IP/密码/路径(全部来自 cluster.conf 变量)
- [ ] 开关类模块有 TOGGLE 检查
- [ ] 引用的工具脚本存在于 `tools/<领域>/` 且路径正确
- [ ] **(装 chart 的模块)chart 已 vendored 到 `cubestack-addon/<组件>/`(tgz 附 `.digest` 边车)且已 `git add`**
- [ ] **(装 chart 的模块)走 `helm_chart_ensure` 恒用本地副本;缺副本时 `err` 退出并给获取方法**
- [ ] **(改含内嵌远端脚本的文件)注释里没有 ASCII 双引号**(用全角 `“ ”`); 改完用 stub `ssh` 数参数个数, 确认载荷没被拆散
- [ ] `bash deployments/scripts/tools/check-modules.sh` exit 0(含第 ⑩ 项离线副本检查)
- [ ] `deploy-cluster.sh --list-steps` 能看到新模块
- [ ] 不影响其他模块(未改他人元数据/文件名)
