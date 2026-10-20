# offline-files/nvidia-gpu-operator/

NVIDIA GPU Operator(英伟达官方)的**离线镜像 tar**(组件镜像 + 预编译驱动 + 验证样例)。

- 消费方: `modules/03_addon/08_nvidia_gpu_operator.sh`(离线模式从本目录 tar 推入集群内置 registry)
- 备料(联网机): `./deployments/scripts/tools/images/nvidia-save-images.sh`(skopeo 直拉, 免 root/docker)
  - `--list` 仅打印将保存的镜像与 skopeo 命令
  - ⚠ 内置 **NGC 预编译覆盖预检**: `driver:<分支>-<内核>-ubuntu22.04` 不存在即报错(内核不在覆盖表)
- tar 命名 = 上游 ref 的 `/ :` → `_`, 如
  - `nvcr.io_nvidia_gpu-operator_v26.7.2.tar`
  - `nvcr.io_nvidia_driver_595-5.15.0-186-generic-ubuntu22.04.tar`
  - ⚠ 驱动 tar 的**内核段必须与有卡节点 `uname -r` 一致**(预编译按内核绑定)

## 集内清单(16 个 ref; 与 chart 渲染提取同口径)

| 类别 | ref |
|---|---|
| operator 本体 | `nvcr.io/nvidia/gpu-operator:${NVIDIA_GPU_OPERATOR_VERSION}`(validator 同镜像) |
| 运行时组件 | `k8s/container-toolkit` · `k8s-device-plugin`(v26 起含 GFD) · `k8s/dcgm-exporter` · `cloud-native/k8s-mig-manager` · `cloud-native/k8s-driver-manager` |
| 预编译驱动 | `nvcr.io/nvidia/driver:${NVIDIA_GPU_DRIVER_BRANCH}-${NVIDIA_GPU_DRIVER_PRECOMPILED_KERNEL}-ubuntu22.04` |
| 验证样例 | `k8s/cuda-sample:vectoradd-cuda12.5.0-ubuntu22.04` |
| NFD | `registry.k8s.io/nfd/node-feature-discovery:v0.19.0`(**清单登记在 k8s-base 组, 避免重复; tar 收入本目录**) |
| 边缘组件(保守备料) | `k8s-cc-manager` · `nvidia-sandbox-device-plugin` · `vgpu-device-manager` · `kubevirt-gpu-device-plugin` |

## 其他通道 / 取源口径(2026-10-14 用户口径: Harbor 为唯一镜像源)

```bash
# 主通道: ① CI(manifest push 触发)同步到 harbor.isuanova.com/mirrors/**;
#         ② 从 Harbor save 离线 tar(本目录):
./deployments/scripts/tools/images/nvidia-save-images.sh     # Harbor 优先, 上游回退; 覆盖 NFD
# 等价通用通道(Harbor 组拉取; 不含 NFD —— NFD 由上面工具专门兜住):
sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group nvidia-gpu-operator
```

## 升级 / 变更内核

1. 改 `cluster.conf` 的 `NVIDIA_GPU_OPERATOR_VERSION` / `NVIDIA_GPU_DRIVER_BRANCH` /
   `NVIDIA_GPU_DRIVER_PRECOMPILED_KERNELS`(先核实 NGC 覆盖);
2. 重跑 `nvidia-save-images.sh`(按新版本补齐; 旧 tar 确认无引用后手工删, 会白占 1-2GB/驱动);
3. 内核升级的完整纪律见 `docs/nvidia-gpu-operator.md`。

> ⚠ 本目录 `*.tar` 已在 `.gitignore` 中忽略(tar 不入库); 只有本 README 受版本控制。
