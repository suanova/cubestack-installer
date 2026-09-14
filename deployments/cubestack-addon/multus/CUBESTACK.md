# Multus CNI — CubeStack 离线 vendoring 适配说明

本目录存放 **Multus CNI(thick 插件)离线安装 manifest**, 供 `modules/03_addon/09_multus.sh` 离线部署(容器多网卡)使用。
离线镜像在 `deployments/offline-files/multus/multus-cni.tar`(gitignore, 不随仓库)。

## 目录内容

```
deployments/cubestack-addon/multus/
├── CUBESTACK.md                      # 本文件(项目适配说明)
└── multus-daemonset-thick.yml        # 官方 thick quickstart(单文件 bundle)
                                      #   · NAD CRD(network-attachment-definitions.k8s.cni.cncf.io)
                                      #   · ClusterRole/Binding + ServiceAccount(multus, kube-system)
                                      #   · ConfigMap multus-daemon-config
                                      #   · DaemonSet kube-multus-ds(main: multus-daemon +
                                      #       init: install-multus 装 /opt/cni/bin)
```

镜像 ref: `ghcr.io/k8snetworkplumbingwg/multus-cni:snapshot-thick`(DaemonSet 主容器 + initContainer 同镜像;
amd64)。

## 离线镜像

```bash
# 联网机(docker 或 skopeo):
docker pull ghcr.io/k8snetworkplumbingwg/multus-cni:snapshot-thick
docker save ghcr.io/k8snetworkplumbingwg/multus-cni:snapshot-thick -o multus-cni.tar
# 放到部署机: deployments/offline-files/multus/multus-cni.tar
```

16_multus 模块把 tar 推送进集群内置 registry(目标 `<reg>/k8snetworkplumbingwg/multus-cni:snapshot-thick`),
再 sed 重写 manifest 镜像名后 `kubectl apply`。tar 缺失时模块报错并给出指引(不静默跳过)。

## 项目集成

- 部署入口: `modules/03_addon/09_multus.sh`(`MULTUS_ENABLED=true`, 或 `--steps multus`)
- 端到端验证: `--steps verify_multus`(见 `modules/03_addon/29_verify_multus.sh`)
- 使用文档: 官方 Quickstart(本仓库 kubespray 自带 `deployments/kubespray/kubespray/docs/CNI/multus.md`)

## 示例网络(模块自动创建)

Multus 只提供"多网卡 attach 能力"; 附加网卡需 CNI plugin(macvlan/bridge 等) + 一个
NetworkAttachmentDefinition。**`macvlan/vlan/bridge` 等参考插件由 kubelet 预装在各节点
`/opt/cni/bin`**, 本模块**不另推插件镜像**(方案 A: 零额外镜像, 直接复用节点内置插件)。
16_multus 按 cluster.conf 的 `MULTUS_*` 自动创建一个 host-local macvlan 示例 NAD
(默认 `kube-system/multus-nad`, master=eth0, `192.168.99.0/24`), 给 pod 挂网卡:

```bash
kubectl get -n kube-system networkattachmentdefinitions.multus.k8s.cni.cncf.io multus-nad

# pod 注解选用(默认建在 kube-system, default 下 pod 需带命名空间前缀):
kubectl run samplepod --image=busybox --restart=Never \
  --annotations=k8s.v1.cni.cncf.io/networks=kube-system/multus-nad \
  --command -- sh -c 'trap : TERM INT; sleep infinity & wait'
kubectl exec samplepod -- ip a        # 应多出 net1 接口
```

> ⚠ `MULTUS_MASTER_IFACE`(默认 eth0)须是集群节点真实网卡名; subnet 范围须不与集群网段冲突。
> macvlan 直连宿主机网卡, 默认与宿主同网段时才可达网关(否则按需调整 IPAM)。

## 卸载

```bash
kubectl -n kube-system delete ds kube-multus-ds
kubectl delete crd network-attachment-definitions.k8s.cni.cncf.io
```

## 与 kubespray 自带 Multus 的关系

kubespray 自带 multus 集成(`kube_network_plugin_multus`, 默认 `false`)。本项目用独立 DaemonSet
(thick 插件, 自带 multus-daemon/install_multus), 不依赖 kubespray 集成; 两开关互不影响。
