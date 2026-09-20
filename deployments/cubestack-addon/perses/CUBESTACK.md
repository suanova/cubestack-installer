# Perses chart(CubeStack vendored 离线副本)

本目录是 **Perses 官方 chart 的离线副本**,随 git 分发。模块 `18_perses.sh` 安装时**恒用这里的 tgz**,
不直接装线上拉到的那份 —— 线上只用于比对 digest 后决定要不要刷新这份副本。

## 目录内容

| 文件 | 说明 |
|---|---|
| `perses-<ver>.tgz` | 官方 chart(来自经典 helm repo `perses.github.io/helm-charts`) |
| `perses-<ver>.tgz.digest` | digest 边车,值为 helm 报告的 `Digest:`(`sha256:...`) |

> 对经典 helm repo 而言,**digest 就是 tgz 文件的 sha256**,可用 `sha256sum` 交叉核验。
> OCI chart 不是这样(那是 manifest 摘要),**必须**从 `helm pull` 输出里取。

## 刷新(联网机)

```bash
./deployments/scripts/tools/images/perses-fetch-charts.sh                    # 默认版本
PERSES_CHART_VERSION=0.24.0 ./deployments/scripts/tools/images/perses-fetch-charts.sh
```

脚本会同时写出 `.digest` 边车。**跑完必须 commit** —— 不提交等于没刷新。

⚠ 升版本时 `cluster.conf` 里的 `PERSES_CHART_VERSION` 也要一起改,否则模块会去找一个不存在的文件名。

## 模块为什么这么用

见 `docs/scripts-development-spec.md` §2.4 与 `docs/perses.md`。

简言之:`31_cubepilot` / `33_bmc_exporter` 原本都写了"私服拉取失败就回退本地 chart",
但仓库里**压根没有那份文件**,私服一抖动回退就是空转。这个目录的存在就是为了让回退真的能兜住。

## 其他文档

- 部署/配置/排障: `docs/perses.md`
- 上游 chart 源码: https://github.com/perses/helm-charts
