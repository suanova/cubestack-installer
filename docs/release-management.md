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
│   └── cubestack-installer-cli.tar      # 2.0.0 的 CLI 镜像（离线加载用）
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
桶根新增 `<版本>/offline-files/` + `<版本>/cubestack-installer-cli.tar`（见上图）。

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
远端 <bucket>/<version>/cubestack-installer-cli.tar
                                        →  本地 <base>/<version>/cubestack-installer-cli.tar
```

`--release` 只切换源根与目标布局，磁盘预检、`mc mirror`、增量续传等逻辑复用现有实现；
`--sub` 的语义完全不变。

### 1.5 现有 CI 的位置

| 工作流 | 现在做什么 | 与发布的关系 |
|---|---|---|
| `sync-images-to-harbor.yml` | 上游镜像 → Harbor `mirrors/**` | 发布前确保 Harbor 有正确上游镜像 |
| `refresh-latest-offline.yml` | 滚动 `latest` 镜像 → MinIO `offline-files/` | **只服务 dev 通道**，不得写版本目录 |
| `rebuild-cli-image.yml` | 重建 `cubestack-installer-cli:latest`；导出 tar 自动同步到 MinIO `offline-files/cli/` | main 合并即自动更新 dev CLI tar；发布时用 `version=2.0.0` 额外推 `:2.0.0`，release tar 由 `release-publish.sh` 写入 `<版本>/` |

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
│   └── cubestack-installer-cli.tar      # 2.0.0 的 CLI 镜像（离线加载用）
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
│   └── cubestack-installer-cli.tar
└── 1.9.0/
```

`fetch --release 2.0.0 --dest /data/cubestack-installer` 会下载：

```text
/data/cubestack-installer/2.0.0/offline-files/...
/data/cubestack-installer/2.0.0/cubestack-installer-cli.tar
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

`model-collection` 约 85G、`dev-lab` 约 44G，release-2.0 **明确把它们放进发布树**，
因此单版本发布树会比较大（核心部署集 + 约 130G），这是已接受的存储冗余。
`virtual-machine` 仍不放入发布树；如果后续某个版本需要，再按同一套
`<版本>/offline-files/` 结构单独生成一份发布树，不影响本方案。

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

# 自研镜像 tag（release-2.0: 所有自研组件统一 2.0.0）
CUBESTACK_OPERATOR_IMAGE_TAG=2.0.0
CUBESTACK_OPERATOR_CHART_VERSION=2.0.0
# release 树自带 chart(offline-files/cubestack-operator/charts/), 部署恒用本地副本
CUBESTACK_OPERATOR_CHART_SYNC=offline
DEV_LAB_IMAGE_TAG=2.0.0
# CLI 镜像(发布脚本用它生成 <版本>/cubestack-installer-cli.tar)
CUBESTACK_CLI_IMAGE=harbor.isuanova.com/suanova/cubestack-installer-cli:2.0.0

# model-collection 的 sglang / vllm-metax 保持各自上游 tag, 不在这里统一;
# 具体 ref/文件名以 offline-files/model-collection/image-list.tsv 为准。

# 上游固定版本：与 release tree 中 tar 文件名一致
# （若无变化可省略，load_config 会沿用 cluster.defaults.conf；发布脚本应校验一致性）
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
  "cli_tar": "../cubestack-installer-cli.tar",
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
- `cubestack-installer-cli.tar` 在 `<版本>/` 下，校验值写入 `release.json` 的
  `cli_tar_sha256` / `cli_tar_size`（不放进 `SHA256SUMS`，避免跨目录相对路径）；
- `_SUCCESS` 内容为版本与时间，**最后写入**；
- fetch 侧先检查 `_SUCCESS`，再下载，最后 `sha256sum -c` + 校验 CLI tar；
- 发布脚本**拒绝覆盖**已存在的 `<版本>/`；修复发新 patch 版本。

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
└── cubestack-installer-cli.tar
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

`fetch-offline-from-minio.sh` 复用现有下载/磁盘预检/`mc mirror` 逻辑，只切换源根与目标布局：

1. 解析 `--release <ver>`（与 `--sub` 互斥）：
   - 本地根 `TARGET`：`--dest` > 环境/minio.conf 的 `CUBESTACK_RELEASE_ROOT` > `${REPO_ROOT}/offline-releases`；
   - 远端版本目录 `RELEASE_BASE="<alias>/<bucket>/<ver>"`；
   - 检查 `${RELEASE_BASE}/offline-files/_SUCCESS`，否则报"发布未完成"；
2. 下载 `${RELEASE_BASE}/offline-files/` → `${TARGET}/<ver>/offline-files/`；
3. 下载 `${RELEASE_BASE}/cubestack-installer-cli.tar` → `${TARGET}/<ver>/cubestack-installer-cli.tar`；
4. 默认校验：
   - 在 `${TARGET}/<ver>/offline-files/` 执行 `sha256sum -c SHA256SUMS`；
   - 按 `release.json.cli_tar_sha256` 校验 CLI tar；
5. 输出 `CUBESTACK_RELEASE` / `CUBESTACK_RELEASE_ROOT` 提示；
6. `--list-releases`：`mc ls <bucket>/`，列出除 `offline-files/` 外的目录（可再按版本号格式过滤）。

> `fetch` 可从环境/`minio.conf` 读 `CUBESTACK_RELEASE_ROOT`；部署时请在 `cluster.conf`
> 设置同一路径（`load_config` 只读 cluster.conf/defaults/环境，不读 minio.conf）。

改动集中在参数解析、源根切换和下载后校验，约 60 行；`--sub` 的现有行为不变，
`DEFAULT_EXCLUDE_SUBS` 也无需改动（版本目录在 `offline-files/` 之外）。

### 5.3 校验语义

| 检查 | 失败处理 |
|---|---|
| `<ver>/offline-files/` 存在 | 报错，列出可用版本 |
| `<ver>/offline-files/_SUCCESS` 存在 | 报错"发布未完成/上传中断" |
| `SHA256SUMS` 存在 | 报错"发布树不完整" |
| 发布树每个文件 sha256 匹配 | 报错，列出不匹配文件 |
| `release.json.cli_tar_sha256` 与 CLI tar 匹配 | 报错（CLI 镜像不完整） |
| `release.env` 中 `RELEASE_VERSION == <ver>` | 报错 |

`--no-verify` 可跳过全量 sha256 / CLI tar 校验（仅建议在反复调试时使用）。

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
       docker-archive:/data/release-staging/2.0.0/cubestack-installer-cli.tar:harbor.isuanova.com/suanova/cubestack-installer-cli:2.0.0
6. 生成元数据（都在 staging/offline-files/ 下）：
     release.env / release.json / SHA256SUMS
     release.json.cli_tar_sha256 / cli_tar_size 记录 ../cubestack-installer-cli.tar
7. 上传到：
     <bucket>/2.0.0/offline-files/                # 发布树
     <bucket>/2.0.0/cubestack-installer-cli.tar   # CLI 镜像
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
| CLI 镜像 | `suanova/cubestack-installer-cli:2.0.0` | `cubestack-installer-cli.tar`（`<版本>/` 下） | 部署机 `docker load` |

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
- `_SUCCESS` 必须最后写入（位于 `<版本>/offline-files/`）；
- `SHA256SUMS` 必须覆盖发布树全部文件；CLI tar 的校验值写入 `release.json`；
- 发布前校验每个 Harbor ref 的 digest 与预期一致（`skopeo inspect --raw`），避免"tag 还在但内容变了"；
- 不执行 `mc mirror --remove` / `--prune`；
- `sync-to-minio.sh --prune` / `--force-full-prune` 不得作用于包含版本目录的桶根
  （建议后续给该脚本加一条"跳过顶层版本目录"的保护；发布树是回滚能力，不能被 dev 刷新删除）；
- 不在日志/argv 中输出 Harbor/MinIO 凭据。

### 6.5 与现有 CI 的关系

- 现有 `refresh-latest-offline.yml` **不动**，继续维护 dev `offline-files/`；
- 发布脚本可以先手工/定时在内网机器执行（与 `cubestack-platform-sync.sh` 的部署位置一致：
  需同时访问 Harbor 与 MinIO）；
- 将来若加 CD，只需在发布机上调用同一个脚本，不改变 MinIO 契约。

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
mc stat minio/cubestack-installer/2.0.0/cubestack-installer-cli.tar
```

### 8.3 部署机取件

```bash
# 1) 取发布版本（本地桶根 /data/cubestack-installer 与 MinIO 桶根同构）
./deployments/scripts/tools/offline/fetch-offline-from-minio.sh \
    --release 2.0.0 --dest /data/cubestack-installer
# → /data/cubestack-installer/2.0.0/{offline-files/, cubestack-installer-cli.tar}

# 2) 配置版本开关（cluster.conf）
CUBESTACK_RELEASE="2.0.0"
CUBESTACK_RELEASE_ROOT="/data/cubestack-installer"
OFFLINE_FILES_ROOT="/data/cubestack-installer/offline-files"   # dev 根

# 3) 加载 2.0.0 的 CLI 镜像（名字/tag 以 tar 内 RepoTags 为准）
sudo docker load -i /data/cubestack-installer/2.0.0/cubestack-installer-cli.tar

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
- [ ] 所有自研组件镜像 tag 均为 `2.0.0`；`model-collection` 镜像按 `image-list.tsv` 保持上游 tag；
- [ ] `model-collection/image-list.tsv` 存在于发布树（模块 37 依赖）；
- [ ] `cubestack-operator/charts/<chart>-2.0.0.tgz` 存在于发布树（模块 25 恒用本地 chart）；
- [ ] `2.0.0/offline-files/` 包含 `release.env`、`SHA256SUMS`、`_SUCCESS`；
- [ ] `2.0.0/cubestack-installer-cli.tar` 存在，sha256 与 `release.json` 一致；
- [ ] `_SUCCESS` 缺失时 `fetch --release` 拒绝下载；
- [ ] `sha256sum -c SHA256SUMS` 全量通过；
- [ ] `CUBESTACK_RELEASE=2.0.0` 时 `OFFLINE_FILES_ROOT` 指向 `2.0.0/offline-files`，且
      `CUBESTACK_OPERATOR_OFFLINE_DIR` / `RDMA_SAVE_DIR` 等 11 个目录变量全部指向发布树；
- [ ] `deploy-cluster.sh --release 2.0.0` 能找到 operator / 各组件 / 上游 tar，无
      "未找到 tar" 告警；
- [ ] 部署后关键镜像的 tag 为 `2.0.0`（或 release.env 中对应版本），无 `_latest` 残留；
- [ ] 回滚到上一个版本可重复执行；
- [ ] 发布脚本重复执行时，检测到已存在的版本直接失败，不覆盖；
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
#    → /data/release-staging/2.0.0/cubestack-installer-cli.tar
#      注意: ceph 镜像按 image_group_dir 写入 kubespray/<ver>/images/, 无顶层 ceph/

# 3) 校验 staging（Harbor digest ↔ tar，文件名 ↔ tag，SHA256SUMS，CLI tar）
bash deployments/scripts/tools/images/release-publish.sh verify --release 2.0.0

# 4) 发布到 MinIO（拒绝覆盖；_SUCCESS 最后写）
bash deployments/scripts/tools/images/release-publish.sh publish --release 2.0.0

# ===== 部署机 =====
# 5) 取件（本地桶根 /data/cubestack-installer 与 MinIO 桶根同构）
./deployments/scripts/tools/offline/fetch-offline-from-minio.sh \
    --release 2.0.0 --dest /data/cubestack-installer
# → /data/cubestack-installer/2.0.0/{offline-files/, cubestack-installer-cli.tar}

# 6) 配置
#   cluster.conf:
#     CUBESTACK_RELEASE="2.0.0"
#     CUBESTACK_RELEASE_ROOT="/data/cubestack-installer"
#     OFFLINE_FILES_ROOT="/data/cubestack-installer/offline-files"

# 7) 加载 CLI 镜像并部署
sudo docker load -i /data/cubestack-installer/2.0.0/cubestack-installer-cli.tar
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
