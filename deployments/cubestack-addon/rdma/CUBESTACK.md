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
- 上游文档: https://github.com/Mellanox/k8s-rdma-shared-dev-plugin

## 资源配置(全局单一 ConfigMap)

模块生成的 ConfigMap `kube-system/rdma-devices`(`config.json`)描述资源池, 字段含义:

| cluster.conf 变量 | 默认 | 说明 |
|---|---|---|
| `RDMA_RESOURCE_PREFIX` | `nvidia.com` | 扩展资源前缀 |
| `RDMA_RESOURCE_NAME` | `mlx5_0` | 扩展资源名(**pool 模式**; pod 申请 `nvidia.com/mlx5_0`; per-hca 模式忽略) |
| `RDMA_HCA_MODE` | `pool` | 资源模式: **`pool`**=全部 HCA 聚合为单个资源(默认, 兼容旧部署); **`per-hca`**=每块 HCA 独立资源(资源名=节点实际 RDMA 设备名如 `mlx5_0`/`mlx5_1`/..., pod 可按资源名精确选卡) |
| `RDMA_HCA_MAX` | `100` | 每资源最大共享 Pod 数(rdmaHcaMax; per-hca 模式下每块卡各一份配额) |
| `RDMA_IF_NAMES` | *(自动检测)* | 宿主机 RDMA 网卡名(逗号分隔, selectors.ifNames); ⚠ **留空 = 模块自动扫描所有节点 `/sys/class/infiniband/*/device/net/` 收集真实设备名+网卡名**(兼容 IB=ibsX / RoCE=ens*/manage0 混合), 显式设置则按此精确过滤 |
| `RDMA_ACTIVE_ONLY` | `true` | 自动检测只收录**链路状态 ACTIVE** 的 HCA(读 `/sys/class/infiniband/*/ports/*/state`); DOWN/DISABLED 卡不建资源不暴露; `false`=全部暴露。仅作用自动检测(RDMA_IF_NAMES 为空), 显式 IF_NAMES 时忽略 |
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
