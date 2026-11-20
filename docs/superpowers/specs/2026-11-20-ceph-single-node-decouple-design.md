# 单节点 Ceph 与 Ceph 模式变量重构 — 设计文档

- 日期: 2026-11-20
- 分支: `single-node-ceph`
- 状态: 已评审，待实现
- 关联技能: cubestack-deploy-scripts / cubestack-addon-module

## 1. 背景与目标

当前 Ceph 部署只支持多节点 Rook-Ceph（`CEPH_MIN_NODES=3`、mon=3、pool size=3/host 故障域），
单节点/少节点集群直接跳过 CephCluster，且 Ceph 启停由 `CEPH_ENABLED` + `CEPH_CSI_ENABLED`
两个变量共同控制、大小写敏感、条件不足时默认硬失败。本设计要达成:

1. 不改变现有**多节点** Ceph 部署流程/行为的前提下，新增独立的**单节点** Ceph 部署脚本。
2. 单节点同样创建 Ceph CSI 的 RBD / CephFS / RGW 资源与默认 StorageClass，名称和语义与多节点一致。
3. Ceph 集群相关脚本按拓扑解耦: 共享原语下沉，单/多节点各自独立编排。
4. 单节点与多节点都支持优雅卸载与覆盖安装。
5. Ceph 配置收敛为**单一变量 `CEPH_MODE`**（none / external / internal），值大小写不敏感。
6. 不满足 Ceph 安装条件时**默认**安装 local-path provisioner。

## 2. 配置模型

### 2.1 变量

| 变量 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `CEPH_MODE` | `none` / `external` / `internal` | `none` | 唯一启停开关。`none`=不装 Ceph 也不装 CSI；`external`=只装 Rook operator/ceph-csi 并接入外部 Ceph；`internal`=集群内 Ceph + CSI |
| `CEPH_TOPOLOGY` | `auto` / `single` / `multi` | `auto` | `auto`: 存储节点=1→single，≥3→multi；2 节点视为不满足。显式值不匹配拓扑时按“条件不足”处理 |
| `CEPH_FALLBACK_TO_LOCALPATH` | bool | `true` | 条件不足时回退 local-path；设 `false` 恢复硬失败 |
| `CEPH_MIN_NODES` | int | `3` | 仅 multi 使用；single 忽略 |
| `CEPH_POOL_FAILURE_DOMAIN` | 空 / `host` / `osd` | 空=auto | auto: multi→host，single→osd |
| `CEPHFS_MDS_ACTIVE_COUNT` | 空 / int | 空=auto | auto: multi→2，single→1 |
| `CEPHFS_MDS_ACTIVE_STANDBY` | 空 / bool | 空=auto | auto: multi→true，single→false |
| `CEPH_RGW_INSTANCES` | 空 / int | 空=auto | auto: multi→2，single→1 |

既有 Ceph 参数（`CEPH_NODES`、`CEPH_NODE_ROLE`、`CEPH_POOL_REPLICAS`、`CEPH_POOL_MIN_SIZE`、
`CEPHFS_ENABLED`、`CEPH_RGW_ENABLED`、`CEPH_*` 等）保留。

### 2.2 删除旧开关

`CEPH_ENABLED` / `CEPH_CSI_ENABLED` 从 `cluster.conf.example`、`cluster.defaults.conf`、
全部脚本、文档和测试中移除。所有代码改用 `CEPH_MODE` 或派生的有效参数。

**旧配置自动迁移**（`load_config`）:

- 检测 cluster.conf 中仍存在的 `CEPH_ENABLED` / `CEPH_CSI_ENABLED`，黄色告警“已弃用”。
- `CEPH_MODE` 未显式设置时按组合映射:
  - `CEPH_ENABLED=true` + `CEPH_CSI_ENABLED=true` → `internal`
  - `CEPH_ENABLED=false/未设` + `CEPH_CSI_ENABLED=true` → `external`
  - `CEPH_ENABLED=true` + `CEPH_CSI_ENABLED=false/未设` → `internal`（CSI 一并启用，warning 说明行为变化）
  - 其余 → `none`
- `CEPH_MODE` 显式设置时以它为准，旧值仅告警忽略。
- 映射后 `unset` 旧变量，任何代码不再读取。

### 2.3 大小写与布尔归一化

- 枚举值: `tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'`；`NOne`/`None`/`NONE` 均等价。
- 布尔值: 统一为 `true`/`false`；接受 `true/TRUE/True/1/yes/YES/on/ON/y` 与
  `false/FALSE/False/0/no/NO/off/OFF/n`；未知值 → 警告并按默认值处理。
- 归一化对象: `CEPH_MODE`、`CEPH_TOPOLOGY`、所有 `CEPH_*` 布尔变量、
  `CEPH_DATA_DISK_POLICY`、`CEPH_EXPOSE_MODE`、`CEPH_EXTERNAL_EXPOSE_MODE`、
  `CEPH_RGW_EXPOSE_MODE` 等枚举值。
- `bool_is_true()` 改为大小写不敏感（全局安全改进）。

### 2.4 模块调度（枚举 TOGGLE）

模块框架新增枚举 TOGGLE 语法:

```bash
# TOGGLE: CEPH_MODE=internal,external
```

- `module_default_on`: 逗号分隔的任一值与当前变量值（lowercase）相等即启用。
- `--enable ceph` / `--enable ceph_csi` 写 `CEPH_MODE=internal`（列表第一个值）。
- **不自动导出**: `--steps ceph` 在 `CEPH_MODE=none` 时不静默打开 Ceph（防误触发磁盘清理），
  只打印指引；用户需 `--enable ceph` 或显式改配置。
- `check-modules.sh` ⑦ 按 `VAR=values` 拆分后校验 `VAR` 已声明。
- `MODULE_ALIAS[ceph_single]=ceph`，`--steps ceph_single` 等价 `--steps ceph`。

## 3. 拓扑与有效参数

`ceph_topology_resolve` 输出 `CEPH_TOPOLOGY_EFFECTIVE`；`ceph_effective_spec` 输出:

| 参数 | multi | single |
|---|---|---|
| 存储节点 | ≥ `CEPH_MIN_NODES`(3) | 恰好 1 |
| `CEPH_EFF_MON_COUNT` | `CEPH_MON_COUNT`(3) | 1（显式 >1 警告并强制 1） |
| `CEPH_EFF_MGR_COUNT` | `CEPH_MGR_COUNT`(2) | 1（可覆盖） |
| `CEPH_EFF_POOL_REPLICAS` | `CEPH_POOL_REPLICAS`(3) | 1（可覆盖，需 ≤ OSD 数） |
| `CEPH_EFF_POOL_MIN_SIZE` | `CEPH_POOL_MIN_SIZE`(2) | 1（可覆盖，≤ replicas） |
| `CEPH_EFF_FAILURE_DOMAIN` | `host` | `osd` |
| `CEPH_EFF_REQUIRE_SAFE_REPLICA_SIZE` | true | size=1 时 false，否则 true |
| `CEPH_EFF_MDS_ACTIVE_COUNT` | 2 | 1 |
| `CEPH_EFF_MDS_ACTIVE_STANDBY` | true | false |
| `CEPH_EFF_RGW_INSTANCES` | 2 | 1 |

校验:

- `CEPH_MODE=external` 不做拓扑解析（不建本地集群）。
- `auto` + 0/2 节点 → 不满足（回退或硬失败）。
- 显式 `single` 要求 `CEPH_NODES`/角色选出的存储节点恰好 1 台。
- 显式 `multi` 要求节点数 ≥ `CEPH_MIN_NODES`，且 `CEPH_EFF_MON_COUNT` ≤ 节点数。
- single: `CEPH_EFF_POOL_REPLICAS` ≤ 该节点可用 OSD 盘数（显式覆盖时校验）。
- multi: 磁盘节点数 ≥ `CEPH_EFF_POOL_REPLICAS`（沿用现有校验）。

## 4. 脚本解耦

### 4.1 文件布局

| 文件 | 职责 |
|---|---|
| `deployments/scripts/lib-common.sh` | 配置归一化、legacy 映射、`ceph_topology_resolve`、`ceph_apply_effective_spec`、扩展 `ceph_installable_check`（真实磁盘/lvm2/根盘探测） |
| `deployments/scripts/modules/03_addon/02_ceph.sh` | `ceph_engine_uninstall`（live-state 卸载）+ `ceph_engine_main`（共享 Rook 部署引擎）+ 模式门禁/拓扑分发；multi 编排保留原步骤/命令 |
| `deployments/scripts/tools/k8s/ceph-single-node.sh`（新） | 单节点独立入口：校验拓扑、设置单节点 profile、调用共享引擎（可独立执行；由 `02_ceph.sh` exec） |
| `deployments/scripts/modules/03_addon/03_ceph_csi.sh` | 读取有效参数，按拓扑渲染内部资源；external 分支不变 |
| `deployments/cubestack-addon/rook/{rbd,cephfs,rgw}/*.yaml` | 新增拓扑模板占位符 |
| `cluster.conf.example` / `cluster.defaults.conf` | 移除旧开关，声明新变量 |
| `lib-module.sh` / `check-modules.sh` | 枚举 TOGGLE 支持与校验 |

> **实现修订（2026-11-20，用户确认）**：单节点不复制/重写 Rook 部署逻辑，而是作为独立入口
> **复用同一套 `ceph_engine_main` 引擎**，仅通过 profile 参数区分（mon/mgr/副本/故障域）。
> 因此不需要 `tools/k8s/lib-ceph.sh`；单/多节点差异由配置和拓扑驱动，消除两份逻辑漂移风险。
> 多节点行为零改动（引擎函数体保持原步骤/命令）。

### 4.2 02_ceph.sh 分发

```
load_config
→ CUBESTACK_CEPH_ENGINE_ONLY=1（被单节点脚本 source）→ 只定义函数，不执行入口
→ uninstall → ceph_engine_uninstall（live-state，单/多通用）
→ CEPH_MODE=none → 跳过
→ CEPH_MODE=external → ceph_engine_main（仅 operator/CSI operator）
→ CEPH_MODE=internal:
    ceph_topology_resolve
    single → exec bash tools/k8s/ceph-single-node.sh
    multi  → ceph_apply_effective_spec multi; ceph_engine_main（原流程）
```

### 4.3 引擎参数化要求

`ceph_engine_main` 只依赖变量，不假设节点数量:

- `CEPH_MON_COUNT` / `CEPH_MGR_COUNT` / `CEPH_POOL_REPLICAS` / `CEPH_POOL_MIN_SIZE`
- `CEPH_MIN_NODES`（单节点=1）
- `CEPH_EFF_FAILURE_DOMAIN`（磁盘数校验与确认屏展示）
- `ceph_engine_uninstall` 供 02 与单节点脚本共用。
- 单节点脚本负责把 `ceph_apply_effective_spec single` 的 `CEPH_EFF_*` 写入上述变量。

## 5. 单节点部署流程

`tools/k8s/ceph-single-node.sh`（`CUBESTACK_MODULE_ACTION=uninstall` 时调用 `ceph_engine_uninstall`）:

1. 门禁: `CEPH_MODE=internal` 且存储节点恰好 1 台。
2. `ceph_apply_effective_spec single`，把有效参数写入 `CEPH_MON_COUNT/MGR/REPLICAS/MIN_SIZE`，`CEPH_MIN_NODES=1`。
3. 调用 `ceph_engine_main`（与多节点共用）:
   - 磁盘选择: `CEPH_DATA_DISKS` 显式优先；否则 `ceph-detect-disks.sh --classify` 取 `free ∪ ceph`；
     无可用盘 → 报错退出（预检阶段应已回退 local-path）。
   - 节点准备: rbd 模块持久化、nbd 清理、lvm2 检查、打 `CEPH_NODE_LABEL`、
     `CEPH_ENABLE_MASTER_SCHEDULE=true` 时移除 control-plane taint。
   - 镜像就绪检查（与多节点一致，k8s 阶段预载）。
   - Rook operator / csi-operator 安装。
   - 已有集群: live-state 检测；pre-clean=true → `ceph-cleanup --delete-cluster`；
     false → 保留数据、认领旧 OSD。
   - 生成 CR: `mon.count=1`、`mgr.count=1`、storage 使用该节点磁盘、placement 与多节点一致。
   - toolbox 就绪；`osd_pool_default_size=CEPH_EFF_POOL_REPLICAS`、
   `osd_pool_default_min_size=CEPH_EFF_POOL_MIN_SIZE`。
10. 健康等待: `HEALTH_OK` 且 OSD ≥ `CEPH_EFF_POOL_REPLICAS`；nbd 恢复、rbd 残留清理、调优同多节点。
11. 恢复停机消费者；`record_installed_component "ceph"`。

## 6. CSI 供给层

- 单节点与多节点创建**相同资源集合**:
  - `CephBlockPool rbd-pool`（拓扑化副本/故障域）
  - `ceph-rbd-ephemeral`（**默认 SC**）、`ceph-rbd-ephemeral-immediate`、`ceph-rbd-durable`、`ceph-block`
  - `CephFilesystem cephfs` + `cephfs-ephemeral` / `cephfs-durable` + subvolume groups
  - `CephObjectStore s3-store` + `rgw-model-admin` / `rgw-model-reader`
- 仅替换模板参数:
  - `__FAILURE_DOMAIN__`
  - `__REQUIRE_SAFE_REPLICA_SIZE__`
  - `__MDS_ACTIVE_COUNT__`
  - `__MDS_ACTIVE_STANDBY__`
  - `__RGW_INSTANCES__`
- SC 名称、参数（除拓扑化的 pool 参数外）、默认标记不变。
- RGW 在 internal 模式仍不创建 bucket SC（与多节点一致）；external 路径完全不变。

## 7. 优雅卸载与覆盖安装

- 单节点复用模块键 `ceph`，因此:
  - `cluster-teardown.sh` 的 `UNINSTALL:1` 发现、`ceph` 压轴排序、计划门禁、
    1800s 超时、`record_installed_component` 登记全部无需改键。
  - `ceph_csi` 删除同一组 SC；`cephfs_mount` 逐节点 umount（单节点只有 1 台）。
- 覆盖安装: single↔multi 切换时由同一 pre-clean 安全序销毁旧集群并清盘；
  `CEPH_PRE_CLEANUP_EXISTING=false` 保留数据认领。日志明确提示拓扑变化。
- 修复现有缺陷:
  - `< CEPH_MIN_NODES` 跳过集群时不再进入 600s `ceph -s` 健康等待。
  - teardown 计划门禁基于**回退后的有效模式**；回退运行不会把 `ceph` 当作在计划内而误删数据。

## 8. local-path 回退（默认开启）

- `CEPH_FALLBACK_TO_LOCALPATH` 默认 `true`，对 internal 与 external 均生效。
- `ceph_installable_check` 扩展为真实探测:
  - external: `CEPH_EXTERNAL_ENV_FILE`（或默认 `external-ceph.env`）必须含
    `ROOK_EXTERNAL_FSID/MON_DATA/USERNAME/USER_SECRET`；手填路径要求
    `CEPH_MONITORS/CEPH_USER/CEPH_KEYRING`，CephFS 凭据成对。
  - internal: Rook manifest 存在；拓扑节点数满足；逐节点磁盘探测（`free ∪ ceph` ≥ 需求）；
    lvm2 可用；根盘可用空间 ≥ `CEPH_NODE_MIN_FREE_GB`、无 DiskPressure。
  - `CEPH_DATA_DISKS` 显式指定时跳过磁盘探测（仍做格式/节点校验）。
  - 探测失败（SSH 不可达等）视为条件未知 → 不满足并明确指出“无法确认”。
- 执行时点: `ensure_node_ssh_access` 之后、优雅覆盖/teardown **之前**。
- 回退动作:
  - 本次运行 `CEPH_MODE=none`（仅运行时，不写回配置）
  - `REGISTRY_STORAGE_CLASS=local-path`、`LOCAL_PATH_ENABLED=true`
  - **重新解析 `RUN_STEPS`**（纳入 `local_path`，移除 ceph 相关模块）
  - 红底横幅列出不满足项与恢复方法
- 已知边界: k8s 基座已部署且未安装 local-path 时，回退后 `04_local_path`
  给出明确修复指引（重跑基座/手工补 addon），不静默成功。

## 9. 测试

新增:

- `tools/tests/test-ceph-mode-topology.sh`
  - `None/NOne/NONE` 归一化、未知值报错
  - legacy 映射四种组合、显式 CEPH_MODE 优先
  - 拓扑解析: 1→single、3/5→multi、0/2→不满足、显式 single/multi 校验
  - 有效参数表（mon/mgr/replicas/min_size/failureDomain/MDS/RGW）
- `tools/tests/test-ceph-single-node.sh`
  - 单节点 CR: mon=1、mgr=1、storage nodes/devices 正确
  - 无盘 → 非零退出；有 `ceph` 残留盘 → 复用
  - 卸载分支存在且调用 `ceph-cleanup`
- `tools/tests/test-ceph-csi-topology.sh`
  - 单节点渲染 `failureDomain: osd`、`requireSafeReplicaSize: false`、
    `activeCount: 1`、`activeStandby: false`、`instances: 1`
  - 多节点渲染保持 3/2/host/true/2/2
  - SC 名称与默认标记不变

扩展:

- `test-cluster-teardown.sh`: 回退计划不含 `ceph`；单节点仍走 `ceph` 压轴。
- `test-ceph-placement.sh`: 共享 placement 函数路径更新。

门禁:

- 所有改动脚本 `bash -n`
- `bash deployments/scripts/tools/check-modules.sh` exit 0
- `deploy-cluster.sh --list-steps` 显示 `ceph` / `ceph_single` 别名

## 10. 兼容性与风险

- 多节点流程保持现有步骤、顺序、命令；共享原语抽取以“输出逐字节等价”为验收条件。
- 删除旧开关是破坏性配置变更，但有自动映射 + 弃用警告；`cluster.conf.example` 不再出现旧变量。
- 单节点为降级可靠性拓扑（无跨主机冗余），文档需明确标注。
- 回退默认开启可能让“本来期望 Ceph 的部署”降级为 local-path；用红底横幅 + 明确恢复步骤降低风险。
- 破坏性磁盘清理仍受 `CEPH_CONFIRM_SLEEP` 与 `CEPH_PRE_CLEANUP_EXISTING` 控制，行为不变。

## 11. 验收标准

1. `CEPH_MODE=internal` + 单节点集群 → 自动走单节点脚本，Ceph HEALTH_OK，RBD/CephFS/RGW SC 与多节点同名。
2. `CEPH_MODE=external` → 不创建本地 CephCluster，仅 CSI。
3. `CEPH_MODE=none` → 不调度任何 Ceph 模块，local-path 默认 SC 就绪。
4. `CEPH_MODE=NOne`、`CEPH_TOPOLOGY=Single` 等大小写混写均生效。
5. 旧配置 `CEPH_ENABLED=true`/`CEPH_CSI_ENABLED=true` 仍能部署并给出弃用警告。
6. 单节点无空闲裸盘 → 自动回退 local-path，部署不中断。
7. `cluster-teardown.sh --uninstall` 对单/多节点 Ceph 都能优雅卸载；覆盖安装不误删 non-plan Ceph 数据。
