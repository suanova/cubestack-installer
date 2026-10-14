# NVIDIA GPU Operator chart(离线副本)

- **文件**: `gpu-operator-v26.7.2.tgz`(小 chart 的 tgz 形态)+ `.digest` 边车
- **上游**: `oci://nvcr.io/nvidia/cloud-native-charts/gpu-operator`
  (备选经典仓库: `helm repo add nvidia https://helm.ngc.nvidia.com/nvidia`)
- **用途**: `08_nvidia_gpu_operator.sh` 部署**恒用**本副本;在线模式仅用它比对刷新
  (见 `helm_chart_ensure`, chart 升级手册见 `deployments/scripts/modules/03_addon/08_nvidia_gpu_operator.sh` 头注释)。
- **镜像集**: 由 `deployments/scripts/tools/images/nvidia-chart-images.sh` 从渲染产物提取(唯一来源);
  备料用 `deployments/scripts/tools/images/nvidia-save-images.sh`。

## 升级到新版本(示例: v26.8.0)

```bash
cd deployments/cubestack-addon/nvidia-gpu-operator
# ① 拉新版本(容器 d / 联网机; OCI chart)
helm pull oci://nvcr.io/nvidia/cloud-native-charts/gpu-operator --version v26.8.0
# ② ⚠ OCI chart 的 Digest 是 manifest 摘要, **不能**自己 sha256sum —— 只能从 pull 输出抄:
helm pull oci://nvcr.io/nvidia/cloud-native-charts/gpu-operator --version v26.8.0 2>&1 \
    | sed -n 's/^Digest:[[:space:]]*//p' | tr -d '\n' > gpu-operator-v26.8.0.tgz.digest
# ③ 更新 cluster.conf 的 NVIDIA_GPU_OPERATOR_VERSION; 用 nvidia-save-images.sh 重备镜像; 
# ④ 提交 tgz + .digest 边车(不提交 = 下次部署又回到旧版)。
```

## 已知形态(供提取器维护参考)

- 组件镜像以 **(repository, image, version) 三元组**落在 ClusterPolicy CR 里, 由 operator 在运行期组合;
  helm 渲染产物中只有 operator 本体与 NFD 是完整 ref。
- v26 起 **GFD 已并入 device-plugin 镜像**(`gfd.image = k8s-device-plugin`, 提取去重后只有一个 ref)。
- `usePrecompiled=true` 时实际驱动镜像 = `driver:<分支>-<内核>-<OS>`(运行期由 operator 依 NFD 内核标签组合)。
