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
    packages_lock: versions/os/ubuntu-22.04.lock
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
- OS 资产（kubespray 树/二进制、deb/rpm）由 release 的 base `files[]` 打包；
  `packages_lock` 只记录包版本。

## OS 包 lock

`versions/os/<id>-<version>.lock`：

```yaml
schema: 1
family: debian
id: ubuntu
version: "22.04"
codename: jammy
source: "http://archive.ubuntu.com/ubuntu (jammy, jammy-updates, jammy-security) as of 2026-11-04"
packages:
  reconcile:      # 所有节点对账安装
    lvm2: "2.03.11-2.1ubuntu5"
  chrony:         # 仅 NTP 模块按需安装
    chrony: "4.2-2ubuntu2.1"
```

> 当前版本解析自 archive.ubuntu.com；后续切换到 `snapshot.ubuntu.com` 的固定时间戳，
> 由 `fetch-os-packages` 下载并写入 bundle digest。

## 更新流程

1. 第三方镜像先改 `container-image-mirror` 的 `images/*.yaml`（tag + digest），合并后
   产生新的 `index.json`；
2. 在 `versions/base.yaml` 改 `version`（或新增镜像条目），保持 `catalog_id` 不变；
3. 改 OS 包时更新对应的 `.lock`；
4. 本地校验：

   ```bash
   python3 deployments/scripts/tools/validate-base-baseline.py
   ```

5. 提交到 installer；合并后 CI 发 `baseline-updated` 给 release，release 开 PR 更新
   `baseline.commit` 并重建 base pin。

## Rocky 扩展点

`os[]` 的 schema 支持多个 OS family；2.1 只实现 Ubuntu。Rocky 的 rpm/dnf 模块、
Rocky 包 lock、Rocky VM 模板和 NVIDIA rhel9 驱动都在后续版本补充，当前不阻塞。
