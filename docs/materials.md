# 物料清单（versions/base.yaml `materials:`）

`materials:` 是 installer 维护的**厂商物料索引**：记录模块需要哪些不能从公共
registry 拉取的制品，以及从哪里获取。它不存字节，只存身份（key）、版本、文件名、
目标目录和来源。

```yaml
materials:
- key: metax:k8s-images
  module: gpu_operator
  version: ${METAX_VERSION}
  file: metax-k8s-images.${METAX_VERSION}.run
  dest: offline-files/metax-gpu
  optional: true
  source:
    type: vendor-portal
    provider: metax
    portal: https://metax-tech.com
    account_required: true
```

## 字段

| 字段 | 说明 |
|---|---|
| `key` | 全局唯一，格式 `<group>:<name>` |
| `module` | 消费该物料的 installer 模块 |
| `version` / `file` / `dest` | 目标文件名和目录；支持 `${VAR}`，变量必须在 `env` 中 |
| `optional` | 缺失时不阻塞非相关安装；由显式开关决定是否要求 |
| `digest` | 可选；有值时校验 sha256 |
| `source.type` | `vendor-portal`（开源用户自取）、`url`、`local`（商业 overlay 供源） |

## 开源在线安装

```bash
# 只报告缺失（warn-only）
sudo ./deployments/scripts/install-online.sh --check-materials

# 要求 MetaX 物料齐全，并启用 GPU operator
sudo ./deployments/scripts/install-online.sh --with-metax
```

用户用自己的厂商账号从 portal 下载，放到 `dest` 指向的目录即可。MetaX 的物料路径
是 `deployments/offline-files/metax-gpu/`。

## 商业打包

公共 baseline 只声明 `vendor-portal` 来源；商业 release 在
`overlays/base-private.yaml` 用同一个 `key` 覆盖 `source`，提供打包机上的本地路径：

```yaml
materials:
- key: metax:k8s-images
  source:
    type: local
    path: /path/to/vendor/metax-k8s-images.0.15.3.run
```

release 打包时按同一份清单把物料放进 base 树，并记录 sha256。厂商是否允许再分发
由商业发布流程确认；不提供本地来源时打包应明确失败，而不是静默缺件。

## 当前条目

- MetaX：`metax-gpu-k8s-package`、`metax-k8s-images`、`metax-k8s-driver-image`

其他模块的厂商物料按同样格式逐步加入，不再各自维护隐式清单。
