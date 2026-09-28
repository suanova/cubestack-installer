# offline-files/kubespray/

kubespray 基座的**离线资产**(二进制 / 系统包 / 节点预加载镜像)。清单在
`deployments/config/images.manifest` 的 `[group: k8s-base]`,本目录的 `images/` 是其落点。

## 本目录的部分资产

| 文件 | 用途 |
|---|---|
| `images/*.tar` | 节点预加载镜像(`PRELOAD_IMAGE_PATTERNS` 决定哪些被同步到节点) |
| `kubeadm` / `kubelet` / `kubectl` / `crictl` / `containerd-*.tar.gz` / `runc` / `etcd-*.tar.gz` | 节点二进制 |
| `calicoctl-*` / `cni-plugins-*.tgz` / `nerdctl-*.tar.gz` / `helm-*.tar.gz` / `skopeo` / `yq` | 工具 |
| `packages/` · `*.deb` | 离线系统包(lvm2、rsync 等) |

## 取镜像

```bash
# 从 Harbor 统一镜像源拉(先由 CI `.github/workflows/sync-images-to-harbor.yml` 同步到 mirrors/**)
sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group k8s-base

# 只看会拉什么、落到哪(不下载)
bash ./deployments/scripts/tools/images/harbor-save-images.sh --list --group k8s-base
```

## kube-vip(控制平面 API VIP)—— 为什么它必须在这里

`ghcr.io/kube-vip/kube-vip:${KUBE_VIP_VERSION}` 支撑 API Server 的 VIP 高可用
(见 [`../../docs/kube-vip-api-ha.md`](../../docs/kube-vip-api-ha.md))。它**必须**进
`PRELOAD_IMAGE_PATTERNS`,原因与时序有关:

```
kubespray cluster.yml
  ├─ preinstall(写 /etc/hosts, 把 API 域名指向 loadbalancer_apiserver.address)
  ├─ 预加载离线镜像到各节点   ← kube-vip 镜像在这里进节点
  ├─ etcd
  ├─ kubernetes/node         ← kube-vip 静态 Pod 在这里落盘并由 kubelet 拉起
  └─ kubeadm init            ← controlPlaneEndpoint 指向 VIP, 依赖 kube-vip 已绑定
```

kube-vip 在 `kubeadm init` **之前**就要起来并绑上 VIP。镜像若没预加载,节点在首装时
拉不到 → 静态 Pod 起不来 → `kubeadm init` 直接失败(失败模式是响亮的,不是静默损坏)。

> ⚠ 版本必须与 kubespray `roles/kubespray_defaults/defaults/main/download.yml` 的
> `kube_vip_image_tag` 一致,改 `KUBE_VIP_VERSION` 时两处要一起改。
> 镜像名不带 `-iptables` 后缀 = `kube_vip_lb_fwdmethod: local`(kubespray 默认, 本项目沿用);
> 若改成 `masquerade`, 上游 ref 会变成 `kube-vip-iptables`, 清单要同步加一条。

## nginx(节点侧 API 本地代理静态 Pod)—— 为什么它必须在这里

`docker.io/library/nginx:${API_LB_NGINX_IMAGE_TAG}`(默认 `1.27.4-alpine`)支撑 kubespray 原生的
**每节点本地 API 代理**: 节点上的 nginx-proxy 静态 Pod 监听本机 `127.0.0.1:6443`, 把 kubelet /
kube-proxy 的 API 流量转发到全部 master —— 于是"节点侧 API 出口"不再依赖任何一台具体 master
(见 [`../../../docs/api-ha/`](../../../docs/api-ha/))。上游开关是 kubespray `all.yml` 的
`loadbalancer_apiserver_localhost` + `loadbalancer_apiserver_type: nginx`(本项目由
`sync-kubespray-config.sh` 按 `API_LOCAL_LB_ENABLED` / `API_LOCAL_LB_TYPE` 写入)。

它与 kube-vip 有**同一个时序约束** —— 镜像必须在"节点预加载"阶段就落到节点 containerd:

```
kubespray cluster.yml
  ├─ 预加载离线镜像到各节点   ← nginx 镜像在这里进节点
  ├─ kubernetes/node         ← nginx-proxy 静态 Pod manifest 落盘(loadbalancer/nginx-proxy.yml)
  └─ kubeadm init            ← 该节点的 API 出口就是本机 nginx-proxy(lb-apiserver → 127.0.0.1)
```

`/etc/kubernetes/manifests/` 下的静态 Pod **只能由 kubelet 从节点本地 containerd 拉镜像**
(`imagePullPolicy` 在节点侧没有 registry 可用), 而本仓库的预加载链路只扫本目录 `images/*.tar`
(见下方"谁消费")——所以这张镜像必须登记在 `k8s-base` 组, 放进别的 group 不会进节点。
缺镜像的失败模式是响亮的: 静态 Pod 起不来 → 该节点 API 不可达 → `kubeadm init` / kubelet 注册失败。

| 项 | 值 |
|---|---|
| 上游 ref | `docker.io/library/nginx:${API_LB_NGINX_IMAGE_TAG}` |
| 版本变量 | `API_LB_NGINX_IMAGE_TAG`(`cluster.conf` / `.example` 的镜像版本节) |
| 离线 tar | `images/docker.io_library_nginx_1.27.4-alpine.tar`(按上游 ref 派生: `/`→`_`, `:`→`_`) |
| 清单条目 | `images.manifest` 的 `k8s-base` 组, **不带第 3 列**(用派生名) |
| 预加载模式 | `PRELOAD_IMAGE_PATTERNS` 里的 `library_nginx`(见下方⚠) |

```bash
# 联网机备料(产物落到本目录 images/)
bash ./deployments/scripts/tools/images/harbor-save-images.sh --list  --group k8s-base   # 先看会拉什么
sudo ./deployments/scripts/tools/images/harbor-save-images.sh         --group k8s-base
```

> ⚠ **不要**给它加第 3 列短名(如 `nginx.tar`)。预加载的匹配是"文件名包含模式", 而 `nginx`
> 组另有 `offline-files/nginx/nginx.tar`(给 verify 模块当 HTTP 测试后端, 见
> `lib-common.sh` 的 `ensure_registry_nginx`)—— 派生的全限定名只被本组的 `library_nginx`
> 命中, 两个 `nginx` 镜像互不干扰。第 3 列是"历史短名"镜像的覆盖名, 用了就走不到派生名。
>
> ⚠ 版本必须与 kubespray `roles/kubespray_defaults/defaults/main/download.yml` 的
> `nginx_image_tag` 一致(当前 `1.27.4-alpine`; `extra_playbooks/` 下另有一份同名副本, 当前同值)。
> 两处不同值 = 节点预加载的 tag 与静态 Pod 实际拉取的 tag 不是同一个, 离线环境直接拉不到。
> 改 `API_LB_NGINX_IMAGE_TAG` 时两边一起改。

## 谁消费

`deployments/kubespray/cubestack-offline.sh` 的 `resolve_preload_image_files()` 按
`PRELOAD_IMAGE_PATTERNS` 过滤本目录 `images/*.tar`,生成 `preload-images.lst`,
再由 `patch-playbooks/cubestack-preload.yml` 同步到各节点。

> ⚠ 本目录下的 `*.tar` 已在 `.gitignore` 中忽略(tar 不入库);只有本 README 受版本控制。
