# offline-files/os/packages/ —— 节点 OS 层 deb(版本无关, 独立于 kubespray 版本目录)

## 目录口径(2026-10-07 定案, 2026-10-08 收敛)
`offline-files/` 的规划原则:
- **版本相关**的资产(裸二进制 / images)→ `kubespray/<版本>/`;
- **版本无关**的 OS 级资产 → 版本目录之外:
  - 镜像/二进制 → `os/` 顶层(ubuntu-22.04.tar / netshoot.tar / mc-*);
  - **节点 OS deb 包 → 本目录**。

**2026-10-08 收敛**: 原 `kubespray/<版本>/packages/` 与 `packages/repair/` 的全部 .deb 已并入
本目录顶层(同名同版本去重), 版本目录不再放 .deb; `kubespray/v2.28.0`(本地临时版本)已按指令删除。

## 结构(两个语义层, 别混)

### ① 顶层 = "对账集"(会被逐个装到**全部**节点)
- `reconcile-node-packages.sh`(模块 12_node_pkgs)逐个对账安装(旧版本由 apt 先摘后装);
- `patch-playbooks/install-packages.yml`(kubespray 部署期, 全节点)兜底安装 + 必需包断言;
- `install-worker-packages.sh` / `02_ceph.sh` 的 lvm2 兜底也读本目录。
- 内容: lvm2 家族 / helm / nodejs / sysstat / pv / rsync / iptables / iputils-ping /
  ca-certificates / curl(1.29) / libcurl4 / systemd 家族修复配对(libudev1/systemd/udev 等,
  原 repair/, 09-28 udev 事故的配对版本) / skopeo(1.4.1, 原 v2.28)等 **33 个**。
- ⚠ **顶层只放"节点应装的通用包"**: reconcile 会对全部节点逐个 `apt install` 这里的每个 deb,
  放错(如带系统库闭包的专用包)会引发无差别顶版(09-28 libudev1 事故同类风险)。

### ② `chrony/` 子目录 = "专用安装集"(仅 NTP 模块按需取用, **不对账**)
- `setup-ntp.sh` 在首 master 缺 chronyd 时离线安装(推节点 → apt --no-download, 见该脚本);
- reconcile 只扫顶层 `*.deb`(glob 不递归), 子目录天然被排除 —— **特意隔离**:
  闭包里的 libc6/libgnutls30 等系统库 deb 绝不能进对账集。
- 内容: `chrony_4.2-2ubuntu2` + 直接 Depends(adduser/iproute2/libcap2-bin/tzdata/ucf/libc6/
  libcap2/libedit2/libgnutls30/libnettle8/libseccomp2)+ 传递闭包, 共 32 个。

## 为什么有 chrony 离线包(2026-10-07 事故复盘)
VM 黄金镜像预装 chrony(create-vm-template.sh), 但 reconcile 的 systemd 修复包含
`systemd-timesyncd` —— 它与 chrony **互斥**(apt 自动摘除对方), 09-30 对账后各 master 的
chrony 被移除 ⇒ 05_k8s_ntp 的权威服务端在离线环境装不回来 ⇒ 模块失败。两处修复:
① setup-ntp.sh 从 `chrony/` 离线装 chrony; ② reconcile 在节点已有 chrony 时跳过
systemd-timesyncd。2026-10-08 repair/ 并入顶层后, install-packages.yml 的白名单 find 也随之取消。

## 刷新方法(联网环境)
- **lvm 家族**: `sudo tools/offline/fetch-lvm-packages.sh`(输出到本目录);
- **chrony 闭包**: 按下面通用法下载(archive.ubuntu.com 锚定与节点同版本):
```bash
mkdir -p /tmp/dl && cd /tmp/dl
curl -sSfO http://archive.ubuntu.com/ubuntu/pool/main/c/chrony/chrony_4.2-2ubuntu2_amd64.deb
# 直接 Depends + 2 层传递闭包(跳过虚拟包):
for l1 in $(apt-cache depends chrony | awk '/Depends:/{print $2}' | tr -d '<>'); do
  echo "$l1"; apt-cache depends "$l1" | awk '/Depends:/{print $2}' | tr -d '<>'
done | sort -u | xargs apt-get download
# 版本口径: 与目标节点 apt 列表(黄金镜像构建期)一致优先; 装完用
# dpkg-deb -f chrony_*.deb Depends 逐个核对闭环
```
改完记得 `/data/offline-files/os/packages/`(容器挂载真身)与仓库
`deployments/offline-files/os/packages/` 双份同步。
