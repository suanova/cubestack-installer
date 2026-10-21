# offline-files/cli/

CubeStack **CLI 镜像**的离线 tar（开发/滚动通道）。

- 产物: `cubestack-installer-cli.tar`（`docker save` 的镜像归档）+ `.digest`（镜像 ID，用于变更判断）
- 生成: `.github/workflows/rebuild-cli-image.yml`
  - push 到 `main`（部署代码/脚本/模板变更）时自动构建 `cubestack-installer-cli:latest`
  - 构建后导出 tar，并同步到 MinIO:
    ```text
    <bucket>/offline-files/cli/cubestack-installer-cli.tar
    <bucket>/offline-files/cli/cubestack-installer-cli.digest
    ```
  - 镜像内容未变（按 image ID）时跳过上传
- 取回（部署机/联网机）:
  ```bash
  ./deployments/scripts/tools/offline/fetch-offline-from-minio.sh --sub cli
  sudo docker load -i deployments/offline-files/cli/cubestack-installer-cli.tar
  ```
- 发布版本（`2.0.0` 等）的 CLI tar 不在这里：由 `release-publish.sh` 生成到
  `<bucket>/<版本>/cubestack-installer-cli.tar`，随 release 树一起分发。

> 本目录只放 README（tar 不入 git）；MinIO 前缀由 `rebuild-cli-image.yml` 自动创建。
