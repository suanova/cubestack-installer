# 节点池调度隔离(node pool)

> 2026-11-02 起**默认口径**：master 默认 **可调度** —— 不 cordon，且由 `node_pool` 模块移除
> kubespray 默认给 control-plane 打的 `node-role.kubernetes.io/control-plane:NoSchedule`
> 污点；系统控制面组件（CoreDNS/metrics-server/registry/MetalLB 等）与 CubeStack
> operator/平台组件仍通过 nodeSelector + toleration 钉到 master。设置
> `NODE_POOL_MASTER_CORDON=true` 可改为 cordon 隔离；设置
> `NODE_POOL_MASTER_SCHEDULABLE=false` 可保留 kubespray 默认污点（不可调度但也不 cordon）。
> GPU worker 隔离在后续阶段补充。
>
> **无可用 worker 安全护栏（2026-10-28）**：没有 **Ready 且未 cordon** 的 worker（单节点
> all-in-one / 纯 master 集群，或配置的 worker 全部 NotReady / 已 cordon）时，即使
> `NODE_POOL_MASTER_CORDON=true` 也**自动跳过 cordon**，master 保持可调度。详见下文
> 「无可用 worker 拓扑」。

## 目标

- **master**：默认 **可调度**（不 cordon、无 control-plane/master 污点），
  Ceph / operator / 平台组件通过 nodeSelector + toleration 钉到 master；设
  `NODE_POOL_MASTER_CORDON=true` 可切回 cordon 隔离（Pod 侧 toleration 保留，
  便于随时切换）。
- **GPU worker**：纯 GPU 节点，只允许 sglang/vllm 推理与 GPU 驱动/设备插件等必要 Pod；
  系统 DaemonSet 例外。
- 允许临时维护时对 master `cordon/drain`，不破坏平台组件的重调度。

## 关键机制（已实机验证，k8s v1.35.8）

`kubectl cordon` 会：

1. 设置 `spec.unschedulable=true`；
2. 由 node controller 加 taint `node.kubernetes.io/unschedulable:NoSchedule`。

scheduler 的 `NodeUnschedulable` 插件在 `spec.unschedulable=true` 时，会检查 Pod 是否容忍
这个隐式 taint。因此：

```yaml
spec:
  nodeSelector:
    node-pool: control-plane
  tolerations:
    - key: node.kubernetes.io/unschedulable
      operator: Exists
      effect: NoSchedule
    # master 通常还有 control-plane taint；按集群实际 key 加：
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
```

容器 d 实验（已清理）：

- 带上述 unschedulable toleration 的 Pod → `Running`；
- 不带 → `Pending`，事件 `0/1 nodes are available: 1 node(s) were unschedulable`；
- DaemonSet 由控制器自动注入 unschedulable toleration，仍会落到 cordon 节点。

> ⚠ 普通 `nodeSelector`/`tolerations`（没有 `node.kubernetes.io/unschedulable` 这一项）**不能**
> 让 Deployment/StatefulSet 落到 cordon 节点。

## 当前已实现（阶段一）

### 工具

`deployments/scripts/tools/node/node-pool.sh`

```bash
sudo ./deployments/scripts/tools/node/node-pool.sh --apply   # 打标签 + 可选 cordon
sudo ./deployments/scripts/tools/node/node-pool.sh --check   # 只读校验
sudo ./deployments/scripts/tools/node/node-pool.sh --remove  # 回滚
sudo ./deployments/scripts/tools/node/node-pool.sh --apply --only <master-hostname>
```

- 只处理 `NODES` 中 `role=master` 的节点；
- 标签/键值、污点、cordon 开关来自 `cluster.defaults.conf` §2.8；
- `NODE_POOL_MASTER_SCHEDULABLE=true`（默认）时，`--apply` 幂等移除 master 的
  `node-role.kubernetes.io/control-plane` / `node-role.kubernetes.io/master` 污点
  （其他污点保持不动）；`--check` 发现残留污点即报漂移。`--remove` **不还原**已移除的污点；
- cordon 由本工具创建时写 annotation
  `cubestack.io/node-pool-cordoned-by-installer=true`；
- `--remove` **只**回滚本工具创建的 cordon（annotation 判定），不会误删用户预先设置的 cordon；
- 幂等：重复 apply 不会重复 cordon。
- **`NODE_POOL_MASTER_CORDON=false` 时 `--apply` 会反向收敛**：本工具创建过的 cordon
  （annotation 判定）会被 uncordon 并清除 annotation；用户/其他工具创建的 cordon 保持不动
  （只告警）。模块的 apply 前不会先跑 `--remove`，所以改开关后重跑即可恢复可调度。
- **ownership 标记写/删失败不再静默忽略**：cordon 后写标记失败 → 回滚 uncordon（不留
  "已 cordon 但无所有权"的不可回滚状态）；uncordon 后删标记返回失败 → **确认性重读**
  annotation：确认已清则视为完成（annotate 可能已在远端生效），确认仍在才重新 cordon 并
  返回非 0；读取失败则不擅自 cordon/报错（避免留下无标记、后续不会被回滚的 cordon）。
  修复后重跑 `--apply/--remove` 即可收敛。

### 无可用 worker 拓扑（单节点 all-in-one / 纯 master / worker 不可用）

没有 **Ready 且未 cordon** 的 worker 时，**即使 `NODE_POOL_MASTER_CORDON=true` 也不 cordon**：

- **触发条件**：`NODES` 中 `role=worker` 数为 0；或配置的 worker 全部 NotReady / 已 cordon
  （apply/check 会实际查询 worker 的 STATUS 与 `spec.unschedulable`，逐个告警不可用原因）。
- **原因**：kubespray 的 CoreDNS / dns-autoscaler 模板只容忍
  `node-role.kubernetes.io/control-plane:NoSchedule`，**没有** `node.kubernetes.io/unschedulable`
  容忍；`NODE_POOL_PLATFORM_PLACEMENT` 设为 `false` 时也不会给它们补。集群里所有节点都被 cordon 后，
  DNS 组件滚动、扩缩容或节点重启后新 Pod 会**永久 Pending**——单节点集群等于整集群 DNS 失效。
- **与单节点 play 一致**：`patch-playbooks/cubestack-single-node.yml` 在只有 1 个 control-plane 时
  会 uncordon 并移除污点；本工具不会再把它 cordon 回去。
- **遗留 cordon 自动回滚**：`--apply` 会把**本工具此前创建**（有 ownership annotation）的 cordon
  回滚（典型场景：先有 worker 时 cordon，后来 worker 被移除）；非本工具创建的 cordon 只告警、不动。
- **`--check`**：该拓扑下期望 master **可调度**；节点被 cordon（任何来源）即报漂移、非 0。
- 存在可用 worker（Ready 且未 cordon）时行为不变：按 `NODE_POOL_MASTER_CORDON` 执行。

### 模块

`deployments/scripts/modules/03_addon/34_node_pool.sh`（排在 `dev_lab`/`model_images`
之前执行，placement 先于 vllm/sglang 大镜像 push 完成）

```bash
# 默认已随全量部署执行(NODE_POOL_ENABLED=true)；也可手动单跑
sudo ./deploy-cluster.sh --steps node_pool

# 回滚(变量用 env 传给 root: sudo 默认 env_reset 会清掉 "VAR=... sudo" 前置赋值)
sudo env NODE_POOL_ACTION=remove ./deploy-cluster.sh --steps node_pool
```

- `DEFAULT: 0`、`TOGGLE: NODE_POOL_ENABLED`（默认 **true**）⇒ 随全量部署在 `dev_lab`/
  `model_images`（vllm/sglang 大镜像 push）**之前**（文件 34）执行；
- `REQUIRES: k8s_deploy`：集群必须先存在；已部署集群上 `k8s_deploy` 状态 done 时不会重跑；
- 执行顺序：先 `cubestack-placement.sh --apply` 给平台组件加 master placement（
  `NODE_POOL_PLATFORM_PLACEMENT=true`（默认）时再跑 `master-placement.sh`），最后打 master 标签/
  按需 cordon；
- **k8s 阶段提前收敛(2026-11-03)**：`06_k8s_deploy.sh` 在 kubespray 成功后、addon 之前会调用
  `tools/node/node-pool.sh --apply`（临时强制 `NODE_POOL_MASTER_CORDON=false`）只做
  "master 可调度"（移除 control-plane/master 污点 + 加 master 标签）。原因：kubespray 的
  registry ReplicaSet 没有 control-plane toleration，而 `05_k8s_registry` 会等它 Ready；
  纯 master / 多 master 无 worker 集群若等到本模块（34）才去污点，registry 会先 600s 超时。
  cordon 与平台 placement 仍由本模块在 `dev_lab`/`model_images` 之前按配置执行（幂等重跑）。
- **异步组件等待**：组件由 operator 异步安装；apply 前按
  `NODE_POOL_PLACEMENT_WAIT_SECONDS`（默认 180s）读取 `CubeStackCluster.status`
  （`conditions.Ready` / `components[].phase`）等待状态收敛，避免首次 placement 因对象尚未
  创建而跳过；`Degraded`/`Failed` 也视为安装结束，不空等。等待期间每次状态查询都按剩余预算
  设置 `--request-timeout` 与远端 `timeout`，单次 API 卡死不会拖过整体上限；`0` 表示只查一轮。
- **local-path PVC 守护**：placement 前检查工作负载 PVC 的 PV `nodeAffinity`；若 PVC 已绑定在
  worker（local-path 无共享存储），钉 master 会让新 Pod `volume node affinity conflict` Pending，
  因此跳过该工作负载并告警（需共享存储或重建 PVC）。Ceph-on（ceph-block/cephfs）无此问题；
  该守护同时避免 registry 在 `dev_lab`/`model_images` 之前被钉到 master 后阻断镜像 push。
  监控组件的 **chart values** 也受守护：`25_cubestack_operator.sh` 生成
  `clusterCR.spec.components.prometheus.values` 前会检查已有 Prometheus/Alertmanager PVC
  绑定；PVC 已绑 worker 或状态无法确认时，不下发对应的 master nodeSelector（tolerations
  保留），避免 operator 先于 34_node_pool 把 STS 改成 master 导致 Pending。
- `remove` 先 uncordon，再移除 master nodeSelector。**回滚不看当前 placement 开关**：
  应用后把 `NODE_POOL_CUBESTACK_PLACEMENT`/`NODE_POOL_PLATFORM_PLACEMENT` 改成 false
  再执行 remove，仍会清掉本工具施加的 nodeSelector（与 cordon 的 ownership 口径一致）。
  `master-placement.sh --remove` 只处理**当前确实带** master selector 的对象——从未应用过
  placement 时不会 patch，也不会重建 registry Pod。存在性查询失败（API/RBAC/SSH）或
  PodTemplate 读取/JSON 解析失败都会让 remove **非 0 退出**，不会被当作"对象不存在/
  无 selector"静默跳过。移除 patch 失败**不再降级为告警**：
  任一 placement 回滚失败都会让工具与 `node_pool` 的 remove **非 0 退出**，避免把残留
  selector 当成功。`cubestack-placement.sh --remove` 还会清理 `CubeStackCluster`
  `spec.global` 中安装器注入的 nodeSelector/tolerations（以及旧版本写入的
  `components.<name>.values`），只删除 installer 的 key/toleration，保留用户自定义条目，
  避免后续组件调和/升级把 placement 重新带回。

### 系统组件 master placement(阶段二 B-1)

`deployments/scripts/tools/k8s/master-placement.sh` 在 cordon 前给以下组件加
`node-role.kubernetes.io/control-plane` nodeSelector + control-plane/unschedulable tolerations：

- `kube-system/deploy/coredns`
- `kube-system/deploy/metrics-server`
- `kube-system/deploy/dns-autoscaler`
- `kube-system/deploy/calico-kube-controllers`
- `kube-system/rs/registry`（registry 是 kubespray 的裸 ReplicaSet）
- `metallb-system/deploy/controller`
- `rook-ceph/deploy/ceph-csi-controller-manager`（ceph-csi-operator 自身；命名空间跟随 `CEPH_NAMESPACE`。
  `03_ceph_csi.sh` 安装后已 patch 一次，这里在部署末尾再收敛一次，覆盖只跑 `ceph`、旧集群升级或
  PodTemplate 被重新渲染的情况）
- `local-path-storage/deploy/local-path-provisioner`（Ceph 启用时不安装 → 不存在则跳过）
- `metax-operator/deploy/metax-gpu-operator-metax-operator`（GPU operator 关闭时不存在 → 跳过）

`metallb-system/ds/speaker` 是 DaemonSet，只补 toleration（必须全节点，含 cordon master）。
`NODE_POOL_PLATFORM_PLACEMENT=true`（默认）时开启该步骤；设为 `false` 可保持系统组件不受本工具影响
（只钉 CubeStack 平台组件）。

> ⚠ kubespray 重跑 `k8s_deploy` 会按 addons.yml 重新渲染这些 Deployment；之后需重跑
> `--steps node_pool` 重新应用。`--remove` 只移除本工具加的 master nodeSelector，
> tolerations 保留（避免 control-plane taint 下的组件 Pending）。

### CubeStack operator/平台组件 master placement(阶段二 B-2)

`deployments/scripts/tools/k8s/cubestack-placement.sh` 给以下 Deployment 加 master
nodeSelector + control-plane/unschedulable tolerations：

- `cubestack-system`：`cubestack-operator`、`cubestack-controller-manager`、`cubepilot-api`、
  `cubepilot-operator`、`cubestack-portal`
- `envoy-gateway-system`：`envoy-gateway` 控制器
- `ai-gateway-system`：`ai-gateway-controller`
- `lws-system`：`lws-controller-manager`
- `cuberouter`：`cuberouter`、`cuberouter-cloudnative-pg`、`redis-operator`
- `monitoring`：`kube-prometheus-grafana`、`kube-prometheus-kube-prome-operator`、
  `kube-prometheus-kube-state-metrics`、`perses-operator-controller-manager`
- `cubestack-system`：`cubestack-docs`（资产型组件，无 chart values 注入路径）

另外直接 patch 以下 operator 调和 CR 的 placement（不直接改 STS 模板，否则下次调和会被覆盖）：

- `monitoring`：`prometheuses.monitoring.coreos.com/kube-prometheus-kube-prome-prometheus`（`spec.nodeSelector/tolerations`）
- `monitoring`：`alertmanagers.monitoring.coreos.com/kube-prometheus-kube-prome-alertmanager`（`spec.nodeSelector/tolerations`）
- `monitoring`：`perses.perses.dev/perses`（`spec.nodeSelector/tolerations`）
- `cuberouter`：`redisreplications.redis.redis.opstreelabs.in/cuberouter-redis`（`spec.nodeSelector/tolerations`
  用于 Redis 数据副本；Sentinel 使用独立的 `spec.sentinel.nodeSelector/tolerations`，必须一起下发，
  否则 Sentinel STS 不会继承 Redis 的 selector）
- `cuberouter`：`clusters.postgresql.cnpg.io/cuberouter-postgres`（CNPG 调度字段在
  `spec.affinity.nodeSelector/tolerations`，不是 `spec.nodeSelector`）

> 多副本 CR（Redis/Sentinel、CNPG、Prometheus/Alertmanager）在 apply 前按 **PVC 名前缀** 检查
> PV `nodeAffinity`：若 PVC 已绑在 worker（local-path），跳过并告警，避免 Pending。
> Ceph RBD/CephFS 等共享存储没有节点亲和性，可正常滚动到 master。

**明确不动**：Envoy Gateway 数据面 proxy Deployment（`envoy-envoy-gateway-system-*`）、
sglang/vllm/model bundle 推理负载、任何 DaemonSet；也不直接 patch DaemonSet/StatefulSet
（Prometheus/Alertmanager/Perses、RedisReplication、CNPG 通过上面的 CR patch 下发）。
GPU worker 隔离在后续阶段单独做。`NODE_POOL_CUBESTACK_PLACEMENT=false` 可关闭。

- operator 自身的 chart 安装也加了 `nodeSelector`/`tolerations`（`25_cubestack_operator.sh`），
  新建/重装时 operator pod 直接落 master。
- **默认通过 CR `spec.global` 注入**（2026-11-12）：`25_cubestack_operator.sh` 在
  `NODE_POOL_CUBESTACK_PLACEMENT=true` 时给 CubeStackCluster 设置
  `spec.global.nodeSelector` + `spec.global.tolerations`，operator 在**创建每个组件工作负载时**
  统一下发；新组件自动覆盖，不再逐组件写 values。
  - **构建门禁**：只有所选 operator 镜像的内容（config）digest 在
    `CUBESTACK_OPERATOR_GLOBAL_PLACEMENT_DIGESTS` 内才下发 global（默认包含 2026-11-12 的
    `454590af…` 构建，内容 digest `sha256:74ead8…`）。旧构建或无法识别的构建会跳过 global
    并告警，由本模块的 PVC 守护逐组件兜底。`CUBESTACK_OPERATOR_GLOBAL_PLACEMENT=auto|true|false`
    控制策略（默认 auto）。升级 operator 后需把新构建的内容 digest 追加到 allowlist。
  - **PVC 门禁**：扫描 `cubestack-system` / `cuberouter` / `monitoring` 下所有已存在的 PVC
    （含 cuberouter 的 `app-data`/`app-logs`、`cubepilot-api-data`、Prometheus/Alertmanager/Perses
    以及 CNPG/Redis 卷）。任一 PVC 已绑 worker（local-path）或绑定无法确认时**不下发** global，
    改由本模块的 `cubestack-placement.sh` 按组件 PVC 守护兜底，避免 Pending。
- 其余场景（cuberouter、Perses server 等）仍由 `cubestack-placement.sh` 兜底 patch；
  Perses server CR 没有 values 注入路径，直接 patch CR spec（lws 由 `lws-cr-values.yaml`
  在创建时下发）。
- **执行时机**：`34_node_pool` 排在 `dev_lab` / `model_images`（vllm/sglang 大镜像 push）之前；
  apply 前按 `NODE_POOL_PLACEMENT_WAIT_SECONDS` 读取 `CubeStackCluster.status` 等待组件状态
  收敛（不再硬编码 Deployment 名单），避免首次 patch 因对象尚未出现而跳过。
- **Ceph 监控重检**：监控组件就绪后，若 `servicemonitors.monitoring.coreos.com` 与
  `rook-ceph` CephCluster 均存在但 ServiceMonitor 缺失，会重启 `rook-ceph-operator`
  （CephCluster 更新谓词忽略纯 annotation，重启才会重新调和），并有界等待/确认
  `rook-ceph-exporter`（或 `rook-ceph-mgr`）ServiceMonitor 生成。
- `--remove` 会清理 `spec.global.nodeSelector/tolerations` 中 installer 写入的条目（保留用户
  自定义 key/toleration），并兼容清理旧版本写入的 `components.<name>.values`。

### 配置（cluster.defaults.conf §2.8）

| 变量 | 默认 | 说明 |
|---|---|---|
| `NODE_POOL_ENABLED` | `true` | 总开关（默认随全量部署） |
| `NODE_POOL_ACTION` | `apply` | `apply` / `check` / `remove` |
| `NODE_POOL_MASTER_LABEL` | `node-pool=control-plane` | master 标签 |
| `NODE_POOL_MASTER_CORDON` | `false` | master 是否 cordon（默认 false=可调度；true=cordon；**无可用 worker 时自动跳过 cordon**） |
| `NODE_POOL_MASTER_SCHEDULABLE` | `true` | 是否移除 master 的 control-plane/master NoSchedule 污点（默认 true=可调度；false=保留 kubespray 默认污点） |
| `NODE_POOL_PLATFORM_PLACEMENT` | `true` | 是否把 CoreDNS/metrics/registry/MetalLB 等系统组件也钉 master（`false`=只钉 CubeStack 平台组件） |
| `NODE_POOL_CUBESTACK_PLACEMENT` | `true` | CubeStack operator/平台组件钉 master（CR `spec.global` 注入；监控 PVC 例外时回退 patch） |
| `CUBESTACK_OPERATOR_GLOBAL_PLACEMENT` | `auto` | `auto`=仅 allowlist 内构建下发 global / `true`=强制 / `false`=禁用 |
| `CUBESTACK_OPERATOR_GLOBAL_PLACEMENT_DIGESTS` | `sha256:74ead8…` | 含 DaemonSet 排除的 operator 内容（config）digest 白名单（逗号分隔） |
| `NODE_POOL_PLACEMENT_WAIT_SECONDS` | `180` | placement 前等待 `CubeStackCluster.status` 组件状态收敛的上限（0=只查一次） |
| `NODE_POOL_GPU_LABEL` | `node-pool=gpu` | 阶段二使用 |
| `NODE_POOL_GPU_TAINT` | `dedicated=gpu:NoSchedule` | 阶段二使用 |
| `NODE_POOL_GPU_NODES` | 空 | 阶段二使用（hostname 列表） |

## 验证

```bash
sudo ./deployments/scripts/tools/node/node-pool.sh --apply
kubectl get node <master> -o jsonpath='{.spec.unschedulable}{"\n"}{.metadata.labels.node-pool}{"\n"}{.spec.taints}{"\n"}'
kubectl get nodes   # 默认 NODE_POOL_MASTER_CORDON=false + SCHEDULABLE=true → master 可调度;
                    # CORDON=true 且有可用 worker 时 master 显示 SchedulingDisabled;
                    # 无可用 worker 时永远不 cordon(见「无可用 worker 拓扑」)

# 带 toleration 的测试 Pod(参见上方 YAML)应 Running; 不带 toleration 时, 仅当 master 仍有
# control-plane 污点或已 cordon 才 Pending(单节点无 worker 集群已移除污点且不 cordon, Pod 可调度)
# 回滚
sudo ./deployments/scripts/tools/node/node-pool.sh --remove
kubectl get node <master> -o jsonpath='{.spec.unschedulable}{"\n"}'   # 空/false
```

离线回归：

```bash
bash deployments/scripts/tools/tests/test-node-pool.sh
bash deployments/scripts/tools/check-modules.sh
```

## 后续阶段（待做）

1. **平台组件 placement 加固**（master 侧）：
   - Ceph mon/osd/mgr 的 `placement` 增加 unschedulable toleration；
   - Rook operator、ceph-csi operator/controller、nodeplugin；
   - registry、CoreDNS、metrics-server、dns-autoscaler；
   - MetalLB controller nodeSelector；
   - cubestack operator chart values / CubeStackCluster 按组件 placement，
     避免把 sglang/vllm 也钉到 master。
2. **GPU worker 隔离**：
   - GPU 节点打 `node-pool=gpu` + `dedicated=gpu:NoSchedule`；
   - sglang/vllm 加 GPU taint toleration + nodeSelector；
   - GPU driver/device-plugin/NFD/RDMA DaemonSet 加 GPU taint toleration；
   - 系统 DaemonSet 保持 `operator: Exists` 全节点覆盖。
3. 在真实多 master + GPU worker 集群验证：
   - 平台 Pod 全在 master、GPU Pod 全在 GPU worker；
   - cordon 后滚动/重启平台 Pod 仍能调度；
   - DaemonSet 全节点覆盖；
   - 无未预期的 Pending。

## 注意事项

- **master 资源**：3 台 master 跑 etcd/apiserver + Ceph + registry + DNS/metrics + operator，
  CPU/内存/磁盘 I/O 竞争明显；Ceph OSD 建议独立盘并限制资源，必要时把 OSD 放到专用存储节点。
- **cordon 是持续状态**：任何没有 special toleration 的新 Pod 都会 Pending；必须在
  Deployment/StatefulSet/CR 的 PodTemplate 里配置，不能只 patch 现有 Pod。
- **control-plane taint**：多节点 kubespray 默认保留
  `node-role.kubernetes.io/control-plane:NoSchedule`；master 上的 Pod 需要同时容忍它。
- **MetaX GPU operator** 在检测到有 GPU 的 master 时会 uncordon 并移除 control-plane taint；
  若 master 有 GPU，需要调整该逻辑，否则会破坏 master 的不可调度状态。
