# offline-files/observability — CubeStack 可观测性离线资产

**本目录是生成物**, 由 `deployments/scripts/tools/offline/pack-observability-assets.sh` 装配,
源为仓库内 vendored 副本(`deployments/cubestack-addon/observability/cubestack/` 与
`deployments/cubestack-addon/bmc-exporter/`)。**不要手工编辑这里的文件** —— 改了下次装配会被覆盖。

| 子目录 | 内容 | 消费方 |
|---|---|---|
| `recording-rules/` | 6 个 PrometheusRule yaml | 模块 `08_prometheus`(apply 到集群) + `28_verify_prometheus`(逐组断言实际加载) |
| `dashboards/grafana/` | 11 个 Grafana dashboard json(→ ConfigMap, sidecar 自动导入) | 同上 |
| `helm/cubestack-bmc-exporter-chart/` | BMC exporter chart(tgz + digest 边车) | 模块 `33_bmc_exporter`(实际安装用仓库 vendored 副本, 这里供离线包完整性) |

分发: 本目录随 `sync-to-minio.sh` 推到 MinIO, 部署机用 `fetch-offline-from-minio.sh` 拉取
(两者都自动发现新子目录, 无需白名单); `trim-offline-files.sh` 不处理本目录。

模块侧的查找顺序(`08_prometheus.sh` / `28_verify_prometheus.sh` 同一口径):
`CUBESTACK_OBSERVABILITY_DIR` > `/opt/cubestack/observability` > 本目录 > 仓库内 vendored。

刷新: 先 `tools/observability/fetch-observability-assets.sh` 更新 vendored 源(联网机, 从上游
suanova/cubestack 取), **提交**后再跑本工具重新装配。
