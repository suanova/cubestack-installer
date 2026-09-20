# offline-files/rdma/

RDMA 共享设备插件(k8s-rdma-shared-dev-plugin)的**离线镜像 tar**(单镜像)。

- 镜像: `ghcr.io/mellanox/k8s-rdma-shared-dev-plugin:${RDMA_IMAGE_TAG}`(默认 `v1.5.4`)
- tar 名: 按上游 ref 自动派生 → `ghcr.io_mellanox_k8s-rdma-shared-dev-plugin_v1.5.4.tar`
- ⚠ **上游在 `ghcr.io/mellanox`(不是 Docker Hub)**; tag 风格不统一: `1.4.0` **无 v 前缀**
  (ghcr 上 `v1.4.0` 是 404), `v1.5.x` **带 v**。默认 `v1.5.4`(修了 RoCE 口被 `issm` 硬检查丢弃的问题)
- 版本真相: `cluster.conf` 的 `RDMA_IMAGE_TAG`; 部署模块按 tar 内**实际 tag** 自适应
- 目录变量: `cluster.conf` 的 `RDMA_SAVE_DIR`(默认指本目录)
- 取镜像:

  ```bash
  sudo ./deployments/scripts/tools/images/rdma-save-images.sh     # 该组件专用工具
  sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group rdma   # 或走统一 Harbor 源
  ```

- 谁消费: `modules/03_addon/10_rdma_shared_dev_plugin.sh`
  (ConfigMap + DaemonSet 由模块 heredoc 生成,源不落盘;本目录只供镜像 tar)
- 升级: 改 `RDMA_IMAGE_TAG` → 重拉 tar → `--steps rdma_shared_dev_plugin`

> ⚠ 本目录下的 `*.tar` 已在 `.gitignore` 中忽略(tar 不入库); 只有本 README 受版本控制。
