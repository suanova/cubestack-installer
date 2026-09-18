# node-exporter

> 监控三件套之一 —— **节点/主机**数据源。本文档说明它在 CubeStack 里的落地方式、
> 离线备料与**升级步骤**。

## 1. 它是什么 / 提供什么指标

node-exporter 以 **DaemonSet** 形式跑在**每个节点**上, 采集**主机层面**的硬件与 OS 指标
(它不看 K8s 对象, 也不看容器)。

| 指标前缀 | 例子 | 说明 |
|---|---|---|
| `node_cpu_*` | `node_cpu_seconds_total` | CPU 各模式累计时间(算利用率的基础) |
| `node_memory_*` | `node_memory_MemAvailable_bytes` | 内存可用/缓存/换页 |
| `node_filesystem_*` | `node_filesystem_avail_bytes` | 各挂载点磁盘容量与可用空间 |
| `node_disk_*` | `node_disk_io_time_seconds_total` | 磁盘 I/O |
| `node_network_*` | `node_network_receive_bytes_total` | 网卡收发字节/错误/丢包 |
| `node_load*` | `node_load1` | 负载均值 |

**GPU 指标不在这里** —— NVIDIA 看 DCGM Exporter, 沐曦看 mx-exporter(见
`deployments/cubestack-addon/metax-gpu-operator/`)。

## 2. 在 CubeStack 里怎么部署

**不单独部署, 也不手写 YAML** —— 它是 `kube-prometheus-stack` 的 subchart, 由
`modules/03_addon/08_prometheus.sh` 一并安装。

- 开关: `cluster.conf` 的 `PROMETHEUS_ENABLED=true`(默认 true)
- 命名空间: `PROMETHEUS_NAMESPACE`(默认 `monitoring`)
- 工作负载: DaemonSet `<release>-prometheus-node-exporter`
- 安装命令: `sudo ./deploy-cluster.sh --steps prometheus`
- 单独验证: `sudo ./deploy-cluster.sh --steps verify_prometheus`

### ⚠ 为什么必须用 chart 而不是手写 DaemonSet

手写 DaemonSet 极容易漏掉这几项, 漏了就是"部分节点没有指标"或"挂载了不该挂的宿主目录":

- `hostNetwork: true` + `hostPID: true`(否则看不到真实主机进程)
- `/proc`、`/sys`、`/` 的**只读**挂载与 rootfs 正确绑定
- **tolerations**: 必须容忍 `node-role.kubernetes.io/control-plane` 等污点,
  否则 master 节点没有 node-exporter
- 安全上下文与端口占用

chart 的 `prometheus-node-exporter` subchart 已经把这些调好了, 因此本项目**只通过
`--set prometheus-node-exporter.*` 定制**。

### 本项目对 chart 做的一处显式设置

安装时模块 08 传了 `--set prometheus-node-exporter.image.distroless=false`:

- `distroless=true` 的镜像**不含 shell**, 排查时无法 `kubectl exec` 进去看挂载是否正确;
- 选非 distroless 变体便于现场诊断, 代价是镜像略大。

> 该值同时决定镜像 tag: distroless 版 tag 形如 `v1.12.1-distroless`,
> 非 distroless 版是 `v1.12.1`。清单里的 `PROMETHEUS_IMAGE_NODE_EXPORTER` 必须与
> `distroless` 的取值**保持一致**, 否则会出现 "tar 找不到 / 拉取 404"。

## 3. 离线备料(镜像)

| 项 | 值 |
|---|---|
| 镜像 | `quay.io/prometheus/node-exporter:<tag>` |
| tag 变量 | `cluster.conf` 的 `PROMETHEUS_IMAGE_NODE_EXPORTER`(默认 `v1.12.1`) |
| ⚠ tag 带 `v` | 裸 `1.12.1` 在 registry 上**不存在** |
| 离线目录 | `deployments/offline-files/node-exporter/` |
| tar 文件名 | `quay.io_prometheus_node-exporter_<tag>.tar` |

镜像清单声明在 `deployments/config/images.manifest`(group = `node-exporter`)。

```bash
sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group node-exporter
```

## 4. 升级步骤(★ 设计要点)

版本**只有一处真相**: `cluster.conf` 的 `PROMETHEUS_IMAGE_NODE_EXPORTER`。

```bash
# ① cluster.conf: PROMETHEUS_IMAGE_NODE_EXPORTER="v1.13.0"(注意与 distroless 取值匹配)
# ② 同步到 Harbor 镜像源
sudo ./deployments/scripts/tools/images/harbor-sync-images.sh --group node-exporter
# ③ 拉成离线 tar(联网机)
sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group node-exporter --force
# ④ 重新部署
sudo ./deploy-cluster.sh --steps prometheus
# ⑤ 验证有数据
sudo ./deploy-cluster.sh --steps verify_prometheus
```

> 💡 node-exporter 通常是"跟 chart 一起升"最省事: `kube-prometheus-stack` 的 subchart
> 版本与 exporter 版本是配套验证过的。单独跳版本时注意 `distroless` 开关与 tag 后缀的对应关系。

## 5. 验证(不是"pod Running 就算过")

`28_verify_prometheus.sh` 第 ④ 步查一条 **node-exporter 独有的指标** `node_cpu_seconds_total`:

- 有数据 → `node-exporter: N 条时序 ✓`
- 轮询 `VERIFY_METRIC_WAIT`(默认 120s)仍为空 → 判失败(可用
  `VERIFY_MONITORING_STRICT=false` 降级为告警)

手工排查:

```bash
# ① 每个节点都要有一个 pod(数量应等于节点数)
kubectl -n monitoring get ds <release>-prometheus-node-exporter -o wide

# ② 某个 pod 起不来的常见原因
kubectl -n monitoring describe pod <node-exporter-pod> | tail -30
#    - ImagePullBackOff → 离线 tar 没推成功 / tag 与 distroless 取值不匹配
#    - 卡 ContainerCreating → 宿主目录挂载被 SELinux/AppArmor 拦

# ③ 直接看它自己的 /metrics
kubectl -n monitoring port-forward ds/<release>-prometheus-node-exporter 9100:9100
curl -s localhost:9100/metrics | grep -m3 '^node_cpu_seconds_total'
```

## 6. 相关

- 监控底座总体: [`../prometheus/README.md`](../prometheus/README.md)
- 对象状态指标: [`../kube-state-metrics/README.md`](../kube-state-metrics/README.md)
- 容器指标: [`../kubelet-cadvisor/README.md`](../kubelet-cadvisor/README.md)
- 镜像镜像源与升级总纲: `docs/harbor-mirror.md`
