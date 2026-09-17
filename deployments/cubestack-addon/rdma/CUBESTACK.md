# k8s-rdma-shared-dev-plugin — CubeStack 离线 vendoring 适配说明

本目录存放 **Mellanox/NVIDIA k8s-rdma-shared-dev-plugin(Device Plugin)离线安装配置**,
供 `modules/03_addon/10_rdma_shared_dev_plugin.sh` 离线部署。
插件将宿主机 RDMA 网卡(InfiniBand/RoCE)的字符设备(`/dev/infiniband/uverbs*`、`rdma_cm`)以 K8s
**扩展资源**形式暴露给 Pod, 并支持多 Pod 共享同一物理 HCA(**rdmaHcaMax** 控制共享份数)。

> 本目录不存 manifest 文件: ConfigMap + DaemonSet 由 10_rdma 模块按 cluster.conf 的
> `RDMA_*` 动态生成(heredoc), 镜像行自动重写为集群内置 registry 地址 —— 与多网卡模块同款
> 「配置即 manifest」模式, 无上游 bundle 需 vendoring。

## 前置条件(节点)

1. 硬件: Mellanox/NVIDIA ConnectX 系列 RDMA 网卡(InfiniBand 或 RoCE)。
2. 驱动: 已装 **MLNX_OFED** 或内核自带 `ib_core`; 验证: `ibstat` / `rdma link show` 能看到 HCA 端口。
3. K8s: 集群正常, kubelet Device Plugin 特性默认开启(无需额外开关)。
4. 数据面隔离(可选): 配合 Multus CNI(模块 09_multus)给 Pod 分配独立 RDMA 数据 IP。

## 离线镜像

```bash
# 联网机(见 deployments/scripts/tools/images/rdma-save-images.sh):
# ⚠ 官方镜像源在 ghcr.io/mellanox(Docker Hub 无此镜像); 1.4.0 无 v 前缀(v1.4.0 在 ghcr 404), v1.5.1+ 才带 v; 默认 v1.5.4 最新(修复 RoCE 口 issm 硬检查, 5 块 HCA 全暴露)
sudo ./deployments/scripts/tools/images/rdma-save-images.sh
# → deployments/offline-files/rdma/ghcr.io_mellanox_k8s-rdma-shared-dev-plugin_v1.5.4.tar
```

10_rdma 模块把 tar 推送进集群内置 registry(目标 `<reg>/mellanox/k8s-rdma-shared-dev-plugin:<tag>`,
**tag 以 tar 内实际镜像 ref 为准**, 兼容 1.4.0 / v1.5.x 两种版本风格),
再按 `RDMA_*` 生成 ConfigMap + DaemonSet 并 apply。tar 缺失时模块报错并给出指引(不静默跳过)。

## 项目集成

- 部署入口: `modules/03_addon/10_rdma_shared_dev_plugin.sh`(`RDMA_ENABLED=true`, 或 `--steps rdma_shared_dev_plugin`)
- 端到端验证: `--steps verify_rdma_shared_dev_plugin`(见 `modules/03_addon/30_verify_rdma_shared_dev_plugin.sh`)
  —— 除 DaemonSet/ConfigMap/节点 allocatable 检查外, **会真起一个测试 pod 申请该扩展资源**
  (资源名从 ConfigMap 动态解析, 不钉节点、由调度器选), 断言: pod 被调度 + 容器内
  `/dev/infiniband/` 出现 `uverbs*` 字符设备(下方"容器内验收点"自动化)。测试镜像走集群内置
  registry(离线可用), 测完自动删除 `verify-rdma-$$` 命名空间。
  ⚠ **不含真实 RDMA 流量**(perftest/rdma-core 不在离线镜像集内), 吞吐/时延验收需另行准备镜像。
- 上游文档: https://github.com/Mellanox/k8s-rdma-shared-dev-plugin

## 资源配置(全局单一 ConfigMap)

模块生成的 ConfigMap `kube-system/rdma-devices`(`config.json`)描述资源池, 字段含义:

| cluster.conf 变量 | 默认 | 说明 |
|---|---|---|
| `RDMA_RESOURCE_PREFIX` | `nvidia.com` | 扩展资源前缀 |
| `RDMA_RESOURCE_NAME` | `mlx5_0` | 扩展资源名(**pool 模式**; pod 申请 `nvidia.com/mlx5_0`; per-hca 模式忽略) |
| `RDMA_HCA_MODE` | `per-hca` | 资源模式: **`per-hca`**=每块 HCA 独立资源(资源名=节点实际 RDMA 设备名如 `mlx5_0`/`mlx5_1`/..., pod 可按资源名精确选卡; **cluster.conf.example 默认值, 推荐**); **`pool`**=全部 HCA 聚合为单个资源(兼容旧部署; 也是模块**代码内建回退值** —— 配置里没写该键时才生效) |
| `RDMA_HCA_MAX` | `100` | 每资源最大共享 Pod 数(rdmaHcaMax; per-hca 模式下每块卡各一份配额) |
| `RDMA_IF_NAMES` | *(自动检测)* | 宿主机 RDMA 网卡名(逗号分隔, selectors.ifNames); ⚠ **留空 = 模块自动扫描所有节点 `/sys/class/infiniband/*/device/net/` 收集真实设备名+网卡名**(兼容 IB=ibsX / RoCE=ens*/manage0 混合), 显式设置则按此精确过滤 |
| `RDMA_ACTIVE_ONLY` | `true` | 自动检测只收录**链路状态 ACTIVE** 的 HCA(读 `/sys/class/infiniband/*/ports/*/state`); DOWN/DISABLED 卡不建资源不暴露; `false`=全部暴露。仅作用自动检测(RDMA_IF_NAMES 为空), 显式 IF_NAMES 时忽略 |
| `RDMA_PLACEHOLDER_HCAS` | `mlx5_0,mlx5_1,mlx5_2` | **纯 VM 无 RDMA 卡**时的占位设备名: 自动检测到 0 块 HCA 时按这些名字生成 config.json, 插件正常起来但**不注册任何扩展资源**(见下方"纯 VM 无 RDMA 卡: 占位模式")。**检测到真实 HCA 时本项被忽略 → 物理机零影响**。把该行改成空值 = 严格模式(per-hca 检测不到即报错退出; 模块代码内建回退也是空) |
| `RDMA_VENDORS` | `15b3` | PCI Vendor ID(逗号分隔; Mellanox/NVIDIA=15b3) |
| `RDMA_UPDATE_INTERVAL` | `300` | periodicUpdateInterval 秒(0=关闭周期更新) |
| `RDMA_NAMESPACE` | `kube-system` | 插件命名空间 |

### 两种资源模式(关键)

- **`pool`(默认)**: 全部匹配网卡聚合进一个资源 `nvidia.com/mlx5_0`, 容量=rdmaHcaMax。
  Pod 只能声明"我要用 RDMA", **不能选择用哪一块卡**。适用于不关心具体网卡的共享场景。
- **`per-hca`**: 每块 HCA 一个 configList 条目 → 一个独立扩展资源, 资源名 = 节点实际
  RDMA 设备名(`/sys/class/infiniband/*` 下的名字, 如 `mlx5_0`/`mlx5_1`/`mlx5_2`...)。
  Pod 通过 `resources.limits` 声明资源名, **精确选择用哪块卡**(如 IB 走 ibsX 设备、RoCE 走 ens*/manage0 设备)。
  多节点同名 HCA(同款设备)自动合并 ifNames, 全集群资源名一致。
  ⚠ 资源名来自节点实际设备名, 部署后以 `kubectl describe node` 的 allocatable 为准。

> 多网卡: pool 模式可把 `RDMA_IF_NAMES` 设多个网卡, 插件按 selectors 匹配聚合到同一资源;
> per-hca 模式则每块卡天然独立(推荐, 需要选卡能力时)。selectors 内同字段取 OR, 字段之间取 AND。

## 纯 VM 无 RDMA 卡: 占位模式

在没有 RDMA 网卡的**虚拟机**上跑完整部署流水线时, 自动检测会得到 0 块 HCA; 而 `per-hca`
模式(`cluster.conf.example` 默认)下模块会直接报错中断:

```
【错误】RDMA_HCA_MODE=per-hca 但未检测到任何 HCA(检查驱动 / RDMA_IF_NAMES)
【错误】  纯 VM 无 RDMA 卡: 在 cluster.conf 设 RDMA_PLACEHOLDER_HCAS="mlx5_0,mlx5_1,mlx5_2" 走占位模式, 或改 RDMA_HCA_MODE=pool
```

`cluster.conf.example` **默认已带占位名**(照 example 配的集群不会撞上这个错; 旧 cluster.conf
没写该键时模块走严格模式, 需按下行显式补上):

```bash
RDMA_PLACEHOLDER_HCAS="mlx5_0,mlx5_1,mlx5_2"   # 仅当自动检测到 0 块 HCA 时才生效
```

占位模式下的行为:

- ConfigMap 按占位名生成 —— `per-hca` 得到三条 `nvidia.com/mlx5_0` / `mlx5_1` / `mlx5_2`;
  `pool` 得到单条 `nvidia.com/mlx5_0` 且 `ifNames` 为三个占位名;
- DaemonSet 正常起来, 插件空转, **不会注册任何扩展资源** —— 占位名是 *RDMA 设备名*而不是
  *netdev 名*, `selectors.ifNames` 永远匹配不到 → 空资源池。因此 `kubectl describe node`
  里看不到 `nvidia.com/mlx5_*` 属**预期**(这正是"装得上但不真注册"的达成方式);
- ConfigMap 带标注 `cubestack.io/rdma-placeholder: "true"`。`verify_rdma_shared_dev_plugin`
  从集群实际状态读该标注, 命中则 ①② 照常真检查、③ 无资源注册**放行 exit 0** 并明确标注
  "未验收真实 RDMA"; **非占位集群维持硬失败**, 标注不会被绕过。

> ⚠ 占位模式只是让部署流水线在 VM 上跑通, **不代表 RDMA 可用**。它不会注册资源, 也不会
> 让 pod 拿到 `/dev/infiniband` 字符设备。

### 物理机为什么不受影响

三重保护, 任一层都足以隔离:

1. **只在"检测到 0 块 HCA"时触发** —— 装卡/加载驱动后自动检测正常, 占位分支根本不会进入;
2. **检测有结果时开关被忽略** —— 即使配置里带着占位名(example 默认就带), 只要扫到真实 HCA 就走真实配置;
3. **要严格就把该行改成空** —— 把 cluster.conf 该行写成 `RDMA_PLACEHOLDER_HCAS=""`(去掉 `:-` 默认值)
   即恢复"检测不到 HCA 就报错退出", 避免"卡插着但驱动坏了"被静默放行(模块代码内建回退也是空:
   不写该键的旧 cluster.conf 走严格模式)。⚠ 只 `export RDMA_PLACEHOLDER_HCAS=` 一个空环境变量**无效**
   —— cluster.conf 的赋值优先于环境变量, 必须改配置文件那一行。

装上卡之后 —— 开关不用动(占位名自动失效), 要重建的是集群里已下发的占位 ConfigMap:

```bash
# 模块 REPEAT:0 会跳过"已装"状态, 必须 --fresh 才会重建 ConfigMap
sudo ./deploy-cluster.sh --steps rdma_shared_dev_plugin --fresh    # --steps 只跑该组件, 不连带 k8s_deploy
sudo ./deploy-cluster.sh --steps verify_rdma_shared_dev_plugin
```

## Pod 使用

**pool 模式**(不选卡, 只申请 RDMA):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: rdma-test-pod
spec:
  containers:
    - name: rdma-app
      image: mellanox/rping-test   # 或含 RDMA 用户态库的镜像
      command: ["sleep", "infinity"]
      resources:
        limits:
          nvidia.com/mlx5_0: 1     # 申请 1 个单位的 mlx5_0 共享资源
      securityContext:
        capabilities:
          add: ["IPC_LOCK"]        # RDMA 内存注册(mlock)必需
```

**per-hca 模式**(按资源名选卡, `RDMA_HCA_MODE=per-hca`):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: rdma-test-pod-hca1
spec:
  containers:
    - name: rdma-app
      image: mellanox/rping-test
      command: ["sleep", "infinity"]
      resources:
        limits:
          nvidia.com/mlx5_1: 1     # 精确选择第 1 块 HCA(以节点 allocatable 实际资源名为准)
      securityContext:
        capabilities:
          add: ["IPC_LOCK"]
```

容器内 `ls -l /dev/infiniband/` 应看到 `uverbs0`、`rdma_cm`; `ibv_devinfo` / `ibstat` 可见网卡。
per-hca 模式下用 `kubectl describe node` 查各节点 allocatable 的完整资源清单,
Pod 调度时会落在拥有所申请资源名的节点(同款 HCA 全集群同名)。

## 与 Multus 配合(数据面隔离)

仅挂载 `/dev/infiniband` 解决「设备访问」; 若 Pod 需走 RDMA 网卡通信(NCCL 等), 还需数据面 IP:

1. Multus 模块(09)建 macvlan NAD, `master` = RDMA 网卡(如 `ens2f0`), host-local IPAM;
2. Pod 加注解 `k8s.v1.cni.cncf.io/networks: <macvlan-NAD>` → 同时获得设备 + 独立数据 IP。

## 排错

- **无扩展资源**: `kubectl -n kube-system logs <rdma-shared-dp-pod>`; 重点检查 `RDMA_VENDORS`/`RDMA_IF_NAMES`
  是否与宿主机实际设备匹配(插件自探测 `/dev/infiniband` + sysfs)。
- **无扩展资源且 ConfigMap 标注 `rdma-placeholder=true`**: 这是 VM 占位模式的**预期**行为(无硬件, 见
  上文"纯 VM 无 RDMA 卡: 占位模式"), 不是故障。若出现在**真实机器**上, 说明部署时没扫到 HCA ——
  先查驱动(`ibstat` / `rdma link show`)与 `RDMA_ACTIVE_ONLY`(DOWN/DISABLED 卡会被过滤); 驱动修好后
  占位名自动失效(无需改开关), 用 `--fresh` 重跑本模块重建 ConfigMap 即可。
- **ibv_reg_mr 失败**: Pod 缺 `IPC_LOCK` capability(见上)。
- **驱动不兼容**: 容器内 libibverbs 版本须与宿主机 MLNX_OFED 匹配; 业务镜像建议基于
  `mellanox/ofed` 同版本构建。
- **SR-IOV 场景**: 开启 SR-IOV(VF)时应改用 `k8s-sriov-network-device-plugin`(每 VF 独立独占),
  本插件仅用于 PF(Physical Function)共享。

## 卸载

```bash
kubectl -n kube-system delete ds rdma-shared-dp-ds
kubectl -n kube-system delete cm rdma-devices
```
