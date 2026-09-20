# CubeStack observability 资产(vendored 副本)

本目录是 **cubestack 源仓库** `observability/` 下资产的只读副本, 供 installer 离线部署使用。
**不要手工编辑** —— 改动会在下次刷新时被覆盖。

| 子目录 | 内容 | 消费方 |
|---|---|---|
| `recording-rules/` | 6 个 `PrometheusRule` CR(gpu / gpu-nvidia / infra / inference / inference-vllm / devenv) | `modules/03_addon/08_prometheus.sh` apply 到 `monitoring` |
| `dashboards/grafana/` | 11 个 Grafana dashboard JSON | `08_prometheus.sh` 做成 ConfigMap, 由 grafana sidecar 导入 |

来源与本次拉取的 commit 见 `SOURCE.txt`(工具自动生成)。

## 刷新

```bash
bash deployments/scripts/tools/observability/fetch-observability-assets.sh
git diff --stat deployments/cubestack-addon/observability/cubestack/   # 看这次上游改了什么
```

## 为什么是 vendored 而不是部署时下载

与 `cubestack-addon/` 下的 chart(kube-prometheus-stack / envoy / rook)同一约定:
部署机通常**不能访问 GitHub**, 资产必须随仓库一起走。因此升级资产 = 重跑刷新脚本 + 提交,
而不是让部署流程去联网。

## 与节点目录 `/opt/cubestack/observability` 的关系

`observability/docs/installer-requirements.md` §5 的离线打包约定把资产放到节点的
`/opt/cubestack/observability/`。两者不冲突 —— 模块按以下顺序选取, 并会打印实际用了哪个:

1. `CUBESTACK_OBSERVABILITY_DIR` 非空且含 `recording-rules/` → 用它(离线包场景)
2. `/opt/cubestack/observability/recording-rules/` 存在 → 用它(照文档 §5 打包的场景)
3. 否则 → 用本目录(仓库内 vendored, 默认)

刷新到节点目录:

```bash
bash deployments/scripts/tools/observability/fetch-observability-assets.sh --dir /opt/cubestack/observability
```

## 上游需求文档

- `observability/docs/installer-requirements.md` —— installer 部署要求(本实现的需求源)
- `observability/docs/dependencies.md` —— 各组件必须打的 label / 暴露的指标(如
  `ai.cubestack.io/inference-service`), recording rule 的 join 依赖它们

本仓库对应的实现说明与踩坑记录见 `docs/prometheus-observability.md`。
