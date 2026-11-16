# 2026-11-16 交互确认与离线同步幂等性变更

## 1. 人工确认：sleep 倒计时 → yes/no

统一由 `deployments/scripts/lib-common.sh` 的 `confirm_yes_no` 处理：

- 交互终端必须输入 `yes`（兼容 `y/是`）才继续；`no`（兼容 `n/否`）中止；空/非法输入重新询问。
- `--yes` / `CUBESTACK_ASSUME_YES=1` 自动确认。
- 非交互环境保持旧的无人值守语义（默认自动继续）；需要强制确认的调用方传 `0`。
- 原 `*_SLEEP` 变量保留为兼容开关：`0` = 跳过确认，非 0 = 询问（不再等待秒数）。

覆盖位置：

| 位置 | 确认内容 |
|---|---|
| `deploy-cluster.sh` | external Ceph 连接参数、internal Ceph 节点/裸盘 |
| `06_k8s_deploy.sh` | 部署前暴露模式/配置、kube-vip 阶段二切换 |
| `02_ceph.sh` | external-ceph.env 缺失、apply CR 前磁盘最终确认 |
| `reset-old-cluster.sh` | 清除旧集群残留 |
| `cluster-teardown.sh` | 开始优雅卸载 |
| `fetch-offline-from-minio.sh` | 精确清理（删除本地多余文件） |
| `cubestack-offline.sh` | 安装/扩容前清除旧 K8s 残留 |

## 2. MinIO release 同步幂等性

症状：`--release 2.0.1` 同步后反复校验失败：

```text
kubespray/_upstream-release-2.32.1/SHA256SUMS: 磁盘存在但清单未登记
SIZES: SIZES 与 SHA256SUMS 路径集合不一致
cubestack-operator/..._v2.0.1.tar: 文件大小不符
```

根因与修复：

1. **远端 2.0.1 不生成 `SIZES`**，旧同步对缺失元数据 `|| true` 忽略，本地旧 `SIZES` 永久残留。
   - 新增 `_sync_meta_file`：`_SUCCESS/SIZES` 按远端实际状态同步；远端不存在则删除本地旧副本；
     `mc stat` 无法确认（网络/权限）时保留并告警。
   - `--repair` 不再跳过元数据项，复用同一套同步逻辑。
2. **元数据豁免按 basename 全局生效**，嵌套的 `_upstream-release-*/SHA256SUMS` 永不删除。
   - `manifest-plan.py` 改为**仅树根**豁免 `SHA256SUMS/SIZES/_SUCCESS/.cubestack-*`/CLI tar；
     嵌套同名文件不在远端清单内时进入 `delete` 计划。
3. 结果：同步后本地树与远端清单/元数据一致；二次同步稳定为 `下载 0 个, 删除 0 个`。

## 3. metax GPU operator 清理卡死

症状：`helm uninstall` 未完成后，`kubectl delete clusteroperator` 长时间卡住，组件清理被
600s 超时打断。

根因：`ClusterOperator` 带 `gpu.metax-tech.com/finalizers`，operator 已卸载后无人摘除；
`kubectl delete` 默认 `wait=true`，永久等待 CR 消失。

修复（`06_gpu_operator.sh`）：

- CR 删除加 `--wait=false`；
- 显式 patch 掉 CR finalizer；
- 有界等待 CR 消失（最多 20s）；
- 删除 namespace 后有界等待其真正消失（最多 60s），避免 `helm --create-namespace`
  撞上 `Terminating` 命名空间。

## 4. 回归验证

```bash
bash deployments/scripts/tools/tests/test-offline-incremental-plan.sh  # 嵌套元数据清理
bash deployments/scripts/tools/tests/test-release-mode.sh              # 旧 SIZES 清理 + 二次同步幂等
bash deployments/scripts/tools/tests/test-cluster-teardown.sh
bash deployments/scripts/tools/check-secrets.sh
bash deployments/scripts/tools/check-modules.sh                        # 58 个模块
```

## 5. 说明

- 更详细的离线同步故障记录见 `docs/troubleshooting.md` §四.8b。
- 为控制变更文件数，本次未逐篇修改相关文档；`docs/ceph-rook.md`、`docs/kube-vip-api-ha.md`、
  `docs/graceful-overwrite/*`、`docs/production-guide.md`、`docs/release-management.md`、
  `docs/offline-files-integrity.md` 等文档中可能仍保留旧的“倒计时”措辞，以本文件所列行为为准。
