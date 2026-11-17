# cubestack-installer `latest/` 离线树布局设计

- 日期: 2026-11-17
- 状态: 设计 + 脚本（仅 `plan` 已验证；`apply` 需确认后执行）
- 相关: `docs/base-baseline.md`、`docs/release-management.md`、`cubestack-release` 仓库
  `docs/release-runbook.md` / `docs/versioning.md`

## 1. 目标

在 MinIO `cubestack-installer` 桶下提供一棵 **自包含、可直接部署** 的 `latest/`
安装树，内容与 `cubestack-release` CI 的最新 snapshot 对齐；同时把本机
`/data/offline-files` **原地**更新为同一棵 `offline-files`。

约束：

- 镜像与 metadata 的唯一真源是 `cubestack-release` 写入的 store
  `s3://cubestack-test/validation`（当前 CI 默认值），不重新从 Harbor 拉取。
- 布局遵循 `cubestack-release` 的 `compose` / `package` / `materialize` /
  `merge-tree` 契约，并参考 `cubestack-test` 现有 `validation/` 布局。
- 操作必须幂等、可续跑、可校验；不手改文件，不执行 `mc mirror --remove`。

## 2. 真源与输入

| 输入 | 位置 | 作用 |
|---|---|---|
| base 版本真源 | `versions/base.yaml`、`versions/groups.yaml` | 版本面变量、base 镜像清单（CI 侧已 compose 进 base 包） |
| 平台镜像清单 | `deployments/offline-files/*/image-list.tsv` | cubestack-operator / dev-lab / model-collection（CI 侧已 compose） |
| 发布 store | `s3://cubestack-test/validation` | snapshot、base 包、内容寻址 artifacts、streams 指针 |
| 本地树 | `/data/offline-files` | 原地更新的目标 |

### 2.1 `versions/*.yaml` → 安装树路径

`versions/base.yaml` 的 `images[]` 用 `dest` + `tar` 决定落盘位置；当前分组：

| `key` 前缀（group） | 来源 | `dest` | 说明 |
|---|---|---|---|
| `k8s-base:*` | `catalog_id` → container-image-mirror | `offline-files/kubespray/${KUBESPRAY_VERSION}/images` | kube-*/etcd/calico/metallb/kube-vip/registry/local-path/nfd/coredns/pause/metrics-server/cpa/nginx/busybox |
| `ceph:*`、`ceph:rook/*` | 同上 | 同上 | Rook / Ceph / ceph-csi-operator / CSI sidecars（kubespray 与 Rook 两套版本并存） |
| `nginx:*` | 同上 | `offline-files/nginx` | 中性名 `nginx.tar` |
| `multus:*` | 同上 | `offline-files/multus` | |
| `rdma:*` | 同上 | `offline-files/rdma` | |
| `netshoot:*` | `source_ref` + `digest`（自建） | `offline-files/netshoot` | 中性名 `netshoot-rdma.tar` |
| `nvidia-gpu-operator:*` | `catalog_id` | `offline-files/nvidia-gpu-operator` | operator / toolkit / device-plugin / dcgm / driver 等 |
| `metax:*`（`materials[]`） | vendor-portal | `offline-files/metax-gpu` | k8s package / images / driver，`optional: true` |
| 平台组件 | `deployments/offline-files/*/image-list.tsv` | `offline-files/cubestack-operator|dev-lab|model-collection` | operator 37 件、dev-lab 3 件、model 5 件 |

`versions/groups.yaml` 只描述逻辑分组（`kind: image|file|material`），不参与落盘路径；
真正路径由 tree.tsv 的 `path` 列决定。

### 2.2 store 布局（2026-11-17 实测）

```text
validation/
  streams/
    2.1-snapshot.yaml      # line/channel/target/manifest_sha256（当前最新快照）
    2.1-stable.yaml        # 指向 releases/2.1.0
    2.1-latest.yaml        # 旧 dev 通道，指向 20261103 快照
  snapshots/<line>-SNAPSHOT-<YYYYMMDD>-<sha7>/
    release.yaml release.env release.json tree.tsv SHA256SUMS _SUCCESS
    offline-files/model-collection/image-list.tsv      # metadata_files
  base/<base-version>/
    base.yaml base.env tree.tsv SHA256SUMS _SUCCESS
  artifacts/
    images/sha256/<blob-sha256>.tar
    images/by-digest/v2/<image-digest>/<ref-hash>.txt   # image digest → blob 索引
    charts/sha256/<blob-sha256>.tgz
    cli/sha256/<blob-sha256>.tar
    files/sha256/<blob-sha256>.bin
    bundles/sha256/<blob-sha256>.tgz
    modules/sha256/<blob-sha256>.tar
```

`tree.tsv` 列（由 `compose` 生成）：

```text
path  artifact  extract  mode  size  sha256  group  package
```

- `path` 相对安装树根，例如 `offline-files/kubespray/v2.32.0/images/x.tar`；
- `artifact` 相对 store 根，例如 `artifacts/images/sha256/<sha>.tar`；
- `sha256` 是 **实际归档文件** 的 digest；`release.yaml` 里的镜像 digest 是
  **镜像身份**，两者不同；
- `extract=true` 表示归档需要展开（当前只有 `modules/`、`binaries.tar.gz`、
  `tree.tar.gz` 三行）。

## 3. 目标布局（单一）

`s3://cubestack-installer/latest/` 下就是 **CI store 布局**，与
`cubestack-release` 的 `base/` + `package-base` / `package` 产物对齐；
MinIO 中不再保留单独的物化安装树。

```text
s3://cubestack-installer/latest/
  base/base-2026.10/
    base.yaml base.env tree.tsv SHA256SUMS _SUCCESS
  artifacts/
    images|charts|cli|files|bundles|modules/sha256/<blob-sha256>.<ext>
    images/by-digest/v2/<image-digest>/<ref-hash>.txt
    files/by-digest/...  cli/by-digest/...
  vendor/
    kubespray/v2.32.0/binaries.tar.gz
    metax/3.8.1.x/x86_64/{metax-gpu-k8s-package.0.15.3.tar.gz,metax-k8s-images.0.15.3.run}
  snapshots/<line>-SNAPSHOT-<date>-<sha7>/
    release.yaml release.env release.json tree.tsv SHA256SUMS _SUCCESS
    offline-files/model-collection/image-list.tsv
  streams/<line>-snapshot.yaml
  STORE-SOURCE.yaml
```

- `tree.tsv` 的 `artifact` 指向 `artifacts/...`，`sha256` 是**归档文件** digest；
- `vendor/` 是 `base/overlay.yaml` 外部文件的来源前缀（binaries、metax
  materials）；
- `STORE-SOURCE.yaml` 记录本次镜像来源（见 §5）。

本地 `/data/offline-files` 由这套布局**物化**得到，是派生结果，不在 MinIO
里保留第二份。

### 3.1 物化规则（本地）

| `tree.tsv` 行 | `apply` 动作 |
|---|---|
| `extract=false`（绝大多数镜像/chart） | 从 `latest/<artifact>` 下载到 `path` |
| `modules/` + `extract=true` | 下载 tar → 解包 → 写到本地 `modules/` |
| `offline-files/.../binaries.tar.gz` + `extract=true` | 下载 → 解包到 **`dirname(path)`**（裸二进制） |
| `offline-files/.../tree.tar.gz` + `extract=true` | 作为 **文件** 写到 `path`，并写 `path.sha256` 边车 |

物化时额外处理 installer 兼容项：operator chart 版本化别名（§6.4）、
`.run` 可执行位（§6.5）、`VERSION.profile` / `tree.tar.gz.sha256`（§6.2）。
这些兼容项**只出现在本地树**，不写回 MinIO store。

## 4. 本地 `SHA256SUMS` / `_SUCCESS` 语义

物化后由本工具生成，与 `cubestack-release` 的 `merge-tree` 一致：

- `offline-files/SHA256SUMS`：对本地 `offline-files/` 下**实际落盘**的所有文件
  （含 `tree.tsv`、`release.*`、`base/*`、展开后的二进制、`tree.tar.gz*.sha256`、
  `VERSION.profile`、operator chart 别名）计算 sha256，按相对路径排序，格式
  `<sha256>  <relpath>`（无 `./` 前缀）。
- `offline-files/_SUCCESS`：`sha256:<sha256(SHA256SUMS)>\n`（CI 原样格式）。
- 元数据最后写，`_SUCCESS` 最后写；中途失败时不应出现半套 `_SUCCESS`。

> MinIO store 里的 `base/SHA256SUMS`、`snapshots/.../SHA256SUMS` 是
> `cubestack-release` 原生元数据，本工具不改写；第 4 节指的是**本地物化树**。

## 5. `STORE-SOURCE.yaml` 指针

放在 `latest/` 根，记录本次镜像来源，便于审计和增量判断：

```yaml
schema: 1
kind: store-mirror
source_store: minio/cubestack-test/validation
target_store: minio/cubestack-installer/latest
source_target: snapshots/2.1-SNAPSHOT-20261117-484e287
base_version: base-2026.10
base_digest: sha256:1c34eee3...
manifest_sha256: sha256:c41d10c4...
published_at: 2026-11-17T...
objects: 305
bytes: 170655952543
copied: 305
skipped: 0
```

## 6. 与 CI 现状的差异（实测发现）

### 6.1 `extract=true` 的展开语义

`cubestack-release` 的 `materialize` 对 `extract=true` 行执行
`out.mkdir(); tar.extractall(out)`，即把归档解到 **与文件同名目录**
（`.../binaries.tar.gz/kubeadm-...`）；而 `base/README.md` 与 installer
（`deployments/kubespray/cubestack-version-dir.sh`）期望：

- `binaries.tar.gz` 的成员在归档根 → 展开到 `offline-files/kubespray/<ver>/`；
- `tree.tar.gz` 保持为文件，并带 `tree.tar.gz.sha256` 边车。

**本设计按 installer 契约处理**（见 §3.3），不复刻该差异。

### 6.2 base 包缺少 installer 要求的两个文件

`base-2026.10` 的 `tree.tsv` 没有 `VERSION.profile`，也没有
`tree.tar.gz.sha256`。本工具：

- `VERSION.profile`：按 `release.env` 的 `KUBESPRAY_VERSION`，从仓库
  `deployments/config/profiles/<ver>.profile` 复制（该文件由
  `make sync-versions` 从 `versions/base.yaml` 生成，当前与 base.env 逐项一致）；
- `tree.tar.gz.sha256`：由 `tree.tar.gz` 的实际 digest 生成。

两者都会进入 `SHA256SUMS`，并会出现在本地树中。

### 6.3 `os/` 节点前置包不在 base 包内

base-2026.10 没有 `offline-files/os/packages/`（2.0.1 发布树有）。
因此原地更新后本地 `os/` 会被判为 stale 并删除。节点前置包检查使用仓库内
`versions/os/*.lock`，不在本次范围内；如仍需本地 `.deb` 缓存，应另建来源，
不要混入 `latest/`。

### 6.4 operator chart 的中性名兼容别名

新 CI 树用中性名 `cubestack-operator/charts/cubestack-operator-chart.tgz`
（见 `cubestack-release` `docs/versioning.md`），但发布版 CLI（commit
`a620467`）的 `resolve_operator_chart_tgz` 只匹配
`<name>-<version>.tgz`，模块 25 离线部署会报 `chart 缺失`。
因此**本地物化时**额外写一个版本化别名：

```text
cubestack-operator/charts/cubestack-operator-chart-<CUBESTACK_OPERATOR_CHART_VERSION>.tgz
```

- 与中性名**同 digest**，进入本地 `SHA256SUMS`；
- 只别名 operator 自身 chart：其他组件 chart 由 `*.tgz` 遍历消费，
  加别名会造成重复推送；
- **不写回 MinIO store**：`cubestack-installer/latest/` 保持与
  `cubestack-release` 逐字节一致；
- 旧 verifier 会对中性名报“非指定 chart 版本”警告（误报），不影响校验通过。

### 6.5 `.run` 文件可执行位

`base-2026.10` 的 `metax-k8s-images.0.15.3.run` 在 `tree.tsv` 里是 `0644`，
但 `modules/03_addon/06_gpu_operator.sh` 用 `[ -x ]` 判定 run 模式。
本地同步时对 `*.run` 强制 `0755`（MinIO 对象不保存 POSIX mode）。

## 7. 本地原地更新

顺序（保证中断可续跑）：

1. 备份旧元数据到 `/data/offline-files/.cubestack-manifest-backup/<ts>/`
   （`release.*`、`tree.tsv`、`SHA256SUMS`、`_SUCCESS`、`base/`）；
2. 删除 `latest` 清单之外的文件（保留 `.cubestack-*` 与备份目录）；
3. 逐个下载 changed/new 到同目录 `.tmp`，校验 sha256 + size 后 `rename`；
4. 最后写元数据，`_SUCCESS` 最后写；
5. 运行 `verify-offline-files.sh --root /data/offline-files --layout release
   --require-success --level quick --no-stamp` 做结构校验。

### 7.1 空间测算（2026-11-17 dry-run）

| 项 | 数值 |
|---|---|
| 目标清单项 | 112 个（含 8 个元数据 + `SHA256SUMS`/`_SUCCESS` + operator chart 别名，未含 extract 展开） |
| extract 归档 | 3 个（595.7 MiB） |
| 目标总大小 | 157.28 GiB（含归档） |
| 本地实际文件 | 297 个 / 112.18 GiB |
| 本地 stale | 239 个 / 95.48 GiB |
| 本地 keep / changed / new | 0 / 58 (21.28 GiB) / 52 (134.25 GiB) |
| 需下载 | 155.53 GiB |
| 当前 `/data` 可用 | 103.34 GiB |
| 删除 stale 后可用 | 198.82 GiB |
| 结论 | 先删 stale 再下载，峰值后余量 ≈ 43 GiB，可行 |

> 现有 2.0.1 与最新 snapshot 的 tar **byte 级不同**（同一镜像重新 save），
> 所以没有可复用的 keep 文件，需全量下载 156.73 GiB。

**执行结果（2026-11-17）**：本地 `/data/offline-files` 136 个文件 / 157.28 GiB，
`verify-offline-files.sh --level quick` 通过（仅中性 chart 名误报）；MinIO
`cubestack-installer/latest/` 已收敛为单一 CI store 布局。

### 7.2 MinIO `latest/` 规模（CI store 布局）

| 组 | 对象 | 大小 |
|---|---|---|
| `artifacts/`（引用的 blob + by-digest 索引） | 289 | 157.28 GiB |
| `base/base-2026.10/` | 5 | <1 MiB |
| `snapshots/<name>/` | 7 | <1 MiB |
| `streams/<line>-snapshot.yaml` | 1 | <1 MiB |
| `vendor/`（binaries + metax materials） | 3 | 1.66 GiB |
| **合计** | **305** | **158.94 GiB** |

`artifacts/payloads/`（base-runtime 4.7G + vendor 5.5G 拆分包）默认不镜像；
需要 `--with-payloads`。

## 8. 工具与用法

脚本：`deployments/scripts/tools/offline/offline-sync.py`

```bash
# 1) 把 CI store（base/artifacts/vendor/snapshots/streams）镜像到
#    cubestack-installer/latest/；默认只读计划
python3 deployments/scripts/tools/offline/offline-sync.py store
python3 deployments/scripts/tools/offline/offline-sync.py store --yes

# 2) 从 latest/ 的 CI store 布局物化本地 offline-files（只读计划 / 执行）
python3 deployments/scripts/tools/offline/offline-sync.py plan
python3 deployments/scripts/tools/offline/offline-sync.py apply --yes

# 3) 指定 stream / snapshot / 本地目录
python3 deployments/scripts/tools/offline/offline-sync.py apply --yes \
  --stream 2.1-snapshot \
  --materialize-from minio/cubestack-installer/latest \
  --local-root /data/offline-files

# 4) 同步/物化正式 release（如 2.1.0），不再局限于 latest
python3 deployments/scripts/tools/offline/offline-sync.py store --yes \
  --release 2.1.0 --store-dst minio/cubestack-installer/2.1.0
python3 deployments/scripts/tools/offline/offline-sync.py apply --yes \
  --release 2.1.0 --materialize-from minio/cubestack-installer/2.1.0
```

常用选项：`--snapshot <target>` / `--release <version>` 跳过 stream 解析、
`--json` 机器可读计划、`--work-dir <dir>` 指定 extract 中转目录；`store` 另支持
`--store-dst`、`--force-upload`、`--with-payloads`、`--skip-vendor`；`apply` 支持
`--skip-local`（只做计划校验）、`--with-install-tree`（同时物化 `modules/` 与
CLI tar 到 `dirname(local-root)`）。

退出码：`0` 成功；`1` 执行失败；`2` 参数/输入错误（含 manifest 校验失败）。

## 9. 非目标

- 不修改 `cubestack-test` store、不写 stream 指针；
- 不构建镜像、不重新拉 Harbor；
- 不处理 `release.yaml` 的 `packages[]` / payload 包（`--with-packages`）；
- 不替代 CI 的 `snapshot` / `deliver` / `release` 流程；本工具只把 CI 产物
  镜像到 `latest/`，并按 installer 契约在本地物化。
