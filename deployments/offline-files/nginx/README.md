# offline-files/nginx/

nginx 的**离线镜像 tar**(内置 registry 的 nginx 副本源 / verify 模块的测试后端)。

- 镜像: `docker.io/library/nginx:${NGINX_TAG}`(默认 `1.27`)
- tar 名: **`nginx.tar`** —— 清单第 3 列的"历史短名"覆盖,不能改成 `<repo>_<tag>.tar`:
  `lib-common.sh` 的 `ensure_registry_nginx()` 按**字面文件名**读取
- 版本真相: `cluster.conf` 的 `NGINX_TAG`
- 取镜像(二选一):

  ```bash
  # 推荐: 从 Harbor 统一镜像源拉(CI 已同步到 mirrors/**)
  sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group nginx

  # 或直连 Docker Hub 自存
  sudo docker pull nginx:1.27
  sudo docker save nginx:1.27 -o deployments/offline-files/nginx/nginx.tar
  ```

- 谁消费: `lib-common.sh` 的 `ensure_registry_nginx()`(被 verify 模块调用,如
  `modules/03_addon/30_verify_rdma_shared_dev_plugin.sh`)
- 升级: 改 `cluster.conf` 的 `NGINX_TAG` → 重拉 tar → 重跑相关 verify

> ⚠ 本目录下的 `*.tar` 已在 `.gitignore` 中忽略(tar 不入库); 只有本 README 受版本控制。
