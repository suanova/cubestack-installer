# Installer 运行依赖工具清单

> 运行 CubeStack installer（`deploy-cluster.sh` 及其 modules/tools）**必要的外部工具**。
> 用途：作为**构建 installer 容器镜像**的依据 —— 镜像内需预装以下工具 + 仓库代码 + kubespray/python 虚拟环境。
> 分类按部署阶段（env 准备 / k8s 部署 / addon / 通用）。

## 0. 基础操作系统

- **Ubuntu 22.04 amd64**（与节点同基座，保证 kubectl/containerd 等二进制兼容）
- 基础命令行：`bash`、`sed`、`awk`、`grep`、`cut`、`head`、`tail`、`tr`、`sort`、`uniq`、`wc`、`cat`、`ls`、`find`、`xargs`、`date`、`sleep`、`seq`、`mktemp`、`dirname`、`basename`、`realpath`、`id`、`whoami`、`hostname`、`uname`、`getent`、`stat`、`du`、`df`、`touch`、`cmp`、`md5sum`、`sha256sum`（coreutils 全量）

## 1. SSH / 远程执行

| 工具 | 用途 | 包 |
|---|---|---|
| `ssh` / `scp` | 连接节点、传文件（部署全程核心） | openssh-client |
| `ssh-keygen` | 生成 SSH 密钥 | openssh-client |
| `sshpass` | 密码回退认证（节点无密钥时） | sshpass |
| `rsync` | 同步（可选） | rsync |

## 2. Kubernetes / 容器运行时

| 工具 | 用途 | 说明 |
|---|---|---|
| `kubectl` | 集群操作/验证 | 版本与集群匹配（v1.32） |
| `helm` | 组件安装（gpu_operator 等） | v3+ |
| `docker` | 镜像 save/load（离线 tar、本地镜像推送） | 版本≥20，API v1.44+ |
| `nerdctl` | 备用容器工具（可选，metax .run nerdctl 模式） | 可选 |
| `ctr` / `containerd` | metax .run 镜像加载、registry 操作 | containerd CLI |
| `podman` | 备用容器工具（可选） | 可选 |
| `skopeo` | **离线 tar → 集群 registry 推送**（核心） | 需支持 docker-archive |

> `docker-daemon:` 传输在当前 docker 下 API 版本过旧不可用 → 用 `docker save` + skopeo `docker-archive` 推送（已实现）。

## 3. 网络 / 防火墙

| 工具 | 用途 | 包 |
|---|---|---|
| `ip` | 网卡/路由检测、VIP 管理 | iproute2 |
| `iptables` | 宿主机 DNAT/SNAT（registry 对外、VM 网络） | iptables |
| `nft` | nftables（备用，iptables 后端） | nftables |
| `sysctl` | 内核参数（IP 转发、br_netfilter） | procps |
| `modprobe` / `kmod` | 内核模块加载（br_netfilter、overlay） | kmod |
| `conntrack` | 连接跟踪（网络排查） | conntrack |
| `ss` | socket 排查 | iproute2 |
| `ping` | 连通性检测 | iputils-ping |
| `route` | 路由查看/管理（备用） | iproute2 |
| `curl` / `wget` | HTTP 探测、镜像/包下载 | curl |
| `haproxy` | API 四层负载均衡（`--enable lb_haproxy`） | haproxy |
| `keepalived` | API VIP 高可用（`--enable lb_keepalived`） | keepalived |
| `dnsmasq` | VM 网络 DHCP（可选） | dnsmasq |

## 4. 虚拟化（仅 VM 阶段，`--skip-net` 裸金属可省）

| 工具 | 用途 | 包 |
|---|---|---|
| `virt-install` | 创建 VM | virtinst |
| `virt-customize` | 定制 VM 镜像（注入 SSH/配置） | libguestfs-tools |
| `virt-sparsify` | VM 磁盘瘦化（可选） | libguestfs-tools |
| `virsh` | libvirt 管理 VM | libvirt-clients |
| `qemu-img` | VM 磁盘操作 | qemu-utils |
| `libvirtd` | libvirt 守护进程 | libvirt-daemon-system |
| `cloud-init` | VM cloud-init（可选） | cloud-init |

## 5. 系统 / 服务管理

| 工具 | 用途 | 包 |
|---|---|---|
| `systemctl` | 管理 systemd 服务（containerd、haproxy、registry DNAT 单元等） | systemd |
| `timedatectl` | 时区/时间 | systemd |
| `chronyd` / `chronyc` | NTP 时间同步（节点 + 宿主） | chrony |
| `useradd` / `groupadd` / `passwd` | 节点用户管理（可选） | passwd |
| `apt-get` / `apt` / `dpkg` | 节点软件包安装（worker 依赖） | apt |

## 6. kubespray / Python

- `python3`（≥3.9）+ pip
- kubespray 虚拟环境（`deployments/kubespray/kubespray/` 内 venv）：`ansible`、`ansible-playbook`、
  `ansible-galaxy`、`jinja2`、`cryptography`、`PyYAML` 等（kubespray requirements.txt）
- `git`（拉取 kubespray 源码/仓库，首次准备）

## 7. 加密 / 归档

| 工具 | 用途 | 包 |
|---|---|---|
| `openssl` | 证书/私钥生成（Registry、HAProxy 等） | openssl |
| `tar` / `gzip` / `xz` | 解压离线包、镜像归档 | tar |
| `jq` | JSON 解析（kubernetes 元数据，可选，脚本多用 python 替代） | jq |
| `unzip` | 解压（可选） | unzip |

---

## 构建 installer 镜像建议（最小集）

- **必装**：§0 基础 + §1 ssh/scp/sshpass + §2 kubectl/helm/docker/ctr/skopeo + §3 ip/iptables/sysctl/modprobe/curl + §5 systemctl/chrony + §6 python3 + venv + §7 tar/xz/openssl
- **可选（裸金属免）**：§4 虚拟化
- **可选（按 operator 开关）**：haproxy/keepalived、nerdctl/podman、dnsmasq
- 镜像内还需：repo 代码（`/cubestack-installer`）、kubespray 离线仓库 `offline-files/kubespray`、metax 离线 `offline-files/metax-gpu`（均可挂载卷，避免入镜像）