# offline-files/perses/

Perses 云原生看板的**离线镜像 tar**,共 2 个。

| 镜像 ref | 版本变量(`cluster.conf`) |
|---|---|
| `docker.io/persesdev/perses` | `PERSES_IMAGE_VERSION`(默认 `v0.54.0`,⚠ 带 `v` 前缀) |
| `docker.io/kiwigrid/k8s-sidecar` | `PERSES_SIDECAR_IMAGE_VERSION`(默认 `2.11.2`,与 08_prometheus 同版本,离线只备一份) |

- tar 名: 按上游 ref 自动派生 → `docker.io_persesdev_perses_v0.54.0.tar`、`docker.io_kiwigrid_k8s-sidecar_2.11.2.tar`
- 目录变量: `cluster.conf` 的 `PERSES_OFFLINE_DIR`(模块内默认指本目录)
- 取镜像:

  ```bash
  # 联网机: 从 Harbor 统一镜像源拉
  sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group perses
  ```

- 谁消费: `modules/03_addon/18_perses.sh`
  - `PERSES_MODE=online`: 部署前先从私服 mirrors 同步镜像到本目录(拉成 `<tar>` + `.digest` 边车,
    digest 未变则跳过); 私服不可达时**自动降级**回本地已有 tar(告警不中断)
  - `PERSES_MODE=offline`: 只用本目录已有 tar,完全不联网
- ⚠ 本目录**只放镜像 tar**; chart 在 `deployments/cubestack-addon/perses/perses-0.23.2.tgz`(+ `.digest` 边车)
- 升级: 改 `PERSES_IMAGE_VERSION` → 重拉 tar → `--steps perses`(chart 侧同步改 `PERSES_CHART_VERSION`)

> ⚠ 本目录下的 `*.tar` 已在 `.gitignore` 中忽略(tar 不入库); 只有本 README 受版本控制。
