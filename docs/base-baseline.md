# 公共 base 基线（versions/base.yaml）

`versions/base.yaml` 是**公共 base 的唯一版本真源**：kubespray、OS 软件包和 base 镜像
的版本都在这里。它由 installer 维护；release 以**固定 commit** 读取它，不在 release
里复制一份版本定义。

## 谁消费

| 消费方 | 方式 |
|---|---|
| installer 开源在线安装 | 直接读本文件的版本，按镜像 catalog 解析 ref/digest |
| cubestack-release（商业版） | 在 `components/base.yaml` 记录 `baseline: {repo, commit, path}`，构建时读取 |
| CLI 镜像 | `deployments/` + `versions/` 一起打进镜像，安装容器内可直接读 |

依赖方向：installer → release 只发 `baseline-updated`；release 不回写 installer。

## 结构

```yaml
schema: 1
kubespray:
  version: v2.32.0
  source: {type: git, repo: suanova/cubestack-installer, path: deployments/kubespray/kubespray}
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
- `catalog_id` 指向 mirror catalog（`container-image-mirror/index.json` 的 `id`）；
  自建公开镜像（如 netshoot-rdma）用 `source_ref` 指向 public `suanova/**`，两者互斥。
- `version` 可以是 `${VAR}` 或字面量；变量必须在 `cluster.defaults.conf` /
  profile 里有定义。禁止 `latest`。
- `dest` / `tar` 里的 `${VAR}` 由安装器解析；`tar` 决定物化后的文件名，模块 35 等
  依赖固定命名。
- OS 包不由 installer 下载或安装；`packages_check` 指向安装前预检清单，installer 只验证
  节点上是否已存在这些包，缺失时列清单退出。
- K8s 二进制（kubelet/kubeadm/kubectl/crictl/CNI 等）仍由 installer 准备；商业离线版由
  release 的 base `files[]` 打包。

## OS 包预检清单

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
- 不下载 `.deb`、不执行 `apt-get install`；缺包时由运维按清单自行安装。
- 版本号仅作为已知良好参考，不参与默认预检。

## 更新流程

1. 第三方镜像先改 `container-image-mirror` 的 `images/*.yaml`（tag + digest），合并后
   产生新的 `index.json`；
2. 在 `versions/base.yaml` 改 `version`（或新增镜像条目），保持 `catalog_id` 不变；
3. 改 OS 预检清单时更新对应的 `.lock`；
4. 本地校验：

   ```bash
   python3 deployments/scripts/tools/validate-base-baseline.py
   ```

5. 提交到 installer；合并后 CI 发 `baseline-updated` 给 release，release 开 PR 更新
   `baseline.commit` 并重建 base pin。

## Rocky 扩展点

`os[]` 的 schema 支持多个 OS family；2.1 只实现 Ubuntu 预检。Rocky 的 rpm 包预检、
Rocky VM 模板和 NVIDIA rhel9 驱动都在后续版本补充，当前不阻塞。
