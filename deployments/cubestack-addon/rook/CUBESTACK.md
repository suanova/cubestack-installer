# Rook-Ceph 离线 vendoring — CubeStack 适配说明

本目录存放 **Rook Operator 离线安装 manifest**(`v1.20.2`, 与 `docs/ceph-rook.md` 版本一致),
供 `modules/03_addon/02_ceph.sh` 离线部署 CephCluster / `03_ceph_csi.sh` 部署 ceph-csi 使用。

> ⚠ manifest 文件不在仓库内(体积大、来自官方 release tag): 首次使用在**联网机**执行
> `deployments/scripts/tools/k8s/rook-fetch-manifests.sh` 下载到本目录, 再拷到部署机。
> ceph 模块检测到 manifest 缺失会报错并给出指引, 不会静默跳过。

## 目录内容

```
deployments/cubestack-addon/rook/
├── CUBESTACK.md
├── crds.yaml            # Rook CRDs(取自官方 release v1.20.2: rook/deploy/examples/crds.yaml)
├── common.yaml          # 公共 RBAC/命名空间
├── csi-operator.yaml    # ⚠ rook v1.20 新增且必须(ceph-csi-operator), 跳过会静默破坏 CSI Provision
├── operator.yaml        # Rook operator Deployment
├── toolbox.yaml         # toolbox(ceph/rbd CLI, 可选)
├── external/            # ★ 外部 Ceph 接入(官方 import 流程, 2026-09-10 vendored; 见下)
└── (charts 见 ../rook-charts/, 单独目录)
```

## external/ — 官方外部 Ceph 接入文件(2026-09-10 vendored)

来源: Rook v1.20.2 `deploy/examples/external/`(与上方 manifest 同版本, 离线拷贝, 无需联网)。
用于 **CEPH_MODE=external** 消费者接入外部 Rook-Ceph(官方 import-external-cluster 流程):

| 文件 | 用途 |
|---|---|
| `import-external-cluster.sh` | 官方导入脚本: source external-ceph.env 后执行, 创建 rook-ceph-mon secret / mon-endpoints CM / 4 个 CSI secret / rgw-admin-ops-user secret / SC(ceph-rbd, cephfs) |
| `cluster-external.yaml` | CephCluster CR(external 模式): 开启 mon 健康检查 → STATE=Connected / 健康上报 |
| `common-external.yaml` | 外部模式 RBAC(RoleBinding/SA, 经 operator 调和消费 secret/CM) |
| `object-external.yaml` | CephObjectStore(externalRgwEndpoints → 提供方 RGW; 消费侧对象存储接入) |
| `create-external-cluster-resources.py` | **提供方**导出脚本(在外部 Ceph 集群上生成 external-ceph.env, 含 CSI secret / healthchecker / RGW admin 密钥) |
| `storageclass-bucket-delete.yaml` / `storageclass-bucket-retain.yaml` | OBC 桶供给 StorageClass(对象存储第 6 步) |
| `object-bucket-claim-delete.yaml` / `object-bucket-claim-retain.yaml` | OBC 示例(声明桶, Rook 自动建桶注入凭据) |
| `01-mon-external.yaml` / `02-rgw-external.yaml` / `03-cephfilesystem-external.yaml` | 本项目自研模板(提供方对外暴露用, 由 ceph-expose-external.sh 消费) |

## rook-charts/ — Helm charts(单独目录)

`deployments/cubestack-addon/rook-charts/` 存放 Rook 官方 Helm charts(v1.20.2 `deploy/charts/`):
`rook-ceph`(operator, 依赖 library + ceph-csi-operator)/ `rook-ceph-cluster`(CephCluster 声明)/
`library`(共享 helper)/ `ceph-csi-drivers`。当前部署走 kubectl apply manifest 路线,
charts 备用(helm 部署路线/参考 values), 不与 manifest 混放。

## 获取(联网机)

```bash
sudo ./deployments/scripts/tools/k8s/rook-fetch-manifests.sh            # 默认 ROOK_VERSION=v1.20.2
# 指定版本: ROOK_VERSION=v1.20.2 sudo ./deployments/scripts/tools/k8s/rook-fetch-manifests.sh
```

## 项目集成

- 部署入口: `modules/03_addon/02_ceph.sh`(`CEPH_ENABLED=true`)+ `03_ceph_csi.sh`(`CEPH_CSI_ENABLED=true`)
- 离线镜像: `tools/images/ceph-save-images.sh`(下载到 `offline-files/kubespray/images`, 与 kubespray 镜像同目录)→
  k8s 部署阶段由 cluster.yml 内置预加载 play 统一同步到节点并 ctr import; 手工补同步: `tools/images/ceph-sync-images.sh`
- 裸盘检测: `tools/k8s/ceph-detect-disks.sh`(自动检测未使用裸盘)
- 节点选择: `CEPH_NODES`(cluster.conf)+ node label(`CEPH_NODE_LABEL`)
- lvm2 离线包: `tools/offline/fetch-lvm-packages.sh` → `offline-files/kubespray/packages`
- 设计/使用文档: `docs/ceph-rook.md`; 故障: `docs/troubleshooting.md`

## 升级 Rook

联网机更新 ROOK_VERSION 重新 fetch(替换 4 个 yaml, 保留 CUBESTACK.md), 并同步
cluster.conf 的 ROOK_VERSION / CEPH_VERSION / CEPHCSI_VERSION / CEPH_CSI_OPERATOR_VERSION。
