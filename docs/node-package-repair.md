# 节点系统包故障:根因、手动修复办法、自动化现状(2026-09-28)

> 本文是 **2026-09-28 "部署死在 `system_packages` / `Manage packages`"** 一役的完整沉淀:
> 三类根因 + 逐条**手动修复办法**(全部记录, 便于人工兜底)+ 哪些已经**自动化** + 两条路线的隔离约定。
> 相关:`docs/troubleshooting.md`(按症状索引)、`tools/node/reconcile-node-packages.sh`(自动化实现)、
> `modules/02_k8s/12_node_pkgs.sh`(自动化的调度壳)。

## 1. 三类根因(按发现顺序)

### R1 · 离线 .deb 与节点已装系统包的**版本漂移** → dpkg 严格依赖被打破

| 现场 | 机制 |
|---|---|
| `libudev1_…3.22` 装进了只有 `udev 3.12` 的节点 | `udev` 严格依赖 `libudev1 (= 3.12)`, 被升到 3.22 后**依赖不成立** |
| 我们的 `curl_…1.25` / `skopeo` 单装, 未带 `libcurl4` / `golang-github-containers-*` | 装完即"有缺依赖的已装包" |
| 后果 | `apt-get` **任何操作**都报 `E: Unmet dependencies` ⇒ 下次部署死在
  kubespray `bootstrap_os → system_packages` 的 "Manage packages"(报错只提表象包, 根因在几轮之前) |

### R2 · 包处于**半装**(half-configured)状态 → 只跑 `apt -f install` 修不掉

- 中断(尤其被 R3 卡死)会留下"已解包未配置"的 `Conf` 队列(`dpkg --audit` 可见)⇒ 必须先 `dpkg --configure -a`。

### R3 · **D 状态死锁**:`mdadm --examine --scan` 撞上遗留 rbd 映射 → dpkg 永不放锁

```
dpkg -i /tmp/packages/dmsetup_*.deb          (或 apt-get -f install → dpkg --configure --pending)
  └─ /var/lib/dpkg/info/initramfs-tools.postinst triggered update-initramfs
       └─ /sbin/mdadm --examine --scan --config=partitions     ← D 状态(不可中断)
```
- 触发源:节点上有**内核 rbd 映射**(`/sys/bus/rbd/devices` 非空)其后端已不可达 —— 上一代集群残留;
- 同批出现的 D 态还有挂在同块设备上的 ext4 的 jbd2 线程(`[calico]` / `[registry]` 等)与 `sync`;
- ⚠ **D 态进程连 `SIGKILL` 都无效** ⇒ 自动化只能识别, **不能代重启**。

### R4 · 环境类:`/data/offline-files` 与仓库 `deployments/offline-files/` **分叉**

- 部署容器挂载的是 **`/data/offline-files`**;仓库那份是另一副本 ⇒ "改了离线件却不生效"(见记忆
  `container-offline-files-live-source`)。本次已用 rsync 对齐(`--delete`)。

## 2. 手动修复办法(全部记录;命令均实测过)

**判据(先看清病灶)**
```bash
sudo apt-get check                                   # 依赖图是否健康(有 E: 即破损)
sudo apt-get -s -f install                           # 看修复计划(要装/要摘哪些)
sudo dpkg --audit                                    # 找半装包(R2)
ps -eo pid,stat,cmd | awk '$2 ~ /^D/ {print}'        # 找 R3(D 态)
ls /sys/bus/rbd/devices                              # 找 rbd 残留(空=无)
```

**R1(版本漂移)**
```bash
# 把"配对需要的包"按 apt 认得的规范名(<包名>_<版本>_<arch>.deb)放到一个目录, 然后:
sudo apt-get -o Dir::Cache::archives=/tmp/cubestack-debs --no-download -y -f install
# ⚠ 文件名必须规范, 否则 apt 在缓存里找不到(实测: 短名 curl_1.29.deb 会被当作 "Unable to fetch")
```
本次用到的配对包(已入库 `offline-files/kubespray/packages/repair/`):
`udev` + `libudev1`(3.22)、`curl` + `libcurl4`(1.29)、
`systemd/systemd-sysv/libsystemd0/libnss-systemd/libpam-systemd/systemd-timesyncd`(249.11-0ubuntu3.22, worker 需要)、
`golang-github-containers-common` + `-image`(skopeo 的依赖)。

**R2(半装)**
```bash
sudo dpkg --configure -a        # 先配置完, 再跑 R1 的 apt -f install
```

**R3(死锁)——唯一解是重启该节点**
```bash
sudo reboot -f
# 为什么 -f: 节点上已有 D 态的 sync / mdadm, 常规关机会卡在同步/卸载上;
#           本地 ext4 靠日志回放在开机时自愈, 该节点本来就要被重装, 强制重启是安全的。
# 重启后复核: ls /sys/bus/rbd/devices 应为空(映射不持久化), dpkg 锁随进程消失。
```
**残留 rbd / Ceph 盘清理**:`tools/k8s/ceph-rbd-cleanup.sh`(清理 rbd 映射)+ `ceph-cleanup.sh --all`(集群+盘)。

**R4(离线件分叉)**
```bash
sudo rsync -a --delete deployments/offline-files/kubespray/ /data/offline-files/kubespray/
ls deployments/offline-files/kubespray/ | wc -l ; sudo ls /data/offline-files/kubespray/ | wc -l   # 条目数须一致
```

## 3. 自动化现状(谁负责哪一段)

| 根因 | 自动化? | 实现 |
|---|---|---|
| R1 | ✅ 全自动 | `tools/node/reconcile-node-packages.sh`:把离线 .deb 按规范名喂给 apt(`Dir::Cache::archives` + `--no-download`), **由 apt 求解器"先摘后装"**;逐包对账并复核 |
| R2 | ✅ 全自动 | 同上, 修复前先 `dpkg --configure -a` |
| R3 | ⚠ **只识别 + 出指引** | 同上, 检测 D 态进程/rbd 残留并打印处置(D 态杀不掉, 不代重启);工具自身已加 `update_initramfs=no` 防护, **避免自己踩进这条链** |
| R4 | ⚠ 手动(一条 rsync) | 分叉检测未自动化(见记忆里的规则:改离线件收尾必跑 rsync) |

调度:`modules/02_k8s/12_node_pkgs.sh`(PHASE k8s, DEFAULT/REPEAT 1), **在 kubespray 之前**(靠
`06_k8s_deploy.sh` 的 `REQUIRES: … node_pkgs` 定序 —— 序号 12 > 06 排不到前面)。
单跑:`bash deployments/scripts/tools/node/reconcile-node-packages.sh [--ip X]… [--dry-run]`

## 4. 两条路线:**互不干扰、独立运行**(2026-09-28 定案)

| | **路线 A · 覆盖重装**(已实现) | **路线 B · 原地升级**(未实现, 只有接口+伪代码) |
|---|---|---|
| 入口 | `deploy-cluster.sh [--fresh] [--yes]` | `cubestack-offline.sh upgrade <集群> [--to vX.Y.Z] [--check] [--yes]` |
| 语义 | 换掉整集群:旧集群残留 → reset → 全新部署 | 保业务:逐小版本 kubeadm + etcd 走 3.5.33 桥 |
| 适用 | 测试/可重建集群;跨 ≥2 个小版本 | 生产集群;跨 1 个小版本;补丁版本 |
| 设计文档 | 本文 §2/§3 + `docs/api-ha/*` | **`docs/cluster-upgrade-path.md`** |

**隔离约定(两条路线不得互相依赖)**:
1. B 的**版本阶梯 / etcd 桥版本 / 回滚逻辑**一律不得进入 A 的路径(A 永远"全新安装", 不碰任何升级路径);
2. A 的 **reset / 旧集群残留检测**不得被 B 调用(B 靠自己的逐版本流程, 不推平集群);
3. 两者**只共享"前置体检与修复"**这一类**中性**能力(`node_pkgs` 对账、`verify_*` 断言)——它们
   既不推平集群、也不升级版本, 对两条路线都只是"把机器修成可部署状态";
4. B 的实现只做**新增**(新命令 + 新脚本 + 新文档), 不改 A 的任何文件与默认值。

## 5. 本次实机状态(2026-09-28 夜)

- 8 台中 **6 台已修复**(`apt-get check` 健康);离线件已按 R4 对齐;`repair/` 12 个配对包已入库并同步到
  `/data/offline-files`(容器可见)。
- **3.33 / 3.36 仍破损** —— 均为 R3(D 态 `mdadm --examine --scan`;3.33 自 2026-09-24 起、3.36 为当晚
  修复时新踩)。**处置: `sudo reboot -f`, 回来后再跑一次对账即可**(`reconcile-node-packages.sh --ip …`)。
