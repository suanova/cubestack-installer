# 05 · 运维手册：查看、演练、排障

> 回答三个问题：**配置在哪看、进程在哪看、出事怎么查。**
> 所有命令均为只读，可在生产直接执行（演练部分除外，已单独标注）。

---

## 1. API 入口：现在到底是哪条路

```bash
# ① 部署机 kubectl 打的地址
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'; echo

# ② 这个名字解析到哪（决定一切）
getent hosts k8s-api.cubestack.io

# ③ 节点侧解析（kubespray 写的第 N 行；本方案的模块会收敛它）
for i in 28 29 31 32 33 34 35 36; do
  printf '3-%-3s ' $i; ssh -o BatchMode=yes ubuntu@10.66.3.$i "grep -h 'k8s-api' /etc/hosts"
done

# ④ 每个客户端实际用什么地址（最关键的两条）
ssh ubuntu@<worker> "sudo grep -m1 'server:' /etc/kubernetes/kubelet.conf"   # 本地代理模式: localhost:6443
ssh ubuntu@<master> "sudo grep -m1 'server:' /etc/kubernetes/kubelet.conf"   # 本地代理模式: 127.0.0.1:6443
ssh ubuntu@<master> "sudo grep -m1 'server:' /etc/kubernetes/admin.conf"

# ⑤ kube-proxy 的 in-cluster kubeconfig
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep server

# ⑥ 集群内 Pod 看到的 API 后端（应当有 3 条）
kubectl get endpoints kubernetes -n default
```

**判读**：`/etc/hosts` 指向单台 IP 且 `kubelet.conf` 是域名 → **单点状态**（[01](01-current-state.md)）。
目标状态要**分开看两侧**（⚠ 管理侧口径不同，见 [04 §4.1](04-decision.md#41-不变的部分明确边界)）：

| 侧 | 目标状态判据（本方案实施后即可观察到） |
|---|---|
| **节点侧** | `kubelet.conf` = `https://localhost:6443`（worker）/ `https://127.0.0.1:6443`（master），且节点 `/etc/hosts` 域名行 = 当前入口地址（`vip` 模式=VIP；`node` 模式=第一台 master）。核查用上面 ③④ |
| **集群内 Pod** | `kubectl get endpoints kubernetes -n default` 有 3 条端点（上面 ⑥） |
| **管理侧（部署机）** | ⚠ **仍是"单台 IP"**：部署机的 `/etc/hosts` 与 kubectl 直连 `API_IP`（第一台 master），**本方案未改这里**（不属回归，见 04 §4.1 的已知限制）。所以在本机看到"域名 → 单台 IP"**不代表配置没生效** —— 请以节点侧那两条为准，本机只用来发命令 |

> 换句话说：**别拿部署机的 `getent hosts k8s-api.cubestack.io` 当验收判据** —— 它在 `vip` 模式下也不会变成 VIP，
> 这是已知限制而非故障。`master01` 宕机时部署机 kubectl 会失联，属 [01 §8](01-current-state.md#8-单点清单本集群实测) 里**本方案未消除**的那一条。

---

## 2. master 上的服务与进程

```bash
# ── systemd 三层 ──
ssh ubuntu@<master> 'for s in kubelet containerd etcd docker; do printf "%-10s: " $s; systemctl is-active $s; done'
# 期望: kubelet/containerd/etcd = active, docker = inactive
# ⚠ 本集群 etcd 是宿主机原生二进制（ExecStart=/usr/local/bin/etcd），不是容器
ssh ubuntu@<master> 'systemctl show etcd -p ExecStart | head -2'

# ── 静态 Pod（kubelet 直接管，不经过 API）──
ssh ubuntu@<master> 'ls -l /etc/kubernetes/manifests/'
# 期望（本地代理模式）: kube-apiserver/controller-manager/scheduler + kube-vip.yml
ssh ubuntu@<worker> 'ls -l /etc/kubernetes/manifests/'
# 期望（本地代理模式）: nginx-proxy.yml

# ── 容器视角 ──
ssh ubuntu@<master> 'sudo crictl ps'
ssh ubuntu@<master> 'sudo crictl ps --name etcd -q'   # 空 = etcd 不在容器里

# ── 监听端口 ──
ssh ubuntu@<master> 'sudo ss -lntp | grep -E ":(6443|2379|2380|10250|10257|10259)\b"'
ssh ubuntu@<worker> 'sudo ss -lntp | grep -E ":(6443|10250|8081)"'
# 6443 = apiserver；2379/2380 = etcd；10250 = kubelet；10257/10259 = controller/scheduler
# 127.0.0.1:6443 + 8081 = nginx-proxy（本地代理模式才有）
```

---

## 3. 高可用组件：装了没有、谁是入口

```bash
# ── 有没有装（三种方案一起查）──
kubectl get pods -A | grep -iE 'vip|haproxy|keepalived|nginx-proxy'
ssh ubuntu@<any> 'ls /etc/kubernetes/manifests/ | grep -E "kube-vip|nginx-proxy|haproxy"'
ssh ubuntu@<any> 'systemctl is-active haproxy keepalived nginx'

# ── 有没有 VIP（本机和三台 master）──
ssh ubuntu@<master> "ip -4 -o addr show | grep -v -E 'kube-ipvs0|nodelocaldns|169.254|127.0.0.1'"
# ⚠ kube-ipvs0 上会有一堆 /32（Service VIP + MetalLB 地址），那不是 API VIP

# ── 证书 SAN 里有没有 VIP（判定"部署过 kube-vip"的硬证据）──
ssh ubuntu@<master> "sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text" \
  | grep -A4 'Subject Alternative Name'

# ── kube-vip 状态 ──
kubectl -n kube-system get pod -l k8s-app=kube-vip -o wide 2>/dev/null || true
ssh ubuntu@<master> 'sudo crictl ps --name kube-vip'
ssh ubuntu@<master> 'sudo crictl logs $(sudo crictl ps --name kube-vip -q) --tail 50 | grep -iE "leader|vip|lock"'

# ── 本地代理是否健康（启用后）──
ssh ubuntu@<worker> "curl -sk https://localhost:6443/healthz; echo; curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8081/healthz"
ssh ubuntu@<worker> 'cat /etc/nginx/nginx.conf'    # 看 upstream 列表与 least_conn
```

---

## 4. kube-proxy / ipvs

```bash
# ── 配置 ──
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E 'mode|scheduler|strictARP|clusterCIDR'

# ── 规则（⚠ 本集群宿主机没装 ipvsadm，kube-proxy 容器是 distroless）──
ssh ubuntu@<node> 'sudo cat /proc/net/ip_vs | head -5'        # 虚拟服务表
ssh ubuntu@<node> 'sudo cat /proc/net/ip_vs_conn | head -20'  # 活动连接（看真实转发去向）
ssh ubuntu@<node> 'sudo wc -l < /proc/net/ip_vs'              # 规则条数

# 十六进制解码速查
#   0AE90001 = 10.233.0.1    01BB = 443      192B = 6443
#   0A42031C = 10.66.3.28    0A42031D = .29  0A42031F = .31
# 例: "TCP 0AE90001:01BB → 0A42031F 192B" = kubernetes Service 转发到 10.66.3.31:6443

# 需要 ipvsadm 的完整视图时，用诊断 pod（需要时再装）
./deploy-cluster.sh --steps netshoot
kubectl -n default exec -it cubestack-netshoot -- ipvsadm -Ln
```

---

## 5. 网络：东西向 / 南北向

```bash
# ── Calico（东西向）──
kubectl get ippools.crd.projectcalico.org -o jsonpath='{range .items[*]}{.metadata.name}: cidr={.spec.cidr} ipip={.spec.ipipMode} vxlan={.spec.vxlanMode} block={.spec.blockSize}{"\n"}{end}'
kubectl get felixconfiguration default -o jsonpath='ipip={.spec.ipipEnabled} vxlan={.spec.vxlanEnabled}{"\n"}'
ssh ubuntu@<node> 'ip -4 route | head -15'      # 跨节点 Pod 路由 via tunl0
ssh ubuntu@<node> 'ip -d link show tunl0 | head -3'   # MTU 1480 = 1500 - IPIP 20

# ── MetalLB（南北向）──
kubectl get svc -A --field-selector spec.type!=ClusterIP
kubectl get ipaddresspool,l2advertisement -A
kubectl -n metallb-system get pods -o wide
kubectl -n metallb-system logs -l component=speaker --tail=100 | grep -i announc   # 谁在播报

# ── registry 实测 ──
curl -s -o /dev/null -w 'registry: %{http_code}\n' http://registry.cubestack.io:5000/v2/

# ── Ceph / 推理（hostNetwork 数据面）──
kubectl -n rook-ceph get pods -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,HOSTNET:.spec.hostNetwork,IP:.status.podIP'
kubectl -n metax-ai-pd get pods -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,IP:.status.podIP'
```

---

## 6. 故障演练（⚠ **会改动运行状态**，需在窗口内执行）

> 目标：验证"任意一台 master 宕机，客户端无感"。每条演练都要**先记录时间、后记录恢复时间**。

### B1 · 摘掉某 worker 的本地代理进程（验证自愈）

```bash
# 触发：把 nginx-proxy 容器杀掉（kubelet 应当自动重启它）
ssh ubuntu@<worker> 'sudo crictl ps --name nginx-proxy -q'      # 记下容器 ID
ssh ubuntu@<worker> 'sudo crictl rm -f <容器ID>'
# 验证：~10s 后
ssh ubuntu@<worker> 'sudo crictl ps --name nginx-proxy'          # 应已重建
ssh ubuntu@<worker> 'curl -sk https://localhost:6443/healthz'    # 应恢复 ok
```

### B2 · 后端黑洞演练（验证"2/3 后端挂掉仍零失败"）

```bash
# ⚠ 关键机制：nginx 不会自己重载配置，改 /etc/nginx/nginx.conf 也不触发 Pod 重建
#    （重建是由 manifest 里 nginx-cfg-checksum 注解变化触发的，那是 ansible 渲染时做的）
#    所以手工演练必须**自己强制重建**容器 —— 见下面第 2 步
ssh ubuntu@<worker> 'sudo cp /etc/nginx/nginx.conf /tmp/nginx.conf.bak'      # 1. 备份
# 2. 把 upstream 里 2 个 server 改成 192.0.2.1:6443（TEST-NET，必然黑洞）
ssh ubuntu@<worker> 'sudo sed -i "0,/server 10\.66\.3\.29:6443/s//server 192.0.2.1:6443/" /etc/nginx/nginx.conf'
# 3. 强制重建：删掉容器，kubelet 会用新配置重启它
ssh ubuntu@<worker> 'sudo crictl rm -f $(sudo crictl ps --name nginx-proxy -q)'
sleep 15
# 4. 打 20 次
ssh ubuntu@<worker> 'for i in $(seq 20); do curl -sk -o /dev/null -w "%{http_code} %{time_total}\n" https://localhost:6443/healthz; done'
# 期望：20/20 = 200，绝大多数 ~0.004s，最坏 ≤1.01s
# 5. 还原（同样需要强制重建）
ssh ubuntu@<worker> 'sudo cp /tmp/nginx.conf.bak /etc/nginx/nginx.conf'
ssh ubuntu@<worker> 'sudo crictl rm -f $(sudo crictl ps --name nginx-proxy -q)'
ssh ubuntu@<worker> 'curl -sk https://localhost:6443/healthz'               # 应恢复 ok
```

### B3 · 停一台 master 的 apiserver（验证节点侧无感）

```bash
# 选一台【非 VIP 持有者】的 master，临时移走 manifest
ssh ubuntu@<master2> 'sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /root/'
# 验证：其余节点 kubelet 应无感
ssh ubuntu@<worker> 'curl -sk https://localhost:6443/healthz'   # 仍 ok
kubectl get nodes                                                # 仍全部 Ready
# 还原
ssh ubuntu@<master2> 'sudo mv /root/kube-apiserver.yaml /etc/kubernetes/manifests/'
```

### B4 · 停 VIP 持有者（验证外部入口切换）

```bash
# 先看谁是持有者
ssh ubuntu@<master> 'ip -4 addr show | grep <VIP>'    # 哪台有 VIP 就是持有者
# 在该台上停 kube-vip（不是停节点，这样能测"进程退出"与"节点失联"两种语义）
ssh ubuntu@<vip-holder> 'sudo crictl rm -f $(sudo crictl ps --name kube-vip -q)'
# 验证：记录 kubectl 开始报错到恢复的时间
while ! kubectl get nodes >/dev/null 2>&1; do echo "$(date +%T) 不可用"; sleep 1; done; echo "$(date +%T) 恢复"
```

### B5 · 回滚演练（可选）

本方案面向**全新安装**，因此"回滚"= 关掉开关重新部署，而不是在线回退：

```bash
# 在演练集群上验证：API_LOCAL_LB_ENABLED=false 重新部署后
#   ① worker 的 kubelet.conf 回到 https://k8s-api.cubestack.io:6443
#   ② nginx-proxy.yml 被模块清理掉
#   ③ 集群仍可正常 kubectl
```
⚠ 需先确认这条路径真的可用（**未实机验证**）—— 这是本方案唯一的"退路"验证项。

---

## 7. 排障决策树

```
kubectl 报错 / 节点 NotReady
│
├─ ① 先看入口是哪条路
│    getent hosts k8s-api.cubestack.io
│    ├─ 解析到单台 master → 该 master 是否活着？(ping / ssh / ss :6443)
│    │     └─ 这就是当前架构的已知单点（见 docs/api-ha/01）
│    └─ 解析到 VIP
│          └─ VIP 现在被谁持有？ sudo crictl ps --name kube-vip / ip addr
│                └─ 无人持有 → kube-vip 静态 Pod 是否 Running？日志里的 leader 选举？
│
├─ ② 单个节点失联，其余正常
│    ssh <node> 'curl -sk https://localhost:6443/healthz'     ← 本地代理模式
│    ├─ 不通 → 看 nginx-proxy 静态 Pod / /etc/nginx/nginx.conf 的 upstream
│    └─ 通   → 问题不在 API 入口，看 kubelet 日志 (journalctl -u kubelet)
│
├─ ③ 全集群同时失联
│    ├─ 三台 master 都活着？ → 大概率是入口/VIP 层
│    ├─ 三台都不行 → etcd quorum？(etcdctl endpoint status) / 证书是否过期
│    └─ 网络层：calico-node 是否 Ready
│
└─ ④ 只有 Pod 内访问 API 失败（kubelet 正常）
     查 kubernetes Service 的 endpoints 是否 3 条
     kubectl get endpoints kubernetes -n default
     └─ 只有 1 条 → advertise-address 被写死成单台（见 docs/kube-vip-api-ha.md §2.5）
```

**排障用的三条"第一手"证据**（比任何日志都快）：

```bash
ssh ubuntu@<node> 'sudo grep -m1 server: /etc/kubernetes/kubelet.conf'  # 客户端意图
ssh ubuntu@<node> 'sudo cat /proc/net/ip_vs_conn | head -20'            # 实际转发
ssh ubuntu@<node> 'sudo ss -lntp | grep 6443'                           # 谁在监听
```

---

## 8. 一行速查（复制即用）

```bash
# 入口总览
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'; echo; getent hosts k8s-api.cubestack.io

# 三台 master 是否都活着
for i in 28 29 31; do printf '3-%s: ' $i; ssh -o ConnectTimeout=5 -o BatchMode=yes ubuntu@10.66.3.$i 'sudo systemctl is-active kubelet; sudo ss -lnt | grep -c ":6443"'; done

# 全集群节点侧入口一览
for i in 28 29 31 32 33 34 35 36; do printf '3-%-3s ' $i; ssh -o ConnectTimeout=5 -o BatchMode=yes ubuntu@10.66.3.$i "sudo grep -m1 -o 'server:.*' /etc/kubernetes/kubelet.conf"; done

# 集群内 API 端点
kubectl get endpoints kubernetes -n default

# 入口是否已切到 VIP
kubectl get svc -A --field-selector spec.type!=ClusterIP | grep -v NodePort
```
