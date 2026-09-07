# CephFS 工作区与模型访问设计(§11, 2026-09-07 定稿)

> 对应规划 §9(CephFS subvolume groups)/ §10(Model 仓库 RGW)/ §11(工作区)。
> 资源 YAML 见 `deployments/cubestack-addon/rook/cephfs/` 与 `rgw/`。

## 1. 核心决策

1. **模型不入 /models 文件系统**:模型以**对象**存 RGW 桶(§10),Pod 只持**只读访问参数**
   (reader 凭证 + S3 端点 + 桶名, 由平台注入) —— 避免对每个使用实例复制一份模型(§17);
   模型的读取/消费由**引擎侧**完成(模型访问设计, 不在本文范围, §10.1)。
2. **DevEnvironment /workspace**:`cephfs-ephemeral` + RWX(多实例/多容器共享),
   PVC 创建即由 CSI 在 ephemeral group 下建 subvolume(§9.1)。
3. **Agent 隔离**:Agent **不挂** DevEnvironment 的 /workspace —— 使用自己在
   `cephfs-ephemeral` 下的**独立 RWO PVC/subvolume**(§11.4), 与用户开发环境隔离;
   模型访问参数同理由平台注入(reader)。

## 2. 存储映射

| 场景 | 载体 | SC | 访问模式 | 生命周期 |
|---|---|---|---|---|
| DevEnvironment /workspace | CephFS subvolume(ephemeral group) | `cephfs-ephemeral` | RWX | 随 PVC 生灭(Delete) |
| Agent 工作区 | CephFS subvolume(ephemeral group) | `cephfs-ephemeral` | RWO | 随 agent PVC 生灭(Delete) |
| 平台共享资产(Skill Marketplace) | CephFS subvolume(durable group) | `cephfs-durable` | RWX | 长期保留(Retain) |
| Model 仓库 | RGW 桶(per-model) | S3(无 PVC) | 对象只读(reader) | 平台显式删桶(§10.7) |
| Image Registry 数据目录 | RBD Filesystem | `ceph-rbd-durable` | RWO | Retain(§11.9/§8.6) |

## 3. DevEnvironment Pod 示例(模型不入 /models)

```yaml
# workspace PVC(§11.1): cephfs-ephemeral + RWX
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: workspace-alice
spec:
  accessModes: [ReadWriteMany]
  volumeMode: Filesystem
  storageClassName: cephfs-ephemeral
  resources: { requests: { storage: 100Gi } }
---
# Pod: 挂 /workspace, 模型经注入的 S3 只读参数访问(不挂载 /models)
apiVersion: v1
kind: Pod
metadata:
  name: devenv-alice
spec:
  containers:
    - name: devenv
      image: <devenv-image>
      volumeMounts:
        - name: ws
          mountPath: /workspace
      envFrom:
        - secretRef: { name: rgw-model-reader }   # 模型只读凭证(§10.4, 平台注入短名)
      env:
        - { name: MODEL_S3_ENDPOINT, value: "http://rook-ceph-rgw-s3-store.rook-ceph.svc:80" }
        - { name: MODEL_S3_REGION,  value: "us-east-1" }
        - { name: MODEL_BUCKET,     value: "<model>-<version>" }   # §10.3 per-model 桶
  volumes:
    - name: ws
      persistentVolumeClaim: { claimName: workspace-alice }
```

> 模型读取:引擎侧经注入的 S3 参数 + reader 凭证从桶只读拉取(缓存/加载属模型访问设计)。

## 4. Agent 隔离(§11.4)

- Agent 使用自己的 `agent-<xxx>` RWO PVC(cephfs-ephemeral 下独立 subvolume),
  **不共享** DevEnvironment 的 /workspace(避免 agent 写入污染用户环境)。
- 生命周期独立:删 agent PVC → 其 subvolume 随删, 不影响用户工作区。
- 模型访问参数同理由平台注入(reader)。

## 5. 资源清单

| 资源 | 文件 |
|---|---|
| subvolume groups(ephemeral/durable) | `rook/cephfs/03-subvolumegroups.yaml` |
| cephfs-ephemeral / cephfs-durable SC | `rook/cephfs/02-storageclass-cephfs.yaml` |
| DevEnvironment /workspace PVC | `rook/cephfs/pvc-templates/05-devenvironment-workspace-pvc.yaml` |
| Agent 工作区 PVC | `rook/cephfs/pvc-templates/06-agent-workspace-pvc.yaml` |
| Model 仓库用户(admin/reader) | `rook/rgw/02-cephobjectstoreuser-model.yaml` |
| 桶只读策略模板 | `rook/rgw/reader-policy.json` |
