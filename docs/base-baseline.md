# 公共 base 基线（versions/base.yaml）

`versions/base.yaml` 是**公共 base 的唯一版本真源**：kubespray、节点前置包和 base 镜像
的版本都在这里。它由 installer 维护；商业打包侧以**固定 commit** 读取，
不在下游复制一份版本定义。

## 谁消费

| 消费方 | 方式 |
|---|---|
| installer 开源在线安装 | 直接读本文件的版本，按镜像 catalog 解析 ref/digest |
| 商业打包侧 | 在自己的基线 pin 中记录 `{repo, commit, path}`，构建时读取 |
| CLI 镜像 | `deployments/` + `versions/` 一起打进镜像，安装容器内可直接读 |

依赖方向：installer 只提供公开基线；商业打包侧读取，不回写 installer。

## 结构

```yaml
schema: 1
kubespray:
  version: v2.32.0
  source: {type: git, repo: suanova/cubestack-installer, path: deployments/kubespray/kubespray}
mirror:
  repo: suanova/container-image-mirror
  commit: <sha>
  path: index.json
env:
  K8S_VERSION: v1.35.8
  KUBESPRAY_VERSION: v2.32.0
  # ... public version values used by images below
os:
  - family: debian
    id: ubuntu
    version: "22.04"
    arch: amd64
    packages_check: versions/os/ubuntu-22.04.lock
images:
  - key: k8s-base:registry.k8s.io/kube-apiserver
    catalog_id: kubernetes/kube-apiserver      # container-image-mirror index.json 的 id
    version: "${K8S_VERSION}"                  # 变量或字面量
    dest: "offline-files/kubespray/${KUBESPRAY_VERSION}/images"
    tar: "registry.k8s.io_kube-apiserver_${K8S_VERSION}.tar"
```

要点：

- `key` 全局唯一，格式 `<group>:<source>`。
- `env` 是**受管版本值的唯一来源**：镜像的 `version`/`dest`/`tar` 通过 `${VAR}` 引用它；
  在线安装启动时会先加载这份 env，再交给 `load_config`。
- `display_only` 列出**没有受支持 override 路径**的版本（kubespray/vendored manifest
  硬编码的 CSI、Rook、CSI-operator、snapshot 等）。它们保留在 `env` 里用于展示和
  离线镜像，但 CI 会断言它们与真实源文件一致；升级必须改源文件，不能只改这里。
- `checksums` 保存受管二进制制品的校验和（当前为 etcd、calicoctl、calico CRDS）。
- `make sync-versions` 从 `versions/base.yaml` 生成：
  - `deployments/config/cluster.defaults.conf` 的 generated block
  - `deployments/config/profiles/v2.32.0.profile`
  - `deployments/kubespray/inventory/.../k8s-versions.yml`
  CI 用 `make check-versions` 拒绝过期的生成文件。
- `mirror` 固定 mirror catalog 的 repo/commit/index；base 镜像的 digest 必须以该
  commit 的 `index.json` 为准，避免漂移。
- `catalog_id` 指向 mirror catalog（`container-image-mirror/index.json` 的 `id`）；
  自建公开镜像用 `source_ref` 指向 public `suanova/**`，两者互斥。`source_ref`
  必须同时写 `digest`（镜像没有 catalog 条目，digest 是唯一的钉）。
- `optional: true` 的镜像默认不在线物化（`--with-dev-lab` 才会带上），但商业 base
  打包会包含它们。dev-lab 的三个镜像目前走这个开关。
- `version` 可以是 `${VAR}` 或字面量；变量必须在 `cluster.defaults.conf` /
  profile 里有定义。禁止 `latest`。
- `dest` / `tar` 里的 `${VAR}` 由安装器解析；`tar` 决定物化后的文件名，模块 35 等
  依赖固定命名。
- 节点前置包（OS 包管理器安装在每个 k8s node 上的依赖，如 lvm2/chrony/curl）不由
  installer 下载或安装；`packages_check` 指向安装前体检清单，installer 只验证
  节点上是否已存在这些包，缺失时列清单告警或退出。
- 包安装后的配置与服务操作仍由 installer 负责：chrony 配置与同步、LVM/Ceph 准备、
  k8s 运行时配置等不属于 OS 包安装。
- K8s 二进制（kubelet/kubeadm/kubectl/crictl/CNI 等）仍由 installer 准备；商业离线版由
  商业 base 的 `files[]` 打包。

## 物料清单

`materials:` 记录无法从公共 registry 拉取的厂商制品（当前为 MetaX 资源包/镜像包/
驱动包）。开源用户按 `source.portal` 自行下载，商业打包在 overlay 里用同一个 key
提供本地来源。字段与流程见 [`materials.md`](materials.md)。

## 节点前置包体检清单

> 节点前置包 = 通过 OS 包管理器安装在每个 k8s node 上的依赖（lvm2、chrony、curl、
> rsync、iptables、iputils-ping、ca-certificates、skopeo 等），不是容器镜像，也不是
> kubelet/kubeadm 等 k8s 二进制。

`versions/os/<id>-<version>.lock` 是**安装前检查清单**，不是下载/安装清单：

```yaml
schema: 1
family: debian
id: ubuntu
version: "22.04"
codename: jammy
source: "Ubuntu 22.04 package set; versions observed on archive.ubuntu.com as of 2026-11-04"
packages:
  reconcile:      # 所有节点都要有
    lvm2: "2.03.11-2.1ubuntu5"
  chrony:         # 仅 NTP 模块按需检查
    chrony: "4.2-2ubuntu2.1"
```

- installer 只检查包是否存在；默认按包名检查，`--strict` 可额外校验版本。
- 2.1 在线安装默认 `--warn-only`：缺包时列清单告警但不失败；`--check-os-packages`
  改为阻断，`--no-check-os-packages` 跳过。
- 不下载 `.deb`、不执行 `apt-get install`；缺包时由运维按清单自行安装。
- 版本号仅作为已知良好参考，不参与默认检查。

## 更新流程

1. 第三方镜像先改 `container-image-mirror` 的 `images/*.yaml`（tag + digest），合并后
   产生新的 `index.json`；
2. 在 `versions/base.yaml` 改受管版本的 `env` 值（或新增镜像条目），保持 `catalog_id`
   不变；`display_only` 里的版本不能在这里改，必须改对应的 kubespray/vendored 源文件；
3. 二进制制品版本变化时同步更新 `checksums`；
4. 运行 `make sync-versions` 更新 derived 文件；
5. 改节点前置包体检清单时更新对应的 `.lock`；
6. 本地校验：

   ```bash
   make check-versions
   python3 deployments/scripts/tools/validate-base-baseline.py
   ```

7. 提交到 installer；商业打包侧按自己的节奏更新基线 commit 并重建 base pin，
   公开 installer 不依赖下游流程。

## K8s 二进制包

kubelet/kubeadm/kubectl/crictl/CNI/containerd/runc/etcd 等由 installer 维护**来源和版本**：

- `versions/base.yaml` 的 `files[]` 使用 `source.type: installer-binaries`，
  只声明 `version` / `arch`；商业打包侧在固定 baseline commit 上补 `repo` / `ref`。
- 商业打包时 checkout installer 的 pinned commit，调用
  `tools/offline/build-k8s-binaries.sh` 从 kubespray 的上游 URL 下载并打成
  `binaries.tar.gz`，不依赖 GitHub Release 资产。
- 生成的 tar 由下游 `fetch-base-sources` 计算 digest、写入 tree、打进 base 树；
  `materialize-base` 解包到 `offline-files/kubespray/<ver>/`。
- 开源在线安装仍由 `k8s_asset_prefetch` 在安装时用同一套 `download-files` 逻辑下载。

这样 installer 只维护“从哪里下载、下载什么版本”，字节由商业打包侧获取。

## Rocky 扩展点

`os[]` 的 schema 支持多个 OS family；2.1 只实现 Ubuntu 节点前置包体检。Rocky 的 rpm 包体检、
Rocky VM 模板和 NVIDIA rhel9 驱动都在后续版本补充，当前不阻塞。
