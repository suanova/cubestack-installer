# CubeStack 脚本使用手册(CLI)

本目录脚本提供完整的**命令行自动化**能力:从宿主网络初始化、SSH 密钥、master 虚拟机创建与免密登录,到 kubespray 兼容 inventory 生成与(可选)K8s 部署。

所有脚本**统一读取** `config/cluster.conf`(唯一数据源),不硬编码 IP / 用户名 / 密码 / 路径。配置优先级:**环境变量 > 配置文件 > 内置兜底默认**。

> UI 兼容性:统一配置结构清晰,`gen-inventory.sh` 同时产出后端风格的 `inventory.ini`,后期 installer 后端可复用同一份 `cluster.conf`。

---

## 1. 快速开始

```bash
# 0) 首次:从模板生成真实配置并按实际环境修改(真实配置含密码,已被 .gitignore)
cp config/cluster.conf.example config/cluster.conf
vim config/cluster.conf          # 修改 宿主机/网络/SSH/节点清单

# 1) 查看集群规划(只读)
sudo ./scripts/deploy-cluster.sh --list

# 2) 一键部署(宿主网络 → SSH密钥 → master虚拟机+免密 → worker连通性 → inventory)
sudo ./scripts/deploy-cluster.sh

# 3) 可选:继续执行 kubespray 集群部署(需 ansible-playbook)
sudo ./scripts/deploy-cluster.sh --skip-net --with-k8s
```

---

## 2. 目录与文件

```
scripts/
├── lib-common.sh          # 公共库:统一配置加载 + IP/MAC 工具(被所有脚本 source)
├── deploy-cluster.sh      # ★ 一键编排(主入口)
├── gen-ssh-key.sh         # 生成集群 SSH 密钥对(幂等)
├── setup-passwordless.sh  # 注入公钥实现目标主机免密登录
├── gen-inventory.sh       # 从配置生成 kubespray 兼容 inventory(hosts.yml + inventory.ini)
├── create-libvirt-vm.sh   # 创建单台 Ubuntu22.04 虚拟机(静态IP,配置驱动)
├── setup-vm-network.sh    # 方案A:创建 privbr0 网桥网络(建桥/回程路由/SNAT/自启)
├── setup-libvirt-nat.sh   # 方案B:创建 libvirt NAT 网络(含 --delete 回滚)
├── verify-vm-network.sh   # 验证宿主网络配置与连通性
├── teardown-vm-network.sh # 回滚方案A桥接网络(SNAT/路由/自启,可删网桥)
├── dev.sh / start-backend.sh / start-frontend.sh   # 项目原有开发/启动脚本
```

统一配置:见 `config/cluster.conf`(真实,已 gitignore)与 `config/cluster.conf.example`(模板,提交)。

---

## 3. 统一配置文件(config/cluster.conf)

配置分四大块,字段含义见文件内注释:

| 区块 | 关键项 | 说明 |
|---|---|---|
| 宿主机 | `HOST_PHYS_IP` `BASE_IMG` `VM_DISK_DIR` | 物理IP(SNAT源)、基础镜像、VM磁盘目录 |
| 网络规划 | `NET_MODE`(bridge/nat)、`BRIDGE` `BRIDGE_IP` `VM_SUBNET` `PHYS_WORKER_NET` / `NAT_NET_NAME` `NAT_SUBNET` `NAT_GATEWAY` | 双方案网段/网关/SNAT目标 |
| SSH | `SSH_KEY_NAME` `SSH_DEFAULT_PASSWORD` `VM_SSH_USERS` `WORKER_SSH_PASSWORD` | 密钥、虚拟机预埋密码、免密用户、裸金属密码 |
| 节点规划 | `NODES=( ... )` | 每行一节点,master(虚拟机)/worker(裸金属) |
| kubespray | `KUBESPRAY_INV_DIR` `KUBESPRAY_DIR` `UPDATE_ETC_HOSTS` | inventory 输出位置、playbook 位置、是否写 /etc/hosts |

### 节点行格式

```
role,hostname,ip,mac,mem_g,cpu,disk_g,ssh_user,ssh_password
```

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

### 5.1 deploy-cluster.sh —— 一键编排(主入口)

```bash
sudo ./scripts/deploy-cluster.sh                # 全流程
sudo ./scripts/deploy-cluster.sh --skip-net     # 跳过宿主网络初始化
sudo ./scripts/deploy-cluster.sh --only <host>  # 仅处理指定节点(可多次)
sudo ./scripts/deploy-cluster.sh --with-k8s     # 完成后执行 kubespray cluster.yml
sudo ./scripts/deploy-cluster.sh --list         # 仅打印集群规划(只读)
```

流程:`宿主网络 → SSH密钥 → master虚拟机创建+免密 → worker连通性检查 → /etc/hosts(可选) → 生成inventory → (可选)k8s`。master 已存在则跳过创建、自动 `virsh start`;worker 仅做只读连通性检查,**不会修改裸金属**。

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
./scripts/gen-inventory.sh
```

生成:
- `deployments/kubespray/inventory/cubestack-cluster/hosts.yml` —— **kubespray 实际使用**(注意 kubespray 的 ansible.cfg 忽略 `.ini`)
- 同目录 `inventory.ini` —— 兼容 installer 后端风格(参考/后续 UI 用)

master 写入 `ansible_ssh_private_key_file`(密钥免密);worker 写入 `ansible_password`(密码认证,未配置则留注释)。

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
