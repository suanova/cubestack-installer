# kubespray v2.32.0 部署 —— 镜像与制品清单(手动下载用)

> 生成于 2026-09-28。数据来源:`harbor-save-images.sh --list`(镜像,49 条逐条比对"已有/缺失")
> + v2.32 树内 `roles/kubespray_defaults/defaults/main/download.yml` 的下载 URL 模板
> + **本机 venv ansible 探针实测的解析值**(不是照旧件名猜的)。
> 配套文档:`handoff.md`(交付清单/待办/裁决)、`plan.md` 的 T13 段。

## 0. 结论:**现在还不能直接部署**,需先过 5 关

| # | 前置 | 不做的后果 |
|---|---|---|
| 1 | **重建 CLI 镜像**(树内 `requirements.txt` 已是 `ansible==12.3.0`) | 第一个 play 撞 ansible 版本门(要 ≥2.19 <2.20) |
| 2 | 新镜像**同步到 Harbor**(CI `sync-images-to-harbor.yml`;本支未在 main 上 → 用 `gh workflow run sync-images-to-harbor.yml -r feat/kubespray-v2.32 -f groups=k8s-base,multus,netshoot,lws`) | 第 3 步无从取 |
| 3 | 在**能连 Harbor 的机器**跑 `sudo deployments/scripts/tools/images/harbor-save-images.sh`(增量,只补缺的) | 镜像 tar 全是 1.32 线旧件,Pod 拉镜像失败 |
| 4 | **容器侧**:新树+补丁层进容器(容器内跑 `cubestack-kubespray-upgrade.sh v2.32.0` 或重建镜像)+ 容器内 `cluster.conf` **补 8 个版本钉子**(值 = 本文件 §1 的 1.35 线) | 容器仍用 v2.28 树;或缺钉子 → sync fail-loud 停在 `k8s_inventory`(有意) |
| 5 | 生态兼容确认:metax operator / rook v1.20 / ceph-csi × **k8s 1.35** 未核 | 组件可能不支持 1.35 |

⚠ **任何情况下先不要跑 `trim-offline-files.sh`** —— 它会删掉 ceph 组 11 个交付 tar + `ubuntu_22.04.tar` + 旧 `nginx_1.27.tar`(共 13 个,见 handoff.md 工单 1)。

## 1. 镜像:缺 19 个(优先用 Harbor 增量管道,不必手动)

`harbor-save-images.sh --list` 的逐条比对结果(**未标 `[已有]` 的 = 需要补**):

**必备(默认部署就要,共 17)**
| 组 | 上游 ref | 目标 tar |
|---|---|---|
| k8s-base | `registry.k8s.io/kube-apiserver:v1.35.8` | `kubespray/images/registry.k8s.io_kube-apiserver_v1.35.8.tar` |
| k8s-base | `registry.k8s.io/kube-controller-manager:v1.35.8` | 同名规则 |
| k8s-base | `registry.k8s.io/kube-scheduler:v1.35.8` | 同上 |
| k8s-base | `registry.k8s.io/kube-proxy:v1.35.8` | 同上 |
| k8s-base | `registry.k8s.io/pause:3.10.1` | `…_pause_3.10.1.tar` |
| k8s-base | `registry.k8s.io/coredns/coredns:v1.12.4` | `…_coredns_coredns_v1.12.4.tar` |
| k8s-base | `registry.k8s.io/metrics-server/metrics-server:v0.9.0` | `…` |
| k8s-base | `registry.k8s.io/cpa/cluster-proportional-autoscaler:v1.10.3` | `…` |
| k8s-base | `quay.io/coreos/etcd:v3.6.14` | `quay.io_coreos_etcd_v3.6.14.tar` |
| k8s-base | `quay.io/calico/cni:v3.31.7` | `quay.io_calico_cni_v3.31.7.tar` |
| k8s-base | `quay.io/calico/node:v3.31.7` | `…` |
| k8s-base | `quay.io/calico/kube-controllers:v3.31.7` | `…` |
| k8s-base | `ghcr.io/kube-vip/kube-vip:v1.0.3` | `ghcr.io_kube-vip_kube-vip_v1.0.3.tar` |
| k8s-base | `docker.io/library/nginx:1.30.1-alpine` | `docker.io_library_nginx_1.30.1-alpine.tar` |
| multus | `ghcr.io/k8snetworkplumbingwg/multus-cni:v4.2.2-thick` | `multus/ghcr.io_k8snetworkplumbingwg_multus-cni_v4.2.2-thick.tar` |
| netshoot | `docker.io/nicolaka/netshoot:latest` | `netshoot/docker.io_nicolaka_netshoot_latest.tar` |
| lws | `registry.k8s.io/lws/lws:v0.10.0` | `lws/registry.k8s.io_lws_lws_v0.10.0.tar`(开 LWS 才需要) |

**按开关(默认关 → 不急)**
| 组 | ref | 说明 |
|---|---|---|
| k8s-base | `registry.k8s.io/sig-storage/local-volume-provisioner:v2.5.0` | 只有 `LOCAL_VOLUME_PROVISIONER_ENABLED=true` 才需要 |
| k8s-base | `registry.k8s.io/nfd/node-feature-discovery:v0.19.0` | 只有 `NFD_ENABLED=true` 才需要 |

> ⚠ **multus 那条是硬门禁**:盘上现有的 `multus/multus-cni.tar` 内容实测仍是 `snapshot-thick`,
> 而模块已改成**内容校验** → 名称/内容不符会**响亮拒绝**。必须产出 `v4.2.2-thick` 的新 tar(名字按上表)。

## 2. 非镜像制品(kubespray 直接下载的二进制: **不在 harbor-save 范围, 必须手工/联网机取**)

现有件全是 1.32 线(`kubelet-1.32.5-amd64`、`etcd-3.5.16-linux-amd64.tar.gz`、`calicoctl-3.29.3-amd64`、
`cni-plugins-linux-amd64-1.4.1.tgz`、`containerd-2.0.5-linux-amd64.tar.gz`、`crictl-1.32.0-linux-amd64.tar.gz`、
`helm-3.16.4-linux-amd64.tar.gz`)—— **全部要按 v2.32 表值换新**(探针实测版本见下)。

| 制品 | 版本(实测) | URL | 目标文件名(沿用既有命名模式, 放 `offline-files/kubespray/`) |
|---|---|---|---|
| kubelet | 1.35.8 | `https://dl.k8s.io/release/v1.35.8/bin/linux/amd64/kubelet` | `kubelet-1.35.8-amd64` |
| kubectl | 1.35.8 | `…/v1.35.8/bin/linux/amd64/kubectl` | `kubectl-1.35.8-amd64` |
| kubeadm | 1.35.8 | `…/v1.35.8/bin/linux/amd64/kubeadm` | `kubeadm-1.35.8-amd64` |
| etcd | 3.6.14 | `https://github.com/etcd-io/etcd/releases/download/v3.6.14/etcd-v3.6.14-linux-amd64.tar.gz` | `etcd-3.6.14-linux-amd64.tar.gz` |
| cni-plugins | **1.9.1** | `https://github.com/containernetworking/plugins/releases/download/v1.9.1/cni-plugins-linux-amd64-v1.9.1.tgz` | `cni-plugins-linux-amd64-1.9.1.tgz` |
| calicoctl | **3.31.7** | `https://github.com/projectcalico/calico/releases/download/v3.31.7/calicoctl-linux-amd64` | `calicoctl-3.31.7-amd64` |
| calico CRDs | 3.31.7 | `https://github.com/projectcalico/calico/raw/v3.31.7/manifests/crds.yaml` | (同既有 CRD 文件的命名) |
| crictl | **1.35.0** | `https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.35.0/crictl-v1.35.0-linux-amd64.tar.gz` | `crictl-v1.35.0-linux-amd64.tar.gz` |
| containerd | **2.3.5** | `https://github.com/containerd/containerd/releases/download/v2.3.5/containerd-2.3.5-linux-amd64.tar.gz` | `containerd-2.3.5-linux-amd64.tar.gz` |
| runc | **1.4.3** | `https://github.com/opencontainers/runc/releases/download/v1.4.3/runc.amd64` | `runc.amd64` |
| helm | **3.22.0** | `https://get.helm.sh/helm-v3.22.0-linux-amd64.tar.gz` | `helm-3.22.0-linux-amd64.tar.gz` |

> 校验值:树内 `roles/kubespray_defaults/vars/main/checksums.yml` 有以上每项的 sha256(如
> `kubelet_checksums.amd64['1.35.8']`、`etcd_binary_checksums`、`cni_binary_checksums` …)—— 下载后请比对。
> **推荐做法**:在联网机跑 `deployments/kubespray/cubestack-offline.sh` 的备料/下载步骤(**它会按正确命名把这批全部取回**),
> 只有它取不到的项才照上表手工下载。
> ⚠ 另有 `offline-files/kubespray/packages/` 的 `helm_4.2.0-1_amd64.deb` / `lvm2_*.deb` 等系统包 ——
> 与上面的 helm 二进制不是一回事, 本清单未涉及, 若系统包也要换代以 `check-modules`/部署日志为准。

## 3. 三处"硬停"是设计, 不是故障(报错文案都带修法)

1. `sync-kubespray-config.sh` §3.2 缺 8 个钉子 → 停在 `k8s_inventory`;
2. multus tar 内容不符 → 停在 `--steps multus`;
3. kube-vip 镜像 tar 缺失 → `09_kube_vip` 自检 fail-closed。
