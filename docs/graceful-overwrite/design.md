# 优雅覆盖安装设计（--fresh 登记 + 反序卸载）

> 状态: 已定稿（2026-10-11 用户确认）  ·  实施计划见同目录 plan.md  ·  用户文档见同目录 README.md
> 口径来源: 用户 2026-10-11 需求 —— "如果集群能够安装成功并且能够访问集群，记录和检查当前安装
> 哪些 operator；当卸载和覆盖 ceph 集群的时候，根据安装的顺序和安装的状态，反序卸载 operator，
> 然后进行 ceph 集群的清理和 Kubernetes 集群的覆盖，实现优雅的覆盖重新安装，而不是暴力卸载和覆盖安装。"

## 1. 背景与问题

现状 `--fresh` = 清本地断点状态 + 照常全量跑，覆盖路径上的"暴力点"：

1. **没有任何"装过什么"的登记**：本地 `.deploy.state` 只有 `key=done`，`--fresh` 一清就没；
   换新容器更是零信息。K8s 覆盖（kubeadm reset）时集群上跑着哪些 operator、什么顺序装的，
   无人知晓。
2. **顺序颠倒的拆除**：kubeadm reset 直接推平一切；Ceph 由部署预检块调 `ceph-cleanup.sh
   --delete-cluster`（含 2026-10-10 新增的 ⓪ 停卷消费者 + 官方安全序），但**其他 operator
   （cubestack-operator/metax GPU/multus/rdma…）没人先停**——它们持有的资源、在飞 IO、
   级联控制器，正是 10-09 挂死事故的同类风险面。
3. 2026-10-10 事故链的教训已经证明：覆盖安装必须"先停消费者 → 再动 ceph → 再动 K8s"，
   而这个顺序目前只对 ceph PVC 的消费者**部分**实现（⓪ 泛化扫描兜底），且发生在 ceph 删除时刻，
   晚于所有 operator 的停止。

## 2. 目标与关键决策

**目标**：`--fresh`（及一切真正覆盖的场景）执行前，先读取"安装登记"，按**首装顺序反序**逐个
**优雅卸载**已安装组件（完整卸载：优雅停 → helm uninstall/删 CR → 残留清理），再清理 Ceph，
最后 K8s 覆盖。全程告警不阻断 —— 与"覆盖安装必成功"口径一致（详见
`docs/graceful-overwrite` 用户文档与 10-10 会话记忆）。

**用户确认的三个关键决策**（2026-10-11）：

| 决策 | 选择 |
|---|---|
| 登记位置 | **集群内 ConfigMap**（随集群走；--fresh 清本地状态/新容器都能读到） |
| 触发范围 | **一切真正覆盖的场景**（k8s_deploy 实际将执行 且 集群可达）——覆盖 --fresh、新容器默认全量、--steps k8s_deploy |
| 卸载力度 | **完整卸载**（先优雅停，再 helm uninstall/删除资源；ceph 复用 ceph-cleanup 官方安全序） |

**架构方案**（用户确认方案 A）：

- **模块自持卸载能力**：每个已实现组件模块在自己文件内增加"卸载段"（头部 `# UNINSTALL: 1`
  声明；`CUBESTACK_MODULE_ACTION=uninstall` 进入）。各组件命名空间/Release/CR 全部来自
  cluster.conf 且各不相同，只有模块自己算得准。
- 新编排工具 `cluster-teardown.sh` 只做：读登记 → 算拆序 → 逐组件调用其模块卸载段 → 汇总。
- 登记缺失（存量集群/旧版本装的）→ **降级路径**：对全部已知组件按模块文件序反排（= 静态依赖序的
  合法拆序），各模块卸载段内部先做存在性检查、不存在则跳过（天然幂等）。

## 3. 详细设计

### 3.1 安装登记（写侧）

- **载体**：ConfigMap `cubestack-install-record`，namespace `kube-system`（恒存在；随 etcd 消亡，
  K8s 覆盖后无残留）。data 单键 `record.json`：

```json
{"schema":1,"cluster":"<CLUSTER_NAME>","components":[
  {"key":"metallb","seq":1,"firstInstalledAt":"2026-10-11T02:00:00Z","lastSeenAt":"...","status":"done"}
]}
```

- **函数**：lib-common.sh 新增 `record_installed_component <key>`：
  - 读 CM（`SSH "${K} -n kube-system get cm cubestack-install-record -o json`，不存在则从
    `{"schema":1,"components":[]}` 起步）→ python3 合并 → `SSH "${K} apply -f -"` 回写。
  - **seq = 首装顺序**：新组件 seq = 现存 max+1；**已存在则保留原 seq**（REPEAT:1 模块重跑不改
    首装序——"按安装顺序反序"的正确语义），只更新 `lastSeenAt`/`status`。
  - 幂等；**任何失败仅 warn，绝不阻断安装**（登记是增强，不是依赖）。`K` 未初始化时直接跳过。
- **调用点**：各模块在**安装成功点**显式调用（不用框架自动钩子——模块自我跳过 TOGGLE=false /
  ceph 存储节点不足等情形不落登记，语义精确）。约 10 处：`01_metallb`、`04_local_path`、
  `05_k8s_registry`、`02_ceph`、`03_ceph_csi`、`06_gpu_operator`、`09_multus`、
  `10_rdma_shared_dev_plugin`、`25_cubestack_operator`、`35_netshoot`。
- 登记内容 = "operator"广义集（本安装器部署进集群的全部组件，含 kubespray addon 类基座）。
  用户手工 kubectl 部署的第三方负载不在登记内（ceph 消费者兜底仍由 ceph-cleanup ⓪ 泛化扫描覆盖）。

### 3.2 卸载接口（模块侧）

- 头部元数据新增可选 `# UNINSTALL: 1`（check-modules 静态校验，见 §3.5）。
- 模块内模板（**必须位于 TOGGLE 跳过之前**——模块现在被关掉、但集群里装着旧版，仍要能卸；
  卸载段自带所需变量派生与 `init_remote_kubectl`，不依赖安装路径的变量块）：

```bash
# 卸载分支(优雅覆盖): 由 cluster-teardown.sh 以 CUBESTACK_MODULE_ACTION=uninstall 调用
if [ "${CUBESTACK_MODULE_ACTION:-install}" = "uninstall" ]; then
    init_remote_kubectl || exit 1
    _uninstall_component   # 存在性检查 → 优雅停 → 卸载 → 残留清理; 幂等/有界/告警不中止
    exit 0
fi
```

- **各组件卸载动作**（现实清单）：

| 组件 | 卸载动作 | 备注 |
|---|---|---|
| cubestack_operator | 删 clusterCR（operator 级联优雅收掉 9 个平台组件）→ **有界等待 csc CR 本体终结（finalizer 完成的契约信号；非 Pod 计数）** → `helm uninstall` operator → 清残留 CRD/命名空间 | 先 CR 后 operator：CR 的 finalizer 需要 operator 活着处理。⚠ 2026-10-13(CodeRabbit): 等待门原先用 Pod 计数(Running 视为已收敛→首轮即放行, 等于没等); CR 未终结则**保留 operator(不 helm uninstall)** + **跳过** ns finalizer 清除/强制删 ns/CRD 清理(防 force-finalize 孤儿对象在重装后复活)并**非 0 退出**(引擎不标 uninstalled) |
| gpu_operator (metax) | 复用现有"清理残留"序列（提为函数，安装/卸载共用）：删 clusteroperator CR → helm uninstall → 删 CRD/ClusterRole/ns/default 旧资源 | 现安装路径 376-390 行就是这套 |
| multus | 删 vendored manifest 资源（DS/CRD/RBAC）+ 本模块创建的示例 NAD | |
| rdma_shared_dev_plugin | 删 DS + ConfigMap | RDMA_NAMESPACE 可配 |
| netshoot | 删 Pod + CM | |
| ceph（含 ceph_csi） | 调 `ceph-cleanup.sh`：`CEPH_PRE_CLEANUP_EXISTING=true`（默认）→ **完整安全序: 停消费者 → 删 Bound ceph PVC(触发 unmap) → 删 nodeplugin → 销毁集群与磁盘数据**；`false`（恢复/认领路径）→ **保留模式(--keep-pvcs): 只停消费者; PVC、nodeplugin、集群、OSD 与卷数据全部保留** | ceph 模块的卸载段是唯一真实动作方；ceph_csi 不设卸载段（SC 等对象随覆盖消亡），仅登记。⓪ 停消费者对 registry(`rs/registry`) / cubestack-operator 停机前登记原副本数(注解 `cubestack.io/pre-stop-replicas`), 02_ceph.sh 7.9 按登记值恢复(2026-10-13, CodeRabbit: 仅恢复被本工具停过且带标记的对象) |
| k8s_registry | 只优雅停机（对 **`rs/registry`(kubespray 建的裸 ReplicaSet, 非 Deployment)** scale 0；停机前以注解 `cubestack.io/pre-stop-replicas` 登记原副本数；registry-pvc 受保护不动；K8s 重装由 kubespray apply 自带恢复，K8s 保留路径由 02_ceph.sh 7.9 按登记值恢复） | ⚠ 2026-10-13 修订: 旧代码操作 `deploy registry` 从未命中(实机即 RS), 停机/恢复全部静默空转 |
| metallb / local_path | 无动作（kubespray 资产，随 K8s 覆盖消亡；登记仅作信息） | |

- ceph-cleanup.sh 配套改造：把 delete_cluster 里的 ⓪ 停消费者块**提取为独立函数/动作**
  （`--stop-consumers [--keep-pvcs]`），使"仅停止、不销毁"（默认含 unmap；PRE_CLEANUP=false 路径走
  `--keep-pvcs` 保留模式，不删 PVC/不 unmap）可独立调用；
  现有 `--delete-cluster` 行为不变。工作区中未提交的 delrs/delcr 修复（裸 RS/CR 直管 Pod
  的处理）保留并作为其一部分。
- **异常退出兜底**（2026-10-13, CodeRabbit）：停机(scale 0 + 标注原副本数)后若整轮部署**异常退出**
  （模块失败/超时/Ctrl-C，7.9 不会执行），由 `deploy-cluster.sh` 的 **EXIT 钩子**（仅非 0 退出，
  且仅计划含 ceph/k8s_deploy 时挂；INT/TERM 转发保证 Ctrl-C/kill 下 EXIT trap 可靠执行）按停机
  标记契约整组恢复 —— 与 02_ceph.sh 7.9 共用 `lib-common.stop_restore_known_consumers`
  （消费者清单单一来源）；成功路径 7.9 已恢复清标 → 钩子天然 no-op，成功行为零改动。
  停机标记随恢复清除；恢复本身失败（SSH 不可达）则标记留存，下次成功运行或下次失败退出重试。

### 3.3 编排引擎（新工具 `tools/k8s/cluster-teardown.sh`）

- **CLI**：
  - `--list`：只读——读登记 + 打印登记表与计划拆序（无实时探测副作用）。
  - `--uninstall [--yes]`：执行反序卸载（`--yes`/`CUBESTACK_ASSUME_YES=1` 免倒计时确认）。
  - 测试钩子：`CUBESTACK_TEARDOWN_TEST_INVENTORY=<file>` 以夹具 JSON 代替读集群（供夹具测试）。
- **候选集** = 全部声明 `# UNINSTALL: 1` 的模块 ∪ 登记中的组件（漏网记录告警跳过）。
- **拆序规则**（精确）：
  1. 主序组 = 登记组件按 `seq` **降序**；
  2. 次序组 = 未登记但声明 `UNINSTALL` 的组件，按模块文件序**反排**（= 静态依赖序的合法拆序：
     如 netshoot→…→multus），整组插在主序组之后、ceph 之前（未登记者多为"旧版本装的/手工补装
     的"，放在动 ceph 前收尾；存在性检查保证不存在即跳过）；
  3. **强制把 `ceph` 移到队尾**（安全不变量：所有消费者先停，才动 ceph；正常 seq/文件序下本已
     满足，此规则是显式断言，便于审查）。`ceph_csi` 不设卸载段（仅登记信息），不进入调用序列。
  4. base 组件（metallb/local_path）无 `UNINSTALL` 声明 → 只登记、不被调用（随 K8s 覆盖消亡）。
- **逐组件执行**：`CUBESTACK_MODULE_ACTION=uninstall bash <模块脚本>` 子进程调用，每组件有界
  （默认 600s，`TEARDOWN_COMPONENT_TIMEOUT` 可配）；卸载后把 CM 里该组件标 `status=uninstalled`
  （审计 + 中途中断可幂等重跑）。
- **失败处理**：单组件失败/超时 → 告警不中止（后续 ceph ⓪ 与 kubeadm reset 兜底；"覆盖必成功"
  口径不变），结尾汇总"卸了/跳了/失败了"。
- **确认交互**：`--uninstall` 在终端交互时打印拆序清单并倒计时 `TEARDOWN_CONFIRM_SLEEP`
  （默认 30s）；非交互且未 `--yes` → **跳过拆解并醒目警告**（后续 reset 前置自身会再次要求
  `--yes`，闸门一致）；登记为空且无候选存在 → 快速空跑，不弹确认。

### 3.4 deploy-cluster.sh 接线（两个挂点）

- **触发判定** `_OVERWRITE_PENDING` = `RUN_STEPS` 含 `k8s_deploy` 且实际状态非 `done`
  （--fresh 清状态后天然成立；新容器无状态文件也成立；断点续跑已完成则不触发）。
- **挂点 A**（`print_plan` 之后、ceph 预检块之前）：密钥已在（同容器重跑场景）→ 条件
  `_OVERWRITE_PENDING && cluster_exists` → 调引擎 `--uninstall`（`CUBESTACK_ASSUME_YES=1` 时
  透传 `--yes`，免倒计时）→
  `export CUBESTACK_TEARDOWN_DONE=1`。此后 ceph 预检块自然看到"无 CephCluster"（其删除分支
  空转），倒计时/磁盘分类照常服务"新装"确认；**Ceph 清理天然排在 operator 之后**，顺序正确。
- **挂点 B**（lib-module.sh `run_module` 执行 k8s_deploy 之前，与 `notify_base_redeploy` 同位）：
  场景 = 新容器（挂点 A 时还没有 SSH 密钥、探测不到集群）→ 此刻密钥已由前序模块
  （vm_sshkey/k8s_passwordless）装好 → 条件 `!CUBESTACK_TEARDOWN_DONE && cluster_exists` →
  跑同一引擎（含 ceph 压轴）。覆盖"新容器默认全量"路径。
- **引擎执行前策略（计划感知门）**：两个挂点向引擎导出本次执行计划（`CUBESTACK_TEARDOWN_PLAN_STEPS`）；
  引擎对**计划不含 `ceph`** 的覆盖跳过其卸载并**响亮说明**（保留 Ceph 集群/OSD 数据 —— 与覆盖预检的
  `_RUN_CEPH` 闸**同源语义**）；计划外的其他组件仍走优雅停机（其资源随 K8s 覆盖消亡，引擎打印一行
  信息）；手工调用引擎（无计划上下文）行为不变。
- **非覆盖路径零改动**：无 k8s_deploy / 已 done / --with-scale / --steps 精确模式不含
  k8s_deploy → 不触发。
- `deploy-cluster.sh` 帮助文本"三种使用方式②"补充新行为说明。

### 3.5 校验 / 测试 / 文档

- **check-modules.sh 新增 ⑲**：① 声明 `# UNINSTALL: 1` 的模块必须含 `CUBESTACK_MODULE_ACTION`
  卸载分支（含 `exit 0`）；② 该分支行号必须**小于**模块内 TOGGLE 变量首次被条件判断的行号
  （静态保证"卸载分支在 TOGGLE 跳过之前"）。
- **`tools/tests/test-cluster-teardown.sh`**（沿用现有 test-*.sh 夹具风格）：
  - 登记合并：新键 → seq=max+1；已有键 → seq 保持、lastSeenAt 更新；空/坏 JSON 容错。
  - 拆序计算：seq 降序；无登记降级（文件序反排）；ceph/ceph_csi 强制队尾；base 空操作。
  - 引擎编排：用假模块 stub 验证调用顺序与失败继续语义（借 `CUBESTACK_TEARDOWN_TEST_INVENTORY`）。
- **文档**：本目录 `README.md`（用户文档：登记结构、拆序规则、两个挂点、失败处理、
  手动 `--list/--uninstall` 用法）；`docs/scripts-development-spec.md` 增补 UNINSTALL 元数据 +
  登记约定（= 新模块规范）；`docs/troubleshooting.md` 增补覆盖安装相关排查段（可选）。
- **真机验证**（下轮实机覆盖时执行）：
  ① 同容器 `--fresh`：观察登记表 → 拆序卸载日志 → ceph 安全序 → K8s 覆盖全链；
  ② 新容器默认全量：验证挂点 B；③ 无登记存量集群：验证降级路径与幂等跳过。
- **实现注记**：引擎执行环（run_component/mark_uninstalled/收尾汇总）由夹具模式短路，未纳入离线测试
  —— 由真机三段验证覆盖。

## 4. 边界与失败处理（明说）

- 卸载失败/超时 → 告警不中止，后续 ceph ⓪（泛化消费者扫描）与 kubeadm reset 兜底。
- `CEPH_PRE_CLEANUP_EXISTING=false`（恢复/认领路径）→ **保留模式(--keep-pvcs)**: 只停消费者；PVC、nodeplugin、集群、OSD 与卷数据全部保留（**不销毁数据**）。
- 中途 Ctrl-C：CM 里组件 status 记录进行到哪，重跑幂等继续。
- verify_* 模块、ceph_backup 不登记不卸载（无集群资产/运维工具）。
- 用户手工装的第三方负载不在登记内（ceph 消费者兜底仍在）。
- K8s 覆盖后 `cubestack-install-record` 随 etcd 消亡 → 新集群从零重新登记，无跨代残留。

## 5. 实施拆解（明细见 plan.md）

1. lib-common.sh：`record_installed_component`（登记函数）
2. ceph-cleanup.sh：⓪ 提取为 `--stop-consumers` 动作（吞并工作区 delrs/delcr 未提交修复）
3. 新工具 `tools/k8s/cluster-teardown.sh`（引擎）
4. ~10 个模块：登记调用 + 卸载段 + `# UNINSTALL: 1`（ceph 模块调 ceph-cleanup）
5. deploy-cluster.sh 挂点 A + lib-module.sh 挂点 B
6. check-modules.sh ⑲ + tools/tests/test-cluster-teardown.sh
7. 文档（本目录 README.md + scripts-development-spec.md + deploy-cluster.sh 帮助）
8. 验证：bash -n 全量、check-modules 全绿、夹具测试、同步部署容器、真机（下轮覆盖）
