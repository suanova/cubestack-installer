# offline-files/node-exporter/

node-exporter 的**离线镜像 tar**(节点/主机指标数据源)。

- 镜像: `quay.io/prometheus/node-exporter:<tag>`(tag 带 `v`, 默认 `v1.12.1`)
- 版本真相: `cluster.conf` 的 `PROMETHEUS_IMAGE_NODE_EXPORTER`
- tar 命名: `quay.io_prometheus_node-exporter_<tag>.tar`(按**上游 ref** 命名)
- ⚠ tag 必须与 chart 的 `prometheus-node-exporter.image.distroless` 取值匹配:
  本项目该开关为 `false` → 用 `v1.12.1`(而非 `v1.12.1-distroless`)

## 取镜像(二选一)

```bash
# 推荐: 从 Harbor 统一镜像源拉
sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group node-exporter

# 直连上游
sudo ./deployments/scripts/tools/images/prometheus-save-images.sh
```

## 谁消费

`modules/03_addon/08_prometheus.sh` 推送进集群内置 registry; chart 以 **DaemonSet** 部署到每个节点
(含 master, 靠 tolerations)。

## 升级

改 `cluster.conf` 的 `PROMETHEUS_IMAGE_NODE_EXPORTER` → 重同步 → 重拉 tar → `--steps prometheus`。
完整步骤见 [`../../cubestack-addon/observability/node-exporter/README.md`](../../cubestack-addon/observability/node-exporter/README.md)。

> ⚠ 本目录下的 `*.tar` 已在 `.gitignore` 中忽略(tar 不入库); 只有本 README 受版本控制。
