# offline-files/

运行时挂载点：存放外部打包流程物化的版本树 `offline-files/` 内容。

- 来源：版本树 `<root>/<version>/offline-files/`（`release.env` + `tree.tsv` +
  `SHA256SUMS` + 镜像/chart tar + 基础镜像）。
- 安装时通过 `--release <version>` 或直接挂载到本目录使用。
- 第三方镜像由 `container-image-mirror` 仓库同步到 Harbor mirrors；
  本目录不保存镜像清单，tar 也不入库。
