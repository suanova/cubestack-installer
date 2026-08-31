# CubeStack 脚本使用手册(CLI)

> **本文档定位**:介绍 `deployments/scripts/` 下脚本的**调用方式与使用案例**。
> **部署套件总览**(支持的软件/架构/目录组织/离线镜像与虚拟机镜像路径):见 [`deployments/README.md`](../README.md)。
> **脚本开发规范**(模块命名/元数据/新增模块流程):见 [`docs/scripts-development-spec.md`](../../docs/scripts-development-spec.md)。

本目录脚本提供完整的**命令行自动化**能力:从宿主网络初始化、SSH 密钥、master 虚拟机创建与免密登录,到 kubespray 兼容 inventory 生成与(可选)K8s 离线部署。

所有脚本**统一读取** `config/cluster.conf` 作为唯一数据源,不硬编码 IP / 用户名 / 密码 / 路径。配置优先级:**环境变量 > 配置文件 > 内置兜底默认**。

> 断点续跑:每阶段完成自动保存状态到 `config/.deploy.state`;下次启动自动跳过已完成阶段;`--fresh` 清状态重新执行。

> UI 兼容性:统一配置结构清晰,`gen-inventory.sh` 同时产出后端风格的 `inventory.ini`,后期 installer 后端可复用同一份 `cluster.conf`。

---

## 1. 快速开始(CLI 容器一键部署)

> ⭐ **推荐方式**:宿主机只需 **Docker**,离线文件/配置/密钥都在容器外管理(挂载),换环境/多集群复用同一套 offline-files。

```bash
# ① 拉取 CLI 镜像(内置 kubespray 源码 + 全部部署脚本 + 工具链: ansible/helm/skopeo/mc/kubectl/sshpass/virsh)
docker pull harbor.isuanova.com/cubestack/cubestack-installer-cli:latest

# ② 宿主机准备大磁盘离线目录(离线文件较大, 建议 ≥50GiB 空闲; 多集群可共用同一份)
mkdir -p /data/offline-files

# ③ 启动容器(后台 + network host): 把离线目录/配置/SSH 密钥挂进容器
sudo docker run -itd --name cubestack-install --network=host \
  -v /data/offline-files:/opt/cubestack-installer/deployments/offline-files \
  harbor.isuanova.com/cubestack/cubestack-installer-cli:latest bash

# ④ 进入容器(容器内已是 root, 无需 sudo)
sudo docker exec -it cubestack-install bash

# ⑤ 从 MinIO 拉取离线文件(默认下载部署必需子目录, 排除 virtual-machine; 已挂载即落盘宿主机)
mc alias set minio http://192.168.16.6:9000 admin CHANGE_ME    # 换真实 MinIO 地址/凭证
./deployments/scripts/tools/offline/fetch-offline-from-minio.sh   # 默认: kubespray/metax-gpu/lws/os/envoy(排除 VM 镜像)

# ⑥ 首次: 从模板生成真实配置(cluster.conf 是唯一数据源, 所有 IP 不硬编码)
cd /opt/cubestack-installer
cp deployments/config/cluster.conf.example deployments/config/cluster.conf

# ⑦ 修改配置(必须改): SSH_DEFAULT_PASSWORD 密码 / NODES 节点 IP 等信息 / METALLB_POOL 地址池
vim deployments/config/cluster.conf

# ⑧ 一键部署(默认 = --with-cubestack 全量: 装全部组件 + kubespray 离线安装)
./deployments/scripts/deploy-cluster.sh
```

**为什么离线目录要挂载(不下载进容器)**:
- 离线文件不入镜像(20G+ 级), **挂载 `offline-files` 后下载即落盘宿主机大磁盘**, 多集群/换环境复用, 免重复下载;
- 容器内 `deploy-cluster.sh` / `fetch-offline-from-minio.sh` 读写的就是挂载目录(`/opt/cubestack-installer/deployments/offline-files`);
- `config/` 挂载: 宿主机编辑 `cluster.conf` 容器内即时生效, 真实配置(含密码)不进容器层。

**宿主机直跑替代**(不想用容器, 机器已装 ansible/skopeo/mc 等):直接 clone 本仓库, 在仓库根执行同样命令(第 ⑤ 步起), 离线文件默认落 `deployments/offline-files`, 脚本自动磁盘检查。

> **全裸金属集群(无虚拟机)**:跳过 VM 网络模块直接部署 → `sudo ./deployments/scripts/deploy-cluster.sh --skip net`(NODES 直接填裸机, 见 §8.7)。
> **需要创建虚拟机**:依赖宿主机 libvirt, 容器加 `--privileged` 或挂载 `/var/run/libvirt`(见 §5.14); 虚拟机镜像 `--sub virtual-machine` 按需拉取。
> **容器重建后复用**:`offline-files`/`config`/`.ssh` 都在宿主机, `docker rm -f cubestack-install` 后重跑 ③④ 即可, 离线文件免重下。

---

## 2. 目录与文件

```
deployments/scripts/
├── lib-common.sh              # 公共库:统一配置加载 + IP/MAC 工具(被所有脚本 source)
│                              #   register_node_to_conf(): awk 幂等注册节点到 cluster.conf
│                              #   save_state/get_state/clear_state: 断点续跑状态管理
│                              #   node_parse(): 统一解析 NODES(5字段, 不区分虚拟机/裸金属)
│                              #   统一读取 config/cluster.conf
├── lib-module.sh              # ★ 模块框架:递归自动发现 modules/<阶段>/*.sh + 元数据解析 + 调度
├── deploy-cluster.sh          # ★ 统一入口(薄壳: 参数解析 + 按模块框架调度, 不内联业务逻辑)
├── modules/                   # ★ 部署模块(按部署环境准备的阶段组织子目录, 自动发现)
│   ├── 01_env/                #   阶段一: 环境准备(发生在部署 kubespray 之前)
│   │   ├── 01_vm_network.sh   #     VM 宿主网络(bridge/nat; 默认关, 由 tools/vm/create-vms.sh 创建 VM 时自动执行)
│   │   ├── 02_vm_sshkey.sh    #     生成 SSH 密钥
│   │   ├── 03_vm_create.sh    #     创建虚拟机(默认关, 由 tools/vm/create-vms.sh 独立执行)
│   │   ├── 04_harbor.sh       #     Harbor 镜像仓库(集群外私有仓库, 部署前就绪)
│   │   ├── 05_lb_haproxy.sh   #     HAProxy API 四层负载均衡(集群部署前准备)
│   │   └── 06_lb_keepalived.sh#     Keepalived API VIP 高可用(集群部署前准备)
│   ├── 02_k8s/                #   阶段二: 离线部署 kubespray(不依赖 VM/裸金属)
│   │   ├── 01_k8s_passwordless.sh  # SSH 免密
│   │   ├── 02_k8s_workerbm.sh      # worker 节点离线装包(全部 worker)
│   │   ├── 03_k8s_hosts.sh         # 更新 /etc/hosts
│   │   ├── 04_k8s_inventory.sh     # 生成 inventory + 同步配置
│   │   ├── 05_k8s_ntp.sh           # NTP 时间同步
│   │   ├── 06_k8s_deploy.sh        # 部署 kubespray(默认关, K8S_ENABLED; 完成后单节点集群自动解除 master 污点使其可调度)
│   │   └── 07_k8s_scale.sh         # 扩容集群(默认关, K8S_SCALE_ENABLED; 扩容后单 control-plane 重新解除污点)
│   └── 03_addon/              #   阶段三: 附加组件(集群部署后; 01~19 中间件, 20 起自研)
│       ├── 01_metallb.sh      #    MetalLB 负载均衡(基座, METALLB_ENABLED)
│       ├── 02_local_path.sh   #    local-path-provisioner(基座, LOCAL_PATH_ENABLED)
│       ├── 03_k8s_registry.sh #    集群内内置 registry addon(REGISTRY_ENABLED)
│       ├── 04_gpu_operator.sh #    沐曦 GPU Operator(P1-5, GPU_OPERATOR_ENABLED)
│       ├── 05_gpu_lws.sh      #    LeaderWorkerSet(P1-8, LWS_ENABLED)
│       ├── 06_prometheus.sh   #    Prometheus+Operator+监控附属(P1-2/3, PROMETHEUS_ENABLED)
│       ├── 07_ceph.sh         #    Ceph 存储集群(P1-6, CEPH_ENABLED)
│       ├── 08_ceph_csi.sh     #    Ceph CSI RBD/RGW/CephFS(P1-7, CEPH_CSI_ENABLED)
│       ├── 09_envoy_gateway.sh#    Envoy Gateway 通用 K8s API 网关(P1-9, ENVOY_GATEWAY_ENABLED)
│       ├── 10_envoy_ai_gateway.sh # Envoy AI Gateway AI 专用网关(P1-9, ENVOY_AI_GATEWAY_ENABLED, 依赖 EG)
│       ├── 11_keycloak.sh     #    Keycloak 统一认证(P2-1, KEYCLOAK_ENABLED)
│       ├── 12_kueue.sh        #    Kueue 队列治理(P2-2 DEV-29, KUEUE_ENABLED)
│       ├── 13_kubevirt.sh     #    KubeVirt 虚拟机能力(P2-3 DEV-35, KUBEVIRT_ENABLED)
│       ├── 14_lustre_csi.sh   #    Lustre CSI(P3-1 DEV-26, LUSTRE_CSI_ENABLED)
│       ├── 20_cubestack_apps.sh#   CubeStack 自研模块占位(20 起, CUBESTACK_APPS_ENABLED)
│       └── 2x_verify_*.sh     #    端到端验证(verify_metallb / verify_registry_storage / verify_metax_gpu
│                              #    / verify_lws / verify_envoy_gateway / verify_envoy_ai_gateway; --steps verify 全跑)
├── tools/                     # ★ 工具脚本(模块的底层实现, 按领域分目录)
│   ├── vm/                    #   虚拟机: create-libvirt-vm.sh / create-vm-template.sh / register-vm.sh
│   ├── net/                   #   网络: setup-vm-network.sh / verify-vm-network.sh / teardown-vm-network.sh / setup-libvirt-nat.sh
│   ├── node/                  #   节点: gen-ssh-key.sh / setup-passwordless.sh / install-worker-packages.sh / prepare-workers.sh
│   │                         #        setup-ntp.sh / sync-hosts.sh / sync-ca*.sh / rebootstrap*.sh
│   ├── k8s/                   #   inventory/配置: gen-inventory.sh / sync-kubespray-config.sh / sync-addons-config.sh
│   ├── images/                #   离线镜像工具: metax-save/load-images.sh / lws-save-images.sh
│   │                         #        envoy-save/load-images.sh(EG+AI 镜像) / envoy-fetch-charts.sh(EG+AI 离线 chart)
│   ├── offline/               #   MinIO 离线文件: fetch-offline-from-minio.sh(拉取) / sync-to-minio.sh(推送) / trim-offline-files.sh(清理) / fetch-offline-files.sh(旧)
│   └── lb/                    #   负载均衡/registry: sync-haproxy.sh / deploy-registry.sh / setup-registry-expose.sh
└── README.md                  # 本文件
```

### 模块化设计说明(规范见 docs/scripts-development-spec.md)

`deploy-cluster.sh` 只做两件事:**参数解析 + 按模块框架调度**,不内联任何业务逻辑。
每个部署功能 = `modules/<阶段目录>/NN_category_action.sh` 一个独立脚本(薄封装, 复用现有工具脚本)。

**目录 = 部署环境准备的阶段**:
- `01_env/` — 阶段一: 环境准备(VM/SSH/Harbor/HAProxy/Keepalived),**发生在部署 kubespray 之前**
- `02_k8s/` — 阶段二: 离线部署 kubespray(不依赖 VM 还是裸金属)
- `03_addon/` — 阶段三: 附加组件(集群部署后; 01~19 中间件, 20 起 CubeStack 自研模块)

**镜像仓库定位**(与部署阶段对应):
- 集群外私有仓库 → **Harbor**(`01_env/04_harbor.sh`, `HARBOR_ENABLED`),环境准备阶段于宿主机就绪
- 集群内 registry → kubespray addon(`03_addon/03_k8s_registry.sh`),**默认不部署**(`REGISTRY_ENABLED=0`)
- 原本地 docker registry(env_registry)已移除,由 Harbor 承担镜像仓库职责

模块头部用注释声明元数据,框架**自动发现**(递归扫描子目录, 按 目录序号+文件序号 排序):

```bash
# MODULE: k8s_deploy          # 模块 key(缺省=文件名去掉 NN_ 前缀)
# DESC: 部署 kubespray 集群   # 一句话描述
# PHASE: k8s                  # 阶段: env / k8s / addon
# DEFAULT: 0                  # 是否默认启用
# REPEAT: 0                   # 1=可重复执行(不写断点状态)
# TOGGLE: K8S_ENABLED         # (可选) cluster.conf 变量, true 时自动启用
```

**新增模块**:
1. 在 `modules/<阶段目录>/` 新建 `NN_category_action.sh`(实现逻辑, 可调用 `tools/` 下工具脚本/kubectl)
2. 按上面格式写元数据头
3. 完成 —— 无需修改 `lib-module.sh` / `deploy-cluster.sh` / 任何注册表

**tools/ 工具脚本**:模块是"薄封装",具体动作(网络/SSH/装包/生成 inventory/配置同步等)在 `tools/<领域>/` 下的工具脚本中实现,被模块通过 `bash "${SCRIPT_DIR}/tools/<领域>/xxx.sh"` 复用。新增工具脚本放入对应领域目录即可(网络→`tools/net/`, 节点→`tools/node/`, inventory/配置→`tools/k8s/`, 负载均衡/registry→`tools/lb/`, 虚拟机→`tools/vm/`)。

**向后兼容**:旧模块名(`net`/`ssh_key`/`vm`/`ssh_passwordless`/`worker_bm`/`hosts`/`inventory`/`ntp`/`k8s`/`scale`/`lws`)由 `lib-module.sh` 的 `MODULE_ALIAS` 自动映射,旧用法 `--steps vm,k8s` 仍然有效。

项目根目录 `scripts/` 下仅有 dev 启动脚本(`dev.sh`/`start-backend.sh`/`start-frontend.sh`),部署脚本统一在 `deployments/scripts/`。

统一配置:见 `config/cluster.conf`(真实,已 gitignore)与 `config/cluster.conf.example`(模板,提交)。
全阶段组件规划与进度追踪:见 `docs/cluster-components-plan.md`(P1/P2/P3)。

---

## 3. 统一配置文件(config/cluster.conf)

配置分五大块,字段含义见文件内注释:

| 区块 | 关键项 | 说明 |
|---|---|---|
| **核心必改项** | `SSH_DEFAULT_PASSWORD` `NODES` `METALLB_POOL` | 节点默认密码、节点清单、MetalLB 地址池(文件顶部醒目位置) |
| 服务暴露 | `SERVICE_EXPOSE_MODE` | 对外暴露方式全局开关: `metallb`(默认,生产, LoadBalancer VIP)/ `nodeport`(测试环境, NodePort, 自动关 MetalLB); 见 §5.8 |
| 宿主机 | `HOST_PHYS_IP` | 宿主机物理 IP(SNAT 源) |
| SSH | `SSH_KEY_NAME` | 密钥名(默认密码见核心必改项 `SSH_DEFAULT_PASSWORD`; 节点独立密码写 NODES 第5字段) |
| 节点规划 | `NODES=( ... )` | 每行一节点(5字段, 不区分虚拟机/裸金属); 虚拟机规格见 `tools/vm/vm-nodes.conf` |
| 离线文件 | `OFFLINE_FILES_DIR` `LOCAL_REPO_DIR` `MINIO_*` | 离线 binary/镜像目录与 MinIO 下载配置(§2.1b) |
| kubespray | `KUBESPRAY_INV_DIR` `KUBESPRAY_DIR` `UPDATE_ETC_HOSTS` | inventory 输出位置、playbook 位置、是否写 /etc/hosts |
| NTP 时间同步 | `NTP_ENABLED` `NTP_SERVER` `NTP_UPSTREAM` `NTP_ALLOW` `NTP_MAX_OFFSET_MS` | k8s 部署前的节点时钟一致化(见 §5.8.2) |

> **虚拟机配置已独立**: 虚拟机创建/网络变量(`BASE_IMG` `VM_DISK_DIR` `VM_SSH_USERS` `VM_SUBNET`
> `BRIDGE` `NET_MODE` `NAT_*` 等)已从 cluster.conf **移至 `tools/vm/vm-nodes.conf`**(由 lib-common
> `load_config` 自动加载), cluster.conf 不再包含任何 VM 相关变量。

### 节点行格式(5字段, 不区分虚拟机/裸金属)

```
role,hostname,ip,ssh_user,ssh_password
```

- `role`: `master`(控制平面) | `worker`(工作节点)
- `ssh_user`: 节点 SSH 用户名
- `ssh_password`: `-` = 用默认密码 `SSH_DEFAULT_PASSWORD`(全节点默认一致); 显式密码 = 该节点用此密码(**支持裸金属不同密码场景**)

```bash
NODES=(
  "master,cubestack-k8s-master01,10.244.1.11,ubuntu,-"
  "worker,cubestack-k8s-worker01,10.244.2.11,ubuntu,-"
  "worker,cubestack-k8s-worker02,10.244.2.12,root,独立密码示例"   # 该节点用独立密码
)
```

> ⚠ **虚拟机规格不在此文件**: 需要**创建虚拟机**的节点在 `deployments/scripts/tools/vm/vm-nodes.conf`(10字段:
> `role,hostname,ip,mac,mem_g,cpu,disk_g,ssh_user,ssh_password,node_type`)中定义, 由
> **`tools/vm/create-vms.sh` 独立执行**(`sudo ./deployments/scripts/tools/vm/create-vms.sh`, 主程序默认不调度),
> 创建成功后**自动把 5 字段信息注入 cluster.conf 的 NODES**。
> 主程序(一键部署/各模块)**不判断节点是虚拟机还是裸金属**, 对所有节点一视同仁。旧 10 字段 NODES 格式仍被兼容解析(向后兼容)。

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
sudo ./scripts/deploy-cluster.sh                       # 默认 = --with-cubestack(基座 + 全部启用的 operator)
sudo ./scripts/deploy-cluster.sh --with-k8s            # 追加 k8s 部署模块(= --enable k8s, 兼容旧名)
sudo ./scripts/deploy-cluster.sh --steps vm,k8s        # 只运行指定模块(逗号分隔, 旧名自动映射)
sudo ./scripts/deploy-cluster.sh --skip hosts          # 跳过某模块
sudo ./scripts/deploy-cluster.sh --skip net --with-k8s  # 全裸金属:跳过网络模块, 部署 k8s
sudo ./scripts/deploy-cluster.sh --phase k8s           # 仅运行 k8s 阶段
sudo ./scripts/deploy-cluster.sh --enable gpu_operator,lws  # 启用默认关闭模块
sudo ./scripts/deploy-cluster.sh --only <host>         # 仅处理指定节点(可多次)
sudo ./scripts/deploy-cluster.sh --list-steps          # 查看全部模块(自动发现)
sudo ./scripts/deploy-cluster.sh --list                # 仅打印集群规划(只读)
sudo ./scripts/deploy-cluster.sh --fresh               # 清断点续跑状态重跑
```

流程按 `modules/*.sh` 文件序号自动发现并执行;每模块完成自动保存状态(断点续跑)。默认(无参数)= `--with-cubestack`:宿主机网络(按需) → SSH密钥 → SSH免密(全部节点)→ worker离线装包 → /etc/hosts(可选) → inventory → **NTP 时间同步(在 k8s 前)** → kubespray 部署 → 基座 + 启用的 operator。**虚拟机创建由 `tools/vm/create-vms.sh` 独立执行, 主程序不判断节点类型**。gpu_operator 默认启用;其余 operator 默认关,按需 `--enable`/`--steps`/`--phase` 或 cluster.conf 开关启用。

随时可只检查节点时钟偏差(只读, 不写任何东西):

```bash
sudo ./scripts/tools/node/setup-ntp.sh --check
```

### 5.2 gen-ssh-key.sh —— SSH 密钥对

```bash
./scripts/tools/node/gen-ssh-key.sh        # 生成 ~/.ssh/cubestack_k8s(ed25519, 幂等)
```

### 5.3 setup-passwordless.sh —— 免密登录

```bash
./scripts/tools/node/setup-passwordless.sh <IP> [user ...]        # user 缺省用配置 VM_SSH_USERS
./scripts/tools/node/setup-passwordless.sh 10.244.1.11            # root + ubuntu
./scripts/tools/node/setup-passwordless.sh 10.244.1.11 ubuntu     # 仅 ubuntu
```

用配置的默认密码(`SSH_DEFAULT_PASSWORD`)注入公钥到目标主机 `~/.ssh/authorized_keys`,随后验证纯密钥登录。要求:已执行 `gen-ssh-key.sh`;目标允许 SSH 密码登录。

### 5.4 gen-inventory.sh —— kubespray inventory

```bash
./scripts/tools/k8s/gen-inventory.sh                    # 生成全部节点
INV_ROLES=master ./scripts/tools/k8s/gen-inventory.sh   # 仅 master(先部署控制平面)
INV_EXCLUDE=mxgpu-1-232 ./scripts/tools/k8s/gen-inventory.sh  # 排除指定节点(逗号分隔)
```

生成:
- `deployments/kubespray/inventory/cubestack-cluster/hosts.yml` —— **kubespray 实际使用**(注意 kubespray 的 ansible.cfg 忽略 `.ini`)
- 同目录 `inventory.ini` —— 兼容 installer 后端风格(参考/后续 UI 用)
- 生成后**自动调用 `sync-kubespray-config.sh`**,从 cluster.conf 动态填充 group_vars 中的 IP(见 5.8)

master 写入 `ansible_ssh_private_key_file`(密钥免密);worker 若密钥存在同样优先用密钥,否则用 `ansible_password`(未配置则留注释)。

**单节点集群(仅 1 个 master、0 个 worker)**:`gen-inventory.sh` 自动把该 master 同时加入
`kube_node` 组,使 kubeadm 不给 control-plane 打 `NoSchedule` 污点(本身可调度)。部署完成
后 `06_k8s_deploy.sh`/`07_k8s_scale.sh` 还会**再次通过 kubectl 移除该节点污点并 uncordon**
(兜底, 对既存集群重跑也生效) —— 因为 kubespray 扩容会重新给 control-plane 打污点, 而
metallb/local-path/registry/gpu-operator 等普通 pod 无污点容忍, 单节点若不可调度会全部
Pending(registry 起不来 → 镜像推不进 → `ImagePullBackOff`)。

### 5.5 create-libvirt-vm.sh —— 单台虚拟机

```bash
./scripts/tools/vm/create-libvirt-vm.sh <主机名> <内存G> <CPU> <磁盘G> <MAC> <静态IP>
./scripts/tools/vm/create-libvirt-vm.sh cubestack-k8s-master01 16 8 50 52:54:00:3b:e9:d2 10.244.1.11
```

网络模式取配置 `NET_MODE`(bridge/nat);`AUTO_SETUP_NET=1` 时网络不存在会自动创建。IP 会校验必须落在虚拟机网段内。通常由 `deploy-cluster.sh` 调用,也可单独使用。

### 5.6 网络三件套(方案A桥接)

```bash
sudo ./scripts/tools/net/setup-vm-network.sh      # 建 privbr0 + 回程路由 + 精准SNAT + 开机自启
sudo ./scripts/tools/net/verify-vm-network.sh     # 9项检查 + 连通性指引
sudo ./scripts/tools/net/teardown-vm-network.sh   # 回滚(SNAT/路由/自启); REMOVE_BRIDGE=1 删网桥
```

### 5.7 网络(NAT方案)

```bash
sudo ./scripts/tools/net/setup-libvirt-nat.sh [网络名]         # 创建(幂等),默认 cubestack-nat/10.245.0.0/16
sudo ./scripts/tools/net/setup-libvirt-nat.sh --delete [网络名] # 删除回滚
```

### 5.8 sync-kubespray-config.sh —— 动态同步 kubespray IP 配置

**避免在 kubespray group_vars 中硬编码环境 IP**,从 `config/cluster.conf` 动态生成:

```bash
./scripts/tools/k8s/sync-kubespray-config.sh
```

自动同步项:

| 配置文件 | 字段 | 数据源 |
|---|---|---|
| `group_vars/all/all.yml` | `loadbalancer_apiserver.address` | `HOST_PHYS_IP`(宿主机物理 IP) |
| `group_vars/all/all.yml` | `supplementary_addresses_in_ssl_keys` | `HOST_PHYS_IP` + 所有 master IP + `lb.k8s.local` |
| `group_vars/k8s_cluster/k8s-net-calico.yml` | `calico_ip_auto_method` | 第一个 worker IP(`can-reach=`) |
| `group_vars/k8s_cluster/k8s-cluster.yml` | `kube_apiserver_extra_args.advertise-address` | `HOST_PHYS_IP` |
| `group_vars/k8s_cluster/addons.yml` | `metallb_config.address_pools.primary.ip_range` | `METALLB_POOL`(MetalLB 负载均衡地址池) |
| `group_vars/k8s_cluster/addons.yml` | `registry_service_loadbalancer_ip` | `REGISTRY_IP`(registry LoadBalancer 固定 VIP) |
| `group_vars/all/containerd.yml` | `containerd_registries_mirrors` | `REGISTRY_DOMAIN`/`REGISTRY_IP`/`REGISTRY_PORT`(节点 containerd HTTP 信任) |
| `group_vars/all/registry.yml` | `registry_domain`/`registry_ip`/`registry_port` | `REGISTRY_*`(供 patch-playbook 读取) |

> 说明:`kube_service_addresses` / `kube_pods_subnet` 为集群内部 CIDR(10.233.x),属 kubespray 默认值,无需从环境同步。
> 说明:集群已默认启用 **MetalLB**(Layer2,地址池来自 `METALLB_POOL`);**Registry(集群内)默认不部署**(`REGISTRY_ENABLED=0`),集群外镜像仓库用 **Harbor**(`HARBOR_ENABLED`);**local-path-provisioner 默认不启动**(`LOCAL_PATH_ENABLED=false`,需本地 PVC 持久化时启用)。组件开关配置见 `group_vars/k8s_cluster/addons.yml`(由 `sync-addons-config.sh` 从 cluster.conf 生成)。
>
> **对外暴露方式(`SERVICE_EXPOSE_MODE`)**:默认 `metallb`(生产)用 LoadBalancer VIP;设 `nodeport`(测试环境)则 `sync-addons-config.sh` 自动**关闭 MetalLB**(addons.yml `metallb_enabled=false`)、registry→NodePort、ingress-nginx(若启用)→NodePort(30080/30081);Envoy Gateway 数据面需转 NodePort(`tools/lb/gateway-nodeport.sh`, 见 `docs/envoy-gateway.md`)。

### 5.8.1 内置 Registry(镜像仓库)使用指南

kubespray 的 registry addon 以 MetalLB **LoadBalancer** 暴露(默认),对外统一域名 `REGISTRY_DOMAIN`(默认 `registry.local`)、固定 VIP `REGISTRY_IP`(默认 `10.244.2.100`)、端口 `REGISTRY_PORT`(默认 `5000`,HTTP 无 TLS)。集群内拉镜像、集群外 push/pull 全走同一条链路:

```
 集群外 push 机                        宿主机(HOST_PHYS_IP)                       集群内
 ──────────────                        ─────────────────                        ──────
 /etc/hosts: HOST_PHYS_IP registry.local
 docker push registry.local:5000/… ──► DNAT: HOST_PHYS_IP:5000 ──► 10.244.2.100:5000 (MetalLB VIP)
                                          (setup-registry-expose.sh)   │  registry.local:5000
 docker pull registry.local:5000/… ◄──── 同上反向                        │  (registry pod, kube-system)
                                                                        │
  各节点 /etc/hosts: 10.244.2.100 registry.local                        │
  各节点 containerd certs.d/registry.local:5000 (HTTP + skip_verify) ◄──┘
  集群内 pod 引用 image: registry.local:5000/<ns>/<img>:<tag> 直接拉取
```

`registry.local` 是「**双解析**」域名:集群内解析为 MetalLB VIP(`10.244.2.100`),集群外解析为宿主机物理 IP(`HOST_PHYS_IP`)——两个网络各用各的解析,不要混用。

#### ① 集群内拉取镜像(部署 pod,主要场景)

1. 先把镜像 push 进仓库(见 ②/③);
2. Deployment / pod 中直接引用:

```yaml
image: registry.local:5000/dev/myapp:v1.0.0
```

集群节点已在部署时自动写好 `/etc/hosts` 与 containerd `certs.d` 信任,任何能调度到该镜像的节点都可直接拉取。节点上也可手动验证:

```bash
curl -s http://registry.local:5000/v2/            # 期望 {"repositories":[...]}
crictl pull registry.local:5000/dev/myapp:v1.0.0  # 预拉到节点本地(可选, 拉取时不再联网)
```

#### ② 集群外 push / pull(docker / containerd)

每个 push / pull 机一次性配置:

```bash
# ① 域名解析 → 宿主机物理 IP(注意是 HOST_PHYS_IP, 不是 VIP!)
echo "<HOST_PHYS_IP> registry.local" | sudo tee -a /etc/hosts

# ② 让 docker 信任该 HTTP 仓库(无 TLS)
sudo mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{ "insecure-registries": ["registry.local:5000"] }
EOF
sudo systemctl restart docker
```

push(与 docker.io 一致, `<namespace>` 即仓库一级目录):

```bash
docker tag myapp:v1.0.0 registry.local:5000/dev/myapp:v1.0.0
docker push registry.local:5000/dev/myapp:v1.0.0
```

pull / 验证:

```bash
docker pull registry.local:5000/dev/myapp:v1.0.0
curl -s http://registry.local:5000/v2/    # 5000 端口由宿主机 DNAT 转发进集群
```

> 需宿主机转发规则已启用:`sudo ./scripts/tools/lb/setup-registry-expose.sh --add`(部署流程已自动执行);撤销:`--delete`。

#### ③ 集群内节点 / pod 内 push(pod 内用 VIP, 不用域名)

节点上直接 push(containerd 客户端复用同一份 hosts.toml):

```bash
ctr -n k8s.io images pull docker.io/library/busybox:latest
ctr -n k8s.io images tag docker.io/library/busybox:latest registry.local:5000/dev/busybox:latest
ctr -n k8s.io images push --plain-http registry.local:5000/dev/busybox:latest
```

> 集群内 **pod 的 DNS 不解析** `registry.local`(集群外域名)。pod 内若要 push,请改用固定 VIP `10.244.2.100:5000`(能路由到即可);跨网段不确定路由时,可把 registry 切成 NodePort 模式后经 `节点IP:REGISTRY_NODEPORT` 访问。

#### 部署 / 启用脚本

| 场景 | 操作 |
|---|---|
| 新集群安装 | 自动完成(kubespray addon + `cubestack-registry.yml` patch 写节点 hosts / containerd 信任) |
| 已部署集群补配(幂等) | `sudo ./scripts/deploy-registry.sh` —— 设 Service 暴露方式 + 各节点 hosts/certs.d + 宿主机 DNAT + 自检 |
| 仅对外转发 | `sudo ./scripts/tools/lb/setup-registry-expose.sh --add` / `--delete` |

关键配置(`cluster.conf`):

```bash
REGISTRY_ENABLED=1                 # 0 关闭 registry 信任/转发配置
REGISTRY_DOMAIN="registry.local"   # 统一内部域名
REGISTRY_IP="10.244.2.100"         # MetalLB 固定 VIP(须在 METALLB_POOL 内, 避开 .0/.255)
REGISTRY_PORT="5000"
REGISTRY_SERVICE_TYPE=""           # 留空=按 SERVICE_EXPOSE_MODE 自动(metallb→loadbalancer, nodeport→nodeport);
                                   # 显式覆盖: loadbalancer | nodeport(不依赖 MetalLB, 外部用 REGISTRY_NODEPORT) | clusterip
REGISTRY_NODEPORT="31148"            # nodeport 模式的固定 NodePort
```

#### 运维注意

- **无认证、无 TLS**:`registry_htpasswd` 默认空(匿名读写)。如需鉴权,在 `group_vars/k8s_cluster/addons.yml` 配 `registry_htpasswd`(htpasswd 格式)。
- **单副本 + RWO PVC**:镜像数据在 registry pod 所在节点的 local-path(`/opt/local-path-provisioner/`),默认 10Gi。**重建 VM / 迁移节点会丢镜像,需重新 push**。
- **存储类**:`registry_storage_class: "local-path"`(需 `LOCAL_PATH_ENABLED=true` 启动 local-path-provisioner 才能创建 PVC),可改为其他 SC(如 Ceph CSI)。
- **镜像命名**:`<namespace>/<image>:<tag>` 组织成仓库一级目录(如 `dev/`、`prod/`),与 docker.io 习惯一致。
- **跨网段 worker 拉镜像**:走集群内解析(→VIP),勿指向宿主机 DNAT 入口。

### 5.8.2 NTP 时间同步(09_k8s_ntp / setup-ntp.sh)—— 部署 k8s 前保证节点时钟一致

kubeadm / etcd 对节点间时钟偏差敏感,若节点时间不一致会导致证书校验、心跳、日志时间线等故障。`modules/02_k8s/05_k8s_ntp.sh` 位于 k8s 阶段**部署模块之前**,为默认启用的可重复模块,一键部署与扩容时自动执行。

原理与机制:

- **权威时间源 = 第一个 master(默认)**:`setup-ntp.sh` 在首 master 配置 chrony 服务端(`local stratum 10`,无公网上游时以本机时钟兜底,离线友好);**不再用宿主机(installer 节点)作权威** —— 部署机可能在 NAT 后/跨网段,节点无法可靠访问。`NTP_SERVER` 显式指定时为首 master 之外的权威服务器(此时首 master 作为普通客户端)。
- **单节点集群(仅 1 master + 0 worker)**:无跨节点时间同步需求,**自动跳过 NTP**。
- **节点客户端**:
  - VM 节点(黄金镜像已预装 chrony)→ 改写 `/etc/chrony/chrony.conf` 为 `server <权威> iburst`,禁用冲突的 systemd-timesyncd,强制步进;
  - 裸金属 worker(离线仓无 chrony 包)→ 用系统自带 `systemd-timesyncd` 指向权威。
- **一次性硬对齐**:应用时对偏差 >1s 的节点用 `date -s @权威epoch` 直接校时(经 SSH 通道传递,即使 NTP 传输失败也保证部署时刻一致)。
- **校验门禁**:全节点与权威(首 master/NTP_SERVER)偏差 ≤ `NTP_MAX_OFFSET_MS`(`2000`ms 默认);超限本步 `exit 1`,部署在 kubespray **之前中止**,避免带病上集群。

用法:

```bash
sudo ./scripts/tools/node/setup-ntp.sh            # apply: 首master chrony 服务端 + 节点客户端 + 硬对齐 + 校验(幂等)
sudo ./scripts/tools/node/setup-ntp.sh --check    # 仅校验各节点时钟偏差(零写入)
sudo ./scripts/tools/node/setup-ntp.sh --delete   # 关闭节点时间同步服务(幂等)
sudo ./scripts/deploy-cluster.sh --only worker02   # 仅处理指定节点(框架 --only 透传)
```

关键配置(`cluster.conf`):

```bash
NTP_ENABLED="${NTP_ENABLED:-1}"                       # 0=跳过时间同步(不推荐)
NTP_SERVER="${NTP_SERVER:-}"                          # 权威时间源 IP; 留空=第一个 master 为权威
NTP_UPSTREAM="${NTP_UPSTREAM:-}"                      # 权威(首 master)的公网上游(如 "pool ntp.aliyun.com iburst"); 留空=离线
NTP_ALLOW="${NTP_ALLOW:-}"                            # 权威 chrony allow 子网; 默认空=仅本机(多子网节点填 "10.66.1.0/24")
NTP_MAX_OFFSET_MS="${NTP_MAX_OFFSET_MS:-2000}"        # 节点-权威偏差阈值(ms); 超限→中止 k8s 部署
```

>> 离线排障要点:
> - 首 master 没有 chrony 且无法 apt 安装(离线)→ 脚本降级以该节点本机时钟为权威,仍做一次性 `date` 硬对齐 + 校验,仅 warn。
> - 裸金属 worker 无 chrony → 自动用 `systemd-timesyncd`;若无法到达权威 UDP/123,会靠一次性硬对齐保证部署时刻一致,并显示偏差告警。
> - 若节点启用 ufw/iptables,需放行 `udp/123`(chrony server 端口)。
> - 新 VM 从黄金镜像快照出来时,时钟停在镜像制作时间 → apply 步骤的硬对齐 + `makestep` 会自动修正,校验不通过会中止部署提示修复。
> - 时间同步只校时钟,不修改时区(VM 已默认 Asia/Shanghai)。

### 5.9 register-vm.sh —— 注册已存在 VM

VM 已通过其他方式创建时,用此脚本将其注册到 `cluster.conf` 的 NODES:

```bash
./scripts/tools/vm/register-vm.sh <role> <hostname> <ip> <mac> <mem> <cpu> <disk> [user] [password]
./scripts/tools/vm/register-vm.sh worker cubestack-k8s-worker01 10.244.1.21 52:54:00:aa:bb:21 16 8 50
```

幂等(已存在则跳过),内部复用 `lib-common.sh` 的 `register_node_to_conf()`(awk 实现)。

### 5.10 install-worker-packages.sh —— 离线包安装到裸机 worker

bare-metal worker(Ubuntu)无法联网时,用 offline-files 中的离线 `.deb` 包安装 kubespray 所需系统包:

```bash
./scripts/tools/node/install-worker-packages.sh <IP> [user]
./scripts/tools/node/install-worker-packages.sh 10.66.1.232 ubuntu
```

包来源: `deployments/offline-files/kubespray/cubestack-cluster/`(由 `OFFLINE_FILES_DIR` 全局变量指定)下的 `.deb` 文件(仓库根目录,与 kubeadm/etcd 等二进制同层)或 `packages/` 子目录,脚本自动收集两者并去重。包含 iputils-ping / rsync / iptables / curl / ca-certificates 及依赖。

### 5.11 fetch-offline-from-minio.sh —— 从 MinIO 拉取离线文件

部署机/新机器缺离线文件时,从 MinIO 下载(**默认拉取部署必需子目录**: kubespray/metax-gpu/lws/os/envoy 等,**排除 virtual-machine** 虚拟机镜像;需要时可 `--sub virtual-machine` 按需拉 VM 镜像,或 `--all` 真正全量)。

**默认下载目录: `/opt/cubestack-installer/deployments/offline-files`(即 `OFFLINE_FILES_DIR` 根)**:
- 在 CLI 容器内执行:下载直接落到容器挂载的 offline-files(宿主机大磁盘),**即装即用**;
- 宿主机直跑本仓库:默认同一路径;想用大磁盘时 `--auto` 自动挑空闲 ≥ 门槛的最大挂载点。

脚本默认开启**磁盘空间检查**:醒目横幅提示至少需要 `MIN_FREE_GB`(默认 **50 GiB**)空闲空间,并比对本次下载所需(远程大小 + 缓冲)与目标可用空间,不足则中止(`--force` 强制继续)。

```bash
./scripts/tools/offline/fetch-offline-from-minio.sh            # 默认: 下载部署必需子目录(排除 virtual-machine)
./scripts/tools/offline/fetch-offline-from-minio.sh --sub virtual-machine  # 按需拉 VM 镜像(仅创建虚拟机时)
./scripts/tools/offline/fetch-offline-from-minio.sh --all      # 真正全量(含 virtual-machine)
./scripts/tools/offline/fetch-offline-from-minio.sh --sub kubespray     # 只拉某子目录(如 kubespray)
./scripts/tools/offline/fetch-offline-from-minio.sh --dest /data/offline-files   # 指定下载目录(即 offline-files 根)
sudo ./scripts/tools/offline/fetch-offline-from-minio.sh --auto       # 宿主机: 自动挑空闲 ≥ 门槛的最大磁盘
./scripts/tools/offline/fetch-offline-from-minio.sh --list      # 只列出 MinIO 可用目录
```

- **mc 检测**:未安装时给出安装指引,可选择自动下载(MinIO 官方二进制,与 Dockerfile-cli 同源);alias 优先用 cluster.conf 的 `MINIO_*` 自动配置,否则探测本机已有 alias,再否则交互录入。
- **桶/目录自适应**:默认桶 `cubestack-installer`、目录 `offline-files`(与 MinIO 实际布局一致),自动回退探测旧布局 `cubestack-offline/kubespray`。
- **子目录排除(默认开启)**:`DEFAULT_EXCLUDE_SUBS`(默认 `virtual-machine`, 体积大且仅创建 VM 时用)在默认/`--all` 下载时自动跳过;`--sub <目录>` 不受排除限制。
- **磁盘空间检查(默认开启)**:醒目提示至少 `MIN_FREE_GB`(默认 50 GiB)空闲;比对本次下载所需(远程大小 + 缓冲)与目标可用空间,不足时红色横幅警告并中止(`--force` 强制继续)。
- **下载后提示**:容器内直接 `cd /opt/cubestack-installer && ./deployments/scripts/deploy-cluster.sh`;宿主机下载到 `<下载目录>` 后,把该目录挂进容器 offline-files(见 §1 快速开始),或 `export OFFLINE_FILES_DIR=<下载目录>` 直跑。

### 5.12 sync-to-minio.sh —— 本地 offline-files 全量镜像同步到 MinIO

源机器把本地 `offline-files` 的**所有子目录**(envoy/kubespray/lws/metax-gpu/os/virtual-machine ...)整体镜像到 MinIO 的 `<桶>/offline-files/`(远端目录结构与本地完全一致),供各部署机 `fetch-offline-from-minio.sh` 拉取(下载侧不变)。等价于 `mc mirror --overwrite ./offline-files/ minio/cubestack-installer/offline-files/`:

```bash
./scripts/tools/offline/sync-to-minio.sh               # 增量同步(默认 mc mirror --overwrite, 自动发现新增/变更文件)
./scripts/tools/offline/sync-to-minio.sh --prune       # 同步 + 删除远端多余文件(与本地严格一致; 远端其他集群共享时勿用)
./scripts/tools/offline/sync-to-minio.sh --dry-run     # 仅预览(不实际同步)
```

- **MinIO 配置**:已有 `minio` mc alias 优先复用;否则用 cluster.conf 的 `MINIO_*`(endpoint/ak/sk)自动配置;都没有则报错给指引(不再探测/交互)。
- **桶/目录**:默认 `cubestack-installer` / `offline-files`(可 `MINIO_BUCKET` / `MINIO_REMOTE_DIR` 覆盖),桶不存在自动创建。
- **可读性预检**:mc mirror 对不可读文件(如 root 属主 0600 的 docker-save tar)会**静默跳过**;同步前先全量扫描,发现不可读文件即报错给指引(`sudo chmod -R a+r <源>` 或 `sudo ./sync-to-minio.sh`),避免部分目录未同步却报"同步完成"。
- **--prune(谨慎)**:等价 `mc mirror --remove`,把远端本地没有的文件一并删除 —— 多集群共用同一 MinIO 桶时慎用。

### 5.13 trim-offline-files.sh —— 清理 offline-files 冗余(只留部署必需)

kubespray/metax-gpu 离线目录由下载命令生成全量清单,含大量本部署用不到的镜像与二进制:

- **kubespray/images**:未匹配 `PRELOAD_IMAGE_PATTERNS`(calico/etcd/kube-*/coredns/metallb 等白名单)的镜像 tar(cilium/flannel/weave/arm64 等);
- **kubespray 根下二进制**:非 containerd 运行时(cilium/cri-o/gvisor/kata/youki/crun/nerdctl/cri-dockerd);
- **metax-gpu**:非当前 `METAX_VERSION`/非 amd64/非本部署组件(operator-bundle/catalog)的镜像 tar。

```bash
sudo ./scripts/tools/offline/trim-offline-files.sh --dry-run    # 仅预览将删除项(推荐先跑)
sudo ./scripts/tools/offline/trim-offline-files.sh              # 实际清理
```

> ⚠ 删除前先备份 offline-files;未来启用新 addon/切换架构/版本时需重新下载或从 MinIO 恢复。

清理后配合 `sync-to-minio.sh` 把精简结果同步回 MinIO,MinIO 侧只存部署必需文件。

### 5.14 容器化部署(补充说明)

宿主机不想装工具链时的完整流程见 **§1 快速开始**(pull → run → exec → fetch → config → deploy)。本节补充:

- **`--network host` 必须**:容器内 ssh 直连节点/集群/registry(默认桥接网段无法访问)。
- **创建虚拟机(依赖宿主机 libvirt)**:加 `--privileged` 或挂载 `/var/run/libvirt`;纯裸金属离线部署无需额外特权。
- **后台运行 + `docker exec`**(非交互式启动):`sudo docker run -itd --name cubestack-install --network host ...` 后 `sudo docker exec -it cubestack-install bash`(见 §1 步骤③④)。
- **离线文件不下载进容器**:离线镜像/二进制不入镜像,由挂载目录共享 —— 容器内 `fetch-offline-from-minio.sh` 下载即落宿主机大磁盘,多集群/换环境复用。
- 根 `README.md` §十四 还有镜像构建(`build-cli-context.sh`)与挂载参数说明。

### 5.15 envoy-load-images.sh —— 预加载 envoy 镜像到集群内置 registry

把 `envoy-save-images.sh` 生成的离线镜像 tar 批量推送到**集群内置 registry**(幂等, 已存在则跳过)。
09/10 部署模块(envoy_gateway / envoy_ai_gateway)部署时也会自动推送; 本脚本用于**独立预加载**
(如先推镜像再装 chart、或补齐某次推送失败缺的镜像)。

```bash
sudo ./scripts/tools/images/envoy-load-images.sh                # tar 目录缺省 = ENVOY_SAVE_DIR
sudo ENVOY_EG_VERSION=v1.9.1 ./scripts/tools/images/envoy-load-images.sh /path/to/envoy-tars
```

**推送目标(与 09/10 模块 helm `--set` 一致)**:

| tar | 推送目标 |
|---|---|
| `*gateway_${ENVOY_EG_VERSION}.tar` | `registry.local:5000/envoyproxy/gateway:${ENVOY_EG_VERSION}` |
| `*envoy_${ENVOY_EG_VERSION}.tar` | `registry.local:5000/envoyproxy/envoy:${ENVOY_EG_VERSION}` |
| `*ai-gateway-controller*.tar` | `registry.local:5000/ai-gateway/ai-gateway-controller:${ENVOY_AI_IMAGE_TAG}` |

- 纯离线(不联网): tar 内容经 `skopeo docker-archive → docker://` 推送, 3 次重试; 需本机装 `skopeo`。
- **nodeport 模式**(无 MetalLB): 用 `ENVOY_PUSH_ENDPOINT=<节点IP>:${REGISTRY_NODEPORT}` 覆盖推送入口。
- 依赖: 集群内置 registry 已部署(`deploy-registry.sh` / `22_verify_registry_storage` 校验)。

---

## 6. 环境变量覆盖(示例)

```bash
# 网络方案切换
VM_NET_MODE=bridge ./scripts/tools/vm/create-libvirt-vm.sh ...     # 覆盖 NET_MODE
# 单次指定密码 / 密钥
SSH_DEFAULT_PASSWORD='xxx' ./scripts/tools/node/setup-passwordless.sh 10.244.1.11
# 指定配置文件
CLUSTER_CONF=/path/to/cluster.conf sudo ./scripts/deploy-cluster.sh --list
```

---

## 7. 常见问题

- **`net.ipv4.route_localnet` 设置失败(No such file)** — 老内核无此参数,本方案不依赖,脚本已自动跳过并仅告警,可忽略。
- **worker 连通性检查失败** — 需在 `config/cluster.conf` 配置 `SSH_DEFAULT_PASSWORD`(或 NODES 第5字段节点独立密码),脚本才用密码测试连通。
- **创建 VM 报"网桥不存在"** — 先 `sudo ./scripts/tools/net/setup-vm-network.sh`,或 `AUTO_SETUP_NET=1` 自动建。
- **kubespray 部署** — `--with-k8s` 需宿主机已装 `ansible-playbook` 且 `KUBESPRAY_DIR` 指向完整 kubespray 仓库(含 `cluster.yml` 与 `group_vars`)。
- **离线部署 kube-proxy 报 ImagePullBackOff** — 需先预加载离线镜像到节点 containerd(见第 8 节,`cubestack-offline.sh scale` 已内置此逻辑)。
- **部署中止在 ntp 模块(时钟偏差超限)** — `NTP_MAX_OFFSET_MS` 超限说明某节点与权威时钟偏差过大(如新 VM 从快照出来、NTP 端口被防火墙挡),应先修复时间源/网络后重跑 `setup-ntp.sh` 或整个部署;该门禁是为避免 etcd/kubeadm 时间敏感故障。
- **节点时间不收敛 / chrony 无输出** — 检查权威(首 master/`NTP_SERVER`)是否在 **udp/123** 监听且 `NTP_ALLOW` 覆盖了节点子网;裸金属 worker 走 `systemd-timesyncd` 时确认能到达权威服务器(如跨网段路由)。
- **只查不改** — `sudo ./scripts/tools/node/setup-ntp.sh --check` 只校验零写入;`--delete` 可整体关闭节点时间同步(不建议)。

---

## 8. 从 0 到 1:离线部署 kubespray 集群

完整流程(全部通过脚本自动完成,无人工干预):

### 8.1 前置条件

**前置条件(宿主机 / 部署机)**:Ubuntu 22.04 + Docker(CLI 容器方式, 见 §1)或已装 `ansible-playbook / skopeo / mc / sshpass / virsh`(宿主机直跑);以下以宿主机直跑为例。

### 8.2 配置(cluster.conf 为唯一数据源)

```bash
cp config/cluster.conf.example config/cluster.conf
# 修改(必改): SSH_DEFAULT_PASSWORD / NODES(每行一个节点)/ METALLB_POOL
vim config/cluster.conf
```

节点格式(5字段, 不区分虚拟机/裸金属):`role,hostname,ip,ssh_user,ssh_password`(密码 `-` = 默认 `SSH_DEFAULT_PASSWORD`);
需要创建虚拟机的节点在 `tools/vm/vm-nodes.conf`(10字段, 含 mac/内存/CPU/磁盘)定义, 创建后自动注入 NODES。

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
# 全流程: 宿主网络 → SSH密钥 → master/worker VM 创建+注册 → 免密 → inventory → 时间同步 → kubespray 离线部署
sudo ./scripts/deploy-cluster.sh --with-k8s
```

该命令自动完成:
1. `setup-vm-network.sh` 初始化 privbr0 网桥 + SNAT
2. `gen-ssh-key.sh` 生成 SSH 密钥
3. 按 NODES 创建 master/worker 虚拟机(基础镜像已由 `create-vm-template.sh` 预制 kubespray 所需包, 创建 VM 不安装任何组件, 离线环境安全)
4. `setup-passwordless.sh` 注入公钥
5. 对 worker 执行 `install-worker-packages.sh` 安装离线包
6. `gen-inventory.sh` + `sync-kubespray-config.sh` 生成 inventory 与配置
7. `setup-ntp.sh`(modules/02_k8s/05_k8s_ntp)同步各节点时间到权威(首 master), 校验偏差 ≤ `NTP_MAX_OFFSET_MS`(在 kubespray 之前)
8. `cubestack-offline.sh install` 执行 kubespray 离线部署

### 8.4 分步部署(可精细控制)

```bash
# ① 初始化宿主网络(bridge 方案)
sudo ./scripts/tools/net/setup-vm-network.sh

# ② 生成 SSH 密钥
./scripts/tools/node/gen-ssh-key.sh

# ③ 创建 master VM(3 台)+ 注册到 cluster.conf + 免密
sudo AUTO_REGISTER_CLUSTER=1 ./scripts/tools/vm/create-libvirt-vm.sh cubestack-k8s-master01 16 8 50 52:54:00:3b:e9:d2 10.244.1.11
SSH_DEFAULT_PASSWORD='CHANGE_ME' ./scripts/tools/node/setup-passwordless.sh 10.244.1.11 ubuntu   # CHANGE_ME 替换为真实密码
# ... 重复 master02 / master03 ...

# ④ 生成 inventory + 同步 kubespray 配置
INV_ROLES=master ./scripts/tools/k8s/gen-inventory.sh        # 先只生成 master

# ⑤ 离线部署 kubespray(先下载离线资源,再安装)
cd deployments/kubespray
CUBESTACK_INVENTORY_DIR=$PWD/inventory/cubestack-cluster \
CUBESTACK_LOCAL_REPO_DIR=$PWD/../offline-files/kubespray/cubestack-cluster \
CUBESTACK_KUBESPRAY_DIR=$PWD/kubespray \
  bash cubestack-offline.sh install
```

### 8.5 扩容(新增 worker 节点)

```bash
# ① 创建 worker VM + 注册(或编辑 cluster.conf NODES 追加 worker 行)
sudo AUTO_REGISTER_CLUSTER=1 ./scripts/tools/vm/create-libvirt-vm.sh cubestack-k8s-worker01 16 8 50 52:54:00:aa:bb:21 10.244.1.21
SSH_DEFAULT_PASSWORD='CHANGE_ME' ./scripts/tools/node/setup-passwordless.sh 10.244.1.21 ubuntu   # CHANGE_ME 替换为真实密码

# ② 生成含新 worker 的 inventory(排除跨网段节点可加 INV_EXCLUDE)
./scripts/tools/k8s/gen-inventory.sh

# ③ 扩容: 预加载镜像到 worker → 执行 scale.yml
cd deployments/kubespray
CUBESTACK_INVENTORY_DIR=$PWD/inventory/cubestack-cluster \
CUBESTACK_LOCAL_REPO_DIR=$PWD/../offline-files/kubespray/cubestack-cluster \
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
./scripts/tools/node/install-worker-packages.sh <workerIP> ubuntu

# ③ 加入 inventory 后扩容
#    注意: worker 通过宿主机 IP:6443(DNAT)访问 API Server,需确保 /etc/hosts 与证书 SAN 配置正确(见 5.8)
./scripts/tools/k8s/gen-inventory.sh
bash deployments/kubespray/cubestack-offline.sh scale --limit kube_node
```

### 8.7 全裸金属集群(无虚拟机)

master 和 worker 全部为裸金属服务器(同网段互通),无需创建 VM 和 VM 网桥网络。

**配置要点**:
- `cluster.conf` 的 NODES 直接填节点(5字段); **不**在 `tools/vm/vm-nodes.conf` 定义任何节点(无 VM)
- 网络模式 `NET_MODE=bridge`(同网段互通,无需 SNAT); VM 相关变量已随 vm-nodes.conf 独立, cluster.conf 无需再删改
- SSH 密码需配置正确(`SSH_DEFAULT_PASSWORD`; 节点密码不同时用 NODES 第5字段独立密码)

**部署命令**:
```bash
# 查看集群规划
sudo ./deployments/scripts/deploy-cluster.sh --list

# 一键部署(默认 = --with-cubestack)
sudo ./deployments/scripts/deploy-cluster.sh
```

宿主网络初始化(VM 网桥/NAT)由 `tools/vm/create-vms.sh` 在创建虚拟机前自动执行(有 VM 定义时才初始化,已存在的网桥/网络幂等跳过);纯裸金属集群无需初始化。
vm-nodes.conf 无节点时不执行任何虚拟机创建(主程序默认不调度 vm_create / vm_network)。
