# 节点池调度隔离(node pool)

> 2026-10-27 起分阶段实现。当前阶段：**master 节点标签 + 可选 cordon 的节点侧基础工具**；
> 平台组件 placement 加固与 GPU worker 隔离在后续阶段补充。

## 目标

- **master**：保持 `Unschedulable=True`（`kubectl get nodes` 显示 `SchedulingDisabled`），
  但 Ceph / operator / 平台业务 Pod 仍能调度到 master。
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
- 标签/键值、cordon 开关来自 `cluster.defaults.conf` §2.8；
- cordon 由本工具创建时写 annotation
  `cubestack.io/node-pool-cordoned-by-installer=true`；
- `--remove` **只**回滚本工具创建的 cordon（annotation 判定），不会误删用户预先设置的 cordon；
- 幂等：重复 apply 不会重复 cordon。

### 模块

`deployments/scripts/modules/03_addon/53_node_pool.sh`

```bash
# 手动执行(推荐; 平台 placement 配置完成后再跑)
NODE_POOL_ENABLED=true sudo ./deploy-cluster.sh --steps node_pool

# 回滚
NODE_POOL_ENABLED=true NODE_POOL_ACTION=remove sudo ./deploy-cluster.sh --steps node_pool
```

- `DEFAULT: 0`、`TOGGLE: NODE_POOL_ENABLED`：默认不随全量部署；
- 若在 cluster.conf 设 `NODE_POOL_ENABLED=true`，它会在 addon 末尾（文件 53）执行；
- `REQUIRES: k8s_deploy`：集群必须先存在；已部署集群上 `k8s_deploy` 状态 done 时不会重跑。

### 配置（cluster.defaults.conf §2.8）

| 变量 | 默认 | 说明 |
|---|---|---|
| `NODE_POOL_ENABLED` | `false` | 总开关（默认不随全量部署） |
| `NODE_POOL_ACTION` | `apply` | `apply` / `check` / `remove` |
| `NODE_POOL_MASTER_LABEL` | `node-pool=control-plane` | master 标签 |
| `NODE_POOL_MASTER_CORDON` | `true` | master 是否 cordon |
| `NODE_POOL_GPU_LABEL` | `node-pool=gpu` | 阶段二使用 |
| `NODE_POOL_GPU_TAINT` | `dedicated=gpu:NoSchedule` | 阶段二使用 |
| `NODE_POOL_GPU_NODES` | 空 | 阶段二使用（hostname 列表） |

## 验证

```bash
sudo ./deployments/scripts/tools/node/node-pool.sh --apply
kubectl get node <master> -o jsonpath='{.spec.unschedulable}{"\n"}{.metadata.labels.node-pool}{"\n"}'
kubectl get nodes   # master 显示 SchedulingDisabled

# 带 toleration 的测试 Pod(参见上方 YAML)应 Running; 不带应 Pending
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
