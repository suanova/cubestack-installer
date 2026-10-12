# offline-files/dev-lab/

开发镜像(jupyter / ssh 系列)**离线镜像 tar**(6 个, 均为平台开发环境镜像)。

- 镜像(上游 = 本台 Harbor 的 `suanova` 项目, tag 统一由 `DEV_LAB_IMAGE_TAG` 控制, 默认 `latest`):
  - `harbor.isuanova.com/suanova/jupyter-minimal:latest`
  - `harbor.isuanova.com/suanova/jupyter-maca-pytorch:latest`
  - `harbor.isuanova.com/suanova/jupyter-cuda-pytorch:latest`
  - `harbor.isuanova.com/suanova/ssh-ubuntu22.04:latest`
  - `harbor.isuanova.com/suanova/ssh-maca-pytorch:latest`
  - `harbor.isuanova.com/suanova/ssh-cuda-pytorch:latest`
- tar 名: 按**上游 ref** 自动派生(如 `harbor.isuanova.com_suanova_jupyter-minimal_latest.tar`)
- ⚠ **上游即本台 Harbor(不是公共 registry)**: `harbor-save-images.sh` 对同源组**直接用原始 ref**
  拉取(不拼 `mirrors/`); 需要在能连 Harbor 的机器上执行(容器 CLI 自带 skopeo 与凭据)
- ⚠ tag 是滚动的 `latest`: 离线 tar 会随上游滚动构建失效 —— **重新部署前重跑一次 save 工具**
  (模块推送按 digest 比对, 内容变了自动重推, 没变跳过)
- 版本真相: `cluster.conf` 的 `DEV_LAB_IMAGE_TAG`; 目录变量: `DEV_LAB_SAVE_DIR`(默认指本目录)
- 取镜像:

  ```bash
  sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group dev-lab
  ```

- 谁消费: `modules/03_addon/08_dev_lab.sh` —— 每次默认部署自动把 tar 推入**集群内置 registry**
  的 `<REG>/suanova/<name>:<tag>`(节点从此拉取, 不访问 Harbor); 缺 tar 的镜像该次 warn 跳过
- 升级/刷新: 上游滚动构建后重跑 save(覆盖 tar) → 下次部署模块按 digest 自动重推

> ⚠ 本目录下的 `*.tar` 已在 `.gitignore` 中忽略(tar 不入库); 只有本 README 受版本控制。
