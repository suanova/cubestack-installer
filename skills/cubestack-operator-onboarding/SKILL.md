# CubeStack Operator 上架标准流程(Skill)

> 当需要**新增 / 替换 / 删除**一个集群 operator(组件)时, 使用本技能。
> 目标: 每个 operator 都按"现有模型"落地 —— 模块化脚本 + 单一配置源(`cluster.conf`) + 端到端验证 + 文档同步, 不破坏已有功能。
> 架构前提(必读): `docs/cluster-architecture.md` —— 网络固定 **Calico + IPIP**(proxy-ARP fabric), 含 webhook 的组件必须考虑跨节点可达。

## 何时使用本技能

- 新增组件(如 cert-manager / ingress-nginx / prometheus / keycloak / ceph 等);
- 替换现有组件或切换其网络/数据面方式;
- 添加一个需要离线镜像的 operator。

## 总原则

1. **不硬编码**: 任何 IP / 端口 / 路径 / 节点, 一律从 `cluster.conf` 读取或派生(sync 脚本负责落到 kubespray `group_vars`)。
2. **不破坏已有**: 只新增模块/配置, 不修改他人模块的元数据头。
3. **`cluster.conf` 为主, 职责三分**(新增/部署 operator 只记这套模型):
   - **全量部署**: `--with-cubestack` / 默认(无 flag) = 部署**基座 + cluster.conf 中已启用的全部 operator**; `--with-k8s` 仅部署 kubespray 基座(k8s + metallb/local-path/registry, 跳过全部 operator)。
   - **预启用(写配置)**: `--enable X` = **只把 `XXX_ENABLED=true` 写入 cluster.conf(持久化), 不部署**; 下次 `--with-cubestack` / 默认部署生效。
   - **立即部署单个**: `--steps X` = 部署被指定的 X(**自动带基座, 且只部署被指定的 operator, 不带出其它默认启用的**); `--steps verify` = 只跑全部验证模块。
   - **排除**: `--skip X` = 全量部署时剔除。
   **必须**: 新增 operator **无需改任何列表** —— operator 由框架自动派生(有 `TOGGLE` 且不在 `BASE_MODULES`(k8s_deploy/k8s_scale/metallb/local_path/k8s_registry)即 operator), 写 TOGGLE 即自动进入 --steps/--enable 调度。
4. **必须能离线**: 新增镜像进离线仓库 + `PRELOAD_IMAGE_PATTERNS`, 节点预加载。
5. **必须可验证**: 每个 operator 配套 `verify_<name>.sh` 端到端验证(不只 pod Running)。
6. **必须沉淀文档**: 架构文档 + troubleshooting + 本技能, 三处同步。

---

## 1. 设计(动手前先想清楚)

回答四个问题, 答案决定落地方式:

| 问题 | 影响 |
|---|---|
| 它需要访问跨节点 pod/网络吗?(webhook/回调/数据面) | 决定是否受 fabric 限制(见 `docs/cluster-architecture.md` §2) |
| 它需要 LoadBalancer 吗? | 走 MetalLB(池在 `METALLB_POOL`), 分配 VIP |
| 它需要持久化吗? | local-path-provisioner(需 `LOCAL_PATH_ENABLED=true`)或外部存储 |
| 它有没有 Webhook/Admission? | 跨节点 webhook 需走 IPIP 数据面; 部署若超时先查 `troubleshooting.md` |

---

## 2. 落地脚本(5 步)

### 2.1 配置开关进 `cluster.conf`(+ `cluster.conf.example`)
```bash
# ---------------- XXX 组件(说明) ----------------
XXX_ENABLED="${XXX_ENABLED:-false}"    # 默认 false; --with-cubestack 按此部署全部启用; --enable 写 true; 立即部署用 --steps
XXX_IP="${XXX_IP:-10.66.1.140}"         # 需要的外部 IP/端口从配置读, 勿硬编码在脚本
```
> 规范: **`cluster.conf` 为主, `XXX_ENABLED=true` 才启用**(默认 false, 基座 addon metallb/local-path/registry 除外, 默认 true)。
> - `--with-cubestack`/默认 = 基座 + cluster.conf 中为 true 的**全部** operator; `--with-k8s` = 仅基座(跳过全部 operator)。
> - `--enable X` = 只写 `XXX_ENABLED=true` 到 cluster.conf(持久化), **不部署**; 下次 --with-cubestack 生效。
> - `--steps X` = 立即部署被指定的 X(**自动带基座; 只部署被指定的 operator**); `--steps verify` = 只跑验证模块。
> - `--skip X` = 全量部署时排除。
> **必须**: 新增 operator 无需改任何列表 —— 框架自动派生(有 `TOGGLE` 且非 `BASE_MODULES` 即 operator), 写 TOGGLE 即自动进入调度。
> 未实现的占位模块(addon_stub)保持 `false`。

### 2.2 写部署模块 `deployments/scripts/modules/<PHASE>/NN_<name>.sh`
- `PHASE`: env / k8s / addon;
- 元数据头(MODULE/DESC/PHASE/DEFAULT/REPEAT/TOGGLE/REQUIRES)—— 参考 `modules/03_addon/21_verify_metallb.sh` 头部;
- `set -euo pipefail` + `source lib-common.sh` + `load_config`;
- 需要 SSH 到 master 执行 kubectl 时**必须** `init_remote_kubectl || exit 1`(幂等; 禁止手抄初始化块);
- 若组件由 kubespray 管理, 用 `TOGGLE: XXX_ENABLED` 并保持 DEFAULT:0;
- **REPEAT 语义**: 重型安装模块用 `REPEAT: 0`(断点续跑 —— 完成后写状态跳过, `--fresh` 清状态重装);
  幂等快速检查类(metallb/local_path/k8s_registry/verify_*)用 `REPEAT: 1`(每次执行)。
- 依赖其他模块时声明 `REQUIRES: <key1> [key2...]`(框架自动拓扑排序, 循环/未知引用会报错);
- 若需额外前置(如 Harbor/Registry), 单独模块, 不塞进现有模块。
- 完成后跑 `bash deployments/scripts/tools/check-modules.sh` 静态校验(必须 exit 0)。

### 2.3 需要同步 kubespray group_vars 时
- 改 `deployments/scripts/tools/k8s/sync-kubespray-config.sh` 增加一节, 从 `cluster.conf` 派生写入对应 `group_vars/*.yml`(幂等, 用 `sed`/`python`, 与现有节风格一致);
- **改完跑一次 sync 验证**输出, 并确认默认路径不改变既有行为。

### 2.4 离线镜像预加载
- 镜像 tar 放进 `${OFFLINE_FILES_DIR}/<集群>/images/`(默认 `deployments/offline-files/kubespray/<集群>/images/`);
- 在 `cluster.conf` 的 `PRELOAD_IMAGE_PATTERNS` 加匹配项(文件名包含匹配)。

### 2.5 写 `verify_<name>.sh`(端到端验证模块)
复制 `modules/03_addon/21_verify_metallb.sh` 为模板, 只改 MODULE/DESC 与验证逻辑:
- ① 组件 pod Ready → ② 核心 CR/资源存在 → ③ 建测试资源(用已预加载镜像, 如 busybox)
  → ④ 等待关键状态(如分配 VIP / Ready)→ ⑤ **真实功能访问**(curl VIP / 调 API / 查数据)→ ⑥ trap 清理;
- ⚠ **不设 TOGGLE**(否则组件开关=true 时会被安装流程自动启用), 保持 DEFAULT:0, 仅 `--steps verify_<name>` 执行;
- 数据源全部从 `cluster.conf` 读(`load_config`)。

### 2.6 安装方式选择(bundle vs helm)
- **默认用官方 manifests bundle + `kubectl apply --server-side`**(参照 LWS: `deployments/cubestack-addon/lws/manifests.yaml`,
  单文件含 namespace/CRD/RBAC/controller/webhook; 离线 vendoring 到 `deployments/cubestack-addon/<op>/`; 镜像用 sed 改到内置 registry)。
- **CRD 超大时不用 helm**: CRD 的 `openAPIV3Schema` 会塞进 helm release Secret, 超 1MiB 报 `Secret is invalid: data: Too long`。
  (LWS 的 leaderworkersets ~1.3MB / disaggregatedsets ~1.5MB 即此因, 官方因此弃 helm 推 bundle。)
- **helm 仅保留给需要 values 定制 / cert-manager 等 bundle 覆盖不了的模式**: chart 放 `deployments/cubestack-addon/<op>/charts/`,
  模块内用 `XXX_INSTALL_MODE`(默认 bundle)切, 并把 CRD 放 `charts/.helmignore` 排除 + kubectl 逐文件 apply。
- 模块内双模式写法参考 `modules/03_addon/05_gpu_lws.sh`(LWS_INSTALL_MODE / LWS_MANIFEST / LWS_CHART_DIR)。

---

## 3. 文档同步(强制, 四选三必做)

| 文档 | 更新内容 |
|---|---|
| `docs/cluster-architecture.md` | §5 operator 表加一行(作用/架构原理/为何采用/部署入口) |
| `docs/troubleshooting.md` | 按模板加条目: 症状 → 根因 → 解法(根治) → 验证 → 相关命令; 根因以证据为准 |
| `skills/cubestack-deploy-scripts/SKILL.md` | 沉淀新命令/知识点到相应章节 |
| `README.md`(如有组件清单) | 组件列表补充 |

> 规范: 只有**真正端到端验证过**的方案才能写进文档作为"解法", 未验证必须如实标注边界。

---

## 4. 审查清单(写完自检)

- [ ] 文件名符合 `NN_<name>.sh`, 序号不与现有冲突(`ls deployments/scripts/modules/`)
- [ ] 元数据头完整(MODULE/DESC/PHASE/DEFAULT/REPEAT/TOGGLE/REQUIRES)
- [ ] 需要远端 kubectl 时已调用 `init_remote_kubectl || exit 1`(未手抄初始化块)
- [ ] REQUIRES 依赖引用存在且无循环
- [ ] `bash deployments/scripts/tools/check-modules.sh` exit 0
- [ ] `set -euo pipefail` + source lib-common + load_config
- [ ] 未硬编码 IP/密码/路径(全部来自 cluster.conf)
- [ ] `deploy-cluster.sh --list-steps` 能看到新模块
- [ ] 离线镜像已进仓库 + PRELOAD 已加
- [ ] `verify_<name>.sh` 能 `--steps` 单独跑通(端到端)
- [ ] 三个文档已同步(架构/troubleshooting/SKILL)
- [ ] 默认路径回归: 不改变现有组件行为

---

## 5. 常用命令

```bash
sudo ./deployments/scripts/deploy-cluster.sh --steps <组件>            # 立即部署指定组件(自动带基座, 只部署指定的)
sudo ./deployments/scripts/deploy-cluster.sh --enable <组件>           # 只写 cluster.conf 预启用(不部署, 下次全量生效)
sudo ./deployments/scripts/deploy-cluster.sh --with-cubestack           # 部署基座 + 全部启用的 operator
sudo ./deployments/scripts/deploy-cluster.sh --steps verify_<组件>      # 端到端验证
sudo ./deployments/scripts/deploy-cluster.sh --list-steps               # 查看全部模块
bash deployments/scripts/tools/k8s/sync-kubespray-config.sh             # 同步 group_vars(改 sync 后必跑)
```
