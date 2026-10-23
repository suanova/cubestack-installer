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
  - 发布顺序: tar 先上传、`.digest` 后上传（digest = 发布提交标记）；run 结束前回读校验
    远端 digest 与 tar 大小，不一致即失败。push / 手动触发由 workflow 级 concurrency
    串行化，不会并发写同一前缀；若 run 中途中断留下“新 tar + 旧 digest”，下次运行会按
    digest 不一致重传两者（自愈）。
- 取回（部署机/联网机）:
  ```bash
  ./deployments/scripts/tools/offline/fetch-offline-from-minio.sh --sub cli
  sudo docker load -i deployments/offline-files/cli/cubestack-installer-cli.tar
  ```
- 发布版本（`2.0.0` 等）的 CLI tar 不在这里：由 `release-publish.sh` 生成到
  `<bucket>/<版本>/cubestack-installer-cli.tar`，随 release 树一起分发。

> 本目录只放 README（tar 不入 git）；MinIO 前缀由 `rebuild-cli-image.yml` 自动创建。
