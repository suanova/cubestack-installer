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
└── repository/
    ├── cubestack-cluster/          # 默认集群离线资源
    │   ├── images/
    │   └── files/
    └── my-prod-cluster/            # 自定义集群离线资源
        ├── images/
        └── files/
