# T-Head 真武 PPU 离线部署

CubeStack 对平头哥真武 PPU 采用 **ACK PoC 优先、native fallback**：

```text
T_HEAD_PPU_PLUGIN_SOURCE=ack      # 默认：ACK ack-ppu-device-plugin 镜像 PoC
T_HEAD_PPU_PLUGIN_SOURCE=native   # fallback：自研 t-head-ppu-device-plugin
```

两种插件都上报 `alibabacloud.com/ppu`，**同一节点只能装一个**。切换来源时模块用同名
DaemonSet 覆盖，并在卸载分支清理。

## 前置条件

1. **KMD**：节点内核驱动已加载，`/dev/alixpu`、`/dev/alixpu_ctl`、
   `/dev/alixpu_ppu<N>` 存在；`ppu-smi -L` 正常。
2. **KMD 与目标内核匹配**：KMD runfile 必须在目标内核上编译/安装成功。需要
   `linux-headers-$(uname -r)`、`gcc`、`make`、`elfutils-libelf-devel`。
3. **SAIL SDK**：
   - `source=native`：必需，插件需要 `ppu-smi`；
   - `source=ack`：可选，ACK 镜像自带 PPU 用户态库，SDK 仅用于节点验证/运维。
4. **节点标签**：
   - NFD 自动提供 `feature.node.kubernetes.io/pci-1ded.present=true`；或
   - installer fallback 标签 `ppu.example.com/device=true`。
   DaemonSet 的 `nodeAffinity` 对两者取 OR。
5. **镜像**：
   - ACK：`registry-cn-wulanchabu.ack.aliyuncs.com/acs/ppu-device-plugin:v1.4.0-8a13b6d4-topology-aliyun`；
   - native：`harbor.isuanova.com/suanova/t-head-ppu-device-plugin:<version>`，需先由插件仓库
     构建/推送。

## 离线资产

```text
deployments/offline-files/t-head-ppu/
├── README.md
├── registry-cn-wulanchabu.ack.aliyuncs.com_acs_ppu-device-plugin_<tag>.tar
├── <harbor>_suanova_t-head-ppu-device-plugin_<version>.tar
├── ppu-driver-<version>-<kernel>.run
├── ppu_<hggcrt>_<os>-<version>.run
└── linux-headers-<kernel>.deb
```

镜像 tar（联网机导出；文件名含镜像 basename + tag，模块用 `find_offline_tar` 匹配）：

```bash
skopeo copy --override-os linux --override-arch amd64 \
  docker://registry-cn-wulanchabu.ack.aliyuncs.com/acs/ppu-device-plugin:v1.4.0-8a13b6d4-topology-aliyun \
  docker-archive:deployments/offline-files/t-head-ppu/registry-cn-wulanchabu.ack.aliyuncs.com_acs_ppu-device-plugin_v1.4.0-8a13b6d4-topology-aliyun.tar
```

KMD/SDK runfile 不是容器镜像，手工放入上述目录。

## 使用

```bash
# 1. 打开总开关
sudo ./deploy-cluster.sh --enable t_head_ppu
# 或 cluster.conf: T_HEAD_PPU_ENABLED=true

# 2. 节点运行时预检（默认只预检；确认后可打开自动安装）
sudo ./deploy-cluster.sh --steps t_head_ppu_runtime
# cluster.conf:
#   T_HEAD_PPU_INSTALL_KMD=true
#   T_HEAD_PPU_INSTALL_SDK=true

# 3. 部署插件（默认 ACK PoC）
sudo ./deploy-cluster.sh --steps t_head_ppu

# 4. 验证
sudo ./deploy-cluster.sh --steps verify_t_head_ppu
```

切换到 native：

```bash
T_HEAD_PPU_PLUGIN_SOURCE=native sudo ./deploy-cluster.sh --steps t_head_ppu --fresh
sudo ./deploy-cluster.sh --steps verify_t_head_ppu
```

## ACK PoC 失败判据

- `failed to initialize NVML: Driver Not Loaded`，但 KMD/`/dev/alixpu*` 已验证；
- 反复出现 ioctl/ABI 错误，疑似镜像内 `libuki` 与宿主 KMD 不匹配；
- 无法枚举/分配整卡；
- ACK DaemonSet/RBAC 在目标集群无法稳定重建。

失败后切 `T_HEAD_PPU_PLUGIN_SOURCE=native`。native 只做整卡；不要指望 `.sliced`
或 MIG（M890/M890P 无硬件 MIG）。

## 验证边界

`verify_t_head_ppu` 验证：

- DaemonSet Running；
- 节点 `alibabacloud.com/ppu*` allocatable；
- 冒烟 Pod 申请一个 PPU 资源，`/dev/alixpu*` 已注入；
- 宿主挂载了 `/usr/local/PPU_SDK` 时，容器内 `ppu-smi -L` 额外执行。

不验证真实训练/推理吞吐、ICN 拓扑或切片隔离；这些需要业务镜像单独验收。

## 与 GPUStack 的关系

GPUStack Operator 是更完整的 K8s PPU 参考（HGML 探测、`.shared/.sliced/.partitioned`、
HGGC slicing shim、MIG、NFD、Kueue）。CubeStack 当前只吸收其关键点：

- `alibabacloud.com/ppu` 资源名；
- NFD `pci-1ded` 节点标签；
- 设备节点 `index` 候选 + `stat` 字符设备 minor 校验；
- 严重 ECC/XID 健康判定。

不引入 GPUStack Operator/slicing shim，保持 fallback 轻量。

> 四种方案的完整对比、ACK 镜像拆解证据、GPUStack/LJ-RuntimeKit 的详细分析见
> [`t-head-ppu-solutions.md`](t-head-ppu-solutions.md)。
