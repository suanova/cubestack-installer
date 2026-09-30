# CubeStack 平台底座 · 生产环境配置指南

> **适用对象**:交付工程师 / 客户运维 / 平台二次开发者
> **适用底座版本**:Kubernetes **v1.35.8**(kubespray v2.32 线)· Rook-Ceph **v1.20.2** · MetalLB **v0.13.9** · containerd **2.3.5**
> **编写依据**:本仓库部署代码 + 一套真实生产集群(8 节点:3 control-plane + 5 worker)的**现场取证**(2026-09-29)
> **约定**:文中标注 **【实机】** 的结论来自上述真集群的实测输出;标注 **【代码】** 的来自仓库实现;两者冲突时以【实机】为准并请回报。所有配置键的**唯一权威来源**是 `deployments/config/cluster.conf`(模板见 `cluster.conf.example`)。

---

## 0. 一页速览

### 0.1 平台底座能力与开关

| 能力 | 开关(`cluster.conf`) | 默认 | 详见 |
|---|---|---|---|
| 集群基座(CNI/etcd/apiserver/控制面) | `K8S_ENABLED` | 关(需显式开) | §1.1 |
| 控制面高可用 · 节点侧本地代理 | `API_LOCAL_LB_ENABLED` | **开** | §1.2 |
| 控制面高可用 · 外部浮动 VIP | `KUBE_VIP_ENABLED` + `K8S_API_VIP` | **关**(需显式开) | §1.2 / §2.3 |
| 对外负载均衡(LB Service) | `METALLB_ENABLED` + `METALLB_POOL` | 开 | §2.1 |
| 服务暴露方式 | `SERVICE_EXPOSE_MODE` | `nodePort`(生产建议 `metallb`) | §2.2 |
| 分布式存储(Rook-Ceph) | `CEPH_ENABLED` / `CEPH_CSI_ENABLED` | 关(需显式开) | §3.1 |
| 块存储 / 文件存储 / 对象存储(S3) | `CEPH_CSI_ENABLED` / `CEPHFS_ENABLED` / `CEPH_RGW_ENABLED` | 随 `CEPH_CSI_ENABLED` | §3.2–§3.4 |
| 接入**外部已有** Ceph 集群 | `CEPH_MODE=external` + `external-ceph.env` | `internal` | §3.5 |
| RDMA 共享设备插件(IB/RoCE) | `RDMA_ENABLED` | **开** | §4 |
| 沐曦(MetaX)GPU Operator | `GPU_OPERATOR_ENABLED` | **开** | §5 |
| GPU 上层的 LLM 工作负载调度 | `LWS_ENABLED`(默认关) | 关 | §5.5 |

### 0.2 本指南覆盖的 5 个"怎么配"

1. **架构长什么样**、控制面高可用怎么实现的、Ceph 集群怎么组网 → §1
2. **怎么开 MetalLB / kube-vip**、VIP 怎么配 → §2
3. **怎么部署 Ceph**、怎么接入**外部** Ceph → §3
4. **默认用哪个 StorageClass**、怎么用 S3 → §3.2 / §3.4
5. **怎么接 RDMA**、**怎么用 GPU** → §4 / §5

### 0.3 部署入口(先知道这个)

所有能力都由**同一套模块化脚本**调度,入口是:

```bash
# 全量部署(按 cluster.conf 里的开关决定装什么)
./deployments/scripts/deploy-cluster.sh

# 只跑某一个能力(不覆盖已有组件; 依赖会自动补齐或跳过)
./deployments/scripts/deploy-cluster.sh --steps ceph
./deployments/scripts/deploy-cluster.sh --steps ceph_csi,rdma_shared_dev_plugin

# 看计划(跑之前先看清会做什么)
./deployments/scripts/deploy-cluster.sh --list-steps
```

> ⚠ **默认全量运行 = 覆盖安装**(不覆盖其它组件的既有部署,但会重跑所有启用模块);
> 只想动某一个组件时,一律用 `--steps <模块名>`。

**在哪执行**:平台以"部署容器(CLI 镜像)"方式交付时,**所有命令都在容器里跑**——容器里才有 kubespray 树、离线资产与预装工具链:

```bash
docker exec -it cubestack-install-a bash        # 进入部署环境(容器名以现场为准)
cd /opt/cubestack-installer 2>/dev/null || cd <部署根>
kubectl get nodes                                # 容器内已配好集群访问
```
裸机路径则直接在部署机上执行(注意 `ansible` 需要 Python ≥3.11,见 `docs/kubespray-upgrade.md`)。

---

## 1. 平台架构

### 1.1 分层总览

```
┌──────────────────────────────────────────────────────────────────────────┐
│  业务/平台应用        GPU 推理 · LLM 调度(LWS/Kueue) · 自研模块(20_cubestack_apps) │
├──────────────────────────────────────────────────────────────────────────┤
│  Operator / Addon     沐曦 GPU Operator · Rook-Ceph(CSI) · MetalLB ·       │
│                       Multus · RDMA Device Plugin · registry · netshoot   │
├──────────────────────────────────────────────────────────────────────────┤
│  K8s 基座(kubespray)  kube-apiserver×3 · etcd×3 · Calico(IPIP) ·          │
│   【实机 v1.35.8】      CoreDNS · kube-proxy(ipvs) · 本地代理 · kube-vip    │
├──────────────────────────────────────────────────────────────────────────┤
│  宿主机(Ubuntu 22.04)  SSH 免密 · NTP · 系统包对账 · 磁盘/网络前置          │
└──────────────────────────────────────────────────────────────────────────┘
```

部署脚本按 `PHASE` 分三段执行,模块间用 `REQUIRES` 声明定序(不是靠文件名序号):

| 段 | 模块 | 说明 |
|---|---|---|
| `env` | `vm_network` · `vm_sshkey` · `vm_create` · `harbor` · `lb_haproxy` · `lb_keepalived` | 宿主机与外部 LB 的**前置准备**(虚拟机场景才需要;裸金属一般只用到 SSH 密钥) |
| `k8s` | `k8s_passwordless` → `k8s_workerbm` → `k8s_hosts` → `k8s_inventory` → `k8s_ntp` → **`k8s_deploy`** → `kube_vip` → `api_local_lb` → `k8s_scale` + 两个 verify | 集群基座与 API 入口 |
| `addon` | `metallb` → `ceph` → `ceph_csi` → `local_path` → `registry` → `gpu_operator` → `rdma_shared_dev_plugin` → … + 各 verify | 集群能力与 operator |

**两个易错点**(【代码】有护栏,但要知道):

- **`k8s_deploy` 是基座**:其余 `k8s`/`addon` 模块几乎都 `REQUIRES: k8s_deploy`。单独跑 `--steps` 时,基座若没跑过会被自动剔除并报错。
- **`K8S_ENABLED` 默认是关的**:不做 `--with-k8s` / 不开这个开关,集群不会被创建;而 addon 模块会因为"集群不存在"失败。

### 1.2 控制面高可用方案(三层,互补而非二选一)

生产环境的 API 入口必须解决三个不同层面的问题,本平台的做法是**三层各管一段**:

```
   外部/管理客户端                    集群内 Pod                     节点上的 kubelet
   (kubectl/CI/监控)                (CoreDNS/业务 Pod)            (每台 worker/master)
        │                                 │                              │
        │ ① 域名 → VIP                    │ ② Service ClusterIP          │ ③ 本机 127.0.0.1:6443
        ▼                                 ▼                              ▼
   ┌─────────┐                      ┌──────────┐                  ┌───────────────┐
   │ kube-vip│ 浮动 VIP(ARP 选举)   │ kube-proxy│ ipvs 轮询 3 台    │ nginx-proxy   │
   │ 静态 Pod │ 挂在某台 master      │  ipvs    │                  │ 本地代理静态 Pod│
   └────┬────┘                      └────┬─────┘                  └───────┬───────┘
        └───────────────┬────────────────┴────────────┬───────────────────┘
                        ▼                             ▼
                 [ master-1 ]                   [ master-2 ]  [ master-3 ]
                  三个 kube-apiserver + 三个 etcd 成员(数据面本身是 HA 的)
```

| 层 | 组件 | 解决什么 | 开关 | 【实机】证据(本环境) |
|---|---|---|---|---|
| ① 外部侧 | **kube-vip** 静态 Pod(每台 master 一个,租约选举出一台持有 VIP) | 给"人/CI/外部系统"一个**不随 master 增减变化的稳定地址** | `KUBE_VIP_ENABLED=true` + `K8S_API_VIP` | 3 台 master 均有 `/etc/kubernetes/manifests/kube-vip.yml`,`address=10.66.3.239`,持有者 `mxgpu-3-28`,`vip_arp=True` |
| ② 集群内 | kube-proxy **ipvs** | Pod → `kubernetes.default.svc` 轮询 3 台 apiserver | 无需配置(ipvs 默认) | `kubectl get endpoints kubernetes` = `10.66.3.28/29/31:6443` 三条 |
| ③ 节点侧 | **本地代理** nginx-proxy 静态 Pod(每台节点) | kubelet/kube-proxy 走**本机** `127.0.0.1:6443`,不再依赖某一台具体 master | `API_LOCAL_LB_ENABLED=true` | 各节点有 `nginx-proxy.yml`;worker 的 `kubelet.conf` = `https://localhost:6443` |

**为什么三层都要**:① 只覆盖外部客户端;kubelet 走的是 kubeconfig 里的地址,如果不做 ③,某个 master 挂掉会让**指向它的节点**失联;kube-proxy 的 ipvs 只管**集群内 Service**,管不到节点上的 kubelet。【代码】`10_api_local_lb.sh` + `09_kube_vip.sh` + kubespray 原生 ipvs 共同构成。

#### 入口模式(唯一来源,三选一,冲突即硬失败)

```
API_EXTERNAL_ADDR 非空 ───────────────→ external(复用环境已有 LB/VIP)
        │
        └ KUBE_VIP_ENABLED=true ──────→ vip(kube-vip 浮动 VIP)
                 │
                 └ 以上都没有 ────────→ node(入口 = 第一台 master,外部入口无 HA)
```

| 模式 | 触发条件 | 外部入口 | 节点侧 |
|---|---|---|---|
| `external` | `API_EXTERNAL_ADDR=10.x.x.x`(环境已有 F5/LVS/云 LB) | 复用既有 LB | 本地代理仍生效 |
| `vip` | `KUBE_VIP_ENABLED=true`(±`K8S_API_VIP`) | kube-vip 浮动 VIP | 本地代理仍生效 |
| `node` | 都不设(默认) | **第一台 master(单点)** | 本地代理仍生效 |

> ⚠ **互斥是硬失败,不是警告**:`API_EXTERNAL_ADDR` 与 `KUBE_VIP_ENABLED=true` 同时给、
> 或 `KUBE_VIP_ENABLED=true` 与 `HAPROXY_ENABLED`/`KEEPALIVED_ENABLED` 同时给,部署会**在入口校验处直接停住**。
> 理由:三者都在争"入口地址"的解释权,同时开是确定性配置冲突。

#### 入口地址如何被全网感知(域名 + `/etc/hosts`)

全平台统一用一个**域名**做入口:`k8s-api.cubestack.io`(可在 `cluster.conf` 改 `API_DOMAIN`)。所有 kubeconfig 用的都是这个域名,**切换入口不需要改任何 kubeconfig,只改域名解析指向**:

```
kubelet / kube-proxy / kubectl / CI  →  https://k8s-api.cubestack.io:6443
                                              │
        ┌─────────────────────────────────────┴─────────────────────────────┐
        ▼                                    ▼                              ▼
  节点 /etc/hosts                    部署机(容器) /etc/hosts          外部客户端 DNS(可选)
  (由本平台模块收敛;                 (每轮安装由 sync_kubeconfig         (由客户 DNS 指向 VIP
   值 = 当前入口地址)                 收敛为当前入口地址)                 或外部 LB 地址)
```

- **证书 SAN 免费获得**:`kube_vip_address` 一非空就会自动进 apiserver 证书 SAN(`control-plane/tasks/kubeadm-setup.yml`),不需要单独申请证书;`supplementary_addresses_in_ssl_keys` 里还有三台 master 的 IP。

```bash
# 【实机】证据:入口域名 + 三台 master IP + VIP 都在证书 SAN 里
$ ssh <master> "sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text" | grep -A2 'Subject Alternative'
                DNS:k8s-api.cubestack.io
 IP Address:10.66.3.28      IP Address:10.66.3.29      IP Address:10.66.3.31
 IP Address:10.66.3.239     ← VIP 也在(所以换 VIP 必须重签/重装)

# 【实机】节点侧本地代理的 upstream = 三台 master(least_conn,1s 超时)
$ ssh <worker> "sudo grep -A5 upstream /etc/nginx/nginx.conf"
  upstream kube_apiserver {
    least_conn;
    server 10.66.3.28:6443;
    server 10.66.3.29:6443;
    server 10.66.3.31:6443;
    }
```
- ⚠ **改 VIP 必须重装集群**:证书 SAN 在 `kubeadm init` 时固化,存量集群的 SAN 只含旧 VIP。
- ⚠ **部署宿主机的 `/etc/hosts` 不跟随**:平台只收敛**节点**与**部署脚本运行环境**(部署容器)两份;宿主机自己那份要手工跑 `tools/node/sync-hosts.sh`。

### 1.3 Ceph 存储架构(内部模式)

```
                    ┌───────────────── Rook Operator(v1.20.2)─────────────────┐
                    │  监听 CephCluster CR,自动编排 mon/mgr/osd/mds/rgw      │
                    └───────────────────────────┬────────────────────────────┘
                                                ▼
   ┌───────────────────────── CephCluster: rook-ceph ─────────────────────────┐
   │  mon ×3(奇数,分布在 3 台 master)   mgr ×2(active+standby)              │
   │  OSD ×N(每块裸盘一个 OSD)          crashcollector(每节点)                │
   │  故障域 failureDomain=host(整机宕机不丢数据)                             │
   └───────┬──────────────────────────┬─────────────────────────┬─────────────┘
           ▼                          ▼                         ▼
     CephBlockPool rbd-pool     CephFilesystem cephfs      CephObjectStore s3-store
     (Replicated, 3 副本,       (+ cubestack-ext-fs,        (RGW,S3 网关)
      min_size=2)                对外接入用)
           │                          │                         │
           ▼                          ▼                         ▼
   StorageClass(RBD CSI)      StorageClass(CephFS CSI)   S3 endpoint(内部 svc)
   ceph-rbd-ephemeral(默认)    cephfs-ephemeral           或对外暴露地址
   ceph-block / ceph-rbd-durable   cephfs-durable
```

**【实机】本环境现状**(2026-09-29 取证,`CEPH_NODES` 未指定、`CEPH_NODE_ROLE=master`、`CEPH_MON_COUNT=3`):

| 项 | 实测值 |
|---|---|
| 集群健康 | `cephcluster/rook-ceph` → `HEALTH_OK`,fsid `85b76591-…`(全新安装) |
| mon / mgr | 3 / 2 |
| OSD | **9 个**(每台 master 3 块 NVMe,单盘 6.98 TB;3 台存储节点各 20.96 TB) |
| 池 | `rbd-pool`(Replicated,**failureDomain=host**,副本 3 / min_size 2) |
| 文件系统 | `cephfs`(2 MDS)+ `cubestack-ext-fs`(1 MDS,供**外部客户端**接入) |
| 对象存储 | `s3-store`(RGW,Phase=Ready) |
| CSI | `ceph-csi-controller-manager` 1/1;RBD / CephFS node plugin 各 8/8 |

**关键设计取舍**(为什么这么组网):

- **OSD 用裸盘直挂**:每块盘一个 OSD(不做 RAID),副本交给 Ceph。**磁盘选择是自动的**(见 §3.1),且"整盘 LVM/已有文件系统"的盘会被判为**在用**而不碰。
- **全部 Ceph 守护进程只跑在存储节点上**(默认 = 3 台 master):mon/osd/mgr 由 `CephCluster.placement` 约束,**mds/rgw 由各自 CR 的 placement 约束**(`CephFilesystem.metadataServer` / `CephObjectStore.gateway`),都靠节点标签 `ceph-storage=rook-ceph`(`CEPH_NODE_LABEL`)选点。⚠ **唯一例外是 CSI nodeplugin** —— 它必须跑在每个可能挂 Ceph 卷的节点(含 worker),这是设计使然,不要试图约束它。
- **mon 必须在 3 台不同主机上**(`mon.count=3` + `failureDomain=host`):单机宕机仍能满足 `min_size=2` 继续写。
- **数据面默认 host-network**:Ceph 的 mon/osd 通信走节点网络(O 卡/NVMe 性能优先),见 `CEPH_HOST_NETWORK`。
- **CSI 与 Rook 分离成两个模块**(`02_ceph` / `03_ceph_csi`):前者管集群,后者管"池 + StorageClass + 可选 FS/RGW",便于单独演进。

### 1.4 网络底座(与暴露/存储相关的两点)

- **CNI = Calico + IPIP 隧道**(数据中心 fabric 只放行 IPIP/proto 4、不放 VXLAN 时会走这条;节点同网段但跨节点 Pod 不通,先看 `docs/cluster-architecture.md` §2.2 的三条判据)。
- **`kube_proxy_strict_arp` 必须为 `true`**(ipvs 模式):kube-vip 的 ARP 模式在 ipvs 集群上是**硬前置**,kubespray 的 kube-vip 任务会直接断言失败。【代码】`sync-kubespray-config.sh` 在 `KUBE_VIP_ENABLED=true` 时自动确保该值为 true,缺了会**报错停住**而不是静默降级。

---

## 2. 对外暴露:MetalLB 与 kube-vip

### 2.1 MetalLB:给 LoadBalancer 型 Service 发地址

**它解决什么**:裸金属/VM 环境没有云厂商的 LB,`type: LoadBalancer` 的 Service 会永远 `<pending>`。MetalLB 在二层用 ARP 通告一批**你自己的空闲 IP**,把这些 IP 分配给这类 Service。

**配置**(`cluster.conf`):

```bash
METALLB_ENABLED="${METALLB_ENABLED:-true}"          # 总开关
METALLB_POOL="${METALLB_POOL:-10.66.3.237-10.66.3.238}"   # ⚠ 必须是与节点同二层网段里的空闲地址段
```

| 约束 | 说明 |
|---|---|
| 网段 | 必须与节点**同二层**(L2 模式靠 ARP 通告),交换机不能做 DHCP snooping 拦截 |
| 空闲 | 池内地址**不能被任何主机/其它集群占用**;已踩过的坑:池里含了别的集群的 VIP,导致 registry 分到那个 IP 后镜像全部拉取失败 |
| 与 kube-vip | **池不得包含 `K8S_API_VIP`**(否则 MetalLB 可能把 API 入口的地址发给某个业务 Service)——【代码】配置校验会硬失败 |
| 与 ipvs | 需要 `kube_proxy_strict_arp=true`(平台已自动确保) |

**部署与验证**:

```bash
# 部署(会创建 IPAddressPool + L2Advertisement,controller/speaker 就绪)
./deployments/scripts/deploy-cluster.sh --steps metallb

# 端到端验证(真正建一个 LoadBalancer Service 并 curl 它,而不只是看 Pod Running)
./deployments/scripts/deploy-cluster.sh --steps verify_metallb
```

```bash
# 【实机】本环境输出
$ kubectl get ipaddresspool -A
NAMESPACE        NAME      AUTO ASSIGN   AVOID BUGGY IPS   ADDRESSES
metallb-system   primary   true          false             ["10.66.3.237-10.66.3.238"]

$ kubectl get l2advertisement -A
NAMESPACE        NAME      IPADDRESSPOOLS   IPADDRESSPOOL SELECTORS   INTERFACES
metallb-system   primary   ["primary"]

$ kubectl -n kube-system get svc registry        # 内置镜像仓库拿到的地址
NAME       TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)
registry   LoadBalancer   10.233.2.135   10.66.3.237   5000:30279/TCP
```

### 2.2 服务暴露方式:`SERVICE_EXPOSE_MODE`

| 取值 | 行为 | 什么时候用 |
|---|---|---|
| `nodePort`(默认) | 用 `NodePort` 暴露;registry 另有 DNAT/`REGISTRY_IP` 兜底 | 无 LB 地址段可用时 |
| `metallb` | 关键服务用 `LoadBalancer`(由 MetalLB 发地址) | **生产推荐**(本环境用的就是它) |
| `hostNetwork` | 直接占用节点端口 | 只有明确需要时 |

```bash
SERVICE_EXPOSE_MODE="${SERVICE_EXPOSE_MODE:-metallb}"
```

> 它同时是 Ceph 对外暴露(`CEPH_EXTERNAL_EXPOSE_MODE`,见 §3.5)的默认随动值 —— 改这一处,存储暴露方式跟着变。

### 2.3 kube-vip:给 API 入口一个浮动 VIP

**它解决什么**:§1.2 的 ① 层。三台 master 上各跑一个 kube-vip 静态 Pod,通过**租约选举**选出一台持有 VIP 并用 ARP 通告;持有者宕机时 VIP 漂移到另一台。

**配置**(`cluster.conf`):

```bash
KUBE_VIP_ENABLED="${KUBE_VIP_ENABLED:-false}"   # ⚠ 默认关;要外部入口 HA 必须显式置 true
K8S_API_VIP="${K8S_API_VIP:-10.66.3.239}"       # 留空 = 自动推导(从 .210 起逐地址探测空闲)
KUBE_VIP_INTERFACE="${KUBE_VIP_INTERFACE:-}"    # 留空 = kube-vip 自动检测网卡;多网卡建议显式指定
KUBE_VIP_CP_DETECT="${KUBE_VIP_CP_DETECT:-false}"  # apiserver 进程级故障检测(默认关,与上游一致)
```

**VIP 怎么选(两种来源)**

| 来源 | 行为 | 建议 |
|---|---|---|
| **显式**(`K8S_API_VIP=10.66.3.239`) | 直接用,不做任何探测 | **生产推荐** —— 可控、可审计,且同网段多套集群时必须显式错开 |
| **自动推导**(留空) | 在各 master 上从 `.210` 起逐地址探测(**ICMP 无应答 且 6443 不可达** = 空闲),排除节点 IP 与 `METALLB_POOL`;起点可用 `K8S_API_VIP_START` 改 | 单集群、网段干净时可用;⚠ 探测由各 master 经 SSH 执行,容器解析不了节点名会静默失效(该缺陷已修) |

**启用步骤**:

```bash
# 1) cluster.conf 里置 KUBE_VIP_ENABLED=true(以及可选 K8S_API_VIP / KUBE_VIP_INTERFACE)
# 2) 先把 VIP 落地(绑定 + 静态 Pod),再切入口 —— 存量集群见 §2.4 两阶段
./deployments/scripts/deploy-cluster.sh --steps kube_vip

# 3) 六项端到端验证(漂移演练/唯一性/网卡正确性…)
./deployments/scripts/deploy-cluster.sh --steps verify_kube_vip
```

```bash
# 【实机】本环境证据
$ ssh <master> "ls /etc/kubernetes/manifests/"     # 三台都有:
kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml  kube-vip.yml

$ ssh <master> "sudo grep -A1 'name: address' /etc/kubernetes/manifests/kube-vip.yml"
      value: "10.66.3.239"                          # 三台一致(同一个 VIP,由租约决定谁持有)

$ ssh mxgpu-3-28 "ip -4 -o addr show | grep 239"    # 只有持有者的网卡上能看到
5: br-lan    inet 10.66.3.239/32 scope global ...   # 本环境持有者 = mxgpu-3-28
```

**故障行为(选型时要知道的边界)**

| 场景 | 表现 | 平台是否已缓解 |
|---|---|---|
| 持有者**断电/失联** | 入口消失约 5s(等租约过期)后漂移 | ✅ 上游默认租约;仓库**有意不调短**(改短会误判抖动) |
| 持有者上 kube-vip **进程正常退出** | 1–2s 内漂移(退出时主动释放租约) | ✅ 实测 |
| 节点活着但 **apiserver 进程死** | `KUBE_VIP_CP_DETECT=false`(默认)时 **VIP 永不漂移**;置 `true` 后约 5s 漂移 | ⚠ 需显式开启;开启代价是 HTTP 探针短抖动可能引发不必要的迁移 |
| **脑裂**(多台同时持 VIP) | API 行为不确定 | ✅ 逐台读回清单断言 `vip_nodename` 唯一(历史上真的踩到过) |
| VIP 落在 MetalLB 池 / 与节点 IP 冲突 | ARP 打架 | ✅ 配置校验硬失败 |

**关闭与回退**(双向收敛):

```bash
# 置 KUBE_VIP_ENABLED=false 重跑 → 删掉各 master 的 kube-vip.yml 并释放 VIP
./deployments/scripts/deploy-cluster.sh --steps kube_vip
```

> ⚠ **入口仍指向 VIP 时会 fail-closed 拦停**(不会自毁):先把入口退回第一台 master(重跑一次
> 全量或 `--steps k8s_deploy`),再关开关清理。这是**有意的护栏** —— 半清理比不清理更难排查。

### 2.4 两阶段切换(存量集群切入口时必读)

VIP 就位 ≠ 入口已切。**存量集群**必须按两阶段走,因为切换瞬间所有客户端会同时改道:

| 阶段 | 动作 | 客户端影响 |
|---|---|---|
| **阶段一** | `--steps kube_vip`(或全量):kube-vip 起来、VIP 绑到某台 master,**入口地址仍是第一台 master** | 无 |
| (人工确认) | 观察 `verify_kube_vip` 六项全过 | 无 |
| **阶段二** | 确认切换(部署时给出倒计时窗口,写入 `KUBE_VIP_SWITCH_CONFIRMED=1`)→ 域名解析与 `loadbalancer_apiserver.address` 切到 VIP → 全节点 apiserver/kubelet 重载 | **秒级抖动**(客户端改道) |

> **全新安装**不需要人工确认:安装时集群还不存在,节点侧又走本地代理(§1.2 ③),部署期间没有人需要 VIP。
> 【代码】`06_k8s_deploy.sh` 的确认门只在"入口原本指向别处"时才触发。

### 2.5 ⚠ 同网段跑多套集群:**VIP 与 MetalLB 池都必须错开**

这是本项目**实机踩过的事故**(2026-09-29):同网段两套集群都用 `10.66.3.240` 当 API VIP,两边的 kube-vip 都持有该地址 ⇒ 客户端到 VIP 的流量**随机落到另一套集群的 apiserver** ⇒ `kubectl` 时好时坏地报:

```
x509: certificate signed by unknown authority
```

**判据**(自包含,不需要本机有集群 pki)——同一地址连取 4 次服务端证书指纹,出现**多个不同**指纹即命中:

```bash
for i in 1 2 3 4; do
  echo | openssl s_client -connect k8s-api.cubestack.io:6443 -servername k8s-api.cubestack.io 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256
  sleep 1
done | sort -u     # 只有 1 行 = 正常;多行 = 被多套集群共用
```

**处置**:① 两套集群各用**不同**的 `K8S_API_VIP` + `METALLB_POOL`(改 VIP 后**必须重装集群**,证书 SAN 固化);② 或先拆除另一套。【代码】`sync_kubeconfig` 的末校验已内置该判定,失败时会直接打印这两条处置。

---

## 3. Ceph 存储

> 本节覆盖:内部部署、**默认 StorageClass 与选型**、**S3 对象存储接入**、**接入外部已有 Ceph**、备份恢复。

### 3.1 部署内部 Ceph 集群

**开关组合**(`cluster.conf`;**两项默认都是关,要显式打开**):

```bash
CEPH_ENABLED="${CEPH_ENABLED:-true}"          # ← 置 true:部署 Rook-Ceph 集群本体(CephCluster)
CEPH_CSI_ENABLED="${CEPH_CSI_ENABLED:-true}"  # ← 置 true:供给层(池 + StorageClass + 可选 CephFS/RGW)
```

| 决策项 | 配置键 | 默认 | 说明 |
|---|---|---|---|
| 模式 | `CEPH_MODE` | `internal` | **唯一开关**:`internal`(集群内自建)/ `external`(接入外部,见 §3.4) |
| 存储节点 | `CEPH_NODES` / `CEPH_NODE_ROLE` / `CEPH_NODE_LABEL` | 空 / `master` / `ceph-storage=rook-ceph` | `CEPH_NODES` 非空则**优先级最高且不做角色过滤**;否则按角色从 `NODES` 里选。⚠ 存储节点数 < `CEPH_MIN_NODES`(默认 **3**)→ **不创建 CephCluster**(只 warn 不中断,表现为"静默没装") |
| master 可调度 | `CEPH_ENABLE_MASTER_SCHEDULE` | `true` | 存储节点是 master 时,master 上默认带 `NoSchedule` 污点 → 模块**自动摘掉**(幂等);恢复:`kubectl taint nodes <master> node-role.kubernetes.io/control-plane=:NoSchedule` |
| 用哪些盘 | `CEPH_DATA_DISK_POLICY` / `CEPH_DATA_DISKS` / `CEPH_DETECT_EXCLUDE` | `auto` / 空 / `^(sda\|sr0\|vda\|nbd[0-9]+)$` | `auto` 自动检测(**`free` ∪ `ceph`**,`inuse`/`mixed` 既不进 CR 也不清理);`explicit` 手工指定:`"node1:/dev/vdb,/dev/vdc;node2:/dev/vdb"` |
| 部署前确认 | `CEPH_CONFIRM_SLEEP` | `60` | 红底列出"各节点磁盘按类分组 + 判定证据"并 sleep 供人工复核(生产别设 0) |
| mon / mgr | `CEPH_MON_COUNT` / `CEPH_MGR_COUNT` | 3 / 2 | mon 必须奇数且 `allowMultiplePerNode=false`;mgr=2 是 active+standby(**单 mgr 是滚动单点**) |
| 副本 | `CEPH_POOL_REPLICAS` / `CEPH_POOL_MIN_SIZE` | 3 / 2 | 故障域 = **host**;`min_size=2` 保证宕一台主机池仍可写 |
| OSD 内存 | `CEPH_OSD_MEMORY_TARGET` | 12(GiB) | 大盘(7TB 级)默认值;小盘可调小省内存 |
| 数据面网络 | `CEPH_HOST_NETWORK` | `true` | mon/osd/mgr 直接监听**节点 IP**(绕开 kube-proxy/NodePort,历史 NodePort 环对 mon msgr v1 握手不可靠) |
| 覆盖安装清盘 | `CEPH_PRE_CLEANUP_EXISTING` | `true` | 清空上次 ceph 所用磁盘;**恢复数据场景必须设 false**(§3.5) |

**部署与验证**(顺序是硬约束:`metallb → ceph → ceph_csi → local_path → registry`;`ceph_csi` 的 `REQUIRES: ceph`):

```bash
./deployments/scripts/deploy-cluster.sh --steps ceph          # ① 集群本体(Rook operator + mon/mgr/osd)
./deployments/scripts/deploy-cluster.sh --steps ceph_csi      # ② 池 + 6 个 StorageClass(+ CephFS/RGW)
./deployments/scripts/deploy-cluster.sh --steps verify_ceph   # ③ 九段端到端验证(真实读写)
```

`verify_ceph` 九段断言:① Rook operator + ceph-csi Ready → ② `CephCluster phase=Ready` 且 `ceph -s` 无 `HEALTH_ERR` → ③ SC 存在 → ④ **RBD 块设备真实读写** → ⑤ ≥3 个 OSD up → ⑥ 清理兜底 → ⑦ **CephFS RWX 文件 I/O** → ⑧ **RGW/S3 上传下载** → ⑨ 对外暴露自检。

**要开 CephFS / 对象存储**,打开后重跑 `ceph_csi`(两项默认都是 true):

```bash
CEPHFS_ENABLED="${CEPHFS_ENABLED:-true}"     # RWX 共享文件系统
CEPH_RGW_ENABLED="${CEPH_RGW_ENABLED:-true}" # S3 对象存储网关(RGW)
```

> **CephFS 额外一步**:平台按 subvolume group 路由(`ephemeral` / `durable`),部署后补跑
> `sudo ./deployments/scripts/tools/k8s/cephfs-group-route.sh apply`(把 SC 的 `clusterID` 指向对应 group)。

### 3.2 StorageClass:默认用哪个、怎么选

internal 模式建 **6 个** SC(RBD 4 + CephFS 2);【实机】本环境实测:

| StorageClass | 后端 | 回收策略 | 绑定模式 | 典型用途 |
|---|---|---|---|---|
| **`ceph-rbd-ephemeral`** | RBD(`rbd-pool`) | Delete | WaitForFirstConsumer | **默认 SC**(带 `is-default-class=true`)—— 通用块存储;**删 PVC 即删卷** |
| `ceph-rbd-ephemeral-immediate` | RBD | Delete | Immediate | 同参数但**立即绑卷**(供 CDI/需要预创建卷的场景) |
| `ceph-rbd-durable` | RBD | **Retain** | WaitForFirstConsumer | 长期保留(删 PVC 保留卷,如 TSDB / registry 数据目录) |
| `ceph-block` | RBD | Delete | WaitForFirstConsumer | **兼容别名**:与 `ceph-rbd-ephemeral` **同 pool/同参数**,唯一差别是没有 default 注解。保留它是因为 kubespray 的 registry addon 按**旧名**引用 |
| `cephfs-ephemeral` | CephFS(`fsName=cephfs`) | Delete | Immediate | **RWX 共享文件**(多 Pod 同时读写) |
| `cephfs-durable` | CephFS | **Retain** | Immediate | 同上,长期保留(平台共享资产) |

**怎么选**:

- 默认什么都不写 → 落到 `ceph-rbd-ephemeral`(RWO 场景)
- **数据不能随 PVC 删除而消失** → `ceph-rbd-durable`
- **多 Pod 同时读写** → `cephfs-ephemeral` / `cephfs-durable`(`accessModes: ReadWriteMany`)
- **需要立即绑定** → `*-immediate` 变体

```yaml
# 用法示例:PVC + Pod
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: demo-pvc
spec:
  storageClassName: ceph-rbd-ephemeral     # 不写则用默认 SC
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: 10Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: demo-pod }
spec:
  containers:
    - name: app
      image: <你环境里可拉到的镜像>            # 例:busybox —— 平台内置 registry 只在 verify 用到时按需推入 nginx,不预置通用镜像
      command: ["sh","-c","echo ok > /data/hello && sync && sleep 3600"]
      volumeMounts: [{ name: data, mountPath: /data }]
  volumes:
    - name: data
      persistentVolumeClaim: { claimName: demo-pvc }
```

```bash
# 查看与判读
kubectl get sc                                    # DEFAULT 列标 true 的那条 = 默认 SC
kubectl get pvc -A                                # WaitForFirstConsumer 的 SC:Pod 未调度前一直 Pending,属正常
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree   # 【实机】9 个 OSD / 3 台存储节点
```

> **内置 registry 的后端**:`REGISTRY_STORAGE_CLASS` 决定它走哪条 SC —— **默认自动跟随 Ceph**:
> 启用了 Ceph(`CEPH_ENABLED` + `CEPH_CSI_ENABLED` 都为 true)时取 `ceph-block`(RBD 复制盘),否则取 `local-path`。
> 【实机】本环境 `registry-pvc` 10Gi 就绑在 `ceph-block`。
> ⚠ 不要手工把它写成 `local-path`:Ceph 模式下 local-path provisioner 是**关的**(集群里没有该 SC),
> registry PVC 会**永远 Pending**。要强制别的 SC 就显式赋值(优先级最高)。
> ⚠ 若 registry 已用旧 SC 建好 PVC,换 SC 需**删旧 PVC** 重建。

### 3.3 对象存储(S3):接入与使用

**RGW(radosgw)** 是 Ceph 的 S3 网关。`CEPH_RGW_ENABLED=true` 且 internal 模式时,平台建两组资源:

| 资源 | 名字 | 说明 |
|---|---|---|
| `CephObjectStore` | `s3-store` | `gateway.port=80`,`preservePoolsOnDelete: true`(防误删 CR 连带删 pool) |
| `CephObjectStoreUser` ×2 | `rgw-model-admin` / `rgw-model-reader` | **平台按"模型仓库"预置的角色**:admin = 全部模型桶 owner(建桶/上传/删桶/配额);reader = 全部桶只读(由桶级 reader policy 授权) |

**① 端点(endpoint)按暴露模式有 4 种形态**:

| 场景 | 端点 |
|---|---|
| 集群内 | `http://rook-ceph-rgw-s3-store.rook-ceph.svc:80` 【实机】 |
| 集群外(host-network,默认) | `<节点IP>:80` |
| 集群外(nodeport) | `http://<节点IP>:<NodePort>`(Service `rook-ceph-rgw-s3-store-external`) |
| 集群外(metallb/LoadBalancer) | `http://<VIP>:80` |

region 固定 `us-east-1`。

**② 取凭据的两条路(别混)**:

```bash
# A. 长期用户(业务用):读平台预置的 Secret
kubectl -n rook-ceph get secret rook-ceph-object-user-s3-store-rgw-model-admin \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'   # → AccessKey / SecretKey / Endpoint
#    分发约定建议:admin → 平台侧上传/管理,reader → 引擎侧只读

# B. 临时用户(验证/调试用):仓库工具会**新建一个临时用户并把 AK/SK 打到 stdout**,用完即删
./deployments/scripts/tools/k8s/rgw-get-user-key.sh            # 省略 uid 时用 verify-rgw-<时间戳>
#    等价的手工命令:
#    kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
#      radosgw-admin user create --uid=<uid> --display-name=verify --format json --rgw-zone=s3-store
```

**③ 建桶与读写验证**——平台自带一个**纯标准库 SigV4** 的验证脚本(不依赖 aws cli):

```bash
AK=<access_key> SK=<secret_key> ENDPOINT=http://rook-ceph-rgw-s3-store.rook-ceph.svc:80 \
  python3 deployments/scripts/tools/k8s/verify-rgw-s3.py
#  流程:PUT bucket → PUT object → GET(校验内容) → DELETE;成功打印 S3-PUT-GET-OK
#  ⚠ 三条易错点(2026-09-29 实测):
#    · 三个变量必须**在同一行**(或先 export)—— 逐行写 `AK=..` 不带 export 时子进程读不到,
#      脚本会转去自建临时用户, 在宿主机/部署容器里会报 radosgw-admin 找不到
#    · `ENDPOINT` 可以只写 `<host>:<port>`(自动补 http://), 但**别省端口**
#    · 不给 AK/SK 也能跑:脚本会经 `kubectl exec` 进 rook-ceph-tools 建临时用户(用完自动删);
#      zone 取 `RGW_ZONE`(默认 s3-store, 与 CephObjectStore 名一致)
```

```bash
# 如果你的机器上有 aws cli,等价命令(必须带 --endpoint-url)
export AWS_ACCESS_KEY_ID=<AK> AWS_SECRET_ACCESS_KEY=<SK> AWS_DEFAULT_REGION=us-east-1
aws --endpoint-url http://<节点IP>:<NodePort> s3 mb s3://demo
aws --endpoint-url http://<节点IP>:<NodePort> s3 cp ./f.txt s3://demo/f.txt
aws --endpoint-url http://<节点IP>:<NodePort> s3 ls s3://demo/
```

**④ 声明式建桶(ObjectBucketClaim)**:

- ⚠ **internal 模式默认没有 bucket SC**;要用 OBC 得自己 apply 仓库里的样例(`deployments/cubestack-addon/rook/external/storageclass-bucket-{delete,retain}.yaml`)**并把 `objectStoreName` 改成 `s3-store`、`objectStoreNamespace` 改成 `rook-ceph`**。
- **官方导入路径(external)会自动建** bucket SC `rook-ceph-bucket` + OBC `model-repo`(见 §3.4)。
- OBC **必须显式写 `namespace`**,否则落到 kubectl 默认 ns,等待检查永远 NotFound(会把"没生效"误判成"未 Bound")。

### 3.4 接入**外部已有** Ceph 集群

`CEPH_MODE` 是**唯一开关**;切到 `external` 后,`02_ceph` 只部署 Rook operator + csi-operator(**不建 CephCluster / 不碰磁盘**),`03_ceph_csi` 建"连接 + 6 个 SC"(并**跳过**集群内 pool/cephfs/rgw)。

**路径一:官方导入(推荐,全自动)**

```bash
# 提供方(A 侧,内部模式):导出接入文件(含真实 keyring,永不入库)
bash deployments/scripts/tools/k8s/ceph-expose-external.sh apply     # 生成 deployments/config/external-ceph.env
# 消费方(B 侧):cluster.conf 只设三行
CEPH_MODE=external
CEPH_ENABLED=true                 # 让 02 部署 operator/csi-operator(官方导入的前提)
CEPH_CSI_ENABLED=true
CEPH_EXTERNAL_ENV_FILE=""         # 留空 = 自动探测 deployments/config/external-ceph.env
```
B 侧检测到 env 文件后全自动:建 mon secret / CM + 4 个 CSI secret → apply `common-external.yaml` + `cluster-external.yaml` → 等 `CephCluster rook-ceph-external` **STATE=Connected** → **滚动重启 provisioner 并确认 `config.json` 已挂载** → 建 6 个 SC → 建 `CephObjectStore external-store` → 建 bucket SC + OBC → (可选,默认关)`CEPH_EXTERNAL_PROVISION_SMOKE=true` 跑数据面冒烟。

**路径二:手填(存量兼容)** —— 用 A 导出的 `external-ceph-self-define-access.conf` 的值填 B 的 `cluster.conf`:

```bash
CEPH_MODE=external
CEPH_ENABLED=true
CEPH_CSI_ENABLED=true
# --- 以下取自 A 的导出(按实际值替换; ⚠ 含真实 keyring, 该文件永不入库) ---
CEPH_MONITORS="10.66.3.28:30100,10.66.3.29:30100,10.66.3.31:30100"   # A 导出的 mon 端点
CEPH_POOL="cubestack-ext-rbd-pool"
CEPH_USER="cubestack-ext-rbd"
CEPH_KEYRING="<A 导出的 RBD key>"
# --- 可选:外部 A 有 CephFilesystem 时才需要(两个用户必须分开!) ---
CEPHFS_FS="cubestack-ext-fs"
CEPHFS_DATA_POOL="cubestack-ext-fs-cubestack-ext-cephfs-data"
CEPHFS_USER="cubestack-ext-cephfs"            # provisioner 角色:建/删 subvolume
CEPHFS_KEYRING="<A 导出>"
CEPHFS_NODE_USER="cubestack-ext-cephfs-node"  # node 角色:挂载与文件 I/O
CEPHFS_NODE_KEYRING="<A 导出>"
# ⚠ 不要设置内部部署相关项(CEPH_NODES / CEPH_DATA_DISK_POLICY / CEPH_MON_COUNT …):它们只属于 A 侧
```

**三条硬约束**(踩过):

| # | 约束 | 违反后果 |
|---|---|---|
| 1 | **CephFS 必须 provisioner / node 双用户分开** | 只给 provisioner caps → 卷建得出来但**挂载后写 EPERM**;只给 node caps → **建卷失败** |
| 2 | 提供方 Rook v1.20 的内部 CSI 用户名带**数字后缀**(如 `client.csi-cephfs-node.1`) | 照抄不带后缀的名字 → 用户不存在 |
| 3 | 同一个 RBD pool **只能被一个 ceph-csi-operator 强一致使用** | 两套集群同写一个 pool → 动态卷/镜像冲突;要多集群共享请用 CephFilesystem |

**反向能力:把本平台内部 Ceph 暴露给外部客户端**(A 侧):

```bash
CEPH_EXTERNAL_EXPOSE="${CEPH_EXTERNAL_EXPOSE:-true}"        # 总开关(默认开)
CEPH_EXTERNAL_EXPOSE_MODE="${CEPH_EXTERNAL_EXPOSE_MODE:-}"  # nodeport|loadbalancer|metallb|clusterip;空=随 SERVICE_EXPOSE_MODE
CEPH_EXTERNAL_USER="${CEPH_EXTERNAL_USER:-cubestack-ext-rbd}"                 # 外部专用 RBD 用户
CEPH_EXTERNAL_RBD_POOL="${CEPH_EXTERNAL_RBD_POOL:-cubestack-ext-rbd-pool}"    # 外部专用 pool(与内部隔离)
```
暴露 + 预定义 4 步(网络层 external Service → 资源层外部 pool/FS → 认证层三个专用用户 → 导出两个文件)+ **5 层自检**(含**外部客户端协议级测试**:从集群外做 mon 握手 + cephx 认证 + rbd 写路径):

```bash
bash deployments/scripts/tools/k8s/ceph-expose-external.sh status    # 5 层自检
bash deployments/scripts/tools/k8s/ceph-expose-external.sh show      # 当前暴露状态
```
【实机】本环境即如此:内部 `cephfs` 之外还建了给外部用的 `cubestack-ext-fs`。

### 3.5 备份与恢复

`ceph_backup` 是**独立运维模块**:**不随部署执行**,部署流程既不会自动备份也不会自动恢复。

```bash
sudo ./deployments/scripts/deploy-cluster.sh --steps ceph_backup                       # 备份(默认 save)
sudo CEPH_BACKUP_ACTION=restore ./deployments/scripts/deploy-cluster.sh --steps ceph_backup  # 恢复
# 其它动作: fetch-fsid | install-cron | run-cron
```

**备份三件套缺一不可**:① `CephCluster` CR(含 `status.fsid`)② `rook-ceph-mon` Secret(fsid + keyring)③ **各节点 mon store**(`/var/lib/rook/mon-*`,含 osdmap/PG map)。产物在首个 master 的 `/var/lib/ceph/backup/current/`(默认保留 10 份)。

> ⚠ **只备份 CR + Secret 不够**:Rook v1.20 的 CRD 没有 `spec.fsid` 字段,认领旧 OSD 数据的唯一途径是复用 mon Secret + mon store;缺 mon store 时 OSD 会卡 `start_boot`(新 mon 的 osdmap epoch 远低于 OSD 本地缓存的 epoch)。

**恢复**(整 ns 重建后认领旧数据):

```bash
sudo CEPH_BACKUP_ACTION=restore ./deployments/scripts/deploy-cluster.sh --steps ceph_backup   # ① 恢复 secret + mon store
CEPH_PRE_CLEANUP_EXISTING=false CEPH_CONFIRM_SLEEP=0 \
  ./deployments/scripts/deploy-cluster.sh --steps ceph        # ② 保留数据模式重跑 ceph
# 校验:fsid 与备份一致(证明是"认领"而不是"新建")
kubectl -n rook-ceph get secret rook-ceph-mon -o jsonpath="{.data.fsid}" | base64 -d
```
恢复是幂等的:节点上已有 `mon-*` 时跳过,**绝不覆盖运行中的集群**。

### 3.6 已知坑与硬约束(部署前必读)

| # | 坑 | 后果 / 规避 |
|---|---|---|
| 1 | 存储节点数 < 3(`CEPH_MIN_NODES`) | **静默不装** Ceph(只 warn);`CEPH_NODE_ROLE=master`(默认)时 master 少于 3 台的集群必须显式把 worker 写进 `CEPH_NODES` |
| 2 | **整盘 LVM PV** 曾经被判 `free` → 会被写进 CR 并清空 | 现已规则化:见到 `LVM2_member` 或设备在 `pvs` 里却认不出归属 → 判 `inuse`(宁可不擦) |
| 3 | `nbd*` 设备 | **恒判 `inuse`,永不清理/永不进 CR**:它很可能是 `rbd-nbd` 映射,擦它会写穿到背后的 RBD 卷 |
| 4 | **旧 OSD label 残留**(Ceph v20 把 label 复制到固定偏移 **10/100/1000 GiB**) | `blkid`/`wipefs` 只看 offset 0 → 盘"看着干净"但 Rook 判 `already prepared` → **0 OSD**;平台改用官方 `ceph-bluestore-tool zap-device`(读 label 自带 `locations` 逐处清零) |
| 5 | 清理 LVM/dm 时按名字扫全节点 | `... \| grep ceph` 会误伤 `data-vg/cephbackup` 这类无关卷;`dmsetup remove_all` 会拆掉本节点所有 dm 映射 ⇒ 必须**按盘收敛** |
| 6 | 守护进程 placement 不要改用 `placement.all` | Rook 会把 `all` 套到 **CSI daemonsets**,把必须跑在每个节点的 nodeplugin 钉死在存储节点 → worker 上的 PVC 挂不上 |
| 7 | OBC 必须显式写 `namespace` | 否则落到 kubectl 默认 ns → 等待检查永远 NotFound(假"未 Bound") |
| 8 | `CEPH_MODE` 全文件**只允许一处赋值** | 示例块曾是"活配置",source 时会把 `external` 与占位 key 覆盖到真实配置上(已全部注释为纯模板) |
| 9 | 凭据纪律 | `external-ceph.env` / 自研导出配置 / `cluster.conf` 都含**真实 keyring,永不入库** |
| 10 | NTP | Ceph 对时钟亚秒级敏感,`HEALTH_WARN clock skew` 即此因(平台在 `k8s_ntp` 阶段已做偏差校验) |

> 深挖:`docs/ceph-rook.md`(架构/参数/外部接入/排障全文)、`docs/ceph-backup-restore.md`、`docs/troubleshooting.md` 的 Ceph 段。

---

## 4. RDMA(InfiniBand / RoCE 共享设备插件)

### 4.1 它做什么

把宿主机 **RDMA 网卡的字符设备**以 **K8s 扩展资源**暴露给 Pod,并支持**多个 Pod 共享同一块物理 HCA**(不独占)。

- 组件:`Mellanox/NVIDIA k8s-rdma-shared-dev-plugin`(标准 Device Plugin)
- 流程:校验离线镜像 tar → 推进集群内置 registry → 建 ConfigMap(资源池定义)+ DaemonSet(插件)→ 等 Ready → 校验节点扩展资源已注册
- 它**不含真实数据面验收**:吞吐/时延要用 `perftest` 另行实测(见 §4.6)

### 4.2 三种资源模式(先选型)

| 模式 | 语义 | 资源名形态 | 何时选 |
|---|---|---|---|
| **`by-link`(默认,推荐)** | 按**链路类型**分成 **IB / RoCE 两个资源池**,同类型多卡合并为一份 `ifNames` 并集 | `rdma/ib_shared_devices`(IB)、`rdma/roce_shared_devices`(RoCE) | **要与真实 GPU 集群共用同一份 Pod 清单**时选它 —— 资源名与那边对齐 |
| `per-hca` | **每块卡一个独立扩展资源**,Pod 按资源名精确选卡 | `${PREFIX}/<设备名>`,如 `nvidia.com/mlx5_0` / `nvidia.com/mlx5_1` | 需要"按卡分配"(IB 走 ibsX、RoCE 走 ens*) |
| `pool` | 全部 HCA 聚合为**单个**资源 | `${PREFIX}/${NAME}` = `nvidia.com/mlx5_0` | 兼容旧部署;Pod 只能说"我要 RDMA",不能选类型也不能选卡 |

> ⚠ 资源名写错是**静默故障**:Pod 申请一个集群里不存在的资源名 → **永远 Pending**,而部署日志一片绿(§4.7 #1)。

### 4.3 配置(`cluster.conf`)

```bash
RDMA_ENABLED="${RDMA_ENABLED:-true}"                      # 总开关
RDMA_IMAGE_TAG="${RDMA_IMAGE_TAG:-v1.5.4}"                # ⚠ 源在 ghcr.io/mellanox(非 Docker Hub);1.4.0 无 v 前缀,v1.5.x 带 v
RDMA_SAVE_DIR="${RDMA_SAVE_DIR:-.../offline-files/rdma}"  # 离线 tar 目录(不入库)
RDMA_HCA_MODE="${RDMA_HCA_MODE:-by-link}"                 # by-link | per-hca | pool
RDMA_IB_RESOURCE="${RDMA_IB_RESOURCE:-rdma/ib_shared_devices}"          # by-link: IB 池资源名
RDMA_ROCE_RESOURCE="${RDMA_ROCE_RESOURCE:-rdma/roce_shared_devices}" # by-link: RoCE 池资源名
RDMA_IF_NAMES="${RDMA_IF_NAMES:-}"                        # ⚠ 留空 = 自动扫描各节点真实网卡(推荐;兼容 IB+RoCE 混合)
RDMA_ACTIVE_ONLY="${RDMA_ACTIVE_ONLY:-true}"              # 只暴露链路 ACTIVE 的卡(DOWN/DISABLED 跳过)
RDMA_HCA_MAX="${RDMA_HCA_MAX:-100}"                       # 每个资源最多允许多少 Pod 共享
RDMA_VENDORS="${RDMA_VENDORS:-15b3}"                      # PCI 厂商 ID(Mellanox/NVIDIA)
RDMA_UPDATE_INTERVAL="${RDMA_UPDATE_INTERVAL:-300}"       # 配置周期重读(秒;0=关闭)
RDMA_NAMESPACE="${RDMA_NAMESPACE:-kube-system}"           # 插件与 ConfigMap 所在命名空间
RDMA_PLACEHOLDER_HCAS="${RDMA_PLACEHOLDER_HCAS:-mlx5_0,mlx5_1,mlx5_2}"  # 见下:仅纯 VM 生效
```

**两条最容易被误读的语义**:

- **`RDMA_IF_NAMES` 留空 ≠ 不检测,而是"自动检测全部节点"**:模块逐节点 SSH 扫描 `/sys/class/infiniband/*/device/net/` 收集真实设备名 + 网卡名(IB=`ibsX`、RoCE=`ens*/manage0` 混装都支持)。**手写网卡名只适配单形态**,推荐留空。
- **`RDMA_PLACEHOLDER_HCAS` 是"纯 VM 无卡"占位模式**:检测到 **0 块 HCA** 时用占位设备名生成配置 —— 插件正常起来但**不注册任何扩展资源**(占位名不是真实 netdev,selectors 永不匹配),ConfigMap 带标注 `cubestack.io/rdma-placeholder=true`,verify 据此放行并标注"未验收真实 RDMA"。**物理机零影响**(检测到真卡时该项被忽略);要严格模式(无卡即报错退出)把它写成 `RDMA_PLACEHOLDER_HCAS=""`(注意:只 `export` 空变量无效,`cluster.conf` 的赋值优先于环境变量)。

### 4.4 启用步骤

**前置(装机器不负责)**:节点已装 Mellanox/NVIDIA 网卡 + **MLNX_OFED 或内核自带 `ib_core`**;`ibstat` / `rdma link show` 能看到 HCA;集群内置 registry 就绪(`REQUIRES: k8s_deploy k8s_registry`)。

```bash
# ① 离线镜像(联网机准备一次)
sudo ./deployments/scripts/tools/images/rdma-save-images.sh          # 存到 offline-files/rdma/
sudo RDMA_IMAGE_TAG=v1.5.4 ./deployments/scripts/tools/images/rdma-save-images.sh   # ⚠ VAR= 必须写在 sudo 之后

# ② 部署(模块名 = 文件名去序号)
sudo ./deployments/scripts/deploy-cluster.sh --steps rdma_shared_dev_plugin
sudo ./deployments/scripts/deploy-cluster.sh --steps rdma_shared_dev_plugin --fresh   # 改配置后必须 --fresh(模块 REPEAT:0)

# ③ 端到端验证
sudo ./deployments/scripts/deploy-cluster.sh --steps verify_rdma_shared_dev_plugin
```

> **不需要重启 kubelet/containerd**:插件是纯 Device Plugin,经 `/var/lib/kubelet/device-plugins` 向 kubelet 注册扩展资源。
> ConfigMap 变更由插件按 `RDMA_UPDATE_INTERVAL`(默认 300s)**周期重读** —— 改完配置"没立刻看到资源"先等一个周期,别急着判定失败。

### 4.5 Pod 里怎么用

```yaml
# by-link 模式(默认):IB 与 RoCE 各是一个资源名,按需申请
apiVersion: v1
kind: Pod
metadata: { name: rdma-test-pod-ib }
spec:
  containers:
    - name: rdma-app
      image: <你环境里可拉到的镜像>            # 例:busybox / mellanox/rping-test(需先在 registry 里)
      command: ["sleep","infinity"]
      resources:
        limits:
          rdma/ib_shared_devices: 1          # IB 池(名字由 RDMA_IB_RESOURCE 决定)
          # rdma/roce_shared_devices: 1   # RoCE 池(需要时开这一条)
      securityContext:
        capabilities:
          add: ["IPC_LOCK"]                   # ⚠ RDMA 内存注册(mlock)必需,缺了 ibv_reg_mr 会失败
```

- `pool` 模式 → `limits: { nvidia.com/mlx5_0: 1 }`;`per-hca` 模式 → `limits: { nvidia.com/mlx5_1: 1 }`(资源名以节点 allocatable 实际值为准)
- **没有必须的环境变量**(设备由插件注入);`NVIDIA_VISIBLE_DEVICES` 是 GPU 域的东西,与 RDMA 无关
- 要**跨节点走 RDMA 通信**,还需网络面:配合 Multus 建 macvlan NAD(`master` = RDMA 网卡),Pod 加注解 `k8s.v1.cni.cncf.io/networks: <NAD>`

### 4.6 验证

```bash
sudo ./deployments/scripts/deploy-cluster.sh --steps verify_rdma_shared_dev_plugin
```

五步断言:① 插件 DaemonSet 有 Running Pod → ② ConfigMap `rdma-devices` 存在(并读占位标注)→ ③ **逐节点**核对扩展资源已注册 → ④ 起测试 Pod 申请 RDMA 资源(走内置 registry,离线可用)→ ⑤ 容器内确认 `/dev/infiniband/uverbs*` 已注入(`rdma_cm` 缺失仅告警)。

```bash
# 手工核对(照抄)
kubectl -n kube-system get cm rdma-devices -o go-template='{{index .data "config.json"}}'   # 资源池定义原文
kubectl describe node <节点> | grep -A5 rdma/                                               # 该节点注册了哪些 RDMA 资源
kubectl -n kube-system logs -l name=rdma-shared-dp --tail=50                                 # 插件日志
# 节点侧(SSH)
ls /sys/class/infiniband/                       # 有哪些 HCA
cat /sys/class/infiniband/<dev>/ports/1/state   # 1:ACTIVE / 4:DOWN
cat /sys/class/net/<if>/type                    # 32=IB / 1=Ethernet(RoCE)
```

```bash
# 【实机】本环境:by-link 两池都注册成功(真实卡:IB=ibs2/ibs3,RoCE=manage0)
$ kubectl -n kube-system get cm rdma-devices -o jsonpath='{.data.config\.json}'
{ "periodicUpdateInterval": 300,
  "configList": [
    { "resourcePrefix":"rdma", "resourceName":"ib_shared_devices",      "rdmaHcaMax":100,
      "selectors": { "vendors":["15b3"], "ifNames":["ibs2","ibs3"] } },
    { "resourcePrefix":"rdma", "resourceName":"roce_shared_devices", "rdmaHcaMax":100,
      "selectors": { "vendors":["15b3"], "ifNames":["manage0"] } } ] }
$ kubectl -n kube-system get ds rdma-shared-dp-ds
NAME              DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
rdma-shared-dp-ds 8         8         8       8            8
```

> ⚠ **验证边界**:上述套件**不含真实 RDMA 流量**(离线镜像集内没有 perftest)。要给出吞吐/时延数据,请另配
> `perftest` 镜像实测;**不要据此判定数据面已验收**。诊断 pod(`--steps netshoot`,内置 rdma-core+perftest)可用于这一步。

### 4.7 常见坑(精选;完整 24 条见 `deployments/cubestack-addon/rdma/CUBESTACK.md` 与 `docs/troubleshooting.md` §8/§9)

| # | 坑 | 一句话规避 |
|---|---|---|
| 1 | **资源名写错 = 静默故障** | Pod 永远 Pending(`Insufficient rdma/...`),部署日志全绿;核对法:`kubectl -n kube-system get cm rdma-devices -o yaml` 与 Pod 里写的名字**必须逐字一致** |
| 2 | 旧版本 **v1.4.0 丢掉 RoCE 口** | 其源码对每块卡硬要求 `issm` 字符设备,RoCE 口没有 → 即使 `ifNames` 配对也被丢弃;用 **v1.5.4** |
| 3 | `/sys/class/infiniband` **不能直接挂载** | 无卡节点上该目录不存在 → containerd 创建目录失败(`operation not permitted`)→ 容器起不来;平台改挂父目录 `/sys/class` |
| 4 | `by-link`/`per-hca` 检测到 **0 块 HCA 会报错退出** | 纯 VM 用 `RDMA_PLACEHOLDER_HCAS` 占位,或改 `pool` 模式(只空转不报错) |
| 5 | **占位模式不会随"装上真卡"自动更新** | ConfigMap 已下发就不会重建:必须 `--steps rdma_shared_dev_plugin --fresh` |
| 6 | `RDMA_ACTIVE_ONLY=true` 会过滤 DOWN/DISABLED 的卡 | "卡在但没资源"先看链路状态,别先怀疑插件 |
| 7 | 装了卡但**驱动没起** | 容器内 `ibv_devices` 无输出 → 查宿主机 MLNX_OFED / `lsmod \| grep mlx5_ib` |
| 8 | 本插件是 **PF 共享** | 需要 SR-IOV 独占 VF 的场景要换 `sriov-network-device-plugin`(不在本平台范围内) |

> 深挖:`deployments/cubestack-addon/rdma/CUBESTACK.md`(逐项设计说明)、`docs/troubleshooting.md` §8/§9(实测事故)、`docs/netshoot.md`(诊断 pod)。

---

## 5. GPU(沐曦 MetaX)

### 5.1 operator 组成

平台用**修复版 Helm chart** 安装 `metax-operator`,再由 operator 按 `ClusterOperator` CR 创建组件 DaemonSet:

```
metax-operator (Deployment, 带 master 容忍+偏好亲和)
      │  按 ClusterOperator CR 生成 ↓
      ├── metax-gpu-label         ① 给节点打标(metax-tech.com/gpu.installed 等)
      ├── metax-driver            ② 驱动管理(默认策略 PreferHost = 用宿主驱动)
      ├── metax-maca              ③ 分发 MXMACA SDK/UMD 包到节点
      ├── metax-container-runtime ④ 把 metax 运行时注册进 containerd ⚠ 只支持 containerd 配置版本 ≤3
      └── metax-gpu-device        ⑤ 设备插件 → 注册扩展资源 metax-tech.com/gpu
```

【实机】本环境 8 台节点上:上述 5 个 DaemonSet **全部 8/8 Ready**;节点 `metax-tech.com/gpu.installed=true`;单节点 allocatable `metax-tech.com/gpu: 8`。

### 5.2 前置条件(装之前必须确认)

| # | 前置 | 说明 |
|---|---|---|
| 1 | **containerd 配置版本 = 3** | ⚠ **硬约束**:沐曦 `container-runtime` 组件只支持 ≤3;containerd 2.3.x 上游模板默认发 `version = 4` → 该组件报 `config version 4 is not support` 并 **CrashLoop**。平台用 `CONTAINERD_CONFIG_VERSION=3`(默认值)覆盖;降 3 的**行为等价性已实测**(只差一个 `[grpc]` 段,且该值是 containerd 内建默认) |
| 2 | **不需要 NFD** | `NFD_ENABLED=false`(默认);节点打标由沐曦自带 `gpu-label` 完成。日志里出现 `NFD volume is not mounted` 是**镜像自带提示**,不是故障 |
| 3 | 宿主机驱动 | 节点已装沐曦内核驱动(`lsmod \| grep metax`),默认 `METAX_DRIVER_DEPLOY_POLICY=PreferHost`(**不要改成 PreferCloud** —— 它会尝试卸载宿主驱动,失败即 CrashLoop) |
| 4 | 集群内置 registry 可达 | `REQUIRES: k8s_deploy k8s_registry`;镜像默认推到 `registry.cubestack.io:5000/metax/*` |
| 5 | 离线镜像 | 联网机 `sudo ./deployments/scripts/tools/images/metax-save-images.sh` → `offline-files/metax-gpu/`(tar 约 27 个 / ~19G,**不入库**) |
| 6 | `METAX_CLUSTER_TYPE=k8s` | 否则 operator 会去探测 OpenShift API 报 `clusterversions ... is forbidden` |

### 5.3 启用步骤

```bash
# cluster.conf(默认即为推荐值)
GPU_OPERATOR_ENABLED="${GPU_OPERATOR_ENABLED:-true}"     # 默认开:全量部署即装 GPU
CONTAINERD_CONFIG_VERSION="${CONTAINERD_CONFIG_VERSION:-3}"
METAX_CLUSTER_TYPE="${METAX_CLUSTER_TYPE:-k8s}"
METAX_DRIVER_DEPLOY_POLICY="${METAX_DRIVER_DEPLOY_POLICY:-PreferHost}"

# 部署
sudo ./deploy-cluster.sh --steps gpu_operator      # 只装 GPU(基座会自动补齐)
sudo ./deploy-cluster.sh --with-cubestack          # 或随全量部署一起
sudo ./deploy-cluster.sh --enable gpu_operator     # 或只写开关,下次全量生效

# 验证
sudo ./deploy-cluster.sh --steps verify_metax_gpu
```

**纯 CPU 集群**(无沐曦卡):模块会先逐节点跑 `mx-smi` 检测,自动走**快速路径**(只等 operator + `gpu-label` 就绪,不再傻等 300s),不会因为"没有 GPU"而失败。

**master 节点特例**:沐曦组件的 DaemonSet **默认没有 control-plane 容忍**,而 master 通常带 `NoSchedule` 污点 →
模块在检测到该 master **确实有 GPU** 时会**自动去污点 + uncordon**(否则 GPU 永远用不上);无 GPU 的 master 保持不可调度。

### 5.4 Pod 里怎么用 GPU

```yaml
apiVersion: v1
kind: Pod
metadata: { name: gpu-task }
spec:
  restartPolicy: Never
  nodeSelector:
    metax-tech.com/gpu.installed: "true"          # 只调度到有沐曦卡的节点
  containers:
    - name: gpu-task
      image: registry.cubestack.io:5000/metax/maca:<版本>   # MXMACA 运行时镜像(版本见 cluster.conf 的 METAX_MACA_IMAGE)
      command: ["mx-smi"]                          # 容器内自检:应列出本 Pod 可见的卡
      env:
        - name: MACA_VISIBLE_DEVICES               # 选卡:MACA 侧变量(如 "0" / "0,2" / GPU UUID / socket ID)
          value: "0"
      resources:
        limits:
          metax-tech.com/gpu: 1                    # ★ 扩展资源名(设备插件注册的)
        requests:
          metax-tech.com/gpu: 1                    # 扩展资源必须 requests=limits
```

| 要什么 | 怎么写 |
|---|---|
| 要 1 张卡 | `metax-tech.com/gpu: 1` |
| 要 8 张卡 | `metax-tech.com/gpu: 8`(单节点 8 卡) |
| 只要"有卡的节点" | `nodeSelector: metax-tech.com/gpu.installed: "true"` |
| 指定某几张卡 | `MACA_VISIBLE_DEVICES`(MACA 兼容 CUDA,实践中也有直接用 `CUDA_VISIBLE_DEVICES` 的) |
| 看有哪些卡 | 容器内 `mx-smi -L` / 节点上 `sudo mx-smi` |
| 避开 master | 自加 `nodeAffinity` 排除 `node-role.kubernetes.io/control-plane`(平台不强制) |

> 设备节点(`/dev/mxcd`、`/dev/dri`)由 Device Plugin 自动注入,**不需要手工挂载**(裸 docker 才需要)。

### 5.5 验证

```bash
sudo ./deploy-cluster.sh --steps verify_metax_gpu     # 或 --steps verify(跑全部 verify 模块)
```

输出逐节点表(`NODE/ROLE/CAP/ALLOC/PRODUCT/MEM/INSTALLED/DRV·MACA·RUN/SCHED/TAINTS`),并做两条异常判定:① 节点已打 `gpu.installed=true` 但 allocatable 为空(设备插件未注册,查 `metax-gpu-device` Pod);② 完全没有任何节点识别到 GPU(查 `gpu-label` / 硬件)。

```bash
# 手工核对(照抄)
sudo mx-smi | grep "Attached GPUs"                       # 节点侧:宿主机能看到几张卡
kubectl get nodes -o json | jq '.items[].status.allocatable | with_entries(select(.key|startswith("metax")))'
kubectl get pods,ds -n metax-operator
kubectl -n metax-operator get ds -o custom-columns=NAME:.metadata.name,SEL:.spec.template.spec.nodeSelector   # 各 DS 的节点选择器(现场取证)
```

> ⚠ **"DaemonSet Ready" ≠ "扩展资源已注册"**:设备插件启动 → ListAndWatch → kubelet 刷新 node status 有**秒级~几十秒**时延;刚部署完立刻查 allocatable 可能误报"没有 GPU"(模块已内置最长 300s 等待)。

### 5.6 与 LWS / Kueue 的关系

| 组件 | 开关 | 默认 | 关系 |
|---|---|---|---|
| **LWS**(LeaderWorkerSet) | `LWS_ENABLED` | **关** | LLM 推理/训练的**组调度**(Leader/Worker 组)+ Prefill/Decode 解耦(`LWS_DISAGGREGATEDSET_ENABLED`)。**与 GPU 无硬依赖**(它的端到端验证用的是 busybox/nginx),要跑 vLLM 多卡/PD 分离时再开 |
| **Kueue** | `KUEUE_ENABLED` | **关** | 队列/配额治理。⚠ 当前是**规划占位模块**(伪代码),开了也不产生实际效果 |

```bash
sudo ./deploy-cluster.sh --steps gpu_lws     # 部署 LWS(默认 bundle 模式,离线友好)
```

### 5.7 常见坑(精选)

| # | 坑 | 规避 |
|---|---|---|
| 1 | **containerd 配置版本 4 → metax-container-runtime CrashLoop** | 保持 `CONTAINERD_CONFIG_VERSION=3`(默认);该键**留空也按 3 处理**(留空回落 4 会让沐曦组件崩,故平台不提供"留空=随上游"模式) |
| 2 | operator 探测 OpenShift 被拒 | `METAX_CLUSTER_TYPE=k8s` + 修复版 chart(平台已内置) |
| 3 | helm 报 `ClusterRole "metax-pre-delete" missing key managed-by` | 每次重部署前清集群级 metax ClusterRole/RoleBinding(模块已自动做) |
| 4 | 大镜像(maca ~5.5G)推送断连 | 先 `tools/node/net-tune.sh`,模块对 skopeo 整包重试 3 次 |
| 5 | 宿主机连不上 `registry.cubestack.io` | `/etc/hosts` 残留旧 IP 或 DNAT 被旧规则遮蔽 → 模块每轮重写 hosts |
| 6 | driver CrashLoop `could not unload metax` | 驱动策略被改成 `PreferCloud` → 改回 `PreferHost` 并重跑部署 |
| 7 | 改完配置不生效 | 模块 `REPEAT:0`(装成功即跳过),重装要 `--fresh` |

> 深挖:`docs/metax-gpu-operator.md`、`docs/troubleshooting.md` §3(GPU 实测事故)、`docs/lws.md`。

---

## 6. 附录

### 6.1 开关速查表(节选;全量见 `cluster.conf.example`)

| 键 | 本环境取值 | 含义 |
|---|---|---|
| `NODES` | 8 台(3 master + 5 worker) | 集群节点清单 |
| `K8S_VERSION` | `v1.35.8` | K8s 版本钉子(与 vendored kubespray 表值一致) |
| `SERVICE_EXPOSE_MODE` | `metallb` | 服务暴露方式 |
| `METALLB_ENABLED` / `METALLB_POOL` | `true` / `10.66.3.237-238` | LB 地址池 |
| `KUBE_VIP_ENABLED` / `K8S_API_VIP` | `true` / `10.66.3.239` | API 浮动 VIP |
| `API_LOCAL_LB_ENABLED` | `true` | 节点侧本地代理 |
| `CEPH_ENABLED` / `CEPH_CSI_ENABLED` | `true` / `true` | Ceph 底座 + 供给层 |
| `CEPH_MODE` / `CEPH_NODE_ROLE` / `CEPH_MON_COUNT` | `internal` / `master` / `3` | 内部模式,存储节点=master,mon=3 |
| `CEPHFS_ENABLED` / `CEPH_RGW_ENABLED` | `true` / `true` | 文件存储 + S3 |
| `RDMA_ENABLED` / `RDMA_HCA_MODE` | `true` / `by-link` | RDMA 共享设备插件 |
| `GPU_OPERATOR_ENABLED` / `CONTAINERD_CONFIG_VERSION` | `true` / `3` | 沐曦 GPU operator |
| `NFD_ENABLED` / `LWS_ENABLED` | `false` / `false` | 未启用的可选能力 |

### 6.2 一页验证命令(交付/验收时照跑)

```bash
# 集群
kubectl get nodes -o wide
kubectl get endpoints kubernetes -n default              # 应为 3 条(master IP)
# 入口 HA
./deployments/scripts/deploy-cluster.sh --steps verify_kube_vip
./deployments/scripts/deploy-cluster.sh --steps verify_api_ha
# 网络暴露
./deployments/scripts/deploy-cluster.sh --steps verify_metallb
kubectl get ipaddresspool,l2advertisement -A
# 存储
./deployments/scripts/deploy-cluster.sh --steps verify_ceph
kubectl get sc && kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
# RDMA / GPU
./deployments/scripts/deploy-cluster.sh --steps verify_rdma_shared_dev_plugin
./deployments/scripts/deploy-cluster.sh --steps verify_metax_gpu
```

### 6.3 版本矩阵(【实机】本环境)

| 组件 | 版本 |
|---|---|
| Kubernetes | v1.35.8 |
| containerd | 2.3.5 |
| kubespray(树) | v2.32.0 |
| Rook / Ceph | v1.20.2 / v20.2.2 |
| ceph-csi / csi-operator | v3.17.0 / v1.0.4 |
| MetalLB | v0.13.9 |
| kube-vip | v1.0.3 |
| RDMA 设备插件 | v1.5.4 |
| 内置 registry | registry:2.8.1 |

### 6.4 相关文档

| 主题 | 文档 |
|---|---|
| 集群网络/存储/组件总览 | `docs/cluster-architecture.md` |
| API 入口高可用(方案、决策、运维、演练) | `docs/api-ha/`(README + 01–07) |
| kube-vip 实现细节与事故 | `docs/kube-vip-api-ha.md` |
| Ceph 全量(架构/参数/内外接入/排障) | `docs/ceph-rook.md` · `docs/ceph-backup-restore.md` |
| GPU operator | `docs/metax-gpu-operator.md` |
| LWS | `docs/lws.md` |
| RDMA 组件设计 | `deployments/cubestack-addon/rdma/CUBESTACK.md` |
| 排障手册(实测事故全集) | `docs/troubleshooting.md` |
| 镜像/Harbor 与离线资产 | `docs/harbor-mirror.md` · `deployments/offline-files/*/README.md` |
| 部署脚本开发规范 | `docs/scripts-development-spec.md` |

