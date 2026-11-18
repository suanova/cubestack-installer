# versions/base.yaml 维护说明

`versions/base.yaml` 是公共 base 的唯一源清单：它描述“要哪些版本、从哪个
mirror/catalog 取、放到安装树的哪里”，不定义产品版本，也不定义发布包。

## 文件结构

```text
schema        # 固定为 1
kubespray     # kubespray 源码来源
mirror        # 第三方镜像 catalog 的 pin
env           # 版本变量，供模板展开和 installer 运行时使用
materials     # 厂商物料（MetaX），开源只给门户地址
os            # OS 前置体检清单，只体检不打包
images        # 镜像清单
files         # k8s 二进制等文件
```

## key 与 group

每个 image/material/file 都有稳定的 `key`：

```text
<group>:<source>
```

例如：

```yaml
- key: netshoot:netshoot-rdma
  source_ref: harbor.isuanova.com/suanova/netshoot-rdma
  version: sha-<commit>
  digest: sha256:...
```

- `group` 是 key 冒号前的部分，表示逻辑分组/消费组；
- `source` 是冒号后的部分，通常是 image repository 或文件 key；
- tag 不放在 key 里，放在 `version`；digest 单独放；
- 升级 tag/digest 时 key 不变。

公共 group 白名单在 `versions/groups.yaml` 定义：

| group | 含义 | 类型 |
|---|---|---|
| `k8s-base` | Kubernetes 基础镜像 | image |
| `ceph` | Ceph/Rook/CSI | image |
| `multus` | Multus CNI | image |
| `rdma` | RDMA plugin | image |
| `nginx` | API LB nginx | image |
| `netshoot` | netshoot-rdma | image |
| `nvidia-gpu-operator` | NVIDIA GPU Operator | image |
| `metax-gpu-operator` | MetaX GPU Operator 镜像 | image |
| `k8s` | kubespray 树/k8s 二进制 | file |
| `metax` | MetaX 厂商物料 | material |

新增 group 必须同时改 `versions/groups.yaml` 和本 README；release 侧还要在
`config/groups.yaml`（私有/overlay）或 `config/packages.yaml`（包映射）里归类。

## images

第三方镜像优先用 `catalog_id`（MetaX GPU operator 是唯一已评审例外，见下）：

```yaml
- key: k8s-base:registry.k8s.io/pause
  catalog_id: kubernetes/pause
  version: ${PAUSE_VERSION}
  dest: offline-files/kubespray/${KUBESPRAY_VERSION}/images
  tar: registry.k8s.io_pause_${PAUSE_VERSION}.tar
```

- digest 不写在这里，由 `mirror.commit + index.json + catalog_id + version` 解析；
- `tar` 是安装树里的文件名（2.1 目标态逐步改为中性/digest 名）。

自研镜像用 `source_ref + digest`：

```yaml
- key: netshoot:netshoot-rdma
  source_ref: harbor.isuanova.com/suanova/netshoot-rdma
  version: sha-<commit>
  digest: sha256:...
  dest: offline-files/netshoot
  optional: true
  tar: netshoot-rdma.tar
```

`catalog_id` 和 `source_ref` 必须二选一；`source_ref` 必须带 sha256 digest。

**MetaX GPU operator 例外**：这些 vendor 镜像在 mirrors 上以 amd64 单 manifest
发布，mirror index 不维护它们的 digest，因此使用 `source_ref + version + digest`。
`digest` 是 `version` 对应 target tag 的 manifest digest；升级 `METAX_VERSION`
时必须同步更新 digest，二者是同一版本的不可分割标识。其他第三方镜像不得使用
该例外，仍必须用 `catalog_id`。

## 升级版本

1. 改 `env` 里的版本变量；
2. 确认 mirror 的 `catalog_id` 有该 tag（`mirror-updated` 只 bump mirror commit）；
3. 运行校验：

```bash
python3 deployments/scripts/tools/validate-base-baseline.py
python3 deployments/scripts/tools/online/lib-base-catalog.py --index <index.json>
```

4. 提交 PR，人工 review。

`mirror-updated` 只更新 `mirror.commit`，不会自动升级版本；版本升级仍由人改 `env`。

## optional

`optional: true` 表示默认不物化，例如 netshoot 和 MetaX GPU operator 镜像。
商业 release 可以按 package/profile 选择是否带上；开源在线安装只有显式开关才物化。

MetaX 的 11 个镜像属于 `metax-gpu-operator` 组：`install-online.sh --with-metax`
会通过 `--include-group metax-gpu-operator` 物化它们；`--include-optional` 包含
所有 optional 镜像。

## materials 与 os

- `materials` 是 MetaX 等厂商物料；开源在线只给 vendor portal，商业 overlay
  用同一个 key 提供可下载 source；
- `os` 只做安装前体检，不下载、不安装、不打包。

## 2.1 目标规则

- 不使用 `latest` / channel；
- 自研镜像 tar 名去 tag，用 digest/中性名；
- netshoot 改为 `sha-<commit>` + 中性 `netshoot-rdma.tar`；

## 常见错误

- key 不是 `<group>:<source>`；
- group 不在 `versions/groups.yaml`；
- `catalog_id` 和 `source_ref` 同时写或都不写；
- `source_ref` 没有 digest；
- tar 名带产品版本或组件 tag；
- 在 `base.yaml` 里写产品版本/发布 tag；
- 私有镜像或 release 专属 tag override 写进公共 base。
