# CubeStack 离线部署套件(deployments/)总览

本目录是 CubeStackInstaller 的**离线部署套件**,承载从宿主机环境准备到 Kubernetes 集群部署、再到 P1/P2/P3 全组件安装的完整 CLI 能力,不依赖公网。

- **脚本调用 / 使用案例**:见 [`deployments/scripts/README.md`](scripts/README.md)
- **脚本开发规范**(模块命名/元数据/新增模块流程):见 [`docs/scripts-development-spec.md`](../docs/scripts-development-spec.md)
- **P1/P2/P3 全阶段组件规划与进度追踪**:见 [`docs/cluster-components-plan.md`](../docs/cluster-components-plan.md)
- **kubespray 离线工具**(多集群):见 [`deployments/kubespray/README.md`](kubespray/README.md)

---

## 一、支持的软件与组件

### 1.1 基础集群(P1 前置, kubespray 部署)

| 软件 | 说明 |
|---|---|
| Kubernetes | 由 Kubespray 部署(默认 v2.28.0 / K8s 1.32.x),高可用控制平面 |
| 容器运行时 | containerd(离线预加载镜像) |
| 网络插件 | Calico(默认; 可选 flannel/cilium/kube-ovn 等) |
| 服务发现 | CoreDNS + nodelocaldns |
| 负载均衡 | MetalLB(Layer2, 地址池 `METALLB_POOL` 可配) |
| 存储 | local-path-provisioner(可选, 默认**不启动**) |

### 1.2 附加组件(P1/P2/P3, 集群部署后安装)

| 阶段 | 组件 | 开关(cluster.conf) | 模块 |
|---|---|---|---|
| P1-2/3 | Prometheus + Operator + 监控附属(node-exporter/DCGM/MetaX/RDMA/Ceph) | `PROMETHEUS_ENABLED` | `03_addon/04_prometheus.sh` |
| P1-4 | Harbor 镜像仓库(**集群外私有仓库**, 环境准备阶段于宿主机就绪) | `HARBOR_ENABLED` | `01_env/04_harbor.sh` |
| P1-5 | 沐曦 MetaX GPU Operator | `GPU_OPERATOR_ENABLED` | `03_addon/01_gpu_operator.sh` |
| P1-6/7 | Ceph 存储集群 + Ceph CSI(RBD/RGW/CephFS) | `CEPH_ENABLED` / `CEPH_CSI_ENABLED` | `03_addon/06_ceph.sh` / `07_ceph_csi.sh` |
| P1-8 | LeaderWorkerSet(LWS) | `LWS_ENABLED` | `03_addon/02_gpu_lws.sh` |
| P1-9 | Envoy AI 网关(统一流量入口) | `ENVOY_GATEWAY_ENABLED` | `03_addon/08_envoy_gateway.sh` |
| P2-1 | Keycloak 统一认证 | `KEYCLOAK_ENABLED` | `03_addon/09_keycloak.sh` |
| P2-2 | Kueue 队列治理(DEV-29) | `KUEUE_ENABLED` | `03_addon/10_kueue.sh` |
| P2-3 | KubeVirt 虚拟机能力(DEV-35) | `KUBEVIRT_ENABLED` | `03_addon/11_kubevirt.sh` |
| P3-1 | Lustre CSI 并行文件存储(DEV-26) | `LUSTRE_CSI_ENABLED` | `03_addon/12_lustre_csi.sh` |

> 镜像仓库双定位:**集群外** = Harbor(`HARBOR_ENABLED`);**集群内** = kubespray registry addon(`REGISTRY_ENABLED`, **默认不部署**)。
> 未实现组件均为**伪代码占位**(`addon_stub` 框架, 见 `docs/scripts-development-spec.md` §4.1), 按各模块头部 TODO 替换真实命令即可。

### 1.3 部署机工具链(宿主机)

| 软件 | 用途 |
|---|---|
| libvirt / qemu-kvm / virt-install | 创建虚拟机(测试环境; 裸金属环境可跳过) |
| ansible + kubespray venv | 离线部署 Kubernetes |
| HAProxy / Keepalived | API 入口四层负载均衡 / VIP 高可用(部署前准备, 可选) |
| chrony / NTP | 集群节点时间同步 |
| docker/nerdctl/podman | 离线镜像导入 / 本地仓库 |

---

## 二、架构

```
┌─────────────────────────────────────────────────────────────────┐
│ 部署机(宿主机 / 管理机)                                          │
│  · config/cluster.conf = 唯一配置源                              │
│  · deployments/scripts = 部署脚本 + modules(三阶段模块)          │
│  · deployments/kubespray = kubespray 源码 + inventory + 离线资源 │
└──────────────┬──────────────────────────────────────────────────┘
               │ SSH / libvirt / ansible
┌──────────────▼──────────────────────────────────────────────────┐
│ 集群节点(mixed: VM + 裸金属可混部)                               │
│  node_type=vm: 由 libvirt 创建虚拟机(测试环境)                   │
│  node_type=bm: 裸金属直连(生产环境, 跳过 VM 创建)                │
└──────────────┬──────────────────────────────────────────────────┘
               │ kubespray cluster.yml / scale.yml
┌──────────────▼──────────────────────────────────────────────────┐
│ Kubernetes 集群                                                  │
│  · 基础: kube-apiserver/etcd/Calico/CoreDNS/MetalLB/local-path   │
│  · P1/P2/P3: GPU/监控/Harbor/Ceph/Envoy/Keycloak/Kueue/KubeVirt │
│  · 离线: 镜像经预加载进 containerd, 不依赖公网                    │
└─────────────────────────────────────────────────────────────────┘
```

**数据流**:`cluster.conf`(唯一数据源) → 脚本解析/校验 → 生成 `hosts.yml` + `group_vars`(IP/组件开关) → kubespray 离线安装 → 附加组件模块逐个启用。

**配置优先级**:环境变量 > `config/cluster.conf` > 内置兜底默认。

---

## 三、目录结构与脚本组织结构

```
deployments/
├── config/
│   ├── cluster.conf.example      # 配置模板(提交仓库, 含全部变量与注释)
│   └── cluster.conf.backup       # 示例环境备份(全裸金属 GPU 集群)
│   └── cluster.conf              # 【运行时】真实配置(含密码, gitignore; cp example 生成)
├── kubespray/
│   ├── kubespray/                # Kubespray 源码(v2.28.0, 含 cluster.yml)
│   ├── cubestack-offline.sh      # 离线安装/扩容入口(init/download/install/scale/check)
│   ├── inventory/                # 集群 inventory(按集群名隔离)
│   │   └── <cluster>/            #   hosts.yml + group_vars + credentials + preload-images.lst
│   ├── repository/               # 【运行时生成】离线资源缓存(见 §五)
│   └── README.md
├── virtual-machine/              # 【运行时生成】虚拟机基础镜像(见 §五)
├── scripts/                      # 部署脚本(详见 scripts/README.md)
│   ├── deploy-cluster.sh         # ★ 统一入口(一键/分步/断点续跑)
│   ├── lib-common.sh             # 公共库(配置加载/工具函数)
│   ├── lib-module.sh             # 模块框架(自动发现/调度/旧名别名)
│   ├── modules/                  # ★ 部署模块(按环境准备阶段组织子目录)
│   │   ├── 01_env/               #   阶段一: 环境准备(Harbor/HAProxy/Keepalived 等, 部署前)
│   │   ├── 02_k8s/               #   阶段二: 离线部署 kubespray(VM/裸金属无关)
│   │   └── 03_addon/             #   阶段三: 附加组件(01~19 中间件, 20 起自研模块)
│   ├── tools/                    # ★ 工具脚本(模块的底层实现, 按领域分目录)
│   │   ├── vm/                   #   虚拟机: create-libvirt-vm.sh / create-vm-template.sh / register-vm.sh
│   │   ├── net/                  #   网络: setup-vm-network.sh / verify / teardown / setup-libvirt-nat.sh
│   │   ├── node/                 #   节点: gen-ssh-key.sh / setup-passwordless.sh / install-worker-packages.sh / setup-ntp.sh 等
│   │   ├── k8s/                  #   inventory/配置: gen-inventory.sh / sync-kubespray-config.sh / sync-addons-config.sh
│   │   └── lb/                   #   负载均衡/registry: sync-haproxy.sh / deploy-registry.sh / setup-registry-expose.sh
│   └── README.md                 # 脚本调用手册 + 使用案例
└── README.md                     # 本文件
```

### 模块组织(按环境准备阶段)

| 阶段目录 | PHASE | 内容 | 时机 |
|---|---|---|---|
| `modules/01_env/` | `env` | VM 网络/SSH 密钥/创建 VM/Harbor/HAProxy/Keepalived | **部署 kubespray 之前** |
| `modules/02_k8s/` | `k8s` | 免密/裸金属 worker/hosts/inventory/NTP/部署/扩容 | 不依赖 VM 还是裸金属 |
| `modules/03_addon/` | `addon` | GPU/监控/Ceph/Envoy/Keycloak/Kueue/KubeVirt/Lustre(01~19 中间件)+ 自研模块(20 起) | 集群部署后 |

**模块 = `modules/<阶段>/NN_category_action.sh` 一个文件**,头部注释声明元数据(`MODULE/DESC/PHASE/DEFAULT/REPEAT/TOGGLE`),框架**自动发现**——新增模块只需放一个文件,无需改任何注册表/入口(详见 `docs/scripts-development-spec.md`)。

---

## 四、脚本如何调用(速览)

> 完整命令、参数与案例见 `deployments/scripts/README.md`;此处仅给最常用入口。

```bash
# 0) 生成并编辑唯一配置
cp deployments/config/cluster.conf.example deployments/config/cluster.conf
vim deployments/config/cluster.conf

# 1) 一键部署(环境准备 → kubespray)
sudo ./deployments/scripts/deploy-cluster.sh --with-k8s

# 2) 全裸金属: 跳过网络模块
sudo ./deployments/scripts/deploy-cluster.sh --skip net --with-k8s

# 3) 只跑指定模块 / 指定阶段
sudo ./deployments/scripts/deploy-cluster.sh --steps vm_create,k8s_deploy
sudo ./deployments/scripts/deploy-cluster.sh --phase k8s

# 4) 启用附加组件(集群部署后)
sudo ./deployments/scripts/deploy-cluster.sh --enable harbor,prometheus
#    或 cluster.conf 里 HARBOR_ENABLED=true 后直接 --with-k8s

# 5) 单独执行某个模块(绕过入口)
sudo bash deployments/scripts/modules/03_addon/05_harbor.sh

# 6) 扩容
sudo ./deployments/scripts/deploy-cluster.sh --with-scale
```

**组件开关**(`cluster.conf` 中 `true/false`):`K8S_ENABLED` / `K8S_SCALE_ENABLED` / `HARBOR_ENABLED` / `PROMETHEUS_ENABLED` / `CEPH_ENABLED` / `CEPH_CSI_ENABLED` / `GPU_OPERATOR_ENABLED` / `LWS_ENABLED` / `ENVOY_GATEWAY_ENABLED` / `KEYCLOAK_ENABLED` / `KUEUE_ENABLED` / `KUBEVIRT_ENABLED` / `LUSTRE_CSI_ENABLED` / `LOCAL_PATH_ENABLED`(默认 false) / `REGISTRY_ENABLED`(默认 0) 等。

---

## 五、离线镜像与虚拟机镜像路径

### 5.1 离线资源缓存(repository/)

离线资源根目录由 `cluster.conf` 的 `LOCAL_REPO_DIR` 指定(按集群名隔离):

```
${REPO_ROOT}/deployments/kubespray/repository/<CLUSTER_NAME>/
├── images/                       # 容器镜像(.tar, 由 cubestack-offline.sh download 下载)
│   ├── quay.io_calico_node_v3.29.3.tar
│   ├── registry.k8s.io_kube-apiserver_v1.32.5.tar
│   └── ...                       # 文件名规则: 镜像 repo/tag 的 / 与 : 替换为 _
├── <二进制文件>                    # kubeadm/kubelet/etcd/calicoctl/cni-plugins 等
└── packages/                     # 系统 .deb 包(iputils-ping/rsync/iptables/curl/ca-certificates)
```

- **生成方式**:联网机执行 `./deployments/kubespray/cubestack-offline.sh download`(读取 inventory group_vars 决定下载哪些镜像/文件),产物即离线仓库。
- **预加载机制**:`inventory/<cluster>/preload-images.lst`(由 `PRELOAD_IMAGE_PATTERNS` 过滤生成)指定部署时同步到节点 containerd 的最小镜像集合;离线部署时节点镜像拉取不依赖公网。

### 5.2 虚拟机基础镜像(virtual-machine/)

虚拟机黄金镜像路径由 `cluster.conf` 的 `BASE_IMG` 指定:

```
${REPO_ROOT}/deployments/virtual-machine/cloud-images/
└── ubuntu2204-k8s-base.qcow2    # 黄金基础镜像(由 create-vm-template.sh 制作)
```

- **制作**:`sudo ./deployments/scripts/tools/vm/create-vm-template.sh`(基于 Ubuntu 22.04 cloud 镜像,内置 ubuntu/root 密码 `k8s@2026`、SSH、时区 Asia/Shanghai、chrony 及 kubespray 离线所需系统包)。
- **VM 磁盘目录**:`VM_DISK_DIR`(默认 `/k8s/vm-disks`),每台虚拟机一个磁盘文件,由 `create-libvirt-vm.sh` 创建。
- **仅测试环境需要**:生产裸金属(`node_type=bm`)不创建虚拟机,不依赖本目录。

### 5.3 集群 inventory(inventory/)

```
deployments/kubespray/inventory/<CLUSTER_NAME>/
├── hosts.yml                     # kubespray 实际使用(由 gen-inventory.sh 生成)
├── inventory.ini                 # 兼容 installer 后端风格(参考)
├── download-hosts.yml            # 离线资源下载专用(localhost+root)
├── preload-images.lst            # 预加载镜像清单(运行时生成)
├── credentials/                  # kubeadm 证书密钥等
└── group_vars/
    ├── all/                      #   all.yml / offline.yml / containerd.yml / registry.yml ...
    └── k8s_cluster/              #   k8s-cluster.yml / addons.yml / k8s-net-calico.yml ...
```

> `hosts.yml` 与 `group_vars` 中的 IP/组件开关均由脚本从 `cluster.conf` **动态生成**(`gen-inventory.sh` + `sync-kubespray-config.sh` + `sync-addons-config.sh`),不硬编码。

---

## 六、快速上手(三步)

```bash
# 1. 生成配置(唯一数据源)
cp deployments/config/cluster.conf.example deployments/config/cluster.conf
vim deployments/config/cluster.conf            # 修改 宿主机IP/网段/节点清单/组件开关

# 2. (可选)制作虚拟机黄金镜像(测试环境)
sudo ./deployments/scripts/tools/vm/create-vm-template.sh

# 3. 一键部署
sudo ./deployments/scripts/deploy-cluster.sh --with-k8s
```

> 全裸金属集群:`node_type=bm` + `--skip net --with-k8s`;分步部署、扩容、跨网段 worker、组件安装等场景见 `deployments/scripts/README.md` 第 8 节。
