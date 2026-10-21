# offline-files/cubestack-operator/charts/

CubeStack 平台 Operator 的 **helm chart 离线副本**, 随离线包(MinIO)分发。

```
charts/
├── README.md                                          # 本文件(受版本控制)
├── cubestack-operator-chart-1.0.0-latest.tgz          # chart(不入 git)
└── cubestack-operator-chart-1.0.0-latest.tgz.digest   # Digest 边车(不入 git)
```

- 上游: `oci://harbor.isuanova.com/suanova-private/cubestack-operator-chart`
- **不是平台组件**: `charts/` 不在 `CubeStackCluster.spec.components` 里, 模块的
  组件镜像扫描会显式跳过它; 不要把它写进 `CUBESTACK_OPERATOR_COMPONENTS`。
- **Digest 语义**: `.tgz.digest` 写 `helm pull` 输出的 `Digest:` 行(OCI manifest 摘要),
  不是 tgz 的 sha256; 不要用 `sha256sum` 重算。

## 刷新与获取

```bash
# 内网同步机: Harbor → charts/ → MinIO
bash deployments/scripts/tools/images/cubestack-platform-sync.sh \
  --collection cubestack-operator --no-pull-state

# 无内网同步机: operator 仓库发 operator-chart-updated,
# .github/workflows/refresh-operator-chart.yml 在 GitHub runner 上完成同样动作

# 部署机: 连同镜像 tar 一起取回
./deployments/scripts/tools/offline/fetch-offline-from-minio.sh --sub cubestack-operator

# 手工
helm pull oci://harbor.isuanova.com/suanova-private/cubestack-operator-chart \
  --version 1.0.0-latest -d deployments/offline-files/cubestack-operator/charts
```

模块解析优先级: `CUBESTACK_OPERATOR_CHART_DIR` > 本目录 > 旧
`deployments/cubestack-addon/cubestack-operator/`(只读 fallback, 保留一个版本)。

> `.tgz` / `.tgz.digest` 由 `.gitignore` 忽略; 本 README 是唯一受版本控制的条目
> (空目录进不了 git)。
