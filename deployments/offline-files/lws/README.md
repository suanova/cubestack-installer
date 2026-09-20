# offline-files/lws/

LeaderWorkerSet(LWS)的**离线镜像 tar**(单镜像; LLM 工作负载调度)。

- 镜像: `registry.k8s.io/lws/lws:${LWS_IMAGE_TAG}`(默认 `v0.10.0`)
- tar 名: 规范名 = 上游 ref 派生 → **`registry.k8s.io_lws_lws_v0.10.0.tar`**(`/` 与 `:` → `_`)
  - 早期文件用的是短横线版 `registry.k8s.io-lws-lws-v0.10.0.tar`; 模块内部先扫 `*.tar` 再兜底
    通配,两种命名都能命中,但新备料请用规范名
- 版本真相: `cluster.conf` 的 `LWS_IMAGE_TAG`
- 取镜像:

  ```bash
  sudo ./deployments/scripts/tools/images/lws-save-images.sh     # 该组件专用工具(输出到本目录)
  sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group lws   # 或走统一 Harbor 源
  ```

- 谁消费: `modules/03_addon/07_gpu_lws.sh`
- ⚠ 本目录**只放镜像 tar**; LWS 的 chart 与清单在 `deployments/cubestack-addon/lws/`
  (`charts/lws-chart-v0.10.0.tgz`、`manifests.yaml`)
- 升级: 改 `LWS_IMAGE_TAG` → 重拉 tar → `--steps gpu_lws`

> ⚠ 本目录下的 `*.tar` 已在 `.gitignore` 中忽略(tar 不入库); 只有本 README 受版本控制。
