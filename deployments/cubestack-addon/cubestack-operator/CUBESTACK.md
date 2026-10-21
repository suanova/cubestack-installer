# CubeStack Operator chart — 已迁移

本目录**不再保存 chart**。`cubestack-operator-chart-*.tgz` 与 `.tgz.digest` 已迁移到:

```
deployments/offline-files/cubestack-operator/charts/
```

## 为什么

- chart 与平台组件镜像 tar 是同一个版本单元, 现在随离线包(MinIO)一起分发;
- CLI 镜像不再包含 chart; 离线安装时模块从挂载的 `offline-files/` 读取;
- 在线模式仍从 Harbor OCI 拉取并刷新这份本地副本。

## 获取 / 刷新

```bash
# 部署机(离线包)
./deployments/scripts/tools/offline/fetch-offline-from-minio.sh --sub cubestack-operator

# 内网同步机(Harbor → 离线包 → MinIO)
bash deployments/scripts/tools/images/cubestack-platform-sync.sh \
  --collection cubestack-operator --no-pull-state

# 手工
helm pull oci://harbor.isuanova.com/suanova-private/cubestack-operator-chart \
  --version 1.0.0-latest -d deployments/offline-files/cubestack-operator/charts
# 把 helm 输出的 "Digest:" 写入 <tgz>.digest —— 不要用 sha256sum
```

## 过渡期

本目录仅作为**一个版本**的只读 fallback。模块解析优先级:

```
CUBESTACK_OPERATOR_CHART_DIR
  > offline-files/cubestack-operator/charts/
  > 本目录
```

下一版本删除本目录、`.gitignore` 中的旧规则, 以及 `check-modules.sh` ⑩ 的过渡豁免。
