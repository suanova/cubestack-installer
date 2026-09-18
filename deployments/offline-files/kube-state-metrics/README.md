# offline-files/kube-state-metrics/

kube-state-metrics 的**离线镜像 tar**(集群对象状态指标数据源)。

- 镜像: `registry.k8s.io/kube-state-metrics/kube-state-metrics:<tag>`(tag 带 `v`, 默认 `v2.20.0`)
- 版本真相: `cluster.conf` 的 `PROMETHEUS_IMAGE_KSM`
- tar 命名: `registry.k8s.io_kube-state-metrics_kube-state-metrics_<tag>.tar`(按**上游 ref** 命名,
  模块 08 用 `*<repo>_<tag>.tar` 通配查找)

## 取镜像(二选一)

```bash
# 推荐: 从 Harbor 统一镜像源拉(先由 CI 同步到 harbor.isuanova.com/mirrors/**)
sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group kube-state-metrics

# 直连上游(不经 Harbor)
sudo ./deployments/scripts/tools/images/prometheus-save-images.sh   # 该脚本同时下载 prometheus 全套
```

## 谁消费

`modules/03_addon/08_prometheus.sh` 在部署时把本目录的 tar 推入**集群内置 registry**,
并把 chart 的镜像注册域重写过去 —— 节点只从内置 registry 拉取, 不访问公网。

## 升级

改 `cluster.conf` 的 `PROMETHEUS_IMAGE_KSM` → 重同步 Harbor → 重拉 tar → `--steps prometheus`。
完整步骤见 [`../../cubestack-addon/observability/kube-state-metrics/README.md`](../../cubestack-addon/observability/kube-state-metrics/README.md)。

> ⚠ 本目录下的 `*.tar` 已在 `.gitignore` 中忽略(tar 不入库); 只有本 README 受版本控制。
