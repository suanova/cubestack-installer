# offline-files/cli/

CubeStack **CLI 镜像**的说明（本目录不放 tar）。

- 镜像: `harbor.isuanova.com/suanova/cubestack-installer-cli`
  - `push main` → `:latest`（开发通道）
  - `workflow_dispatch` + `version` → `:<version>`（发布通道）
- 镜像内容: 部署代码 + 工具链；不含离线镜像 tar。
- 版本树里的 `cubestack-installer-cli.tar` 由外部打包流程从 Harbor 镜像生成，
  随 `<root>/<version>/` 一起交付。
- 本仓库不再向 MinIO 上传 CLI tar。
