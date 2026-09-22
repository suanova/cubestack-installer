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

## 谁消费

`deployments/kubespray/cubestack-offline.sh` 的 `resolve_preload_image_files()` 按
`PRELOAD_IMAGE_PATTERNS` 过滤本目录 `images/*.tar`,生成 `preload-images.lst`,
再由 `patch-playbooks/cubestack-preload.yml` 同步到各节点。

> ⚠ 本目录下的 `*.tar` 已在 `.gitignore` 中忽略(tar 不入库);只有本 README 受版本控制。
