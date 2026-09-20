# offline-files/prometheus/

Prometheus 监控栈(operator + 本体 + Grafana + 边车)的**离线镜像 tar**,共 8 个。

| 镜像 ref | 版本变量(`cluster.conf`) |
|---|---|
| `quay.io/prometheus-operator/prometheus-operator` | `PROMETHEUS_APP_VERSION` |
| `quay.io/prometheus-operator/prometheus-config-reloader` | `PROMETHEUS_APP_VERSION` |
| `quay.io/prometheus-operator/admission-webhook` | `PROMETHEUS_APP_VERSION` |
| `quay.io/prometheus/prometheus` | `PROMETHEUS_IMAGE_PROMETHEUS` |
| `quay.io/prometheus/alertmanager` | `PROMETHEUS_IMAGE_ALERTMANAGER` |
| `docker.io/grafana/grafana` | `PROMETHEUS_IMAGE_GRAFANA` |
| `quay.io/kiwigrid/k8s-sidecar` | `PROMETHEUS_IMAGE_SIDECAR` |
| `docker.io/jkroepke/kube-webhook-certgen` | `PROMETHEUS_IMAGE_CERTGEN` |

- tar 名: 按**上游 ref** 自动派生(`/` 与 `:` → `_`),如
  `docker.io_grafana_grafana_13.2.1-distroless.tar`
- 取镜像(二选一):

  ```bash
  # 推荐: 从 Harbor 统一镜像源拉
  sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group prometheus

  # 或直连上游(该脚本同时下载 prometheus 全套)
  sudo ./deployments/scripts/tools/images/prometheus-save-images.sh
  ```

- 谁消费: `modules/03_addon/08_prometheus.sh`(部署时推入集群内置 registry,chart 镜像注册域重写过去)
- 同栈的另外两个组在各自目录: `offline-files/node-exporter/`、`offline-files/kube-state-metrics/`
- 升级: 改 `cluster.conf` 的版本变量 → 重同步 Harbor → 重拉 tar → `--steps prometheus`

> ⚠ 本目录下的 `*.tar` 已在 `.gitignore` 中忽略(tar 不入库); 只有本 README 受版本控制。
