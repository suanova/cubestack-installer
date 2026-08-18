# CubeStack 脚本使用手册(CLI)

本目录脚本提供完整的**命令行自动化**能力:从宿主网络初始化、SSH 密钥、master 虚拟机创建与免密登录,到 kubespray 兼容 inventory 生成与(可选)K8s 离线部署。

所有脚本**统一读取** `config/cluster.conf`(单集群)或 `config/cluster-${CLUSTER_NAME}.conf`(多集群)作为唯一数据源,不硬编码 IP / 用户名 / 密码 / 路径。配置优先级:**环境变量 > 配置文件 > 内置兜底默认**。

> 多集群:通过 `--cluster <name>` 或环境变量 `CLUSTER_NAME` 或 `CUBESTACK_CLUSTER` 指定集群名,默认 `cubestack-cluster`。例如 `./deploy-cluster.sh --cluster prod` 读取 `config/cluster-prod.conf`。
>
> 断点续跑:每阶段完成自动保存状态到 `config/.cluster-${CLUSTER_NAME}.state`;下次启动自动跳过已完成阶段;`--fresh` 清状态重新执行。

> UI 兼容性:统一配置结构清晰,`gen-inventory.sh` 同时产出后端风格的 `inventory.ini`,后期 installer 后端可复用同一份 `cluster.conf`。

---

## 1. 快速开始

```bash
# 0) 首次:从模板生成真实配置并按实际环境修改(真实配置含密码,已被 .gitignore)
cp config/cluster.conf.example config/cluster.conf
vim config/cluster.conf          # 修改 宿主机/网络/SSH/节点清单

# 1) 查看集群规划(只读)
sudo ./deployments/scripts/deploy-cluster.sh --list

# 2) 一键部署(宿主网络 → SSH密钥 → master虚拟机+免密 → worker连通性 → inventory)
sudo ./deployments/scripts/deploy-cluster.sh

# 3) 多集群:指定集群名(读取 config/cluster-<name>.conf)
sudo ./deployments/scripts/deploy-cluster.sh --cluster mycluster --list

# 4) 断点续跑:完成后继续(自动跳过已完成阶段)
sudo ./deployments/scripts/deploy-cluster.sh --skip-net --with-k8s

# 5) 清状态重新执行
sudo ./deployments/scripts/deploy-cluster.sh --fresh --with-k8s
```

---

## 2. 目录与文件

```
deployments/scripts/
├── lib-common.sh              # 公共库:统一配置加载 + IP/MAC 工具(被所有脚本 source)
│                              #   register_node_to_conf(): awk 幂等注册节点到 cluster.conf
│                              #   save_state/get_state/clear_state: 断点续跑状态管理
│                              #   node_is_vm(): 按 node_type 判断 vm/裸金属
│                              #   CLUSTER_NAME 解析: 支持多集群 cluster-${name}.conf
├── lib-deploy.sh              # ★ 模块注册表(DEPLOY_STEPS) + 调度(steps/*.sh 在此登记)
├── deploy-cluster.sh          # ★ 统一入口(模块化编排,薄壳: 参数解析 + 按注册表调度)
├── steps/                     # ★ 部署模块(每个 = 复用现有脚本的薄封装, 可插拔)
│   ├── 01-network.sh          #   初始化宿主网络 → setup-vm-network.sh / setup-libvirt-nat.sh
│   ├── 02-ssh-key.sh          #   生成 SSH 密钥     → gen-ssh-key.sh
│   ├── 03-vm.sh               #   创建虚拟机并启动   → create-libvirt-vm.sh
│   ├── 04-ssh-passwordless.sh #   SSH 免密         → setup-passwordless.sh
│   ├── 05-worker-bm.sh        #   裸金属 worker 装包 → install-worker-packages.sh
│   ├── 06-hosts.sh            #   更新 /etc/hosts
│   ├── 07-inventory.sh        #   生成 inventory   → gen-inventory.sh
│   ├── 08-k8s.sh              #   部署 kubespray   → cubestack-offline.sh(默认关闭)
│   ├── 09-gpu-operator.sh     #   沐曦 GPU Operator(占位, 默认关闭)
│   └── 10-lws.sh              #   LeaderWorkerSet(占位, 默认关闭)
├── gen-ssh-key.sh             # 生成集群 SSH 密钥对(幂等)
├── setup-passwordless.sh      # 注入公钥实现目标主机免密登录
├── gen-inventory.sh           # 从配置生成 kubespray inventory + 同步 kubespray 配置
├── sync-kubespray-config.sh   # ★ 从 cluster.conf 动态生成 kubespray group_vars 中的 IP
├── register-vm.sh             # 将已存在 VM 注册到 cluster.conf NODES
├── create-libvirt-vm.sh       # 创建单台 Ubuntu22.04 虚拟机(静态IP,配置驱动,自动注册; 不再安装任何组件)
├── create-vm-template.sh      # 制作黄金基础镜像(预埋用户/SSH/时区/kubespray所需包; 包固化唯一入口)
├── install-worker-packages.sh # 离线 .deb 包安装到 bare-metal worker 节点
├── setup-vm-network.sh        # 方案A:创建 privbr0 网桥网络(建桥/回程路由/SNAT/自启)
├── setup-libvirt-nat.sh       # 方案B:创建 libvirt NAT 网络(含 --delete 回滚)
├── verify-vm-network.sh       # 验证宿主网络配置与连通性
├── teardown-vm-network.sh     # 回滚方案A桥接网络(SNAT/路由/自启,可删网桥)
└── README.md                  # 本文件
```

### 模块化设计说明

`deploy-cluster.sh` 只做两件事:**参数解析 + 按注册表调度**,不内联任何业务逻辑。
每个部署功能 = `steps/` 下一个独立脚本(薄封装, 复用现有脚本, 不重复实现)。

**新增模块(如未来接入 GPU Operator / LWS 等)**:
1. 在 `steps/` 新建 `<NN>-<name>.sh`(实现逻辑, 可调用现有脚本/kubectl)
2. 在 `lib-deploy.sh` 的 `DEPLOY_STEPS` 追加一行: `"key|描述|脚本文件名|默认启用(1/0)"`
3. 无需修改 `deploy-cluster.sh`

项目根目录 `scripts/` 下仅有 dev 启动脚本(`dev.sh`/`start-backend.sh`/`start-frontend.sh`),部署脚本统一在 `deployments/scripts/`。

统一配置:见 `config/cluster.conf`(真实,已 gitignore)与 `config/cluster.conf.example`(模板,提交)。

---

## 3. 统一配置文件(config/cluster.conf)

配置分四大块,字段含义见文件内注释:

| 区块 | 关键项 | 说明 |
|---|---|---|
| 宿主机 | `HOST_PHYS_IP` `BASE_IMG` `VM_DISK_DIR` | 物理IP(SNAT源)、基础镜像、VM磁盘目录 |
| 网络规划 | `NET_MODE`(bridge/nat)、`BRIDGE` `BRIDGE_IP` `VM_SUBNET` `PHYS_WORKER_NET` / `NAT_NET_NAME` `NAT_SUBNET` `NAT_GATEWAY` | 双方案网段/网关/SNAT目标 |
| SSH | `SSH_KEY_NAME` `SSH_DEFAULT_PASSWORD` `VM_SSH_USERS` `WORKER_SSH_PASSWORD` | 密钥、虚拟机预埋密码、免密用户、裸金属密码 |
| 节点规划 | `NODES=( ... )` | 每行一节点,类型由第10字段 `node_type` 决定: vm=虚拟机 / bm=裸金属 |
| kubespray | `KUBESPRAY_INV_DIR` `KUBESPRAY_DIR` `UPDATE_ETC_HOSTS` | inventory 输出位置、playbook 位置、是否写 /etc/hosts |

### 节点行格式

```
role,hostname,ip,mac,mem_g,cpu,disk_g,ssh_user,ssh_password,node_type
```

`node_type`:`vm`=创建为虚拟机(自动启动) / `bm`=裸金属(不创建 VM,走密码连通+离线装包)。省略时回退推断:master 默认 `vm`,其余按是否有 VM 参数(MAC 非 `-` 且 内存>0)判断。

- `role`: `master`(虚拟机,自动创建) | `worker`(裸金属,仅记录/连通性检查)
- `mac`: 显式 MAC,或 `-` 按主机名确定性生成(幂等)
- `mem_g/cpu/disk_g`: 仅 master 使用;worker 填 `0`
- `ssh_password`: 显式密码,或 `-` 用默认(master→`SSH_DEFAULT_PASSWORD`, worker→`WORKER_SSH_PASSWORD`)

```bash
NODES=(
  "master,cubestack-k8s-master01,10.244.1.11,52:54:00:3b:e9:d2,16,8,50,ubuntu,-"
  "worker,mxgpu-1-232,10.66.1.232,-,0,0,0,ubuntu,-"
)
```

---

## 4. 双网络方案

| | 方案A `bridge`(默认) | 方案B `nat` |
|---|---|---|
| 网络类型 | 私有 Linux 网桥 `privbr0` | libvirt NAT 网络 |
| 特点 | **精准 SNAT** 仅对物理Worker网段伪装 + 回程路由,适配跨二层互通 | libvirt 自动建桥+全局MASQUERADE+dnsmasq,零手工 |
| 配置 | `NET_MODE=bridge`, `BRIDGE`/`VM_SUBNET`/`PHYS_WORKER_NET` | `NET_MODE=nat`, `NAT_NET_NAME`/`NAT_SUBNET`/`NAT_GATEWAY` |
| 初始化脚本 | `setup-vm-network.sh` | `setup-libvirt-nat.sh` |
| 验证/回滚 | `verify-vm-network.sh` / `teardown-vm-network.sh` | `virsh net-*` / `setup-libvirt-nat.sh --delete` |

---

## 5. 脚本用法详解

### 5.1 deploy-cluster.sh —— 一键部署统一入口(模块化)

```bash
sudo ./scripts/deploy-cluster.sh                       # 默认基础设施模块(net/ssh_key/vm/ssh_passwordless/worker_bm/hosts/inventory)
sudo ./scripts/deploy-cluster.sh --with-k8s            # 追加 k8s 部署模块(= --enable k8s)
sudo ./scripts/deploy-cluster.sh --steps vm,k8s        # 只运行指定模块(逗号分隔)
sudo ./scripts/deploy-cluster.sh --skip hosts          # 跳过某模块
sudo ./scripts/deploy-cluster.sh --enable gpu_operator,lws  # 启用默认关闭模块(需先实现 steps/ 脚本)
sudo ./scripts/deploy-cluster.sh --only <host>         # 仅处理指定节点(可多次)
sudo ./scripts/deploy-cluster.sh --list-steps          # 查看全部模块
sudo ./scripts/deploy-cluster.sh --list                # 仅打印集群规划(只读)
sudo ./scripts/deploy-cluster.sh --fresh               # 清断点续跑状态重跑
```

流程按 `lib-deploy.sh` 注册表顺序执行 `steps/*.sh`;每模块完成自动保存状态(断点续跑)。默认模块:网络 → SSH密钥 → 虚拟机创建+启动 → SSH免密 → 裸金属worker装包 → /etc/hosts(可选) → inventory。k8s/gpu_operator/lws 默认关闭,按需 `--enable`/`--steps` 启用。

### 5.2 gen-ssh-key.sh —— SSH 密钥对

```bash
./scripts/gen-ssh-key.sh        # 生成 ~/.ssh/cubestack_k8s(ed25519, 幂等)
```

### 5.3 setup-passwordless.sh —— 免密登录

```bash
./scripts/setup-passwordless.sh <IP> [user ...]        # user 缺省用配置 VM_SSH_USERS
./scripts/setup-passwordless.sh 10.244.1.11            # root + ubuntu
./scripts/setup-passwordless.sh 10.244.1.11 ubuntu     # 仅 ubuntu
```

用配置的默认密码(`SSH_DEFAULT_PASSWORD`)注入公钥到目标主机 `~/.ssh/authorized_keys`,随后验证纯密钥登录。要求:已执行 `gen-ssh-key.sh`;目标允许 SSH 密码登录。

### 5.4 gen-inventory.sh —— kubespray inventory

```bash
./scripts/gen-inventory.sh                    # 生成全部节点
INV_ROLES=master ./scripts/gen-inventory.sh   # 仅 master(先部署控制平面)
INV_EXCLUDE=mxgpu-1-232 ./scripts/gen-inventory.sh  # 排除指定节点(逗号分隔)
```

生成:
- `deployments/kubespray/inventory/cubestack-cluster/hosts.yml` —— **kubespray 实际使用**(注意 kubespray 的 ansible.cfg 忽略 `.ini`)
- 同目录 `inventory.ini` —— 兼容 installer 后端风格(参考/后续 UI 用)
- 生成后**自动调用 `sync-kubespray-config.sh`**,从 cluster.conf 动态填充 group_vars 中的 IP(见 5.8)

master 写入 `ansible_ssh_private_key_file`(密钥免密);worker 若密钥存在同样优先用密钥,否则用 `ansible_password`(未配置则留注释)。

### 5.8 sync-kubespray-config.sh —— 动态同步 kubespray IP 配置

**避免在 kubespray group_vars 中硬编码环境 IP**,从 `config/cluster.conf` 动态生成:

```bash
./scripts/sync-kubespray-config.sh
```

自动同步项:

| 配置文件 | 字段 | 数据源 |
|---|---|---|
| `group_vars/all/all.yml` | `loadbalancer_apiserver.address` | `HOST_PHYS_IP`(宿主机物理 IP) |
| `group_vars/all/all.yml` | `supplementary_addresses_in_ssl_keys` | `HOST_PHYS_IP` + 所有 master IP + `lb.k8s.local` |
| `group_vars/k8s_cluster/k8s-net-calico.yml` | `calico_ip_auto_method` | 第一个 worker IP(`can-reach=`) |
| `group_vars/k8s_cluster/k8s-cluster.yml` | `kube_apiserver_extra_args.advertise-address` | `HOST_PHYS_IP` |

> 说明:`kube_service_addresses` / `kube_pods_subnet` 为集群内部 CIDR(10.233.x),属 kubespray 默认值,无需从环境同步。

### 5.9 register-vm.sh —— 注册已存在 VM

VM 已通过其他方式创建时,用此脚本将其注册到 `cluster.conf` 的 NODES:

```bash
./scripts/register-vm.sh <role> <hostname> <ip> <mac> <mem> <cpu> <disk> [user] [password]
./scripts/register-vm.sh worker cubestack-k8s-worker01 10.244.1.21 52:54:00:aa:bb:21 16 8 50
```

幂等(已存在则跳过),内部复用 `lib-common.sh` 的 `register_node_to_conf()`(awk 实现)。

### 5.10 install-worker-packages.sh —— 离线包安装到裸机 worker

bare-metal worker(Ubuntu)无法联网时,用 repository 中的离线 `.deb` 包安装 kubespray 所需系统包:

```bash
./scripts/install-worker-packages.sh <IP> [user]
./scripts/install-worker-packages.sh 10.66.1.232 ubuntu
```

包来源: `deployments/kubespray/repository/cubestack-cluster/` 下的 `.deb` 文件(仓库根目录,与 kubeadm/etcd 等二进制同层)或 `packages/` 子目录,脚本自动收集两者并去重。包含 iputils-ping / rsync / iptables / curl / ca-certificates 及依赖。

### 5.5 create-libvirt-vm.sh —— 单台虚拟机

```bash
./scripts/create-libvirt-vm.sh <主机名> <内存G> <CPU> <磁盘G> <MAC> <静态IP>
./scripts/create-libvirt-vm.sh cubestack-k8s-master01 16 8 50 52:54:00:3b:e9:d2 10.244.1.11
```

网络模式取配置 `NET_MODE`(bridge/nat);`AUTO_SETUP_NET=1` 时网络不存在会自动创建。IP 会校验必须落在虚拟机网段内。通常由 `deploy-cluster.sh` 调用,也可单独使用。

### 5.6 网络三件套(方案A桥接)

```bash
sudo ./scripts/setup-vm-network.sh      # 建 privbr0 + 回程路由 + 精准SNAT + 开机自启
sudo ./scripts/verify-vm-network.sh     # 9项检查 + 连通性指引
sudo ./scripts/teardown-vm-network.sh   # 回滚(SNAT/路由/自启); REMOVE_BRIDGE=1 删网桥
```

### 5.7 网络(NAT方案)

```bash
sudo ./scripts/setup-libvirt-nat.sh [网络名]         # 创建(幂等),默认 cubestack-nat/10.245.0.0/16
sudo ./scripts/setup-libvirt-nat.sh --delete [网络名] # 删除回滚
```

---

## 6. 环境变量覆盖(示例)

```bash
# 网络方案切换
VM_NET_MODE=bridge ./scripts/create-libvirt-vm.sh ...     # 覆盖 NET_MODE
# 单次指定密码 / 密钥
SSH_DEFAULT_PASSWORD='xxx' ./scripts/setup-passwordless.sh 10.244.1.11
# 指定配置文件
CLUSTER_CONF=/path/to/cluster.conf sudo ./scripts/deploy-cluster.sh --list
```

---

## 7. 常见问题

- **`net.ipv4.route_localnet` 设置失败(No such file)** — 老内核无此参数,本方案不依赖,脚本已自动跳过并仅告警,可忽略。
- **worker 连通性检查失败** — 需在 `config/cluster.conf` 填写 `WORKER_SSH_PASSWORD`(或节点行第9字段),脚本才用密码测试裸金属。
- **创建 VM 报"网桥不存在"** — 先 `sudo ./scripts/setup-vm-network.sh`,或 `AUTO_SETUP_NET=1` 自动建。
- **kubespray 部署** — `--with-k8s` 需宿主机已装 `ansible-playbook` 且 `KUBESPRAY_DIR` 指向完整 kubespray 仓库(含 `cluster.yml` 与 `group_vars`)。
- **离线部署 kube-proxy 报 ImagePullBackOff** — 需先预加载离线镜像到节点 containerd(见第 8 节,`cubestack-offline.sh scale` 已内置此逻辑)。

---

## 8. 从 0 到 1:离线部署 kubespray 集群

完整流程(全部通过脚本自动完成,无人工干预):

### 8.1 前置条件

| 依赖 | 说明 |
|---|---|
| 宿主机 | Ubuntu 22.04,已装 `libvirt / virt-install / qemu / virt-customize` |
| 基础镜像 | `deployments/virtual-machine/cloud-images/ubuntu2204-k8s-base.qcow2`(由 `create-vm-template.sh` 制作,预埋 ubuntu/root 密码 `k8s@2026`、SSH、时区及 kubespray 所需包) |
| 离线资源 | `deployments/kubespray/repository/cubestack-cluster/`(镜像 `images/` + 二进制 + `packages/` 系统包) |
| kubespray | `deployments/kubespray/kubespray/`(含 `cluster.yml`,Python 依赖可离线/在线安装) |

### 8.2 配置(cluster.conf 为唯一数据源)

```bash
cp config/cluster.conf.example config/cluster.conf
# 修改: HOST_PHYS_IP / BASE_IMG / VM_DISK_DIR / 网段 / NODES(每行一个节点)
vim config/cluster.conf
```

节点格式:`role,hostname,ip,mac,mem_g,cpu,disk_g,ssh_user,ssh_password,node_type`(第10字段 `node_type`=vm 虚拟机 / bm 裸金属, 省略时自动推断)

**离线镜像预加载(最小集合)**:部署前只把"kubespray 必需镜像"同步到节点 containerd,避免全量 rsync 无关镜像(cilium/flannel/ingress-nginx/dashboard 等)拖慢部署。通过 `cluster.conf` 的 `PRELOAD_IMAGE_PATTERNS` 配置:

```bash
# 空格分隔的匹配条目; 含 ".tar" 为精确文件名匹配(如 quay.io_calico_node_v3.29.3.tar), 否则为文件名包含匹配(如 calico)
# 留空 = 全量同步 images/ 目录; 默认值为内置最小集合(见 cluster.conf.example)
PRELOAD_IMAGE_PATTERNS="calico_cni calico_kube-controllers calico_node etcd kube-apiserver \
kube-controller-manager kube-proxy kube-scheduler coredns cluster-proportional-autoscaler \
k8s-dns-node-cache metrics-server pause"
```

> 也可在 `inventory/<cluster>/preload-images.conf` 中单独覆盖(standalone 运行 `cubestack-offline.sh` 时生效;`PRELOAD_IMAGE_PATTERNS=""` 即全量同步)。

> **所有 IP 不硬编码**:kubespray group_vars 中的宿主机 IP、master IP、Calico can-reach 等均由 `sync-kubespray-config.sh` 从 cluster.conf 动态生成。

### 8.3 一键部署(推荐)

```bash
# 全流程: 宿主网络 → SSH密钥 → master/worker VM 创建+注册 → 免密 → inventory → kubespray 离线部署
sudo ./scripts/deploy-cluster.sh --with-k8s
```

该命令自动完成:
1. `setup-vm-network.sh` 初始化 privbr0 网桥 + SNAT
2. `gen-ssh-key.sh` 生成 SSH 密钥
3. 按 NODES 创建 master/worker 虚拟机(基础镜像已由 `create-vm-template.sh` 预制 kubespray 所需包, 创建 VM 不安装任何组件, 离线环境安全)
4. `setup-passwordless.sh` 注入公钥
5. 对 worker 执行 `install-worker-packages.sh` 安装离线包
6. `gen-inventory.sh` + `sync-kubespray-config.sh` 生成 inventory 与配置
7. `cubestack-offline.sh install` 执行 kubespray 离线部署

### 8.4 分步部署(可精细控制)

```bash
# ① 初始化宿主网络(bridge 方案)
sudo ./scripts/setup-vm-network.sh

# ② 生成 SSH 密钥
./scripts/gen-ssh-key.sh

# ③ 创建 master VM(3 台)+ 注册到 cluster.conf + 免密
sudo AUTO_REGISTER_CLUSTER=1 ./scripts/create-libvirt-vm.sh cubestack-k8s-master01 16 8 50 52:54:00:3b:e9:d2 10.244.1.11
SSH_DEFAULT_PASSWORD='k8s@2026' ./scripts/setup-passwordless.sh 10.244.1.11 ubuntu
# ... 重复 master02 / master03 ...

# ④ 生成 inventory + 同步 kubespray 配置
INV_ROLES=master ./scripts/gen-inventory.sh        # 先只生成 master

# ⑤ 离线部署 kubespray(先下载离线资源,再安装)
cd deployments/kubespray
CUBESTACK_INVENTORY_DIR=$PWD/inventory/cubestack-cluster \
CUBESTACK_LOCAL_REPO_DIR=$PWD/repository/cubestack-cluster \
CUBESTACK_KUBESPRAY_DIR=$PWD/kubespray \
  bash cubestack-offline.sh install
```

### 8.5 扩容(新增 worker 节点)

```bash
# ① 创建 worker VM + 注册(或编辑 cluster.conf NODES 追加 worker 行)
sudo AUTO_REGISTER_CLUSTER=1 ./scripts/create-libvirt-vm.sh cubestack-k8s-worker01 16 8 50 52:54:00:aa:bb:21 10.244.1.21
SSH_DEFAULT_PASSWORD='k8s@2026' ./scripts/setup-passwordless.sh 10.244.1.21 ubuntu

# ② 生成含新 worker 的 inventory(排除跨网段节点可加 INV_EXCLUDE)
./scripts/gen-inventory.sh

# ③ 扩容: 预加载镜像到 worker → 执行 scale.yml
cd deployments/kubespray
CUBESTACK_INVENTORY_DIR=$PWD/inventory/cubestack-cluster \
CUBESTACK_LOCAL_REPO_DIR=$PWD/repository/cubestack-cluster \
CUBESTACK_KUBESPRAY_DIR=$PWD/kubespray \
  bash cubestack-offline.sh scale --limit kube_node
```

> `cubestack-offline.sh scale` 已内置:先按 `PRELOAD_IMAGE_PATTERNS` 将最小镜像集合(默认 13 个,如 kube-*、etcd、coredns、calico、metrics-server、pause)rsync 到 worker 并 `ctr image import` 预加载,再执行 `scale.yml`,避免 kube-proxy 等镜像 ImagePullBackOff。

### 8.6 bare-metal worker(跨网段)

```bash
# ① 先通过密码注入 SSH 公钥(免密)
export SSHPASS='<worker密码>'
sshpass -e ssh ubuntu@<workerIP> "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys" < ~/.ssh/cubestack_k8s.pub

# ② 安装离线系统包
./scripts/install-worker-packages.sh <workerIP> ubuntu

# ③ 加入 inventory 后扩容
#    注意: worker 通过宿主机 IP:6443(DNAT)访问 API Server,需确保 /etc/hosts 与证书 SAN 配置正确(见 5.8)
./scripts/gen-inventory.sh
bash deployments/kubespray/cubestack-offline.sh scale --limit kube_node
```
