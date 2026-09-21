# CubeStack BMC Exporter chart(离线副本)

本目录是 `cubestack-bmc-exporter-chart` 的**离线副本**,随 git 分发。模块 `33_bmc_exporter.sh`
安装时**恒用这里的 tgz**,不直接装私服上拉到的那份 —— 在线只用于比对 digest 后决定要不要刷新。

| 文件 | 说明 |
|---|---|
| `cubestack-bmc-exporter-<ver>.tgz` | CI 发布到私服 `harbor.isuanova.com/suanova` 的 chart |
| `cubestack-bmc-exporter-<ver>.tgz.digest` | digest 边车(`sha256:...`,值是 OCI manifest 摘要) |

⚠ 文件名里**没有** `-chart` 后缀 —— 私服仓库名是 `cubestack-bmc-exporter-chart`,但模块把 helm
落盘名规整成了 `<chart 名去掉 -chart>-<ver>.tgz`(见 `BMC_EXPORTER_CHART_TGZ` 的派生)。

⚠ 边车是 **OCI manifest 摘要**,不是文件 sha256,**不能**用 `sha256sum` 重算 —— 必须从
`helm pull` 的输出里取 `Digest:` 那一行。

## 刷新(联网机,需私服可达)

```bash
helm pull oci://harbor.isuanova.com/suanova/cubestack-bmc-exporter-chart \
  --version <ver> -d /tmp
# 把落盘的 cubestack-bmc-exporter-chart-<ver>.tgz 改名为 cubestack-bmc-exporter-<ver>.tgz,
# 连同 helm 报告的 Digest: 一起写成本目录下的 tgz 与 .digest, 然后 commit
```

⚠ 升版本时 `cluster.conf` 的 `BMC_EXPORTER_CHART_VERSION` 要一起改。

## 为什么有这个目录

模块原本就写了"私服拉取失败回退本地 chart",但仓库里**从没有过那份文件** —— 私服一抖动
(实测有过 TLS 超时)回退就是空转。补上这个目录,回退才真的能兜住。

见 `docs/scripts-development-spec.md` §2.4。
