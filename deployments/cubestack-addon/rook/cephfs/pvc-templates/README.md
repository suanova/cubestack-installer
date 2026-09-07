# CephFS 工作区 PVC 模板(§11 对齐)

本目录存放 **DevEnvironment / Agent 工作区 PVC 模板**(§11.1-§11.4),
对应用户开发环境与智能体的 CephFS 隔离设计。手工 `kubectl apply -f <file>`(改 namespace/容量)。

| 文件 | 用途 | SC | 关键属性 |
|---|---|---|---|
| `05-devenvironment-workspace-pvc.yaml` | DevEnvironment `/workspace`(§11.1-§11.3) | `cephfs-ephemeral` | RWX/Filesystem, ephemeral group 下 subvolume |
| `06-agent-workspace-pvc.yaml` | Agent 独立工作区(§11.4) | `cephfs-ephemeral` | RWO/Filesystem, 与用户环境隔离 |
| `07-skill-marketplace-pvc.yaml` | Skill Marketplace(§11.8) | `cephfs-durable` | RWX/Filesystem/Retain, durable group, 平台写/agent 只读 |

## 设计要点(§11)

- **模型不入 /models 文件系统**:模型以对象存 RGW 桶(§10),Pod 只持**只读访问参数**
  (reader 凭证 + S3 端点 + 桶名, 由平台注入) —— 避免对每个使用实例复制一份模型(§17);
  模型读取/消费由引擎侧完成(模型访问设计, 不在本文)。
- **DevEnvironment /workspace**:`cephfs-ephemeral` + RWX(多实例/多容器共享), PVC 创建即建
  subvolume(ephemeral group); 删 PVC → subvolume 随删(§11.6 生命周期)。
- **Agent 隔离(§11.4)**:Agent **不挂** DevEnvironment 的 /workspace, 使用自己在
  `cephfs-ephemeral` 下的**独立 RWO PVC/subvolume**, 与用户开发环境隔离;
  模型访问参数同理由平台注入(reader)。
- **回收语义**:工作区随 PVC 生灭(Delete, ephemeral group); 平台共享资产走
  `cephfs-durable`(Retain, durable group, §11.7/§11.8)。
