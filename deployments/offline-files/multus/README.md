# offline-files/multus/

Multus CNI 的**离线镜像 tar**(容器多网卡; 单镜像)。

- 镜像: `ghcr.io/k8snetworkplumbingwg/multus-cni:${MULTUS_IMAGE_TAG}`(默认 `snapshot-thick`)
- tar 名: 按上游 ref 自动派生 → `ghcr.io_k8snetworkplumbingwg_multus-cni_snapshot-thick.tar`
- 版本真相: `cluster.conf` 的 `MULTUS_IMAGE_TAG`(须与 vendored manifest 一致)
- 目录变量: `cluster.conf` 的 `MULTUS_SAVE_DIR`(默认指本目录)
- 取镜像:

  ```bash
  sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group multus
  ```

- 谁消费: `modules/03_addon/09_multus.sh`
- ⚠ 本目录**只放镜像 tar**; Multus 的部署清单(Thick plugin DaemonSet)在
  `deployments/cubestack-addon/multus/multus-daemonset-thick.yml`,不在这里
- 升级: 改 `MULTUS_IMAGE_TAG` → 重拉 tar → `--steps multus`

> ⚠ 本目录下的 `*.tar` 已在 `.gitignore` 中忽略(tar 不入库); 只有本 README 受版本控制。
