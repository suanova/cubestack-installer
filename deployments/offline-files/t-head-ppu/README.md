# offline-files/t-head-ppu/

T-Head 真武 PPU 离线资产根目录。**两种 device plugin 二选一**：

- `T_HEAD_PPU_PLUGIN_SOURCE=ack`（默认）：ACK `ack-ppu-device-plugin` PoC；
- `T_HEAD_PPU_PLUGIN_SOURCE=native`：自研 `t-head-ppu-device-plugin` fallback。

不要把两个插件同时装在同一节点：它们都上报 `alibabacloud.com/ppu`，会重复/冲突分配。

## 目录内容

```text
offline-files/t-head-ppu/
├── README.md
├── registry-cn-wulanchabu.ack.aliyuncs.com_acs_ppu-device-plugin_<tag>.tar
├── <harbor>_suanova_t-head-ppu-device-plugin_<version>.tar
├── ppu-driver-<version>-<kernel>.run
├── ppu_<hggcrt>_<os>-<version>.run
└── linux-headers-<kernel>.deb      # 可选；KMD 本地编译需要
```

- ACK 镜像：上游公开镜像；离线 tar 由联网机用 `skopeo copy … docker-archive:` 导出到本目录。
  文件名需包含镜像 basename 与 tag（`16_t_head_ppu_device_plugin.sh` 用 `find_offline_tar`
  按后缀匹配）。如需纳入公共镜像 catalog，登记到 `container-image-mirror`——2026-11 起
  installer 不再维护 `images.manifest`。
- 自研镜像：由 `t-head-ppu-device-plugin` 仓库构建并推送到 Harbor；tar 同样导出到本目录。
  **镜像不存在时模块会报缺失 tar**——启用 native 前先把镜像构建/推送好。
- KMD/SDK runfile：不是容器镜像，手工放到本目录。
- KMD 需要目标内核的 `linux-headers-$(uname -r)`、`gcc`、`make`、
  `elfutils-libelf-devel`；离线节点若没有，请把对应 `.deb` 一并放入本目录并由
  `t_head_ppu_runtime` 模块安装（当前模块先做预检并给出明确缺失提示）。

## 获取

```bash
# 联网机：把 ACK 镜像导出为 docker-archive tar
# (文件名含镜像 basename + tag; 部署机只从内置 registry 拉取)
skopeo copy --override-os linux --override-arch amd64 \
  docker://registry-cn-wulanchabu.ack.aliyuncs.com/acs/ppu-device-plugin:v1.4.0-8a13b6d4-topology-aliyun \
  docker-archive:deployments/offline-files/t-head-ppu/registry-cn-wulanchabu.ack.aliyuncs.com_acs_ppu-device-plugin_v1.4.0-8a13b6d4-topology-aliyun.tar

# 自研镜像同理(Harbor → tar), 文件名只需包含 basename 与 version
```

KMD/SDK 从 T-Head/浪潮交付介质或 AIStack 交付包中获取，选择与 CubeStack 目标内核
匹配的 KMD 版本。

## 消费

- 模块 `15_t_head_ppu_runtime.sh`：KMD/SDK 预检/可选安装 + 节点标签。
- 模块 `16_t_head_ppu_device_plugin.sh`：按 `T_HEAD_PPU_PLUGIN_SOURCE` 推送镜像、
  应用 `cubestack-addon/t-head-ppu/{ack,native}/` 下的清单。
- 模块 `24_verify_t_head_ppu.sh`：DaemonSet、节点 allocatable、冒烟 Pod。

> `*.tar` / `*.run` 不入 git；只有本 README 受版本控制。
