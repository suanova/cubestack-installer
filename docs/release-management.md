# CubeStack release-2.0 版本化制品管理方案

> **状态**: v5（已实施；离线回归通过，待实机发布验证）
> **编写日期**: 2026-10-21
> **决策确认**: 2026-10-21（见 §10）
> **实施落地**: 2026-10-21（`load_config` / `--release` / `fetch --release` / 发布定义 / `release-publish.sh` / 离线回归）
> **适用对象**: 发布经理 / 部署脚本维护者 / 交付工程师
> **适用范围**: `release-2.0` 及后续版本；**以离线 MinIO 为主**，Harbor 部分仅为建议
> **关联文档**:
> - [`docs/harbor-mirror.md`](harbor-mirror.md) —— 上游镜像 → Harbor `mirrors` 的现有机制
> - [`docs/cubestack-operator.md`](cubestack-operator.md) —— operator 部署与滚动 `latest`
> - [`deployments/offline-files/cubestack-operator/README.md`](../deployments/offline-files/cubestack-operator/README.md) —— 平台组件离线镜像现状
> - [`deployments/config/images.manifest`](../deployments/config/images.manifest) —— 上游镜像清单

---

## 0. 结论先行

**不新建桶、不重排现有 `offline-files/<group>/`、不改部署模块的业务逻辑**，只在桶根新增版本目录：

```text
cubestack-installer/                     # MinIO 桶根
├── offline-files/                       # 现有 dev 通道，原样不动
│   ├── ceph/  kubespray/  rdma/  cubestack-operator/ ...
├── 2.0.0/                               # 新增：一个自包含的发布版本
│   ├── offline-files/                   # 与现有 offline-files 完全同构
│   │   ├── release.env                  # 版本变量（部署时加载）
│   │   ├── release.json                 # 发布元数据
│   │   ├── SHA256SUMS                   # 全树校验和
│   │   ├── _SUCCESS                     # 最后写入；存在才算发布完成
│   │   ├── kubespray/v2.32.0/           # 含二进制/packages/images(k8s-base + ceph)
│   │   ├── cubestack-operator/          # 与 offline-files 同构(含 charts/)
│   │   ├── rdma/  multus/  dev-lab/  model-collection/  ...
│   │   └── ...                          # 只包含本版本启用的组件
│   └── cubestack-installer-cli-v2.0.0.tar      # 2.0.0 的 CLI 镜像（离线加载用）
└── 1.9.0/                               # 历史版本，供回滚
```

部署时只多一个开关：

```bash
# cluster.conf
CUBESTACK_RELEASE="2.0.0"
```

**已定范围（2026-10-21）**: 发布树**包含** `dev-lab` 与 `model-collection`（接受按版本重复的
存储冗余）；**不包含** `virtual-machine`。所有自研组件统一 `2.0.0`（`model-collection` 里的
sglang / vllm-metax 保持各自上游版本）；版本开关同时支持 `cluster.conf` 与
`deploy-cluster.sh --release`。

**MinIO 结构（2026-10-21 定稿）**: `cubestack-installer/offline-files/` 完全不动；
桶根新增 `<版本>/offline-files/` + `<版本>/cubestack-installer-cli-v<版本>.tar`（见上图）。

`load_config` 会把 `OFFLINE_FILES_ROOT` 指到 `.../2.0.0/offline-files`，并加载该目录的
`release.env`；现有模块的 tar 查找逻辑**一行不用改**。

**代码改动总量估计**：

| 文件 | 改动 | 估计行数 |
|---|---|---|
| `deployments/scripts/lib-common.sh` | `load_config` 识别 `CUBESTACK_RELEASE`、加载 `release.env`、重定向 11 个离线目录变量；`ensure_registry_nginx` 增加发布树路径 | ~35 |
| `deployments/scripts/tools/offline/fetch-offline-from-minio.sh` | 新增 `--release` / `--list-releases` / `--no-verify`（下载/磁盘预检逻辑复用现有实现） | ~60 |
| `deployments/scripts/deploy-cluster.sh` | 新增 `--release <版本>` 参数 | ~5 |
| `deployments/config/cluster.defaults.conf` | 新增 `CUBESTACK_RELEASE` / `CUBESTACK_RELEASE_ROOT` 默认空值 | 2 |
| `.gitignore` | 忽略运行时目录 `offline-releases/` | 1 |
| `deployments/releases/<版本>/` | 新增发布清单（release.env / release-images.tsv） | 每版本 2 个文件 |
| `deployments/scripts/modules/03_addon/02_ceph.sh` | lvm2 离线包预检改用 `${OFFLINE_FILES_ROOT}/os/packages` | 1 |
| `deployments/scripts/tools/node/install-worker-packages.sh` | `PKG_DIRS` 增加 `${OFFLINE_FILES_ROOT}/os/packages` | 1 |
| **其余部署模块（03_addon/*.sh）** | **0 改动** | **0** |

如果连 `load_config` 都不想改，也可以手工 `export OFFLINE_FILES_ROOT=...` 并自行设置 11 个目录变量，
但那样容易漏配；建议保留这 ~35 行。

---

## 1. 现有部署代码是怎么找 tar 的（设计必须遵守的事实）

### 1.1 路径派生

`deployments/scripts/lib-common.sh:736-751`：

```bash
OFFLINE_FILES_ROOT="${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}"
OFFLINE_FILES_DIR="${OFFLINE_FILES_DIR:-${OFFLINE_FILES_ROOT}/kubespray/${KUBESPRAY_VERSION}}"
LOCAL_REPO_DIR="${LOCAL_REPO_DIR:-${OFFLINE_FILES_DIR}}"
```

- `OFFLINE_FILES_ROOT` 是**所有组件目录的共同父目录**；
- `OFFLINE_FILES_DIR` 是 kubespray 的版本资产目录（裸二进制 + `images/` + `packages/`）；
- 模块普遍用 `OFFLINE_FILES_ROOT/<group>` 找镜像 tar。

### 1.2 各模块的实际目录变量

| 模块 | 变量 | 默认值（`cluster.defaults.conf`） |
|---|---|---|
| operator + 平台组件 | `CUBESTACK_OPERATOR_OFFLINE_DIR` | `${REPO_ROOT}/deployments/offline-files/cubestack-operator` |
| Ceph | `CEPH_IMAGE_DIR` | `${REPO_ROOT}/deployments/offline-files/kubespray/images`（模块内另有 `${OFFLINE_FILES_DIR}/images` 兜底，但 defaults 已赋值，实际用 defaults 值） |
| MetaX | `METAX_OFFLINE_DIR` / `METAX_PKG_DIR` | `${REPO_ROOT}/deployments/offline-files/metax-gpu` |
| Multus | `MULTUS_SAVE_DIR` | `${REPO_ROOT}/deployments/offline-files/multus` |
| NVIDIA GPU | `NVIDIA_GPU_OPERATOR_OFFLINE_DIR` | `${REPO_ROOT}/deployments/offline-files/nvidia-gpu-operator` |
| RDMA | `RDMA_SAVE_DIR` | `${REPO_ROOT}/deployments/offline-files/rdma` |
| netshoot | `NETSHOOT_SAVE_DIR` / `NETSHOOT_BASE_TAR` | `.../netshoot` / `.../os/netshoot.tar` |
| dev-lab | `DEV_LAB_SAVE_DIR` | `${REPO_ROOT}/deployments/offline-files/dev-lab` |
| model images | `MODEL_IMAGES_SAVE_DIR` | `${REPO_ROOT}/deployments/offline-files/model-collection` |

> **关键**: 这些变量**不跟随** `OFFLINE_FILES_ROOT`。所以版本切换必须同时重定向它们，否则
> operator 仍然会去 dev 目录找 tar。方案在 `load_config` 的 release 分支统一处理（§4.1）。

### 1.3 tar 命名规则

`deployments/scripts/tools/images/lib-image-manifest.sh:213-219`：

```text
<上游 ref> 的 / 和 : 全部替换为 _，再加 .tar
例: registry.k8s.io/sig-storage/csi-provisioner:v6.2.0
 -> registry.k8s.io_sig-storage_csi-provisioner_v6.2.0.tar
```

少数历史短名由清单第 3 列锁死：`busybox.tar`、`nginx.tar`。模块按**文件名**解析目标 ref
（`25_cubestack_operator.sh` 的组件推送逻辑），所以：

- **不要改 tar 命名规则**；
- 版本化发布时，自研镜像文件名里必须带版本（如 `..._2.0.0.tar`），模块才能解析出 `:2.0.0`；
- `busybox.tar` / `nginx.tar` 这种固定名，放进**版本目录内部**即可，不会与 dev 目录冲突。

### 1.4 现有离线取件工具

`fetch-offline-from-minio.sh --sub <路径>` 的现有行为：

```text
远端 <bucket>/offline-files/<sub>/  →  本地 <dest>/<sub>/
```

`--sub` 的源根固定是 `<bucket>/offline-files/`，因此**不能**直接取桶根的
`<bucket>/2.0.0/offline-files/`。本方案新增 `--release`：

```text
远端 <bucket>/<version>/offline-files/  →  本地 <base>/<version>/offline-files/
远端 <bucket>/<version>/cubestack-installer-cli-v<version>.tar
                                        →  本地 <base>/<version>/cubestack-installer-cli-v<version>.tar
```

`--release` 只切换源根与目标布局，磁盘预检、增量续传等逻辑复用现有实现；发布树默认用
**`mc mirror --overwrite --remove` 精确镜像**（`--no-clean` 时用 `mc cp --recursive` 按对象名复制；
`--sub` 仍用 `mc mirror`），从源头保证部署树只由该版本目录的对象决定，与 latest 通道互不影响。

### 1.5 现有 CI 的位置

| 工作流 | 现在做什么 | 与发布的关系 |
|---|---|---|
| `sync-images-to-harbor.yml` | 上游镜像 → Harbor `mirrors/**` | 发布前确保 Harbor 有正确上游镜像 |
| `refresh-latest-offline.yml` | 滚动 `latest` 镜像 → MinIO `offline-files/` | **只服务 dev 通道**，不得写版本目录 |
| `sync-release-images.yml` | 组件镜像/ chart / CLI tar → MinIO `<release>/offline-files/` 原地刷新 | `repository_dispatch` / `push`(release-* 版本定义) / `workflow_dispatch`；CLI tar 由 `rebuild-cli-image.yml` 同 job 内同步；见 §6.6 |
| `release-tag-bump.yml` | 上游 `release-tag-published` → 更新 `deployments/releases/<release>/release.env` 与 `release-images.tsv` → 开/更新一个 `release-bump/<release>` PR | 版本定义必须先 review 合并，push 触发的同步才会执行；见 §6.6 |
| `rebuild-cli-image.yml` | 重建 CLI 镜像；main 导出 tar 到 MinIO `offline-files/cli/`；release-2.0 推版本化镜像并在同一 job 内同步 `<版本>/` CLI 元数据 | main 合并即自动更新 dev CLI tar；release-2.0 push 自动完成 Harbor + MinIO 一致发布；`version=` 可额外推版本 tag |

目前只有 CI、没有 CD。因此本方案的**发布动作**是**在能同时访问 Harbor 与 MinIO 的机器上执行同步脚本**，
CI 仅作为可选自动化入口，不假设存在发布流水线。main 合并的 dev 通道已可自动完成
“构建 CLI 镜像 → 导出 tar → 同步 MinIO `offline-files/cli/`”。

---

## 2. 方案总览：桶根版本目录 + 自包含发布树

### 2.1 MinIO 目录

```text
cubestack-installer/                     # MinIO 桶根
├── offline-files/                       # ┐ 现有 dev 通道，原样不动
│   ├── ceph/                           # │
│   ├── kubespray/v2.32.0/              # │ k8s + ceph 镜像都在 images/
│   ├── cubestack-operator/             # │
│   ├── rdma/  multus/  netshoot/ ...   # ┘
├── 2.0.0/                               # 新增：一个自包含的发布版本
│   ├── offline-files/                   # 与现有 offline-files 完全同构
│   │   ├── release.env                  # 版本变量（部署时加载）
│   │   ├── release.json                 # 发布元数据（含 CLI tar 校验值）
│   │   ├── SHA256SUMS                   # 发布树校验和
│   │   ├── _SUCCESS                     # 最后写入；存在才算发布完成
│   │   ├── kubespray/v2.32.0/           # 含二进制/packages/images(k8s-base + ceph)
│   │   ├── cubestack-operator/          # 本体 + 各组件子目录 + charts/
│   │   ├── rdma/  multus/  dev-lab/  model-collection/  ...
│   │   └── ...                          # 只包含本版本启用的组件
│   └── cubestack-installer-cli-v2.0.0.tar      # 2.0.0 的 CLI 镜像（离线加载用）
└── 1.9.0/                               # 历史版本，供回滚
```

**为什么是"完整树"而不是"共享件 + 清单"**：

- 部署模块只认 `OFFLINE_FILES_ROOT/<group>/<tar>`，完整树让 `OFFLINE_FILES_ROOT` 一次切换即可，
  **模块业务逻辑零改动**（仅 §4.1 的 2 处路径兜底）；
- `busybox.tar` / `nginx.tar` 等固定名文件在版本目录内部隔离，不会互相覆盖；
- 发布树自包含，回滚只需切版本号，不依赖 dev 目录当时的状态；
- 代价是 MinIO 存储按版本重复。控制方式见 §2.3。

### 2.2 本地目录

本地目录与 MinIO 桶根**同构**（`<base>` = 本地镜像的桶根；生产建议 dev 与 release
放在同一个 base 下，便于切换）：

```text
<base>/
├── offline-files/                       # dev 通道（OFFLINE_FILES_ROOT）
├── 2.0.0/
│   ├── offline-files/                   # release 根（部署时 OFFLINE_FILES_ROOT 指向这里）
│   └── cubestack-installer-cli-v2.0.0.tar
└── 1.9.0/
```

`fetch --release 2.0.0 --dest /data/cubestack-installer` 会下载：

```text
/data/cubestack-installer/2.0.0/offline-files/...
/data/cubestack-installer/2.0.0/cubestack-installer-cli-v2.0.0.tar
```

部署配置：

```bash
# cluster.conf
CUBESTACK_RELEASE="2.0.0"
OFFLINE_FILES_ROOT="/data/cubestack-installer/offline-files"   # dev 根
# 可选；默认 <repo>/offline-releases，生产建议显式设为 /data/cubestack-installer
CUBESTACK_RELEASE_ROOT="/data/cubestack-installer"
```

`load_config` 会把 `OFFLINE_FILES_ROOT` 重定向到
`${CUBESTACK_RELEASE_ROOT}/2.0.0/offline-files`，并加载其中的 `release.env`。

- 不设 `CUBESTACK_RELEASE_ROOT` 时，默认取 `${REPO_ROOT}/offline-releases`（新的运行时目录，
  已 gitignore，避免把大文件放进 `deployments/`）；
- 生产环境建议用 `--dest` / `CUBESTACK_RELEASE_ROOT` 指到大磁盘
  （如 `/data/cubestack-installer`），本地布局与 MinIO 桶根同构。

### 2.3 发布树包含哪些组

发布树只放**本版本部署实际需要的组**，由 `release.env` 的 `RELEASE_GROUPS` 控制：

| 类别 | 组 | 默认 |
|---|---|---|
| 基座 | `kubespray`（含 `images/` + 二进制 + packages） | 必选 |
| 存储 | `ceph`（写入 `kubespray/<ver>/images`） | 随 `CEPH_ENABLED` |
| 网络/设备 | `multus`、`rdma`、`netshoot`、`nginx` | 随开关 |
| 平台 | `cubestack-operator`（本体 + 各组件子目录） | 必选 |
| GPU | `metax-gpu`、`nvidia-gpu-operator` | 随开关 |
| 大件（已包含） | `dev-lab`、`model-collection` | **2.0 已确认包含**（接受冗余；单版本体积较大） |
| 虚拟机 | `virtual-machine` | **2.0 已确认排除**（按需单独交付） |

`model-collection` 约 33G、`dev-lab` 约 46G，release-2.0 **明确把它们放进发布树**，
因此单版本发布树会比较大（核心部署集 + 约 79G），这是已接受的存储冗余。
`virtual-machine` 仍不放入发布树；如果后续某个版本需要，再按同一套
`<版本>/offline-files/` 结构单独生成一份发布树，不影响本方案。

> **NVIDIA 组必须自带 NFD 镜像**：`NFD_ENABLED=false`（默认）时 NVIDIA operator 使用内嵌
> NFD，模块只从 `offline-files/nvidia-gpu-operator/` 找 `nfd/node-feature-discovery` 镜像。
> 该镜像在 `images.manifest` 里登记为 `k8s-base`，`release-publish.sh stage` 会从发布树的
> `kubespray/<ver>/images/` 自动补入本组，`verify` 会强制校验（缺失直接失败）。

---

## 3. 发布树内的三个元数据文件

### 3.1 `release.env`

由发布脚本生成，随发布树分发；`load_config` 在 release 模式下 `source` 它。

内容 = **影响 tar 文件名和部署版本的全部变量**。示例：

```bash
# <bucket>/2.0.0/offline-files/release.env
RELEASE_VERSION=2.0.0

# kubespray（决定 OFFLINE_FILES_DIR 的版本子目录）
KUBESPRAY_VERSION=v2.32.0
KUBESPRAY_PROFILE=v2.32.0

# 自研镜像 tag(仅镜像清单/发布树登记用; 部署时 operator 镜像 tag 由 chart 自带, installer 不覆盖)
CUBESTACK_OPERATOR_IMAGE_TAG=v2.0.0
# chart 版本(发布树文件名 + verify 校验用; Chart.yaml version 必须一致)
CUBESTACK_OPERATOR_CHART_VERSION=2.0.0
# release 树自带 chart(offline-files/cubestack-operator/charts/), 部署恒用本地副本
CUBESTACK_OPERATOR_CHART_SYNC=offline
# dev-lab: Harbor 三家 tag 命名不一致, 必须按镜像分别钉; dev-lab 镜像名不追加 release 后缀
DEV_LAB_CPU_TAG=py310-torch2.4
DEV_LAB_MACA_TAG=3.9.0.12-py310-torch2.4
DEV_LAB_CUDA_TAG=26.08
# CLI 镜像(发布脚本用它生成 <版本>/cubestack-installer-cli-v<版本>.tar)
CUBESTACK_CLI_IMAGE=harbor.isuanova.com/suanova/cubestack-installer-cli:v2.0.0

# model-collection 的 sglang / vllm-metax 保持各自上游 tag, 不在这里统一;
# 具体 ref/文件名以 offline-files/model-collection/image-list.tsv 为准。

# 上游固定版本：与 release tree 中 tar 文件名一致
# images.manifest 引用的**全部版本变量都必须在此冻结**(发布机构建时优先于 cluster.conf,
# 否则同一版本在不同发布机上会产出不同 tag 的发布树; test-release-mode.sh ⑥b 门禁)。
K8S_VERSION=v1.35.8
CALICO_VERSION=v3.32.2
CEPH_VERSION=v20.2.2
# …(其余 Ceph/CSI/kubespray 基座版本见 deployments/releases/2.0.0/release.env)
RDMA_IMAGE_TAG=v1.5.4
MULTUS_IMAGE_TAG=v4.2.2-thick

# metax-gpu（RELEASE_GROUPS 包含时；与发布树 tar 文件名一致）
METAX_VERSION=0.15.3
METAX_DRIVER_VERSION=3.8.1.6-amd64
METAX_MACA_IMAGE=maca:3.8.1.2-ubuntu22.04-amd64

# nvidia-gpu-operator（如包含；与发布树 tar 文件名一致）
NVIDIA_GPU_OPERATOR_VERSION=v26.7.2
NVIDIA_GPU_DRIVER_BRANCH=595
NVIDIA_GPU_DRIVER_PRECOMPILED_KERNEL=5.15.0-186-generic

# 本发布树包含的组（供发布脚本/人工核对）
RELEASE_GROUPS="kubespray ceph multus rdma netshoot nginx cubestack-operator dev-lab model-collection metax-gpu nvidia-gpu-operator"
```

规则：

- **不要**在 `release.env` 里写 `OFFLINE_FILES_ROOT` / 各 `*_SAVE_DIR`；这些由 `load_config`
  根据实际根目录派生（§4.1）。
- `release.env` 中的变量在 release 模式下**优先于 `cluster.conf` / `cluster.defaults.conf`**。
  发布树是版本真相；要例外，请改发布树并重新发布，而不是在客户 `cluster.conf` 里覆盖。
- **operator 版本默认由 chart 决定(2026-10-22)**: 发布树的 chart 版本可以与 release 版本不同
  (例: release `2.0.0-rc1` + chart `cubestack-operator-chart-1.0.0-latest.tgz`); 部署模块按
  `<RELEASE>` / `CUBESTACK_OPERATOR_CHART_VERSION` / `Chart.yaml version` 发现 chart。
  operator 镜像 tag **默认不传**, 由 chart 自带(`appVersion` / `values.image.tag`)决定;
  只有必要时才设 `CUBESTACK_OPERATOR_IMAGE_TAG_OVERRIDE=<tag>`(仅覆盖 cubestack-operator
  自身镜像, **不覆盖** operator catalog 内其他组件版本)。`CUBESTACK_OPERATOR_IMAGE_TAG`
  仅用于镜像清单/发布树登记。发布树的镜像 tar 必须按最终 operator ref 命名。
- **`release-publish.sh verify` 门禁**: chart `Chart.yaml` 的 `version` 必须等于
  `CUBESTACK_OPERATOR_CHART_VERSION`, `appVersion` 必须等于 `CUBESTACK_OPERATOR_IMAGE_TAG`
  (防止 chart 与镜像错配); `release-images.tsv` 必须登记该 operator tag; `RELEASE_GROUPS`
  中每个组必须在发布树里至少落位一个文件。
- ⚠ `KUBESPRAY_VERSION` / `K8S_VERSION` 等 **kubespray 版本面变量**随后会被
  `deployments/config/profiles/<KUBESPRAY_PROFILE>.profile` 接管（`load_config` 的既有逻辑）。
  发布时 CLI 镜像固定为 `2.0.0`，镜像内的 profile 随之冻结，所以两者应当一致；发布脚本需校验
  `release.env` 的 kubespray 版本与 CLI 镜像内 profile 一致。
- `KUBESPRAY_PROFILE` 指向 CLI 镜像内已有的版本档案；发布时 CLI 镜像固定为 `2.0.0`，
  档案随之冻结。

### 3.2 `release.json`

供审计和排障，不参与部署；也可用纯文本 `release.txt`，但推荐 JSON
（`fetch`/发布脚本需要解析 `cli_tar_sha256`）：

```json
{
  "release": "2.0.0",
  "installer_version": "2.0.0",
  "git_tag": "v2.0.0",
  "git_commit": "a1b2c3d4e5f6...",
  "built_at": "2026-10-21T12:00:00Z",
  "built_by": "release-operator",
  "kubespray_version": "v2.32.0",
  "operator_chart_version": "2.0.0",
  "groups": ["kubespray", "ceph", "multus", "rdma", "netshoot", "nginx", "cubestack-operator", "dev-lab", "model-collection"],
  "cli_image": "harbor.isuanova.com/suanova/cubestack-installer-cli:2.0.0",
  "cli_tar": "../cubestack-installer-cli-v2.0.0.tar",
  "cli_tar_sha256": "<64位hex，与 sha256sum 输出一致>",
  "cli_tar_size": 123456789,
  "harbor": {
    "mirror": "harbor.isuanova.com/mirrors/**",
    "self_built": "harbor.isuanova.com/suanova-private/*:2.0.0"
  }
}
```

### 3.3 `SHA256SUMS` 与 `_SUCCESS`

```text
# 在 <版本>/offline-files/ 根目录生成（路径相对该根）
<sha256>  kubespray/v2.32.0/kubeadm-1.35.8-amd64
<sha256>  cubestack-operator/harbor..._cubestack-operator_2.0.0.tar
...
```

- `SHA256SUMS` 覆盖 `<版本>/offline-files/` 内除自身和 `_SUCCESS` 外的全部文件；
- `cubestack-installer-cli-v2.0.0.tar` 在 `<版本>/` 下，校验值写入 `release.json` 的
  `cli_tar_sha256` / `cli_tar_size`（不放进 `SHA256SUMS`，避免跨目录相对路径）；
- CLI tar 文件名**必须带发布版本**（`cubestack-installer-cli-v<版本>.tar`），保证不同版本在同一
  本地桶根/下载目录互不覆盖；`fetch` 仍兼容旧布局 `cubestack-installer-cli.tar`
  （`release.json` 无 `cli_tar` 字段或远端只有旧名时自动回退）。
- `_SUCCESS` 内容为版本与时间，**最后写入**；
- fetch 侧先检查 `_SUCCESS`，再下载，最后 `sha256sum -c` + 校验 CLI tar；
  (2026-10-28 起统一由 `verify-offline-files.sh` 校验，并校验
  `_SUCCESS.sha256sums == sha256(SHA256SUMS)` 绑定与清单双向覆盖)
- 发布脚本**拒绝覆盖**已存在的 `<版本>/`；修复发新 patch 版本。
- 发布树随带校验器 `offline-files/tools/verify-offline-files.sh`（由 `SHA256SUMS`
  覆盖），供纯宿主机部署离线使用。

**release-2.0 组件原地刷新例外（2026-10-26）**：

- `sync-release-images.yml` + `release-sync-images.sh` 可以原地刷新已发布版本；
  这是**唯一**允许修改已存在 `<版本>/` 的受控通道，范围仅 `cubestack-operator/` 集合、
  operator chart、CLI tar 和三个 `release.env` 变量（见 §6.6）。
- 刷新开始写 `<版本>/_REFRESH_PENDING`，并**临时删除** `offline-files/_SUCCESS`；
  fetch 在此期间会明确报“发布正在原地刷新”，不会拿半套树。
- 刷新完成后最后写 `_SUCCESS`，删除 marker；失败保留 marker + 无 `_SUCCESS`，
  下一次同 subdirs/`all` 重跑修复。
- CLI tar 的 raw manifest digest 同时记录在 `<版本>/_CLI_IMAGE_DIGEST`（offline-files 外）
  和 `release.json.cli_image_digest`；CLI tar 本身仍由 `release.json.cli_tar_sha256/size` 校验。
- **CLI 一致性不变量**：Harbor 镜像 digest == `release.json.cli_image_digest` ==
  `<版本>/_CLI_IMAGE_DIGEST`，且 `sha256(<版本>/cubestack-installer-cli-v<版本>.tar)` ==
  `release.json.cli_tar_sha256`。release-2.0 的 `rebuild-cli-image.yml` 在同一 job 内调用
  `release-sync-images.sh --component cli ...`，脚本在写 `_SUCCESS` 前断言上述值；失败则不写
  `_SUCCESS`，fetch 会拒绝半套树。

---

## 4. 版本切换：`CUBESTACK_RELEASE`

### 4.1 `load_config` 的改动（约 30 行）

在 `deployments/scripts/lib-common.sh` 的 `load_config` 中，**版本档案块之前**插入
（约 line 654 前）：

```bash
# ---- release 模式: 版本目录 + release.env ----
OFFLINE_FILES_ROOT="${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}"
if [ -n "${CUBESTACK_RELEASE:-}" ]; then
    # 本地桶根: 默认 <repo>/offline-releases; 大磁盘场景显式设置
    CUBESTACK_RELEASE_ROOT="${CUBESTACK_RELEASE_ROOT:-${REPO_ROOT}/offline-releases}"
    _rel_root="${CUBESTACK_RELEASE_ROOT}/${CUBESTACK_RELEASE}/offline-files"
    if [ ! -f "${_rel_root}/release.env" ]; then
        err "未找到发布版本 ${CUBESTACK_RELEASE}: ${_rel_root}/release.env"
        err "  先取件: ./deployments/scripts/tools/offline/fetch-offline-from-minio.sh --release ${CUBESTACK_RELEASE} --dest ${CUBESTACK_RELEASE_ROOT}"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "${_rel_root}/release.env"
    if [ "${RELEASE_VERSION:-}" != "${CUBESTACK_RELEASE}" ]; then
        err "release.env 版本不符: RELEASE_VERSION=${RELEASE_VERSION:-<空>} CUBESTACK_RELEASE=${CUBESTACK_RELEASE}"
        exit 1
    fi
    OFFLINE_FILES_ROOT="${_rel_root}"

    # 这些变量默认写死指向 dev offline-files, release 模式必须重定向
    METAX_OFFLINE_DIR="${OFFLINE_FILES_ROOT}/metax-gpu"
    METAX_PKG_DIR="${METAX_OFFLINE_DIR}"
    CUBESTACK_OPERATOR_OFFLINE_DIR="${OFFLINE_FILES_ROOT}/cubestack-operator"
    MULTUS_SAVE_DIR="${OFFLINE_FILES_ROOT}/multus"
    NVIDIA_GPU_OPERATOR_OFFLINE_DIR="${OFFLINE_FILES_ROOT}/nvidia-gpu-operator"
    RDMA_SAVE_DIR="${OFFLINE_FILES_ROOT}/rdma"
    NETSHOOT_SAVE_DIR="${OFFLINE_FILES_ROOT}/netshoot"
    NETSHOOT_BASE_TAR="${OFFLINE_FILES_ROOT}/os/netshoot.tar"
    # dev-lab / model-collection 也随发布树分发（接受冗余）
    DEV_LAB_SAVE_DIR="${OFFLINE_FILES_ROOT}/dev-lab"
    MODEL_IMAGES_SAVE_DIR="${OFFLINE_FILES_ROOT}/model-collection"
    CEPH_IMAGE_DIR="${OFFLINE_FILES_ROOT}/kubespray/${KUBESPRAY_VERSION}/images"
    export CUBESTACK_RELEASE_ROOT METAX_OFFLINE_DIR METAX_PKG_DIR CUBESTACK_OPERATOR_OFFLINE_DIR \
           MULTUS_SAVE_DIR NVIDIA_GPU_OPERATOR_OFFLINE_DIR RDMA_SAVE_DIR \
           NETSHOOT_SAVE_DIR NETSHOOT_BASE_TAR DEV_LAB_SAVE_DIR \
           MODEL_IMAGES_SAVE_DIR CEPH_IMAGE_DIR
    unset _rel_root
fi
```

要点：

- 放在版本档案块之前，`release.env` 里的 `KUBESPRAY_VERSION` / `KUBESPRAY_PROFILE` 才能生效；
- `CUBESTACK_RELEASE_ROOT` 是**本地桶根**（MinIO `cubestack-installer/` 的镜像），
  默认 `${REPO_ROOT}/offline-releases`；生产环境建议显式设为 `/data/cubestack-installer`；
- ⚠ `release.env` **必须显式设置 `KUBESPRAY_VERSION`**，否则上面 `CEPH_IMAGE_DIR` 会拼出
  `<release>/kubespray//images`，且 `OFFLINE_FILES_DIR` 的默认派生也会拿不到正确版本；
- 后文原来的 `OFFLINE_FILES_ROOT="${OFFLINE_FILES_ROOT:-...}"` 会保留已经设置的值；
- 之后 `OFFLINE_FILES_DIR` / `LOCAL_REPO_DIR` 自动派生到发布树内，kubespray 模块无需改动；
- 目录变量重定向后，各组件模块（operator / metax / multus / rdma / …）直接找到发布树里的 tar；
- 非 release 模式（`CUBESTACK_RELEASE` 为空）**完全走原逻辑**，dev 行为不变。

**配套的 3 处硬编码路径**（不处理会在 release 模式下回落到 dev 目录）：

```bash
# lib-common.sh: ensure_registry_nginx 的搜索路径增加发布树
find_offline_tar ... "${REPO_ROOT}/deployments/offline-files/nginx" \
                     "${OFFLINE_FILES_ROOT}/nginx" \
                     "${LOCAL_REPO_DIR}/images"

# 02_ceph.sh:485 lvm2 离线包预检
[ -d "${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}/os/packages" ]

# install-worker-packages.sh:35 PKG_DIRS 增加
"${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}/os/packages"
```

这三处都是**一行级**修改，且对 dev 模式无影响（默认根就是 `deployments/offline-files`）。

### 4.2 `deploy-cluster.sh --release`（约 5 行）

在参数解析区（`--profile` 旁边）增加：

```bash
--release)   RELEASE_ARG="${2:?--release 需要版本号(如 2.0.0)}"; shift 2 ;;
```

在 `load_config` 之前（与 `--profile` 的 export 同位置）：

```bash
[ -n "${RELEASE_ARG:-}" ] && export CUBESTACK_RELEASE="${RELEASE_ARG}"
```

用法：

```bash
sudo ./deploy-cluster.sh --release 2.0.0
# 等价于 cluster.conf 里写 CUBESTACK_RELEASE="2.0.0"
```

### 4.3 三种模式对照

| 模式 | `CUBESTACK_RELEASE` | `CUBESTACK_RELEASE_ROOT` | 实际 `OFFLINE_FILES_ROOT` | 使用的 tar |
|---|---|---|---|---|
| dev（默认） | 空 | — | `deployments/offline-files` | 现有 `_latest` / 固定版本 tar |
| release（默认） | `2.0.0` | `<repo>/offline-releases` | `<repo>/offline-releases/2.0.0/offline-files` | 发布树 |
| release（大磁盘） | `2.0.0` | `/data/cubestack-installer` | `/data/cubestack-installer/2.0.0/offline-files` | 发布树 |

> `cluster.conf` 里的 `OFFLINE_FILES_ROOT` 仍写 dev 根（`.../offline-files`）；
> release 模式下由 `CUBESTACK_RELEASE_ROOT` + `CUBESTACK_RELEASE` 派生出发布根，
> 再覆盖 `OFFLINE_FILES_ROOT`。

### 4.4 flat 布局：release 资产平铺在 `deployments/offline-files`

如果部署机不希望创建 `<CUBESTACK_RELEASE_ROOT>/<版本>/offline-files/` 版本树，可让 release-2.0
直接使用标准 `deployments/offline-files/`。**推荐无需在 cluster.conf 配置**：只要该目录里有
`release.env`，`load_config` 会自动进入 flat release 模式。

```bash
# 最小用法：把 release 树的 offline-files 平铺到 deployments/offline-files
mc mirror <alias>/<bucket>/2.0.0/offline-files/ /opt/cubestack-installer/deployments/offline-files/
sudo ./deploy-cluster.sh
# load_config 自动读取 offline-files/release.env:
#   CUBESTACK_RELEASE=<release.env 的 RELEASE_VERSION>
#   CUBESTACK_RELEASE_LAYOUT=flat
#   CUBESTACK_RELEASE_ROOT=""（不再使用 /data/cubestack-installer/2.0.0/...）
```

需要显式覆盖时仍可写：

```bash
# cluster.conf（可选）
CUBESTACK_RELEASE="2.0.0"
CUBESTACK_RELEASE_LAYOUT="flat"
# CUBESTACK_RELEASE_ROOT 留空/忽略
```

行为：

- **`release.env` 优先取平铺目录内** `${OFFLINE_FILES_ROOT}/release.env`（部署以它为主）；
  若不存在，才回退仓库内 `deployments/releases/<版本>/release.env`；
- `OFFLINE_FILES_ROOT` 保持 `deployments/offline-files`（容器内
  `/opt/cubestack-installer/deployments/offline-files`）；
- operator / multus / rdma / ceph / dev-lab / model-collection 等全部从该平铺目录读取；
- `CUBESTACK_RELEASE_ROOT` 在 flat 模式下被置空，避免误回落到 `/data/...` 版本树；
- 没有 `release.env` 时保持 dev 模式（读同一目录的 latest 资产）；
- 切回 latest 时若平铺目录里仍有 `release.env`，可显式设 `CUBESTACK_RELEASE_AUTO="false"`
  强制 dev 模式（或移除/改名该 release.env）。

```text
deployments/offline-files/
├── cubestack-operator/
├── kubespray/v2.32.0/{images,packages,...}
├── multus/  rdma/  metax-gpu/  nvidia-gpu-operator/
├── dev-lab/  model-collection/  os/  ...
├── release.env / release.json / SHA256SUMS / _SUCCESS
```

> MinIO 上的 `<bucket>/2.0.0/offline-files/` 仍保持版本化布局；flat 只是**部署机本地**的
> 平铺方式。推荐用 fetch 的 flat 模式：
> ```bash
> ./deployments/scripts/tools/offline/fetch-offline-from-minio.sh \
>   --release 2.0.0 --flat --dest /opt/cubestack-installer/deployments/offline-files
> ```
> （`--flat` 不建 `<版本>/` 目录；CLI tar 不在 flat 模式下载）
> 切换到 latest 前请移除/改名该 `release.env`，或设 `CUBESTACK_RELEASE_AUTO="false"`。

| 模式 | `CUBESTACK_RELEASE` | `CUBESTACK_RELEASE_LAYOUT` | 实际 `OFFLINE_FILES_ROOT` | `release.env` 来源 |
|---|---|---|---|---|
| dev | 空且目录无 release.env | — | `deployments/offline-files` | 不加载 |
| release tree | `2.0.0` | `tree` | `<root>/2.0.0/offline-files` | 发布树内 |
| **release flat（自动）** | 由 `offline-files/release.env` 自动推导 | `flat` | `deployments/offline-files` | `deployments/offline-files/release.env`（优先） |
| release flat（显式） | `2.0.0` | `flat` | `deployments/offline-files` | 同上；缺失时回退 repo 发布定义 |

---

## 5. 离线取件：`fetch --release`

### 5.1 用户视角

```bash
# 默认下载到 <本地桶根>/2.0.0/（默认本地桶根 = deployments/）
./fetch-offline-from-minio.sh --release 2.0.0

# 推荐：指定本地桶根（与 MinIO cubestack-installer/ 同构）
./fetch-offline-from-minio.sh --release 2.0.0 --dest /data/cubestack-installer

# 只校验本地已下载的发布版本
./fetch-offline-from-minio.sh --release 2.0.0 --verify-only \
    --dest /data/cubestack-installer

# 精确同步(默认: release/flat 覆盖并删除本地多余文件; 30s 倒计时)
./fetch-offline-from-minio.sh --release 2.0.0 --dest /data/cubestack-installer
# 下载失败后断点续传(先校验本地, 部分文件按 offset 续传, 完整则跳过下载)
./fetch-offline-from-minio.sh --release 2.0.0 --dest /data/cubestack-installer --resume
# 调整下载重试(默认 3 次, 间隔 3s)
./fetch-offline-from-minio.sh --release 2.0.0 --dest /data/cubestack-installer --retry 5 --retry-delay 5
# 保留本地多余文件 / 调整倒计时
./fetch-offline-from-minio.sh --release 2.0.0 --dest /data/cubestack-installer --no-clean
./fetch-offline-from-minio.sh --release 2.0.0 --dest /data/cubestack-installer --clean-countdown 30

# 列出 MinIO 上可用版本（桶根下除 offline-files/ 外的版本目录）
./fetch-offline-from-minio.sh --list-releases
```

> ⚠ release-2.0 发布树包含 `dev-lab` / `model-collection`，单版本约 **130G+**；
> 取件前确保目标盘空间充足（`--min-free` 可调）。

下载后的布局：

```text
/data/cubestack-installer/2.0.0/
├── offline-files/
│   ├── release.env
│   ├── release.json
│   ├── SHA256SUMS
│   ├── _SUCCESS
│   └── kubespray/ cubestack-operator/ rdma/ ...
└── cubestack-installer-cli-v2.0.0.tar
```

> ⚠ `--release` 模式下 `--dest` 是**本地桶根**（包含 `<版本>/` 与 `offline-files/`），
> 与 `--sub` 模式下 `--dest`（`offline-files/` 根）语义不同；`--sub` 行为不变。

下载完成后输出：

```text
export CUBESTACK_RELEASE=2.0.0
export CUBESTACK_RELEASE_ROOT=/data/cubestack-installer
# load_config 会自动把 OFFLINE_FILES_ROOT 指向
#   /data/cubestack-installer/2.0.0/offline-files
```

### 5.2 实现方式

`fetch-offline-from-minio.sh` 复用现有下载/磁盘预检逻辑，只切换源根与目标布局；其中
release 模式默认用 `mc mirror --overwrite --remove` 精确镜像版本目录（`--no-clean` 时用
`mc cp --recursive`），`--sub` 模式仍用 `mc mirror`：

1. 解析 `--release <ver>`（与 `--sub` 互斥）：
   - 本地根 `TARGET`：`--dest` > 环境/minio.conf 的 `CUBESTACK_RELEASE_ROOT` > `${REPO_ROOT}/offline-releases`；
   - 远端版本目录 `RELEASE_BASE="<alias>/<bucket>/<ver>"`；
   - 检查 `${RELEASE_BASE}/offline-files/_SUCCESS`，否则报"发布未完成"；
2. 下载 `${RELEASE_BASE}/offline-files/` → `${TARGET}/<ver>/offline-files/`；
3. 下载 `${RELEASE_BASE}/cubestack-installer-cli-v<ver>.tar` → `${TARGET}/<ver>/cubestack-installer-cli-v<ver>.tar`；
4. 默认校验：
   - 在 `${TARGET}/<ver>/offline-files/` 执行 `sha256sum -c SHA256SUMS`；
   - 按 `release.json.cli_tar_sha256` 校验 CLI tar；
5. 输出 `CUBESTACK_RELEASE` / `CUBESTACK_RELEASE_ROOT` 提示；
6. `--list-releases`：`mc ls <bucket>/`，列出除 `offline-files/` 外的目录（可再按版本号格式过滤）。

> `fetch` 可从环境/`minio.conf` 读 `CUBESTACK_RELEASE_ROOT`；部署时请在 `cluster.conf`
> 设置同一路径（`load_config` 只读 cluster.conf/defaults/环境，不读 minio.conf）。
>
> release/flat 模式默认**精确清理**：`mc mirror --overwrite --remove` 会让本地
> `offline-files` 与 MinIO 一致，删除本地多余文件。执行前有 30 秒红色倒计时
> （`--clean-countdown N` 调整，`--yes` 跳过），`Ctrl-C` 中止；非交互环境没有
> `--yes` 会直接中止。`--no-clean` 保留本地多余文件（此时完整性校验会因
> “磁盘存在但清单未登记”失败，仅建议调试用）。`.cubestack-*`（校验戳/清单备份）
> 始终保留。

改动集中在参数解析、源根切换和下载后校验，约 60 行；`--sub` 的现有行为不变，
`DEFAULT_EXCLUDE_SUBS` 也无需改动（版本目录在 `offline-files/` 之外）。

### 5.3 校验语义

| 检查 | 失败处理 |
|---|---|
| `<ver>/offline-files/` 存在 | 报错，列出可用版本 |
| `<ver>/offline-files/_SUCCESS` 存在 | 报错"发布未完成/上传中断" |
| `SHA256SUMS` 存在 | 报错"发布树不完整" |
| 发布树每个文件 sha256 匹配 | 报错，列出不匹配文件 |
| `_SUCCESS.sha256sums == sha256(SHA256SUMS)` | 报错(发布标记与清单不匹配) |
| `release.json.cli_tar_sha256` 与 CLI tar 匹配 | 报错（CLI 镜像不完整） |
| `release.env` 中 `RELEASE_VERSION == <ver>` | 报错 |

`--no-verify` 可跳过全量 sha256 / CLI tar 校验（仅建议在反复调试时使用）。
`--repair` 会在校验失败时只重下坏文件（最多 1 轮），坏文件先移到
`<本地桶根>/.repair-quarantine/<版本>/<时间戳>/`。校验通过后会写
`.cubestack-verified.json` 校验戳，部署门禁可秒级复查。

---

## 6. 发布端：同步脚本契约

> 你们已有/将有一个"从 Harbor 同步正确镜像到 MinIO"的脚本。本节定义它**必须遵守的输出契约**，
> 不限定实现。仓库内已提供参考实现 `deployments/scripts/tools/images/release-publish.sh`
> （`stage` / `verify` / `publish` 三个子命令）。

### 6.1 输入

| 输入 | 位置 | 说明 |
|---|---|---|
| 发布版本 | `--release 2.0.0` | 决定 MinIO 前缀 |
| 版本变量 | `deployments/releases/2.0.0/release.env` | 决定 tar 文件名中的 tag |
| 平台组件镜像清单 | `deployments/releases/2.0.0/release-images.tsv` | 复用现有 TSV 格式（`subdir / file / pull_ref / save_ref`） |
| model-collection 清单 | `deployments/offline-files/model-collection/image-list.tsv` | sglang / vllm-metax，保持上游 tag |
| dev-lab | `deployments/config/images.manifest` 的 `dev-lab` 组 | 由 `DEV_LAB_IMAGE_TAG=2.0.0` 控制 |
| 上游镜像清单 | `deployments/config/images.manifest` | 现有唯一清单 |
| Harbor 凭据 | 环境变量 / 600 权限文件 | 不落仓库、不进 argv |

> `deployments/releases/` 是**仓库内的发布定义目录**（版本变量 + 平台镜像清单），
> 与 MinIO 桶根的版本目录（`cubestack-installer/2.0.0/`）是两回事：
> 前者进 git、随 CLI 镜像分发；后者是运行期制品。
>
> 发布树还会带上 `offline-files/tools/verify-offline-files.sh`（校验器本体），
> 由 `SHA256SUMS` 覆盖，确保纯宿主机部署也能做完整性校验。

### 6.2 参考流程

```text
1. source release.env（export 版本变量）
2. 建空 staging 目录：
     /data/release-staging/2.0.0/offline-files/     # 发布树
     /data/release-staging/2.0.0/                   # 放 CLI tar
3. 上游镜像 → staging/offline-files/（复用现有工具，不新增下载逻辑）：
     IMAGE_OFFLINE_ROOT=/data/release-staging/2.0.0/offline-files \
       harbor-save-images.sh \
         --exclude-group cubestack-operator,cubestack-platform,netshoot
   （nginx / multus / rdma / nvidia / kubespray+ceph / dev-lab 等由该工具按清单写入；
     dev-lab 用 release.env 的 DEV_LAB_IMAGE_TAG=2.0.0 生成 *_2.0.0.tar；
     netshoot 组只用于构建派生镜像, 模块部署时不用它, 故排除）
4. 平台/自研镜像 → staging/offline-files/cubestack-operator：
     cubestack-platform-save-images.sh \
       --list deployments/releases/2.0.0/release-images.tsv \
       --out /data/release-staging/2.0.0/offline-files/cubestack-operator
   （operator 本体 = subdir "." 行；各组件 = 子目录行；release-2.0 所有自研组件统一 :2.0.0）
4b. model-collection → staging/offline-files/model-collection：
     cubestack-platform-save-images.sh \
       --list deployments/offline-files/model-collection/image-list.tsv \
       --out /data/release-staging/2.0.0/offline-files/model-collection
   （sglang / vllm-metax 保持各自上游 tag；image-list.tsv 必须一起复制进发布树，
     模块 37 从这里读取清单）
5. 复制非镜像资产（现有 offline-files 里已有的）到 staging/offline-files/：
     kubespray/<KUBESPRAY_VERSION>/ 的二进制/packages/tree.tar.gz/VERSION.profile
     os/（含 packages/）
     netshoot/ 的自建 netshoot-rdma-*.tar（上游 netshoot 组已排除，不需要）
     cubestack-operator/observability/ 非镜像资产
     cubestack-operator/charts/<chart>-<版本>.tgz + .digest（版本 = release.env 的 CUBESTACK_OPERATOR_CHART_VERSION）
     metax-gpu/ 整个目录（tars + run/资源包/chart；该组默认不走 harbor-save；未启用 GPU 时跳过）
     model-collection/image-list.tsv（模块 37 的单一事实源；README 可选）
   注意：staging 必须是空目录，避免把 dev 目录里的 _latest.tar 带进发布树。
   model-collection / dev-lab 的大件可沿用现有 `.tar.gz`（模块双读 `.tar` / `.tar.gz`），
   直接复制可显著节省空间与传输时间；若用保存工具重新拉取则产出普通 `.tar`。
5b. 产出 CLI tar（离线部署机加载用）：
     skopeo copy --override-os linux --override-arch amd64 \
       docker://harbor.isuanova.com/suanova/cubestack-installer-cli:2.0.0 \
       docker-archive:/data/release-staging/2.0.0/cubestack-installer-cli-v2.0.0.tar:harbor.isuanova.com/suanova/cubestack-installer-cli:2.0.0
6. 生成元数据（都在 staging/offline-files/ 下）：
     release.env / release.json / SHA256SUMS
     release.json.cli_tar_sha256 / cli_tar_size 记录 ../cubestack-installer-cli-v2.0.0.tar
7. 上传到：
     <bucket>/2.0.0/offline-files/                # 发布树
     <bucket>/2.0.0/cubestack-installer-cli-v2.0.0.tar   # CLI 镜像
   要求：<bucket>/2.0.0/ 不存在；先传文件，最后传 offline-files/_SUCCESS
8. 校验：远端逐文件 sha256 ↔ SHA256SUMS；CLI tar ↔ release.json；release.env 版本一致
```

### 6.3 tar 命名与镜像来源

| 镜像类别 | 拉取源（Harbor） | tar 文件名（`save_ref`） | 模块落点 |
|---|---|---|---|
| operator 本体 | `suanova-private/cubestack-operator:2.0.0` | `harbor.isuanova.com_suanova-private_cubestack-operator_2.0.0.tar` | `<REG>/suanova-private/...` |
| 平台自研组件 | `suanova*/<name>:2.0.0` | `harbor.isuanova.com_suanova_<name>_2.0.0.tar` | `<REG>/suanova/<name>:2.0.0` |
| 第三方组件 | `mirrors/<上游ref>:<版本>` | 按上游 ref（`/`、`:` → `_`） | `<REG>/mirrors/<上游ref>` |
| dev-lab | `suanova/{cpu,maca,cuda}-pytorch:2.0.0` | `..._2.0.0.tar` | `<REG>/suanova/...` |
| model-collection | `suanova/sglang:<上游tag>` / `suanova/vllm-metax:<上游tag>` | 按 `model-collection/image-list.tsv` | `<REG>/suanova/...` |
| 固定短名 | `mirrors/...` | `busybox.tar` / `nginx.tar` | 按模块字面名读取 |
| CLI 镜像 | `suanova/cubestack-installer-cli:2.0.0` | `cubestack-installer-cli-v2.0.0.tar`（`<版本>/` 下） | 部署机 `docker load` |

`release-images.tsv` 示例：

```text
# subdir	file	pull_ref	save_ref
.	harbor.isuanova.com_suanova-private_cubestack-operator_2.0.0.tar	harbor.isuanova.com/suanova-private/cubestack-operator:2.0.0	harbor.isuanova.com/suanova-private/cubestack-operator:2.0.0
controller-manager	harbor.isuanova.com_suanova_cubestack-controller-manager_2.0.0.tar	harbor.isuanova.com/suanova/cubestack-controller-manager:2.0.0	harbor.isuanova.com/suanova/cubestack-controller-manager:2.0.0
envoy-gateway	docker.io_envoyproxy_ratelimit_0482748e.tar	harbor.isuanova.com/mirrors/docker.io/envoyproxy/ratelimit:0482748e	docker.io/envoyproxy/ratelimit:0482748e
```

> `pull_ref` 是 Harbor 实际拉取地址；`save_ref` 是写进 tar RepoTags、供部署模块解析的目标 ref。
> 二者可以不同（例如 bmc/idrac 从 `suanova-private` 拉、按 `suanova/...` 保存），现有工具已支持。

### 6.4 发布脚本的硬性约束

- **只写** `<bucket>/<版本>/`；**绝不修改** `offline-files/<group>/` 下的现有文件；
- **不覆盖**已存在的 `<bucket>/<版本>/`；版本号已存在直接失败；
  **唯一例外**是 §6.6 的 `release-sync-images.sh` 原地组件刷新（仅 cubestack-operator 集合 + chart + CLI，
  且必须按 tar/digest → release.env/release.json → SHA256SUMS → _SUCCESS 顺序）；
- `_SUCCESS` 必须最后写入（位于 `<版本>/offline-files/`）；
- `SHA256SUMS` 必须覆盖发布树全部文件；CLI tar 的校验值写入 `release.json`；
- 发布前校验每个 Harbor ref 的 digest 与预期一致（`skopeo inspect --raw`），避免"tag 还在但内容变了"；
- 不执行 `mc mirror --remove` / `--prune`；
- `sync-to-minio.sh --prune` / `--force-full-prune` 不得作用于包含版本目录的桶根
  （建议后续给该脚本加一条"跳过顶层版本目录"的保护；发布树是回滚能力，不能被 dev 刷新删除）；
- 不在日志/argv 中输出 Harbor/MinIO 凭据。

### 6.5 与现有 CI 的关系

- 现有 `refresh-latest-offline.yml` **不动**，继续维护 dev `offline-files/`；
- `sync-release-images.yml` 只维护 `<release>/offline-files/`，绝不写 dev 前缀；
- 发布脚本可以先手工/定时在内网机器执行（与 `cubestack-platform-sync.sh` 的部署位置一致：
  需同时访问 Harbor 与 MinIO）；
- 将来若加 CD，只需在发布机上调用同一个脚本，不改变 MinIO 契约。

### 6.6 release-2.0 组件镜像原地刷新（`release-sync-images.sh`）

**定位**：发布树已经由 `release-publish.sh` 完整发布后，组件仓库又发了 rc/GA 镜像、chart 或 CLI
时，用同一套流程把 `<bucket>/<release>/offline-files/cubestack-operator/` 原地刷新到新版本。
`2.0.0-rcX` 与 `2.0.0` GA 都走这一个脚本/工作流，不硬编码 rc/GA。

**数据源（release 定义是唯一真相）**：

- `deployments/releases/<release>/release.env`：operator tag、chart version、CLI image；
- `deployments/releases/<release>/release-images.tsv`：37 个镜像的 subdir/file/pull/save；
- `deployments/releases/<release>/components.tsv`：component → 来源仓库/子目录：

  ```text
  component            source_repo                    subdirs
  publish              suanova/cubestack-operator     .
  cubestack-operator   suanova/cubestack-operator     . bmc
  operator-chart       suanova/cubestack-operator     -
  bmc                  suanova/cubestack-operator     bmc
  operator-image       suanova/cubestack              controller-manager
  portal-image         suanova/cubestack              portal
  cubepilot            suanova/cubepilot              cubepilot
  cuberouter           suanova/cuberouter             cuberouter
  platform             -                              . bmc controller-manager cubepilot cuberouter portal
  all                  -                              *
  release-first-party  -                              . controller-manager cubepilot cuberouter portal
  ```

- `*` = 全部 37 行（含第三方依赖）；`-` = 仅 chart；`platform` = first-party 子目录。
- `release-first-party` = 上游统一 tag 的全部 first-party 镜像，**不含 `bmc`**（bmc 按 commit SHA 固定）。

**触发方式**：

1. 组件仓库发 `repository_dispatch: release-updated`（`release-2.0-updated` 兼容）：

   ```json
   {"event_type":"release-updated",
    "client_payload":{"release":"2.0.0","component":"publish","tag":"v2.0.0",
                      "source_repo":"suanova/cubestack-operator","sha":"<commit>",
                      "checkout_ref":"release-2.0"}}
   ```

   `component` 可省略（默认 `all`），也可 CSV（如 `operator-image,portal-image`）；
   `tag`/`source_repo` 只用于一致性校验。**dispatch 前必须先把 release 定义更新到新 tag**，
   否则 tag/env 校验会失败，不会静默同步错版本。
2. push 到 `release-*` 且改动 `deployments/releases/*/{release.env,release-images.tsv}`：
   从 push 的 before..after 推导 release 目录，先同步 first-party 镜像，再同步 operator chart。
   这类改动通常来自上游 tag 触发的版本定义 PR（见下文「上游 tag 自动更新版本定义」）。
3. `workflow_dispatch` 手动触发（首次 seed/恢复/补跑）；
4. **CLI tar 不走本 workflow**：`rebuild-cli-image.yml` 在 release-2.0 推完版本化镜像后，
   在同一 job 内执行 `release-sync-images.sh --component cli ...`，避免跨 workflow 的
   Harbor/MinIO 不一致窗口；本 workflow 只处理组件镜像/chart 的 dispatch。

   `component=cli` 可用于手动重试 CLI tar：需显式提供
   `--cli-tar <版本化 tar>` 与 `--cli-image-digest sha256:...`，只更新 CLI 与三份元数据，
   不处理镜像/chart。

> GitHub 的 `repository_dispatch` 只触发默认分支 `main` 上的 workflow；
> 因此 `.github/workflows/sync-release-images.yml` 在 **main 与各 release-* 分支各有一份
> 完全相同**的文件，main 副本 checkout 目标 release 后执行对应脚本。
> 修改时必须同步 cherry-pick。

**执行顺序（`release-sync-images.sh`）**：

```text
预检 (_SUCCESS/SHA256SUMS/release.env/release.json/CLI tar)
  → 选择 components.tsv + release-images.tsv 行, 校验 tag/source_repo
  → release.env diff (仅 3 个允许 key; dev-lab/metax/nvidia 等 out-of-scope 只告警保持旧值)
  → 拉取/构建所有源 (镜像/chart/CLI) —— 失败在写 marker 前退出, 发布树仍可用
  → 写 <release>/_REFRESH_PENDING
  → 删除 offline-files/_SUCCESS
  → 上传 tar → .digest; stale tar 清理; chart; CLI tar
  → release.env; release.json; SHA256SUMS
  → 远端逐文件 sha256 校验
  → 写 _CLI_IMAGE_DIGEST(并回读校验)
  → 最后写 _SUCCESS; 删除 _REFRESH_PENDING
```

- **允许变化**：`CUBESTACK_OPERATOR_IMAGE_TAG`、`CUBESTACK_OPERATOR_CHART_VERSION`、`CUBESTACK_CLI_IMAGE`；
- **允许忽略并告警**：`DEV_LAB_*`、`METAX_*`、`NVIDIA_*`、`RDMA_IMAGE_TAG`、`MULTUS_IMAGE_TAG`、
  `NGINX_TAG`（树内保持旧值；这些组要升级需完整 `release-publish.sh`）；
- **其他 key 变化**（KUBESPRAY_VERSION/RELEASE_GROUPS/上游版本等）→ 失败；
- `stale tar 清理`：只扫 selected subdir 的 maxdepth=1，删除不在该 subdir 全量 tsv 行里的旧
  `*.tar`/`*.tar.gz` 及 `.digest`；`README.md`/`observability/`/`charts/` 保留；`--keep-stale` 关闭；
- **CLI tar**：在 `<release>/` 下，不进 `SHA256SUMS`；`release.json.cli_tar_sha256/cli_tar_size`
  校验；同 tag 内容变化由 `_CLI_IMAGE_DIGEST` 和 `release.json.cli_image_digest` 发现。
  `--component cli --cli-tar <tar> --cli-image-digest sha256:...` 是 CLI-only 模式：只更新
  CLI tar 与 `release.json`/`SHA256SUMS`/`_SUCCESS`，不读镜像/chart；CLI 构建 workflow
  在同一个 job 内用它完成发布，失败则整个 workflow 失败。
- 其他组件（cubepilot/controller-manager/portal/cuberouter）只同步镜像 tar；若本次 release 同时
  改了 operator chart 里的组件 tag/values，需要再 dispatch `component=operator-chart`（或在
  release 定义里改 chart version，让 `sync_chart` 生效）。

**常用命令**：

```bash
# 只读预检（推荐先跑）
bash deployments/scripts/tools/images/release-sync-images.sh --release 2.0.0 --component all --preflight
# 演练（不写 marker/不上传）
bash deployments/scripts/tools/images/release-sync-images.sh --release 2.0.0 --component all --dry-run
# 只同步某个组件（第三方依赖用 --first-party-only 跳过）
bash deployments/scripts/tools/images/release-sync-images.sh --release 2.0.0 --component portal-image --first-party-only
# 失败恢复：同 component 重跑即可；_SUCCESS 被手工删掉时加 --recover
bash deployments/scripts/tools/images/release-sync-images.sh --release 2.0.0 --component publish --recover
```

> `--source-dir <dir>` 的布局与发布树 `cubestack-operator/` 同构：
> `<dir>/cubestack-operator/<subdir>/<file>` + `<file>.digest`（顶层 `.` 就是
> `<dir>/cubestack-operator/<file>`），供发布机复用已备好的 tar。

> ⚠ **原地刷新会改变已发布版本**，rc→GA 时旧 rc tar 会被清理（回滚能力减弱）。
> 建议 GA 前对 `<release>/` 做 MinIO 快照/版本化，或改用新版本目录（完整 `release-publish.sh`）。
> 刷新期间 fetch 会失败（`_SUCCESS` 缺失 + `_REFRESH_PENDING` 提示），完成后恢复。

#### 上游 tag 自动更新版本定义

cubestack-operator 在 cubestack / cubepilot / cuberouter 都已发布同一版本后推送 `v*` tag 时，
`.github/workflows/release-tag-bump.yml` 通过 `release-tag-published` dispatch 自动更新版本定义：

- **payload**：`release`、`source_repo=suanova/cubestack-operator`、`component=release-first-party`、
  `git_tag`（如 `v2.0.0`）、`image_tag`（带 v 前缀的实际镜像 tag）、`chart_version`（裸 SemVer）。
- **流程**：校验触发来源 → 要求 `deployments/releases/<release>/` 已存在 → 在 Harbor 预检
  每个 first-party 镜像与 chart → 更新 `release.env` 与 `release-images.tsv` → 提交到
  `release-bump/<release>` → 对 `release-<major>.<minor>` 开一个（或复用已有）PR。
- **合并后**：push 触发 `release-sync-images.sh`，把镜像与 chart 写入 MinIO `<release>/offline-files/`。
- **失败**：其他仓库的制品尚未发布时不会开 PR；发布后重跑 bump workflow 即可
  （手动输入 `source_repo`、`component`、`image_tag`、`chart_version`、`git_tag`、`release`、`checkout_ref`）。
- **单仓库 hotfix**：改用 `workflow_dispatch`，填该仓库的 `component` 和实际镜像 tag。
- **上线耦合**：bump workflow、`release-bump-pr.sh`、改名后的 `sync-release-images.yml` 与
  `release-first-party` 行必须先 cherry-pick 到 `release-2.0` 再开启 operator dispatch，
  否则 bump PR 能开，但合并后的 MinIO 同步不会运行。
- **回滚**：合并前关闭 bump PR 即可取消本次更新；**合并后关闭 PR 无效**，发布树与 MinIO
  已更新。需要回退时重跑 `sync-release-images.yml` 指向目标版本，或走完整
  `release-publish.sh` 修正发布树。

---

## 7. Harbor 侧建议（非强制）

Harbor 不是本方案的依赖；现有部署代码只消费 MinIO 里的 tar。以下是给镜像生产/同步环节的建议，
用于保证"同步脚本拉到的确实是 2.0.0 该有的字节"。

### 7.1 标签

| 类别 | 建议 |
|---|---|
| 自研镜像 | 发布时打不可变 semver `2.0.0`；`latest` 只保留在 dev 构建 |
| operator chart | `2.0.0`（替代 `1.0.0-latest`） |
| CLI 镜像 | `cubestack-installer-cli:2.0.0`（替代只发 `latest`） |
| 第三方 | 保持上游版本 tag；不要用 `latest` 进入发布树 |
| 固定短名镜像 | `busybox` / `nginx` 在发布树内锁定具体版本 |

### 7.2 不可变与 digest

- Harbor 项目可对 `2.*` 开启 immutable tag rule，防止同名 tag 被覆盖；
- 发布脚本记录每个 ref 的 digest（写入 `release.json` 可选字段），并在同步前用
  `skopeo inspect --raw` 校验；
- 若已有 `cubestack-release` 之类的独立项目，可将发布镜像放进去；没有也不影响本方案，
  同步脚本只需能按显式 ref 拉取即可。

### 7.3 自研镜像的版本号

- **release-2.0 所有自研组件统一使用 `2.0.0`**（operator 本体、平台组件、CLI、dev-lab、
  cubepilot / cuberouter / bmc / controller-manager / portal 等）；
- `model-collection` 的 sglang / vllm-metax 属于模型镜像，保持各自上游 tag
  （以 `offline-files/model-collection/image-list.tsv` 为准）；
- 其余第三方组件保持上游版本 tag；
- **关键约束**：`release.env` 里的 tag 必须与 `release-images.tsv` / tar 文件名完全一致；
  发布脚本应在发布前做机械校验（否则模块会找不到 tar）。

---

## 8. release-2.0 操作手册

### 8.0 分支与 cherry-pick 流程（2026-10-25）

- `release-2.0` 是 2.0 的**发布维护分支**；`deployments/releases/2.0.0/`、CLI tar 带版本命名、
  `fetch --release` 的精确取件/清理、发布树 `_SUCCESS` 落位等契约在该分支冻结。
- 日常修复先合入 `main`，再 **cherry-pick 到 `release-2.0`**；也可以直接对 `release-2.0` 提 PR。
- CI（`.github/workflows/ci-validate.yml`）对 **push 到 `main` / `release-2.0`** 以及所有 PR
  运行；其中 `test-release-mode.sh` 专门校验 release 模式契约（路径派生、带版本 CLI tar、
  旧布局兼容、`mc cp` 取件、`_SUCCESS`、发布定义冻结）；`test-release-sync-images.sh` 校验
  组件原地刷新（fake mc/fixture，覆盖 tar/chart/CLI/SHA256SUMS/_SUCCESS/恢复）。
- 正式发版在 `release-2.0` 分支上执行 `release-publish.sh stage/verify/publish --release 2.0.0`。
- 发布后的组件增量更新走 `sync-release-images.yml`（§6.6）；`release-publish.sh` 仍是
  首次完整发布/新版本目录的唯一入口。

### 8.1 发布前（镜像生产）

1. 各组件仓库产出 `2.0.0` 镜像（operator / 平台组件 / CLI / dev-lab）；
   CLI 镜像用 `rebuild-cli-image.yml` 的 `version=2.0.0` 手动触发（在 `v2.0.0` tag 上 dispatch，
   或在发布机上 build/tag/push）；
   `model-collection` 的 sglang / vllm-metax 按 `offline-files/model-collection/image-list.tsv`
   备齐（保持各自上游 tag）；
2. 准备 operator chart：`offline-files/cubestack-operator/charts/cubestack-operator-chart-2.0.0.tgz`
   + `.digest`（**CLI 镜像已不再包含 chart**；可用 `refresh-operator-chart.yml` 的
   `chart_version=2.0.0` 同步到 MinIO，再在发布机 `fetch --sub cubestack-operator` 取回）；
3. 上游镜像同步到 Harbor `mirrors/`（现有 CI 或 `harbor-sync-images.sh`）；
4. 仓库内准备：
   - `deployments/releases/2.0.0/release.env`
   - `deployments/releases/2.0.0/release-images.tsv`
   - `deployments/releases/2.0.0/components.tsv`（组件 → 来源仓库/子目录，见 §6.6）

> **CLI 镜像必须内置 GNU `patch`**（kubespray 补丁层的前置）：`Dockerfile-cli-base` 安装 `patch`，
> `Dockerfile-cli` 构建期断言 `command -v patch`；`.github/workflows/rebuild-cli-image.yml`
> 构建后也会实际运行一次镜像做校验。2026-10-25 实机发现旧 base 镜像缺 `patch`，导致
> `cubestack-offline.sh` 的补丁层被静默跳过（Calico RBAC 等 14 个补丁不生效）；发布前务必确认
> `docker run --rm --entrypoint bash <cli-image> -lc 'command -v patch'` 成功。
>
> **已有发布树的 CLI tar 命名迁移**：旧布局 `<版本>/cubestack-installer-cli.tar` 应改为
> `<版本>/cubestack-installer-cli-v<版本>.tar`；同步更新 `release.json` 的
> `cli_tar`/`cli_tar_sha256`/`cli_tar_size`，重新生成 `SHA256SUMS`，最后重写 `_SUCCESS`。
> `fetch --release` 仍兼容旧名（release.json 无 `cli_tar` 时自动回退）。

### 8.2 生成并发布 MinIO 发布树

在能同时访问 Harbor 与 MinIO 的机器上：

```bash
# 参考实现（或你们自己的同步脚本）
bash deployments/scripts/tools/images/release-publish.sh stage   --release 2.0.0
bash deployments/scripts/tools/images/release-publish.sh verify  --release 2.0.0 --stage-dir /data/release-staging/2.0.0
bash deployments/scripts/tools/images/release-publish.sh publish --release 2.0.0 --stage-dir /data/release-staging/2.0.0
```

发布完成后检查：

```bash
mc ls -r minio/cubestack-installer/2.0.0/offline-files/ | tail
mc stat minio/cubestack-installer/2.0.0/offline-files/_SUCCESS
mc stat minio/cubestack-installer/2.0.0/cubestack-installer-cli-v2.0.0.tar
```

### 8.2b 组件增量刷新（rcX → GA）

发布树完整发布后，组件仓库发 rc/GA 镜像时不需要重新发布 118G 全树，走 §6.6 的原地刷新：

```bash
# 1) 更新 release 定义（release-2.0 分支，PR/直接提交）：
#    release.env: CUBESTACK_OPERATOR_IMAGE_TAG / CHART_VERSION / CLI_IMAGE
#    release-images.tsv: 对应镜像行 file/tag
# 2) rebuild-cli-image.yml 在 release-2.0 推完镜像后，同一 job 内自动同步 CLI tar
# 3) 或在发布机/CI 手动：
bash deployments/scripts/tools/images/release-sync-images.sh \
  --release 2.0.0 --component all --preflight
bash deployments/scripts/tools/images/release-sync-images.sh \
  --release 2.0.0 --component all --dry-run
bash deployments/scripts/tools/images/release-sync-images.sh \
  --release 2.0.0 --component all
# 3b) 只重试 CLI tar（不碰镜像/chart；需提供版本化 tar 与 Harbor registry digest）：
bash deployments/scripts/tools/images/release-sync-images.sh \
  --release 2.0.0 --component cli \
  --cli-tar /path/cubestack-installer-cli-v2.0.0.tar \
  --cli-image-digest sha256:<registry-digest>
# 4) 验收
bash deployments/scripts/tools/offline/fetch-offline-from-minio.sh \
  --release 2.0.0 --dest /tmp/release-verify --yes
bash deployments/scripts/tools/offline/fetch-offline-from-minio.sh \
  --release 2.0.0 --dest /tmp/release-verify --verify-only
```

> rcX 与 GA 的差别只在 `release.env`/`release-images.tsv` 里的 tag/chart/CLI 值；脚本不硬编码。
> `DEV_LAB_*`/`METAX_*`/`NVIDIA_*` 等 out-of-scope diff 只告警、保持旧值；这些组升级仍需完整发布。
> 同一 release 目录内 rc→GA 会清理旧 rc tar（回滚能力减弱，GA 前建议快照）。

### 8.3 部署机取件

```bash
# 1) 取发布版本（本地桶根 /data/cubestack-installer 与 MinIO 桶根同构）
./deployments/scripts/tools/offline/fetch-offline-from-minio.sh \
    --release 2.0.0 --dest /data/cubestack-installer
# → /data/cubestack-installer/2.0.0/{offline-files/, cubestack-installer-cli-v2.0.0.tar}

# 2) 配置版本开关（cluster.conf）
CUBESTACK_RELEASE="2.0.0"
CUBESTACK_RELEASE_ROOT="/data/cubestack-installer"
OFFLINE_FILES_ROOT="/data/cubestack-installer/offline-files"   # dev 根

# 3) 加载 2.0.0 的 CLI 镜像（名字/tag 以 tar 内 RepoTags 为准）
sudo docker load -i /data/cubestack-installer/2.0.0/cubestack-installer-cli-v2.0.0.tar

# 4) 部署（在 CLI 容器内或宿主机直跑）
sudo ./deployments/scripts/deploy-cluster.sh
# 或一次性指定：
sudo ./deployments/scripts/deploy-cluster.sh --release 2.0.0
```

> `load_config` 会自动把 `OFFLINE_FILES_ROOT` 指向
> `/data/cubestack-installer/2.0.0/offline-files`，并加载其中的 `release.env`。

### 8.4 部署后验收

```bash
# 版本开关生效
grep -E 'RELEASE_VERSION|CUBESTACK_RELEASE' \
  /data/cubestack-installer/2.0.0/offline-files/release.env

# 节点实际镜像 digest / tag（示例）
kubectl -n cubestack-system get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[*].image}{"\n"}{end}'

# 现有验证
sudo ./deployments/scripts/deploy-cluster.sh --steps verify_cubestack_operator
```

### 8.5 回滚

```bash
# 版本目录保留 1.9.0，只需切版本
CUBESTACK_RELEASE="1.9.0"
CUBESTACK_RELEASE_ROOT="/data/cubestack-installer"
sudo ./deployments/scripts/deploy-cluster.sh
```

前提：旧版本的 `1.9.0/` 仍在 MinIO/本地；因此发布版本目录**不要删除历史版本**
（至少保留最近 2–3 个 + 所有已交付版本）。

---

## 9. 验收标准

- [ ] dev 模式（`CUBESTACK_RELEASE` 为空）行为与今天完全一致；
- [ ] release-2.0 发布树**包含** `dev-lab` / `model-collection`，**不含** `virtual-machine`；
- [ ] 所有自研组件镜像 tag 与 `release.env` / `release-images.tsv` 一致（rcX 或 `2.0.0` GA）；`model-collection` 镜像按 `image-list.tsv` 保持上游 tag；
- [ ] `model-collection/image-list.tsv` 存在于发布树（模块 37 依赖）；
- [ ] `cubestack-operator/charts/<chart>-2.0.0.tgz` 存在于发布树（模块 25 恒用本地 chart）；
- [ ] `2.0.0/offline-files/` 包含 `release.env`、`SHA256SUMS`、`_SUCCESS`；
- [ ] `2.0.0/cubestack-installer-cli-v2.0.0.tar` 存在，sha256 与 `release.json` 一致；
- [ ] `_SUCCESS` 缺失时 `fetch --release` 拒绝下载；
- [ ] `sha256sum -c SHA256SUMS` 全量通过；
- [ ] `CUBESTACK_RELEASE=2.0.0` 时 `OFFLINE_FILES_ROOT` 指向 `2.0.0/offline-files`，且
      `CUBESTACK_OPERATOR_OFFLINE_DIR` / `RDMA_SAVE_DIR` 等 11 个目录变量全部指向发布树；
- [ ] `deploy-cluster.sh --release 2.0.0` 能找到 operator / 各组件 / 上游 tar，无
      "未找到 tar" 告警；
- [ ] 部署后关键镜像的 tag 为 `2.0.0`（或 release.env 中对应版本），无 `_latest` 残留；
- [ ] 回滚到上一个版本可重复执行；
- [ ] 发布脚本重复执行时，检测到已存在的版本直接失败，不覆盖；
- [ ] 组件增量刷新后 `_REFRESH_PENDING` 不存在，`_SUCCESS.sha256sums == sha256(SHA256SUMS)`；
- [ ] 刷新期间 `fetch --release` 明确报“正在原地刷新”，刷新后 `--verify-only` 通过；
- [ ] 组件增量刷新不删除未选中子目录文件；stale cleanup 只清理 selected subdir 旧 tag；
- [ ] CLI tar 不在 `SHA256SUMS`，其 sha256/size 与 `release.json` 一致；
- [ ] 现有 `refresh-latest-offline.yml` / `sync-to-minio.sh` 不会写顶层版本目录。

---

## 10. 风险与决策

| 风险 | 影响 | 对策 |
|---|---|---|
| 发布树按版本完整复制 | MinIO 存储增长 | 2.0 包含 `dev-lab` / `model-collection`（约 130G/版本，已接受），排除 `virtual-machine`；保留最近 2–3 个版本 |
| `release.env` 覆盖 `cluster.conf` | 客户现场无法临时改版本 | 明确"发布树是版本真相"；要例外就重新发布或由维护者显式改 `release.env` |
| 11 个目录变量漏改 | 某个模块仍读 dev 目录 | `load_config` 统一重定向（§4.1）；验收时逐个 grep |
| tar 文件名与 `release.env` tag 不一致 | 模块找不到 tar | 发布脚本发布前做机械校验（文件名 ↔ tag） |
| Harbor tag 被覆盖 | 同步到的内容与发布时不同 | 发布前记录 digest；Harbor 建议开 immutable |
| `fetch --release` 全量 sha256 较慢 | 取件时间增加 | 默认校验，提供 `--no-verify` |
| 固定短名文件（busybox/nginx）在版本间变化 | 旧版本被新文件覆盖 | 版本目录隔离，各版本各存一份 |
| CLI tar 与 `release.env` 版本不一致 | 部署机用了错误版本的 CLI | 发布脚本校验 tar RepoTags = `cubestack-installer-cli:2.0.0`；fetch 校验 `release.json.cli_tar_sha256` |
| 组件原地刷新中途失败 | 发布树暂时没有 `_SUCCESS` | 保留 `_REFRESH_PENDING`，同 subdirs/`all` 重跑；fetch 明确报“正在刷新” |
| rc→GA 原地刷新删除旧 rc tar | 旧版本回滚能力减弱 | GA 前对 `<release>/` 做 MinIO 快照/版本化，或改用新版本目录完整发布 |
| main/release-2.0 两份 workflow 漂移 | 自动触发行为不一致 | 文件头注明必须同步 cherry-pick；v1 靠评审/文档 |
| 现有 `sync-to-minio.sh --prune` 误删版本目录 | 回滚能力丢失 | 版本目录在桶根、与 `offline-files/` 平级；prune 只作用于 dev 前缀，发布脚本不使用 prune |

**已确认决策（2026-10-21）**：

| # | 决策 | 结论 |
|---|---|---|
| 1 | 发布树包含范围 | `dev-lab` / `model-collection` **包含**（接受冗余）；`virtual-machine` **排除**；其余按开关 |
| 2 | 自研组件版本 | **统一 `2.0.0`**（operator / 平台组件 / CLI / dev-lab / cubepilot / cuberouter / bmc 等）；model-collection 保持上游 tag |
| 3 | 版本开关 | `cluster.conf` 的 `CUBESTACK_RELEASE` 与 `deploy-cluster.sh --release` **两者都支持** |
| 4 | 存储开销 | **接受**发布树按版本完整复制 |

**后续实施讨论项**（不影响本方案）：

- `release-publish.sh` 的命令名/子命令是否按附录 A；
- GPU 组（`metax-gpu` / `nvidia-gpu-operator`）在 2.0 是否默认包含；
- `sync-to-minio.sh` 是否增加"跳过顶层版本目录"的保护；
- 发布树保留份数（建议最近 2–3 个 + 所有已交付版本）。

---

## 11. 变更清单

| 文件 | 类型 | 说明 |
|---|---|---|
| `deployments/scripts/lib-common.sh` | 修改 | release 模式：版本目录、`release.env`、11 个目录变量重定向 |
| `deployments/scripts/deploy-cluster.sh` | 修改 | `--release <版本>` 参数与帮助 |
| `deployments/scripts/tools/offline/fetch-offline-from-minio.sh` | 修改 | `--release` / `--list-releases` / `--verify-only` / `--no-verify`；下载 `offline-files/` + CLI tar |
| `deployments/scripts/modules/03_addon/02_ceph.sh` | 修改 | lvm2 离线包预检改用 `${OFFLINE_FILES_ROOT}/os/packages`（1 行） |
| `deployments/scripts/tools/node/install-worker-packages.sh` | 修改 | `PKG_DIRS` 增加发布树 `os/packages`（1 行） |
| `deployments/config/cluster.defaults.conf` | 修改 | `CUBESTACK_RELEASE` / `CUBESTACK_RELEASE_ROOT` 默认空值 + 注释 |
| `.gitignore` | 修改 | 忽略运行时发布目录 `offline-releases/` |
| `deployments/releases/2.0.0/release.env` | 新增 | 版本变量（发布树真相） |
| `deployments/releases/2.0.0/release-images.tsv` | 新增 | 平台组件镜像清单（现有 TSV 格式） |
| `deployments/scripts/tools/images/release-publish.sh` | 新增（参考） | stage / verify / publish；可替换为你们已有的同步脚本 |
| `deployments/scripts/tools/tests/test-release-mode.sh` | 新增 | release 模式离线回归(路径派生/fetch/校验) |
| `.github/workflows/ci-validate.yml` | 修改 | CI 增加 release 模式回归步骤 |
| `docs/release-management.md` | 新增/更新 | 本文 |
| 其余部署模块 `modules/03_addon/*.sh` | **不改** | 继续通过 `OFFLINE_FILES_ROOT` / 各 `*_SAVE_DIR` 找 tar（`02_ceph.sh` 仅 1 行路径兜底） |

---

## 附录 A：完整操作示例（从零到部署）

```bash
# ===== 发布机（能访问 Harbor + MinIO）=====
cd cubestack-installer

# 1) 确认 release 定义
cat deployments/releases/2.0.0/release.env
cat deployments/releases/2.0.0/release-images.tsv

# 2) 生成 staging
bash deployments/scripts/tools/images/release-publish.sh stage --release 2.0.0
#    → /data/release-staging/2.0.0/offline-files/{kubespray,multus,rdma,...,cubestack-operator}
#    → /data/release-staging/2.0.0/cubestack-installer-cli-v2.0.0.tar
#      注意: ceph 镜像按 image_group_dir 写入 kubespray/<ver>/images/, 无顶层 ceph/

# 3) 校验 staging（Harbor digest ↔ tar，文件名 ↔ tag，SHA256SUMS，CLI tar）
bash deployments/scripts/tools/images/release-publish.sh verify --release 2.0.0

# 4) 发布到 MinIO（拒绝覆盖；_SUCCESS 最后写）
bash deployments/scripts/tools/images/release-publish.sh publish --release 2.0.0

# ===== 部署机 =====
# 5) 取件（本地桶根 /data/cubestack-installer 与 MinIO 桶根同构）
./deployments/scripts/tools/offline/fetch-offline-from-minio.sh \
    --release 2.0.0 --dest /data/cubestack-installer
# → /data/cubestack-installer/2.0.0/{offline-files/, cubestack-installer-cli-v2.0.0.tar}

# 6) 配置
#   cluster.conf:
#     CUBESTACK_RELEASE="2.0.0"
#     CUBESTACK_RELEASE_ROOT="/data/cubestack-installer"
#     OFFLINE_FILES_ROOT="/data/cubestack-installer/offline-files"

# 7) 加载 CLI 镜像并部署
sudo docker load -i /data/cubestack-installer/2.0.0/cubestack-installer-cli-v2.0.0.tar
sudo ./deployments/scripts/deploy-cluster.sh

# 8) 验证
sudo ./deployments/scripts/deploy-cluster.sh --steps verify_cubestack_operator
```

## 附录 B：`release.env` 变量清单

| 变量 | 作用 | 示例 |
|---|---|---|
| `RELEASE_VERSION` | 发布版本（必须与目录名一致） | `2.0.0` |
| `KUBESPRAY_VERSION` | kubespray 版本目录 | `v2.32.0` |
| `KUBESPRAY_PROFILE` | 版本档案 | `v2.32.0` |
| `CUBESTACK_OPERATOR_IMAGE_TAG` | operator 镜像 tag | `2.0.0` |
| `CUBESTACK_OPERATOR_CHART_VERSION` | operator chart 版本 | `2.0.0` |
| `CUBESTACK_OPERATOR_CHART_SYNC` | chart 来源（release 树恒用本地） | `offline` |
| `CUBESTACK_CLI_IMAGE` | 生成 CLI tar 的镜像 ref | `harbor.isuanova.com/suanova/cubestack-installer-cli:2.0.0` |
| `DEV_LAB_IMAGE_TAG` | dev-lab 镜像 tag（release-2.0 包含 dev-lab） | `2.0.0` |
| `RDMA_IMAGE_TAG` | RDMA 插件 tag | `v1.5.4` |
| `MULTUS_IMAGE_TAG` | Multus tag | `v4.2.2-thick` |
| `RELEASE_GROUPS` | 发布树包含的组（审计用） | `kubespray ceph ...` |

> `model-collection` 的 sglang / vllm-metax tag 在
> `offline-files/model-collection/image-list.tsv` 中，没有全局变量；
> `virtual-machine` 不在 release-2.0 发布树中。
>
> release-2.0 组件刷新额外文件/字段：
> - `deployments/releases/<版本>/components.tsv`（组件 → 来源仓库/子目录，§6.6）；
> - `<版本>/_REFRESH_PENDING`（刷新中，fetch 会明确拒绝）、`<版本>/_CLI_IMAGE_DIGEST`（CLI raw digest）；
> - `release.json` 的 `refreshed_at` / `refreshed_components` / `refreshed_git_commit` / `refreshed_by`。

> 上游版本变量（`CEPH_VERSION`、`ROOK_VERSION`、`CSI_*`、`METAX_*` 等）若与
> `cluster.defaults.conf` 一致可省略；发布脚本应校验 `images.manifest` 中每个 `${VAR}`
> 都能解析出非空值，并确认对应 tar 已在发布树中。

## 附录 C：为什么不在现有目录里直接放新版 tar

| 方案 | 代码改动 | 结构改动 | 风险 |
|---|---|---|---|
| 现有目录 + 新 tag 文件名 | 小 | 无 | `busybox.tar` 等固定名会跨版本冲突；模块可能同时看到多个版本 |
| 每个组件加 `<版本>/` 子目录 | 大（所有模块改路径） | 中 | 破坏现有 `OFFLINE_FILES_ROOT/<group>` 约定 |
| **`<桶根>/<版本>/offline-files/` 完整树** | **小** | **新增桶根下的版本目录，现有 `offline-files/` 不动** | 存储按版本重复；用组裁剪控制 |
| 独立新桶 | 中（fetch/工具改桶） | 大 | 现有脚本、权限、监控都要改 |

本方案选择第三种：现有部署代码零改动，MinIO 现有 `offline-files/` 零改动，
只增加可整体删除/回滚的桶根版本目录（`2.0.0/`）。
