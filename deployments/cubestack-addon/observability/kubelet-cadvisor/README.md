# kubelet / cAdvisor

> 监控三件套之一 —— **容器**数据源。**这一件不需要部署, 也没有镜像**。
> 本文档说明为什么, 以及在 CubeStack 里它到底是靠什么在工作的。

## 1. 结论先行

| 问题 | 答案 |
|---|---|
| 需要单独部署吗? | **不需要**。cAdvisor 已编译进每个节点的 `kubelet` 进程 |
| 需要同步镜像吗? | **不需要**。没有独立镜像; kubelet 由节点上的 systemd 单元跑 |
| 需要配什么? | 只需让 Prometheus **去抓** kubelet 暴露的端点 |
| 谁配的? | `kube-prometheus-stack` chart 自带的 kubelet ServiceMonitor(默认开启) |

`deployments/offline-files/kubelet-cadvisor/` 因此**只有说明文档, 不含任何 tar** ——
这是有意的, 表示"此处确实无镜像可备"。`images.manifest` 里该 group 也刻意**不声明任何镜像**。

## 2. 指标从哪来

kubelet 在**每个节点的 10250 端口**暴露三类端点:

| 端点 | 内容 | 指标前缀 |
|---|---|---|
| `/metrics` | kubelet 自身运行指标 | `kubelet_*` |
| `/metrics/cadvisor` | **容器**资源用量(cAdvisor 数据) | `container_*` |
| `/metrics/probes` | 探针执行统计 | `prober_*` |

容器指标的例子:

| 指标 | 说明 |
|---|---|
| `container_cpu_usage_seconds_total` | 容器 CPU 累计时间(算容器 CPU 用量的基础) |
| `container_memory_working_set_bytes` | 容器内存工作集(K8s OOM 判定用的就是这个) |
| `container_network_receive_bytes_total` | 容器网络收发 |
| `container_fs_usage_bytes` | 容器可写层磁盘占用 |
| `container_spec_cpu_quota` | CPU 配额(与 usage 相除得到使用率) |

> 区分: **kubelet 的 `/metrics`** 讲的是 kubelet 自己; **`/metrics/cadvisor`** 才是**容器**。
> 排查容器 OOM / CPU 打满 / 磁盘写爆, 用的是 `container_*` 这一族。

## 3. 在 CubeStack 里它是怎么被接上的

`kube-prometheus-stack` 的 `values.yaml` 默认:

```yaml
kubelet:
  enabled: true
  serviceMonitor:
    cAdvisor: true      # 抓 /metrics/cadvisor
    probes: true        # 抓 /metrics/probes
```

chart 会因此生成:

- 一个 **`kubelet` Service**(ClusterIP=None, 端口 10250)与对应 **Endpoints**;
- 一个 **ServiceMonitor**, 用 `role: node` 的服务发现把每个节点都纳进来;
- Prometheus 抓取所需的 **ClusterRole**(授权访问 `/api/v1/nodes/<node>/proxy/metrics/cadvisor`
  与 kubelet 的 10250), 见 chart 的 `templates/prometheus/clusterrole.yaml`。

因此**模块 08 不需要为 cAdvisor 做任何额外动作** —— 装完 kube-prometheus-stack
它就在采集了。

### 需要动它的少数场景

| 现象 | 原因与处理 |
|---|---|
| 抓取 `connection refused` / `x509` 失败 | 集群 kubelet 用了非标准的自签证书或改了 serving cert 路径; 需给 ServiceMonitor 配 `tlsConfig.insecureSkipVerify` 或注入 CA |
| cAdvisor 指标基数爆炸 | cAdvisor 默认暴露大量容器级指标; 可在 chart 的 `kubelet.serviceMonitor.metricRelabelings` 里丢弃低频指标 |
| 只想抓 `/metrics` 不抓 cAdvisor | `--set kubelet.serviceMonitor.cAdvisor=false` —— ⚠ 不建议, 那样就没有容器指标了 |

配置入口都在 chart(`--set kubelet.*`), **不要手写 scrape_config 挂到别处**。

## 4. 独立 Prometheus 的等价配置(供参考)

若将来出现"已经有自己的 Prometheus, 只补数据源"的场景, 原生 `prometheus.yml` 里对应的 job
长这样(节选自上游文档, 本项目当前**不用**这种方式):

```yaml
- job_name: 'kubernetes-cadvisor'
  scheme: https
  tls_config:
    ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    insecure_skip_verify: true
  bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
  kubernetes_sd_configs:
    - role: node
  relabel_configs:
    - action: labelmap
      regex: __meta_kubernetes_node_label_(.+)
    - target_label: __address__
      replacement: kubernetes.default.svc:443
    - source_labels: [__meta_kubernetes_node_name]
      regex: (.+)
      target_label: __metrics_path__
      replacement: /api/v1/nodes/${1}/proxy/metrics/cadvisor
```

要点: 走 **API Server 代理**(`/api/v1/nodes/<node>/proxy/...`)而不是直连 10250,
可以复用 ServiceAccount 的 RBAC 与集群 CA, 免去 kubelet 服务端证书的麻烦。

## 5. 验证

`28_verify_prometheus.sh` 第 ④ 步查一条 **cAdvisor 独有的指标** `container_cpu_usage_seconds_total`:

- 有数据 → `kubelet-cAdvisor: N 条时序 ✓`
- 轮询 `VERIFY_METRIC_WAIT`(默认 120s)仍为空 → 判失败
  (环境确实不支持时用 `VERIFY_MONITORING_STRICT=false` 降级为告警)

手工排查:

```bash
# ① ServiceMonitor 在不在
kubectl -n monitoring get servicemonitor | grep kubelet

# ② 从 Prometheus 看 target 状态(为何 down)
kubectl -n monitoring port-forward svc/<release>-prometheus 9090
#   浏览器打开 http://localhost:9090/targets, 找 job="kubelet" 的 Last Error

# ③ 任意节点上直接验证端点可达(需在节点上执行)
curl -sk https://<node-ip>:10250/metrics/cadvisor | head -5

# ④ RBAC: Prometheus 的 SA 有没有 nodes/proxy / nodes/metrics 权限
kubectl -n monitoring get clusterrole <release>-prometheus -o yaml | grep -A5 -E 'nodes/(proxy|metrics)'
```

## 6. 相关

- 监控底座总体: [`../prometheus/README.md`](../prometheus/README.md)
- 对象状态指标: [`../kube-state-metrics/README.md`](../kube-state-metrics/README.md)
- 节点指标: [`../node-exporter/README.md`](../node-exporter/README.md)
- 镜像镜像源与升级总纲: `docs/harbor-mirror.md`
