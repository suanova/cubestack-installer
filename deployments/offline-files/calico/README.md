# offline-files/calico/ —— Calico 官方完整发布包存档

Calico **官方 release 完整包**(`release-<v>.tgz`: 容器镜像 + 二进制 + manifests)存档, 供重建离线精选件 / 换环境取件。
⚠ `*.tgz` 与 `.sha256` 边车**不入库**(gitignore), 只有本 README 受版本控制。

## 内容

| 文件 | 大小(bytes) | sha256 | 用途 |
|---|---|---|---|
| `release-v3.32.2.tgz` | 1108070262 | `d88cb7e2f7d56b5a24bd2853300f026bab7b1debd978b0c8a1d560a1707a26fd` | **当前默认版**(`CALICO_VERSION=v3.32.2`)官方归档 |
| `release-v3.33.0.tgz` | 543458999 | `168b6411a2ac2d6bac734648c44171b5380259d54c1179c47b08c4bb4825932c` | **待定**(见下"3.33 说明")评估材料 |

- 来源: `https://github.com/projectcalico/calico/releases/download/<v>/release-<v>.tgz`(2026-10-15 下载)
- ⚠ GitHub **不发布** asset 官方 sha256 —— 上表为下载后自记的完整性基准(同值写于 `<file>.sha256` 边车); 重下后请比对

## 包内结构

**v3.32.2(旧多镜像模型, 与当前部署一致)**
- `images/`: 7 个组件 tar —— calico-cni / calico-node / calico-kube-controllers / calico-typha / calico-dikastes / calico-pod2daemon / calico-flannel-migration-controller
- `bin/`: CNI 插件(多架构) + calicoctl 等; `manifests/`: 官方清单(bundle / crds.yaml 等 28 项)

**v3.33.0(上游"单镜像改造", 待定)**
- `images/`: 仅 **`calico.tar` + `calico-node.tar`** —— 单镜像是 distroless 派发器(Entrypoint `/usr/bin/calico`, 子命令 `calico component …` 标注 internal);
  `calico/cni` / `calico/kube-controllers` / `calico/typha` 等**全架构停发**(quay 实测 404, 与 CPU 类型无关)
- `bin/`: calicoctl(多架构) + calico-bpf 等; `manifests/`: 30 项

## 与部署的接线(当前 3.32.2 实际消费的精简件)

部署路径**不直接用**本包, 而用精简件 `deployments/offline-files/kubespray/v2.32.0/`:
- `images/quay.io_calico_{cni,node,kube-controllers}_v3.32.2.tar`(RepoTags = 原 quay ref, 供 kubespray 预加载; 从本包 `images/*.tar` 取出后 `docker load` 并重打原 ref 即可重建)
- `calicoctl-3.32.2-amd64` + `calico-3.32.2-kdd-crds.yaml`(sha256 已入树内校验表, 见补丁 `14-calico-3.32.2-checksums.patch`)

## 3.33 说明(待定, 若推进需独立排期)

kubespray(v2.32 与上游 master 同)仍按**旧镜像模型**渲染: install-cni 初始化容器用 `calico/cni`、控制器用 `calico/kube-controllers`,
容器依赖镜像自带 entrypoint, 且校验表封顶 3.31.7 ⇒ **3.33.0 目前无法直接部署**(镜像缺 + 模板模型不符 + 表缺)。
若推进: ① 树模板补丁把相关容器改为调 `calico component …`(需实机核对内部接口); ② 用本包 `bin/calicoctl/calicoctl-linux-amd64`
与 `manifests/crds.yaml` 计算 sha256 补校验表; ③ 按 Calico 官方规约逐 minor(3.31→3.32→3.33)升级并验证 CRD 兼容。
