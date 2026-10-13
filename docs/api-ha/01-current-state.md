# 01 · 现状分析（实机取证）

> 取证时间：**2026-09-27** · 集群：`mxgpu-3-28/29/31`（control-plane）+ `mxgpu-3-32…36`（worker），共 8 台
> 取证方式：`kubectl`（部署机）+ `ssh ubuntu@10.66.3.28/29/31/32`（免密 sudo），全程只读
> 复现命令见本文 [附录](#附录一键复现)
>
> 🔁 **后续状态（2026-09-28 起）**：本文是**取证时刻的快照**，它测出的那个单点已被落地消除 ——
> `docs/api-ha/` 的 ①+② 组合方案已实施（见 [04-decision.md](04-decision.md)），kube-vip 实机生效：
> `/etc/kubernetes/manifests/kube-vip.yml` 在场、容器 Running、**VIP `10.66.3.240` 已绑定到节点网卡**。
> 因此 **§3.5 / §3.6（"kube-vip 从未部署"）与 §8 单点清单第 1 行属于历史快照**，保留作为基线，
> **不再代表现状**（这张快照证明的"当时确实没有 VIP"，正是后面所有验证要对照的起点）。
> ⚠ kube-vip 侧实现在 2026-09-28 又变过一次（**收编**：静态 Pod 清单改由 kubespray 自己渲染），
> 见 [07-kube-vip-upstream-assessment.md](07-kube-vip-upstream-assessment.md) 与
> [../kube-vip-api-ha.md §19](../kube-vip-api-ha.md#19-收编静态-pod-写入权交还上游2026-09-28)。

---

## 1. 结论先行

| 问题 | 答案 |
|---|---|
| API 入口是高可用吗？ | **不是**。全集群所有客户端都指向 **master01（10.66.3.28）单点** |
| 有 VIP 吗？ | **没有**。三台 master 上都没有额外地址，证书 SAN 里也没有 VIP |
| 装了 LB 组件吗？ | **没有**。kube-vip / haproxy / keepalived / nginx-proxy 一个都没有 |
| 那三台 master 是白装的吗？ | 不是 —— **集群内 Pod 访问 API 已经是三台负载均衡**（ipvs），只有"节点级/管理级"是单点 |
| 数据面（etcd）健康吗？ | **健康**。3 成员 quorum 正常，无错误 |

一句话：**数据面是 HA 的，客户端入口不是。**

---

## 2. 集群基本盘

```
$ kubectl get nodes
NAME         STATUS   ROLES           AGE    VERSION   INTERNAL-IP   CONTAINER-RUNTIME
mxgpu-3-28   Ready    control-plane   3d5h   v1.32.5   10.66.3.28    containerd://2.0.5
mxgpu-3-29   Ready    control-plane   3d5h   v1.32.5   10.66.3.29    containerd://2.0.5
mxgpu-3-31   Ready    control-plane   3d5h   v1.32.5   10.66.3.31    containerd://2.0.5
mxgpu-3-32…36  Ready  <none>          3d5h   v1.32.5   10.66.3.32-36 containerd://2.0.5
```

| 组件 | 版本 |
|---|---|
| Kubernetes | v1.32.5 |
| 容器运行时 | containerd 2.0.5 |
| OS / 内核 | Ubuntu 22.04.5 / 5.15.0-119-generic |
| Calico | `quay.io/calico/node:v3.29.3` |
| kube-proxy | `registry.k8s.io/kube-proxy:v1.32.5`（**ipvs 模式**） |
| MetalLB | `quay.io/metallb/speaker:v0.13.9`（L2） |
| etcd | 3.5.16，三成员 |

etcd 健康（在 master01 上执行 `etcdctl endpoint status`）：

```
| ENDPOINT               | ID               | VERSION | DB SIZE | IS LEADER | ERRORS |
| https://10.66.3.28:2379| 766a6a0180289f69 | 3.5.16  | 494 MB  |  false    |        |
| https://10.66.3.29:2379| 5a732b4af2496804 | 3.5.16  | 496 MB  |  false    |        |
| https://10.66.3.31:2379| 6daaea38404e8ca3 | 3.5.16  | 530 MB  |  true     |        |
```

> 三台成员的 `RAFT APPLIED INDEX` 完全一致（3948663），说明 quorum 与复制都是健康的。
> **etcd 层已经是 HA**，问题不在这一层。

---

## 3. API 入口链路（本文核心）

### 3.1 客户端视角

| 客户端 | 实际连的地址 | 证据 |
|---|---|---|
| 部署机 `kubectl` | `https://k8s-api.cubestack.io:6443` → `10.66.3.28` | `kubectl config view --minify` |
| **每台节点的 kubelet** | 同上（**含三台 master 自己的 kubelet**） | `kubelet.conf` |
| kube-proxy | 同上 | `kube-proxy.conf` / ConfigMap |
| master 上的 `kubectl` | 同上 | `admin.conf` / `super-admin.conf` |
| 节点上的组件（按域名连） | 同上 | 各节点 `/etc/hosts` |
| **集群内 Pod** | `kubernetes.default.svc` → ipvs 轮询三台 ✅ | EndpointSlice + ipvs 活连接 |

### 3.2 证据：`/etc/hosts` 的静态映射

三台 master **和** worker，**每一台**都是同一行：

```
$ for i in 28 29 31 32; do ssh ubuntu@10.66.3.$i "grep -h 'k8s-api' /etc/hosts"; done
10.66.3.28      k8s-api.cubestack.io       # ← 三台 master 全部指向 .28
10.66.3.28      k8s-api.cubestack.io
10.66.3.28      k8s-api.cubestack.io
10.66.3.28      k8s-api.cubestack.io       # ← worker01 也指向 .28
```

这行由 kubespray 的 preinstall 任务写入（`roles/kubernetes/preinstall/tasks/0090-etchosts.yml:31`；
⚠ 2026-09-28 注：**v2.32 树已删除该任务**，现由本仓库 `modules/02_k8s/03_k8s_hosts.sh` 写；当时（v2.28 树）的判断无误），
数据源是 `group_vars/all/all.yml` 的 `loadbalancer_apiserver.address`。

### 3.3 证据：kubelet 的实际 server

```
$ ssh ubuntu@10.66.3.32 "sudo grep server: /etc/kubernetes/kubelet.conf"
    server: https://k8s-api.cubestack.io:6443      # worker01 → /etc/hosts → 10.66.3.28
```

**关键点：三台 master 自己的 kubelet 也是同一个地址**（走域名 → .28），而不是各自的本地 apiserver。
这是"外部 LB 分支优先"的必然结果（见 [02 文档 §5](02-kubespray-native-lb.md#5-入口推导链核心)）。

### 3.4 证据：admin.conf / super-admin.conf

```
$ ssh ubuntu@10.66.3.28 "sudo grep -m1 'server:' /etc/kubernetes/admin.conf /etc/kubernetes/super-admin.conf"
/etc/kubernetes/admin.conf:       server: https://k8s-api.cubestack.io:6443
/etc/kubernetes/super-admin.conf: server: https://k8s-api.cubestack.io:6443
```

### 3.5 证据：证书 SAN —— **判定"kube-vip 从未部署"的硬证据**

```
$ ssh ubuntu@10.66.3.28 "sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text" | grep -A3 'Subject Alternative'
  X509v3 Subject Alternative Name:
    DNS:k8s-api.cubestack.io, DNS:kubernetes, DNS:kubernetes.default,
    DNS:kubernetes.default.svc, DNS:kubernetes.default.svc.cluster.local,
    DNS:localhost, DNS:mxgpu-3-28, DNS:mxgpu-3-29, DNS:mxgpu-3-31,
    IP Address:10.233.0.1, IP Address:10.66.3.28, IP Address:127.0.0.1,
    IP Address:0:0:0:0:0:0:0:1, IP Address:10.66.3.29, IP Address:10.66.3.31
```

**SAN 里没有任何 VIP 地址。** 证书不会因为组件被清理而回退，因此可以断定：
**kube-vip 从未在这套集群上部署过**（若部署过，VIP 必然在 SAN 里，见
[kube-vip-api-ha.md §18](../kube-vip-api-ha.md)）。

### 3.6 证据：确实没有任何 LB 组件

| 检查 | 结果 |
|---|---|
| 静态 Pod 清单 `ls /etc/kubernetes/manifests/` | 只有 `kube-apiserver.yaml` / `kube-controller-manager.yaml` / `kube-scheduler.yaml` |
| `kubectl get pods -A \| grep -iE 'vip\|haproxy\|keepalived\|nginx-proxy'` | 空 |
| `systemctl is-active haproxy keepalived nginx`（master01） | `inactive / inactive / inactive` |
| `/etc/haproxy` `/etc/keepalived` `/etc/nginx` | 不存在 |
| master01 网卡地址 `ip -4 -o addr show` | 只有 `br-lan 10.66.3.28/24`（**无 VIP**）+ `virbr0` + `nodelocaldns 169.254.25.10` + `kube-ipvs0` 若干 /32 + `tunl0` |

> 注：`kube-ipvs0` 上的 /32 是 kube-proxy ipvs 模式的正常产物（Service VIP 与 MetalLB 地址都绑在这里），
> **不是** API 的 VIP。

### 3.7 那么单点到底在哪

```
                        ┌──────────────────────────┐
   所有节点 kubelet ────┤                          │
   kube-proxy      ────┤  k8s-api.cubestack.io    │
   kubectl/CI      ────┤  /etc/hosts → 10.66.3.28 ├──→ [mxgpu-3-28]  ← 唯一入口
   外部系统        ────┤                          │        ▲
                        └──────────────────────────┘        │
                                                   mxgpu-3-29 / 3-31
                                                   （apiserver 健康，但无客户端使用）
```

**master01 宕机 = 全集群失联**（不是降级）：kubelet 无法上报、新 Pod 无法调度、
controller/Service/PVC 交互全断；只有已经在跑的 Pod 之间的东西向流量不受影响。

---

## 4. 集群内（Pod 侧）其实已经是均衡的

这一层**当前已满足**，作为回归基线记录：

```
$ kubectl get endpoints kubernetes -n default
NAME         ENDPOINTS                                            AGE
kubernetes   10.66.3.28:6443,10.66.3.29:6443,10.66.3.31:6443      3d5h
```

内核 ipvs 活连接（在 master01 上读 `/proc/net/ip_vs_conn`，无需 ipvsadm）：

```
Pro FromIP   FPrt ToIP     TPrt DestIP   DPrt State       Expires
TCP 0AE939D5 BC72 0AE939D5 01BB 0AE9640C 280A ESTABLISHED     871
TCP 0AE90001 939C 0AE90001 01BB 0A42031F 192B ESTABLISHED     875   ← 10.233.0.1:443 → 10.66.3.31:6443
TCP 0AE90001 8A32 0AE90001 01BB 0A42031D 192B ESTABLISHED     884   ← → 10.66.3.29:6443
TCP 0AE96410 E7AE 0AE90001 01BB 0A42031F 192B ESTABLISHED     899   ← → 10.66.3.31:6443
TCP 0AE9640C E6D4 0AE90001 01BB 0A42031C 192B ESTABLISHED     899   ← → 10.66.3.28:6443
```

解码：`0AE90001` = `10.233.0.1`（kubernetes Service），`01BB` = 443，`0A42031C/D/F` = `10.66.3.28/29/31`，
`192B` = 6443。**同一个 Service 的连接被分散到三台 master** —— ipvs 的 `rr` 在正常工作。

> 为什么这里能均摊而 kubelet 不能：apiserver 的 `--advertise-address` 是**各节点自己的 IP**
> （master01 上是 `10.66.3.28`），所以 `kubernetes` Service 的 EndpointSlice 有 3 条；
> 而 kubelet 走的是 `/etc/hosts` 的**静态域名映射**，与 Service 无关。

---

## 5. 南北向（集群外 ↔ 集群内）现状

| 入口 | 地址 | 状态 |
|---|---|---|
| API Server | 各 master `*:6443` 监听，但**域名固定指 .28** | ⚠ 单点 |
| registry | `10.66.3.235:5000`（**MetalLB L2**） | ✅ 实测 `HTTP 200` |
| registry（备用） | 任一节点 `:30141` NodePort | ✅ 存在 |
| metax 调度器指标 | `:31680` NodePort | ❌ **无后端 endpoints，当前不可达** |
| 推理服务（sglang） | hostNetwork，节点 IP `:3xxxx`（**master01 上 74 个**） | ✅ 直开，不经 kube-proxy |
| Ceph (RGW/mon/mgr) | 仅 ClusterIP + `hostNetwork` | 未对外暴露 |
| ingress-nginx / Gateway / Envoy | — | 均未启用（Gateway/Envoy 已从仓库移除） |

registry Service 细节（MetalLB 侧）：

```yaml
type: LoadBalancer
loadBalancerIP: 10.66.3.235          # 池: 10.66.3.235-237 (ipaddresspool/primary)
ports: [{name: registry, port: 5000, targetPort: 5000, nodePort: 30141}]
annotations:
  metallb.universe.tf/allow-shared-ip: cubestack-shared-vip   # 为将来共用 VIP 留的口子
  metallb.universe.tf/ip-allocated-from-pool: primary
```

MetalLB 形态：`speaker` 是 **8 节点 DaemonSet**（L2 模式，`L2Advertisement primary`），
`controller` 在 `mxgpu-3-31`；kube-proxy `strictARP: true`（L2 必需）。

各节点 `/etc/hosts`：`10.66.3.235 registry.cubestack.io`。

---

## 6. 东西向（集群内互访）现状

分三层，粒度完全不同：

### 6.1 通用 Pod 网络 —— Calico + IPIP 隧道

```
$ kubectl get ippools.crd.projectcalico.org -o jsonpath=...
default-pool: cidr=10.233.64.0/18  ipipMode=Always  vxlanMode=Never  blockSize=26  natOutgoing=true

$ ssh ubuntu@10.66.3.32 "ip route"
10.233.68.64/26 via 10.66.3.34 dev tunl0 proto bird onlink    ← 跨节点走 IPIP 隧道
10.233.70.193 dev cali7d9a6b079e5 scope link                  ← 本节点 Pod 走 veth
$ ip -d link show tunl0
    link/ipip ... mtu 1480                                    ← 1500 − 20 (IPIP 头)
```

| 项 | 值 |
|---|---|
| Service CIDR | `10.233.0.0/18`（apiserver `--service-cluster-ip-range`） |
| Pod CIDR | `10.233.64.0/18`（kube-proxy `clusterCIDR`），每节点 `/26` |
| 封装 | IPIP Always（外层 = 节点 IP），MTU 1480 |
| DNS | CoreDNS + 每节点 `nodelocaldns`（`169.254.25.10:53`） |

> 选 IPIP 不是默认偏好：底层 fabric 只放行 IP proto 4，丢弃 UDP 4789（VXLAN），详见
> [../cluster-architecture.md](../cluster-architecture.md) 第 34 行起。

### 6.2 Service 负载均衡 —— kube-proxy IPVS

```yaml
mode: ipvs
ipvs: {scheduler: rr, strictARP: true}
nodePortAddresses: []
clusterCIDR: 10.233.64.0/18
```

全节点共 **87 条虚拟服务 / 本次采样 16 条活动连接**。实测转发样本见 §4。

### 6.3 数据面绕行（**大流量不走 CNI**）

| 负载 | 网络模式 | 说明 |
|---|---|---|
| Metax 推理（prefill/decode/hicache/mooncake） | `hostNetwork: true` | 直接用节点 IP + 主机端口，**完全绕过 CNI 与 kube-proxy** |
| Ceph mon/osd/mgr | `hostNetwork: true` | mon 在 .28/.29/.31，直接监听节点 IP:6789/3300 |
| RDMA | 设备插件 | 计划资源名：每节点 `rdma/ib_shared_devices: 100` + `rdma/roce_shared_devices: 100`；尚需重跑 `rdma_shared_dev_plugin` 并核验节点 allocatable，未确认为当前部署状态 |
| GPU | 设备插件 | 每节点 `metax-tech.com/gpu: 8` |

---

## 7. 顺带发现的问题（与入口 HA 无关，但建议记一笔）

| # | 发现 | 影响 | 证据 |
|---|---|---|---|
| 1 | **Multus NAD 指向不存在的网卡**：`multus-nad` 配置为 `macvlan master=eth0`，但节点上没有 `eth0`（实际是 `manage0`，master 上还桥接为 `br-lan`） | 任何 Pod 引用该二级网络都会失败（当前无 Pod 使用，所以静默） | `kubectl -n kube-system get net-attach-def multus-nad -o jsonpath={.spec}`；`ssh … ip -o link show eth0` → 不存在 |
| 2 | metax 调度器指标 NodePort `31680` **无后端 endpoints** | 端口对外可达性为假（连接被拒） | `kubectl -n metax-operator get endpoints metax-gpu-scheduler-metrics` → 空 |
| 3 | 节点上残留他环境 hosts 条目（`shanghai-d-master01/02/03 → 192.168.16.x`） | 无功能影响，排查时易误导 | worker01 `/etc/hosts:18-20` |

---

## 8. 单点清单（本集群实测）

| 单点 | 故障后果 | 影响面 |
|---|---|---|
| **master01（10.66.3.28）** | 全集群 API 失联 | **全部**节点级 + 管理级 + 外部 |
| master02 / master03 | 无影响（当前无客户端使用） | — |
| 部署机 `/etc/hosts` | 部署机 kubectl/CI 失联 | 运维面 · ⚠ **本方案未消除**（只解决了节点侧/外部侧；**部署宿主机**自身解析仍写第一台 master，见 [04 §4.1](04-decision.md#41-不变的部分明确边界)）—— ⚠ 2026-09-28 起**部署容器**里那份改为跟随入口，两份文件不是一回事 |
| MetalLB speaker 单点 | registry 等 LB 地址失联（L2 模式下由 elected speaker 播报） | 南北向 components |

> 只有第一条是"入口 HA"要解决的问题。第二条恰好说明**已经具备 HA 的物理条件，只是没接线**。
> 第三行（部署机 `/etc/hosts`）**不在本方案的消除范围内** —— 它是"改部署机解析"这个独立后续项，
> 别把它读成已解决（[04 §4.1](04-decision.md#41-不变的部分明确边界) 有理由与修法入口）。

---

## 附录：一键复现

```bash
# ── 入口链路 ──
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'; echo
getent hosts k8s-api.cubestack.io
for i in 28 29 31 32; do ssh ubuntu@10.66.3.$i "grep -h 'k8s-api' /etc/hosts"; done
ssh ubuntu@10.66.3.32 "sudo grep server: /etc/kubernetes/kubelet.conf"
ssh ubuntu@10.66.3.28 "sudo grep -m1 'server:' /etc/kubernetes/admin.conf"

# ── 证书 SAN（判定有无 VIP 的硬证据）──
ssh ubuntu@10.66.3.28 "sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text" \
  | grep -A3 'Subject Alternative'

# ── 有无 LB 组件 ──
kubectl get pods -A | grep -iE 'vip|haproxy|keepalived|nginx-proxy'
ssh ubuntu@10.66.3.28 "ls /etc/kubernetes/manifests/; ip -4 -o addr show | grep -v kube-ipvs0"

# ── 集群内是否均衡 ──
kubectl get endpoints kubernetes -n default
ssh ubuntu@10.66.3.28 "sudo cat /proc/net/ip_vs_conn | head"

# ── etcd 健康 ──
ssh ubuntu@10.66.3.28 "sudo ETCDCTL_API=3 /usr/local/bin/etcdctl \
  --endpoints=https://10.66.3.28:2379,https://10.66.3.29:2379,https://10.66.3.31:2379 \
  --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/node-mxgpu-3-28.pem \
  --key=/etc/ssl/etcd/ssl/node-mxgpu-3-28-key.pem endpoint status -w table"

# ── 南北向 ──
kubectl get svc -A --field-selector spec.type!=ClusterIP
kubectl get ipaddresspool,l2advertisement -A
curl -s -o /dev/null -w '%{http_code}\n' http://registry.cubestack.io:5000/v2/   # 期望 200

# ── 东西向 ──
kubectl get ippools.crd.projectcalico.org -o yaml | grep -E 'cidr|ipipMode|vxlanMode|blockSize'
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E 'mode|scheduler|strictARP'
```
