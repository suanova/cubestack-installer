# Prometheus Operator(kube-prometheus-stack)离线部署资源

本目录存放 `08_prometheus` 模块(modules/03_addon/08_prometheus.sh)部署使用的 **helm chart 源码**(vendored 进 git), 与 `docs/cluster-components-plan.md` P1 监控底座对齐。

```
observability/prometheus/
└── kube-prometheus-stack/     # chart 源码(默认 90.0.0 / appVersion v0.93.1)
```

## 备料(联网机)

- **chart 刷新**: `sudo bash deployments/scripts/tools/images/prometheus-fetch-charts.sh`
  (helm pull 或 curl 直下官方 chart tgz → 解包覆盖本目录; 版本用环境变量 `PROMETHEUS_CHART_VERSION` 指定)
- **镜像下载**: `sudo bash deployments/scripts/tools/images/prometheus-save-images.sh`
  (独立运行, 不依赖 cluster.conf; docker pull → skopeo 兜底, 每镜像独立 tar + `--platform linux/amd64`,
  保存到 `deployments/offline-files/prometheus/`; `--list` 只看清单, `--force` 强制重下)

chart 默认启用的组件镜像(与 save 脚本内置清单一致):

| 组件 | 镜像 |
|---|---|
| operator / config-reloader / admission-webhook | quay.io/prometheus-operator/*:v0.93.1 |
| prometheus | quay.io/prometheus/prometheus:v3.14.0-distroless |
| alertmanager | quay.io/prometheus/alertmanager:v0.34.0 |
| node-exporter | quay.io/prometheus/node-exporter:1.12.1 |
| kube-state-metrics | registry.k8s.io/kube-state-metrics/kube-state-metrics:2.20.0 |
| grafana + k8s-sidecar | docker.io/grafana/grafana:13.2.1-distroless + quay.io/kiwigrid/k8s-sidecar:2.11.2 |
| webhook certgen | docker.io/jkroepke/kube-webhook-certgen:1.8.8 |

(thanosRuler / kubeRBACProxy / windows-exporter / CRD 升级 Job 默认关闭, 不备料)

## 部署

`PROMETHEUS_ENABLED=true` 后随全量部署, 或 `--steps prometheus` 单独部署。模块行为:

- 离线镜像 tar → 推送进集群内置 registry(镜像名保留原始 repo 路径, 如 `registry.cubestack.io:5000/quay.io/prometheus/prometheus`)
- `helm upgrade --install kube-prometheus <chart> -n monitoring --create-namespace`, 全部组件镜像显式重写为内置 registry
- 参数: `retention=15d`、Prometheus PVC 50Gi(**不指定 storageClassName, 用系统默认 SC**)
- 参数化: `PROMETHEUS_RETENTION_DAYS` / `PROMETHEUS_STORAGE_SIZE` / `PROMETHEUS_NAMESPACE`(cluster.conf)
