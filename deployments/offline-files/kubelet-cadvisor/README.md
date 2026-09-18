# offline-files/kubelet-cadvisor/

**本目录刻意不放任何镜像** —— kubelet / cAdvisor **没有独立镜像可备料**。

- cAdvisor 已编译进每个节点的 `kubelet` 进程, 由节点上的 systemd 单元运行;
- 指标由 kubelet 在 **10250 端口**暴露(`/metrics`、`/metrics/cadvisor`、`/metrics/probes`);
- Prometheus 抓取配置由 `kube-prometheus-stack` chart 自带的 kubelet ServiceMonitor 提供
  (默认开启), 因此**无需部署任何工作负载**。

`deployments/config/images.manifest` 里该 group 同样**不声明任何镜像** —— 这是有意的,
用"清单里是空的"明确表达"此处确实无镜像", 而不是漏配。

## 那它怎么验证?

`modules/03_addon/28_verify_prometheus.sh` 第 ④ 步查 `container_cpu_usage_seconds_total`
(只有 kubelet 的 `/metrics/cadvisor` 会产生)→ 有数据才算容器指标链通。

## 详细说明

为什么不需要部署、指标从哪来、抓取失败的常见原因与排查命令, 见:
[`../../cubestack-addon/observability/kubelet-cadvisor/README.md`](../../cubestack-addon/observability/kubelet-cadvisor/README.md)
