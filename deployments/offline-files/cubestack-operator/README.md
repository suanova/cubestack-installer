# offline-files/cubestack-operator/

CubeStack 平台 Operator **及其平台组件**的离线资产(2026-10-08 起从各兄弟目录收敛于此)。

## 结构

| 内容 | 说明 |
|---|---|
| `harbor.isuanova.com_suanova-private_cubestack-operator_latest.tar` | **operator 本体**(滚动 tag, 与 chart 配套; 由 `harbor-save-images.sh --group cubestack-operator` 生成) |
| 平台组件镜像 tar(**顶层扁平**, 42 项) | envoy 网关 5 / prometheus 栈 10(含 grafana/ksm/node-exporter/alertmanager/operator 家族)/ perses 1 / BMC exporter 2 + digest 边车 / cubepilot 4 + digest 边车。**2026-10-08 从已并入的旧目录**(envoy/ prometheus/ perses/ bmc/ cubepilot/)收敛 —— 它们对应 chart CR 默认启用的组件(envoyGateway/prometheus(+grafana)/perses/exporters.bmc/cubepilot) |
| `observability/`(**子目录**) | 非镜像资产: `helm/cubestack-bmc-exporter-chart/`(BMC exporter chart tgz+digest)/ `dashboards/grafana/` / `recording-rules/` / `MANIFEST.txt` |

⚠ **镜像 tar 必须在顶层扁平**: 消费方(见下)用 `find_offline_tar` 按文件名 glob 扫描**顶层** `*.tar`, 子目录不会被找到。

## 消费方与行为

- `modules/03_addon/25_cubestack_operator.sh`:
  - operator 本体: 源优先级 `auto` = Harbor(在线) → **离线 tar** → 本地 docker daemon; 逐个推入集群内置 registry, 节点只从那里拉;
  - 滚动 tag 幂等靠 **digest 比对**(不是 tag 存在性); 要拿新的本体 tar: `harbor-save-images.sh --group cubestack-operator --force`。
- 版本真相: `cluster.conf` 4.6b 的 `CUBESTACK_OPERATOR_IMAGE_TAG` / `CUBESTACK_OPERATOR_CHART_VERSION`;
  目录变量: `CUBESTACK_OPERATOR_OFFLINE_DIR`(默认指本目录)。
- 平台组件镜像的**上游 ref** 见 tar 文件名(ref 派生命名); 这些组件当前**不在** `images.manifest`
  的 group 清单里(原 group 随 09-23 组件模块移除而删), 重新登记与否见 offline-files/os/README.md 的讨论。

## 历史(2026-10-08 目录收敛)

原 `bmc/` `cubepilot/` `envoy/` `kube-state-metrics/` `node-exporter/` `observability/` `perses/`
`prometheus/` 八个目录为已移除模块的离线残留; 现由 cubestack-operator(平台组件统一编排)承接,
镜像并入本目录(重复项按内容 digest 去重: kube-state-metrics 与 prometheus 批 md5 相同、
node-exporter/kiwigrid 的 docker-save 版与 prometheus 批 digest 相同, 各删一份)。

- chart 的离线副本**不在**本目录(`cubestack-addon/cubestack-operator/`), 随 git 分发。

> ⚠ 本目录下的 `*.tar` / `*.digest` 已在 `.gitignore` 中忽略(不入库); 只有本 README 受版本控制。
