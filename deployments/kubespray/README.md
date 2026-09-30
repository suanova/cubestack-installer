# 🚀 Cubestack 离线部署自动化工具

基于 **Kubespray** 的全自动化离线 Kubernetes 集群部署解决方案。支持**多集群管理**，通过集群名称参数化实现一套脚本管理多个独立集群的离线资源与配置。

## ✨ 核心特性

- 🏷️ **多集群支持**：通过集群名称隔离 Inventory 与离线资源，默认 `cubestack-cluster`
- 🔄 **源码自动管理**：自动检测/克隆 Kubespray 源码，自动管理 Python 虚拟环境
- 📦 **精准资源下载**：自动解析 Inventory，仅下载当前集群版本所需的镜像与二进制
- 🛡️ **Ubuntu 适配**：内置 `ubuntu` 用户 + sudo 提权逻辑，开箱即用
- 🔌 **零侵入切换**：部署新集群仅需指定名称 + 修改 IP，无需改动脚本

---

## 📋 前置条件

| 项目 | 联网机 (下载) | 离线机 (安装) |
|------|-------------|-------------|
| OS | Ubuntu 20.04/22.04/24.04 | Ubuntu 20.04/22.04/24.04 |
| 网络 | 可访问互联网 | 纯内网 |
| 用户 | 当前用户有 docker/nerdctl 权限 | `ubuntu` 用户 SSH 免密 + sudo NOPASSWD |
| 软件 | git, python3, python3-venv, docker/nerdctl | 无额外要求 (由 bundle 自带) |

---

## 📂 目录结构 (多集群隔离)

```text
/opt/cubestack-installer/
├── cubestack-offline.sh            # 核心脚本
├── README.md
├── kubespray/                      # [共享] Kubespray 源码 + venv
├── inventory/
│   ├── cubestack-cluster/          # 默认集群配置
│   │   ├── hosts.yml
│   │   └── group_vars/
│   └── my-prod-cluster/            # 自定义集群配置
│       ├── hosts.yml
│       └── group_vars/
└── offline-files/                  # 离线文件根目录(路径由 OFFLINE_FILES_DIR 切换)
    └── kubespray/                  # kubespray 离线资源(按集群名隔离)
        ├── cubestack-cluster/      # 默认集群离线资源
        │   ├── images/
        │   └── files/
        └── my-prod-cluster/        # 自定义集群离线资源
            ├── images/
            └── files/
```

> **两种布局下的离线资源根目录**(2026-09-28 起脚本自动判定,判据 = `BASE_DIR` 的上一级是否叫 `deployments`):
>
> | 布局 | 脚本位置 | 离线资源根(默认) | 是否按集群名隔离 |
> |---|---|---|---|
> | **仓库/容器** | `<root>/deployments/kubespray/` | `<root>/deployments/offline-files/kubespray/` | **否**(与 `cluster.conf` 的 `LOCAL_REPO_DIR`、全仓库其它脚本一致) |
> | **扁平 standalone** | `<root>/cubestack-offline.sh`(与 `kubespray/` 平铺) | `<root>/offline-files/kubespray/` | 是(`<集群名>/images`、`<集群名>/files`) |
>
> 即:在仓库里直接 `./deployments/kubespray/cubestack-offline.sh download <集群>`(不传 `OFFLINE_FILES_DIR`),
> 镜像 tar 落 `deployments/offline-files/kubespray/images/`、二进制落 `deployments/offline-files/kubespray/` 本身 ——
> 正是部署流程读取的位置。显式传 `OFFLINE_FILES_DIR` / `CUBESTACK_LOCAL_REPO_DIR` 时以传入值为准(最高优先)。
