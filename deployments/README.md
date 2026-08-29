# CubeStack 离线部署套件(deployments/)总览

本目录是 CubeStackInstaller 的**离线部署套件**,承载从宿主机环境准备到 Kubernetes 集群部署、再到 P1/P2/P3 全组件安装的完整 CLI 能力,不依赖公网。

- **脚本调用 / 使用案例**:见 [`deployments/scripts/README.md`](scripts/README.md)
- **脚本开发规范**(模块命名/元数据/新增模块流程):见 [`docs/scripts-development-spec.md`](../docs/scripts-development-spec.md)
- **P1/P2/P3 全阶段组件规划与进度追踪**:见 [`docs/cluster-components-plan.md`](../docs/cluster-components-plan.md)
- **kubespray 离线工具**(多集群):见 [`deployments/kubespray/README.md`](kubespray/README.md)
- **CLI 容器(可选)**: [`Dockerfile-cli`](../Dockerfile-cli) 打包 kubespray 源码 + 部署脚本 + 工具链
  (ansible/helm/skopeo/mc/kubectl 等, 不含离线镜像/binary), 可在容器内直接离线安装。
  运行(仓库根目录执行, 挂载离线文件/配置/SSH 密钥, `--network host` 必须):
  ```bash
  sudo docker run --rm -it --network host \
    -v $PWD/deployments/offline-files:/opt/cubestack-installer/deployments/offline-files \
    -v $PWD/deployments/config/cluster.conf:/opt/cubestack-installer/deployments/config/cluster.conf \
    -v $HOME/.ssh:/root/.ssh \
    harbor.isuanova.com/cubestack/cubestack-installer-cli:latest
  ```
  进容器后 `cd /opt/cubestack-installer && ./deployments/scripts/deploy-cluster.sh`;完整说明见根 `README.md` §十四「容器化部署(Docker)」。

> ⚠ **节点格式(新)**: cluster.conf 的 NODES 为 **5 字段**(`role,hostname,ip,ssh_user,ssh_password`, 不区分虚拟机/裸金属;
> 密码 `-` = 默认 `SSH_DEFAULT_PASSWORD`)。需要**创建虚拟机**的节点在
> `deployments/scripts/tools/vm/vm-nodes.conf`(10字段)定义, 创建后自动注入 NODES。详见 `scripts/README.md` §3。

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

> **单节点集群(仅 1 个 control-plane)**:`k8s_deploy` 部署完成后会自动移除该 master 的
> `NoSchedule` 污点并 uncordon(设为可调度)。因为 metallb controller / local-path /
> registry / gpu_operator 等普通 pod 无 control-plane 污点容忍, 单节点若 master 不可调度会
> 全部 Pending(registry 起不来 → 镜像推不进 → `ImagePullBackOff`)。`k8s_scale` 扩容后若仍
> 是单 control-plane 也会重新收敛一次(kubespray 扩容会重新给 control-plane 打污点)。

> ⚠ **MetalLB 网络需求(Layer2 模式)**:
> - 地址池 IP 必须与集群节点**同一二层网络(同一子网)且空闲**;
> - **裸金属集群**: 无需 bridge/NAT 网络(纯物理 L2 直连),不初始化宿主机网络,池取节点物理网段空闲段(如 `10.66.1.130-10.66.1.139`);
> - **虚拟机集群**: 需 bridge(`privbr0`) 网络,池取 VM 网段空闲段(如 `10.244.2.0/24`);
> - 依赖 `kube_proxy_strict_arp=true`(默认已开启);池与节点网段冲突会导致 LB 无法通告;
> - **DHCP 管理网段时**: 池内 IP 必须先在 DHCP 服务器加入**排除/保留段**(如 `ip dhcp excluded-address`),否则 DHCP 会重复分配给其他设备 → 与 LB IP 冲突;
> - 若网络开启 **DHCP Snooping / IP Source Guard**,需在 speaker 节点接入端口放开,否则 ARP 通告的静态 LB IP 流量会被交换机丢弃。
| 存储 | local-path-provisioner(可选, 默认**不启动**) |

### 1.2 附加组件(P1/P2/P3, 集群部署后安装)

| 阶段 | 组件 | 开关(cluster.conf) | 模块 |
|---|---|---|---|
| P1-2/3 | Prometheus + Operator + 监控附属(node-exporter/DCGM/MetaX/RDMA/Ceph) | `PROMETHEUS_ENABLED` | `03_addon/04_prometheus.sh` |
| P1-4 | Harbor 镜像仓库(**集群外私有仓库**, 环境准备阶段于宿主机就绪) | `HARBOR_ENABLED` | `01_env/04_harbor.sh` |
| P1-5 | 沐曦 MetaX GPU Operator | `GPU_OPERATOR_ENABLED` | `03_addon/01_gpu_operator.sh` |
| P1-6/7 | Ceph 存储集群 + Ceph CSI(RBD/RGW/CephFS) | `CEPH_ENABLED` / `CEPH_CSI_ENABLED` | `03_addon/06_ceph.sh` / `07_ceph_csi.sh` |
| P1-8 | LeaderWorkerSet(LWS) | `LWS_ENABLED` | `03_addon/02_gpu_lws.sh` |
| P1-9 | Envoy 网关二件套: Envoy Gateway(通用 API 网关)+ Envoy AI Gateway(AI 专用扩展层) | `ENVOY_GATEWAY_ENABLED` / `ENVOY_AI_GATEWAY_ENABLED` | `03_addon/09_envoy_gateway.sh` / `10_envoy_ai_gateway.sh`(见 `docs/envoy-gateway.md`) |
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
│  · cluster.conf NODES(5字段)不区分虚拟机/裸金属                  │
│  · 虚拟机: tools/vm/vm-nodes.conf 定义规格, libvirt 创建(测试环境) │
│  · 裸金属: 不在 vm-nodes.conf 中的节点, 直连(生产环境)            │
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
│   └── README.md
├── offline-files/                # 【运行时生成】离线文件(kubespray/metax-gpu/虚拟机镜像, 见 §五)
│   ├── kubespray/                #   离线资源缓存(按集群名隔离), 路径由 OFFLINE_FILES_DIR 切换
│   └── virtual-machine/          #   虚拟机基础镜像(由 BASE_IMG 指定, 见 §五)
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

### 5.1 离线文件缓存(offline-files/)

**目录规划**:`deployments/offline-files/` 是所有离线文件的**总根目录**,按领域分子目录(未来可新增):

```
deployments/offline-files/
├── kubespray/                  # ★ kubespray 离线文件(原 deployments/kubespray/repository 内容)
│   └── <CLUSTER_NAME>/         #   按集群名隔离(images/ + 二进制 + packages/)
│       ├── images/             #   容器镜像(.tar, 由 cubestack-offline.sh download 下载)
│       ├── <二进制文件>          #   kubeadm/kubelet/etcd/calicoctl/cni-plugins 等
│       └── packages/           #   系统 .deb 包(iputils-ping/rsync/iptables/curl/ca-certificates)
├── metax-gpu/                  # 沐曦 GPU Operator 离线文件(镜像 tar/资源包/驱动)
└── virtual-machine/            # 虚拟机黄金镜像(体积大, 仅创建虚拟机时用; 默认拉取脚本排除)
    └── cloud-images/ubuntu2204-k8s-base.qcow2
```

**路径变量**:

| 变量 | 默认值 | 说明 |
|---|---|---|
| `OFFLINE_FILES_DIR` | `${REPO_ROOT}/deployments/offline-files/kubespray` | kubespray 离线文件根目录(全局可切换) |
| `LOCAL_REPO_DIR` | `${OFFLINE_FILES_DIR}/${CLUSTER_NAME}` | 当前集群 kubespray 离线资源目录 |
| `METAX_OFFLINE_DIR` | `${REPO_ROOT}/deployments/offline-files/metax-gpu` | 沐曦 GPU Operator 离线文件目录 |

> 路径切换: 设置环境变量 `OFFLINE_FILES_DIR` 即可整体切换 kubespray 离线文件根目录(如挂载到独立磁盘/共享存储);
> `LOCAL_REPO_DIR` 也可单独覆盖到任意位置(最高优先)。

- **生成方式**:联网机执行 `./deployments/kubespray/cubestack-offline.sh download`(读取 inventory group_vars 决定下载哪些镜像/文件),产物即离线仓库。
- **预加载机制**:`inventory/<cluster>/preload-images.lst`(由 `PRELOAD_IMAGE_PATTERNS` 过滤生成)指定部署时同步到节点 containerd 的最小镜像集合;离线部署时节点镜像拉取不依赖公网。
- **MinIO 分发**:源机器 `tools/offline/sync-to-minio.sh` 把本地 offline-files 增量同步到 MinIO(`mc mirror --overwrite`);部署机 `tools/offline/fetch-offline-from-minio.sh` 拉取(默认排除 virtual-machine,按需 `--sub virtual-machine`/`--all`);冗余清理见 `tools/offline/trim-offline-files.sh`。

### 5.2 虚拟机基础镜像(offline-files/virtual-machine/)

虚拟机黄金镜像路径由 `cluster.conf` 的 `BASE_IMG` 指定:

```
${REPO_ROOT}/deployments/offline-files/virtual-machine/cloud-images/
└── ubuntu2204-k8s-base.qcow2    # 黄金基础镜像(由 create-vm-template.sh 制作)
```

- **制作**:`sudo ./deployments/scripts/tools/vm/create-vm-template.sh`(基于 Ubuntu 22.04 cloud 镜像,内置 ubuntu/root 默认密码、SSH、时区 Asia/Shanghai、chrony 及 kubespray 离线所需系统包)。
- **VM 磁盘目录**:`VM_DISK_DIR`(默认 `/k8s/vm-disks`),每台虚拟机一个磁盘文件,由 `create-libvirt-vm.sh` 创建。
- **仅测试环境需要**:纯裸金属生产集群不创建虚拟机,不依赖本目录(vm-nodes.conf 无节点即可)。

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

# 3. 一键部署(默认 = --with-cubestack: 基座 + cluster.conf 启用的全部 operator)
sudo ./deployments/scripts/deploy-cluster.sh
```

> 全裸金属集群:vm-nodes.conf 不定义节点即可(宿主机网络初始化非必要,需时用 tools/net/setup-vm-network.sh);仅基座用 `--with-k8s`;
> 分步部署、扩容、跨网段 worker、组件安装等场景见 `deployments/scripts/README.md` 第 8 节。
