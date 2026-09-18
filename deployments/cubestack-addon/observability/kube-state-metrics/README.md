# kube-state-metrics(KSM)

> 监控三件套之一 —— **集群对象状态**数据源。本文档说明它在 CubeStack 里的落地方式、
> 离线备料与**升级步骤**。

## 1. 它是什么 / 提供什么指标

kube-state-metrics **监听 Kubernetes API Server**, 把集群对象的状态翻译成 Prometheus 指标。
它**不采集节点硬件**、也**不抓容器** —— 那是 node-exporter 与 kubelet/cAdvisor 的职责。

| 指标前缀 | 例子 | 说明 |
|---|---|---|
| `kube_deployment_*` | `kube_deployment_status_replicas` | Deployment 期望/就绪副本数 |
| `kube_pod_*` | `kube_pod_status_phase` | Pod 阶段(Pending/Running/...)、重启次数 |
| `kube_node_*` | `kube_node_status_condition` | 节点 Ready / MemoryPressure 等状况 |
| `kube_persistentvolumeclaim_*` | `kube_persistentvolumeclaim_status_phase` | PVC 绑定状态 |
| `kube_job_*` / `kube_cronjob_*` | `kube_job_status_succeeded` | 批处理任务状态 |

排查"Deployment 副本数不对 / Pod 为什么 Pending / PVC 为什么没绑上"这类**编排层**问题时,
看的就是 KSM 的指标。

## 2. 在 CubeStack 里怎么部署

**不单独部署, 也不手写 YAML** —— 它是 `kube-prometheus-stack` 的 subchart, 由
`modules/03_addon/08_prometheus.sh` 在安装监控底座时一并装好(operator 模式,
自动带 ServiceMonitor / RBAC / 集群角色)。

- 开关: `cluster.conf` 的 `PROMETHEUS_ENABLED=true`(默认 true)
- 命名空间: `PROMETHEUS_NAMESPACE`(默认 `monitoring`)
- 工作负载: Deployment `<release>-kube-state-metrics`
- 安装命令: `sudo ./deploy-cluster.sh --steps prometheus`
- 单独验证: `sudo ./deploy-cluster.sh --steps verify_prometheus`

官方明确不建议手写 KSM 的 YAML 用于生产(RBAC / 安全上下文 / 亲和性容易漏),
本项目遵循该建议: 只通过 chart 参数(`--set kube-state-metrics.*`)定制。

## 3. 离线备料(镜像)

| 项 | 值 |
|---|---|
| 镜像 | `registry.k8s.io/kube-state-metrics/kube-state-metrics:<tag>` |
| tag 变量 | `cluster.conf` 的 `PROMETHEUS_IMAGE_KSM`(默认 `v2.20.0`) |
| ⚠ tag 带 `v` | 裸 `2.20.0` 在 registry 上**不存在**, 必须写成 `v2.20.0` |
| 离线目录 | `deployments/offline-files/kube-state-metrics/` |
| tar 文件名 | `registry.k8s.io_kube-state-metrics_kube-state-metrics_<tag>.tar` |

镜像清单声明在 `deployments/config/images.manifest`(group = `kube-state-metrics`)。

拉取(联网机):

```bash
sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group kube-state-metrics
```

模块 08 会在部署时把该 tar 推入集群内置 registry, 并把 chart 的镜像注册域重写过去
(`--set kube-state-metrics.image.registry=...`), 节点**只从内置 registry 拉取**。

## 4. 升级步骤(★ 设计要点)

版本**只有一处真相**: `cluster.conf` 的 `PROMETHEUS_IMAGE_KSM`。
`images.manifest` 用 `${PROMETHEUS_IMAGE_KSM}` 占位引用它, 因此:

```bash
# ① 改一处版本(集群上执行)
#    cluster.conf: PROMETHEUS_IMAGE_KSM="v2.21.0"
# ② 同步到 Harbor 镜像源(CI 或联网机; CI 跑 workflow 亦可)
sudo ./deployments/scripts/tools/images/harbor-sync-images.sh --group kube-state-metrics
# ③ 拉成离线 tar(联网机; 也可在部署机能连 Harbor 时直接做)
sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group kube-state-metrics --force
# ④ 重新部署(模块会推新 tar 进内置 registry 并 helm upgrade)
sudo ./deploy-cluster.sh --steps prometheus
# ⑤ 验证数据源真的有数据
sudo ./deploy-cluster.sh --steps verify_prometheus
```

**版本兼容性**: KSM 版本必须与集群 K8s API 版本兼容, 查官方兼容矩阵
(<https://github.com/kubernetes/kube-state-metrics#compatibility-matrix>)。
`kube-prometheus-stack` 默认为你选好了配套版本 —— **不必要时不要单独升 KSM**,
跟着 chart 一起升更省心(见 `docs/harbor-mirror.md` §升级)。

## 5. 验证(不是"pod Running 就算过")

`28_verify_prometheus.sh` 第 ④ 步会查一条 **KSM 独有的指标** `kube_pod_info`:

- 有数据 → `kube-state-metrics: N 条时序 ✓`
- 轮询 `VERIFY_METRIC_WAIT`(默认 120s)仍为空 → 判失败(可用
  `VERIFY_MONITORING_STRICT=false` 降级为告警)

手工排查:

```bash
kubectl -n monitoring get deploy -l app.kubernetes.io/name=kube-state-metrics
kubectl -n monitoring get servicemonitor | grep kube-state-metrics
# 直接看 KSM 自己的 /metrics 有没有 kube_pod_info
kubectl -n monitoring port-forward deploy/<release>-kube-state-metrics 8080:8080
curl -s localhost:8080/metrics | grep -m3 '^kube_pod_info'
```

## 6. 相关

- 监控底座总体: [`../prometheus/README.md`](../prometheus/README.md)
- 节点指标: [`../node-exporter/README.md`](../node-exporter/README.md)
- 容器指标: [`../kubelet-cadvisor/README.md`](../kubelet-cadvisor/README.md)
- 镜像镜像源与升级总纲: `docs/harbor-mirror.md`
