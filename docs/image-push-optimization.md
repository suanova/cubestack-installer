# 大镜像 push 加速(dev_lab / model-collection)

> 适用: `36_dev_lab.sh`(6 镜像 ≈44G)、`37_model_images.sh`(3 镜像 ≈33G)把离线 tar 推入
> 集群内置 registry。本文记录瓶颈、已落地的优化、配置旋钮与 benchmark 方法。
> 相关: `docs/harbor-mirror.md`(镜像保鲜管道)、`docs/ceph-rook.md`(registry 后端)。

## 1. 瓶颈(实测)

| 现象 | 证据 |
|---|---|
| 串行推镜像 | 两个模块按 `IMAGES`/`image-list.tsv` 逐镜像 `skopeo copy`,前一个完成才推下一个 |
| 层串行 | `push_image_skopeo` 未传 `--image-parallel-copies`,skopeo 默认并发层数很低 |
| **幂等失效** | 源 docker-archive 的层是**未压缩 tar**;skopeo push 时重新 gzip(本地实测源层 81MB → 目标 31.8MB),**manifest/layer digest 全变**;老逻辑比较 manifest digest → 每次部署都判定"内容变了"并重推 |
| 无 precompute | 未用 `--dest-precompute-digests`,sglang 变体共享的 base 层可能被重复上传 |
| 压缩参数无效 | skopeo 1.16.1 的 `--dest-compress-level` / `--dest-compress-format zstd` 对 `docker://` 推送**不生效**(实测目标仍是默认 gzip;zstd 仅对 `dir` 生效,`uncompressed` 不支持) |

**关键结论**: config blob 的 digest 在重压缩前后**保持不变**(本地实测源/目标一致),
因此幂等判断应比较 **config digest**,而不是 manifest digest。

## 2. 已落地的优化(2026-10-19)

1. **config-digest 幂等**(`lib-common.sh::image_config_digest_raw`)
   - 内容未变直接跳过;多架构/取不到时回退 manifest digest(保守推送)。
   - 这一项避免每轮重复推送 130G。
2. **层并行**: `push_image_skopeo` 支持透传参数;两个模块默认
   `--image-parallel-copies ${IMAGE_PUSH_PARALLEL_LAYERS:-4}`。
3. **跳过已有层**: 默认 `--dest-precompute-digests`,registry 已有的 blob 不再上传。
4. **有限跨镜像并行 + base-first**:
   - 先**同步**推第一个镜像(填充共享 base 层),其余镜像按
     `${IMAGE_PUSH_PARALLEL_IMAGES:-2}` 有界并行(`lib-common.sh::parallel_run`)。
   - 避免 sglang 变体共享层在并发启动时被重复上传。
5. **重试**: `--retry-times ${IMAGE_PUSH_RETRY_TIMES:-5}`(skopeo 内部);
   `push_image_skopeo` 仍有 3 次整包重试(错误文件按 `BASHPID` 隔离,并行安全)。
6. **可观测**: 每个镜像输出 `已推送(源 …, Ns, ~M MB/s)`;汇总行统计新推/跳过/缺 tar/失败。
7. **回归**: `deployments/scripts/tools/tests/test-image-push-optimize.sh`(离线;已接入 CI)。

## 3. 配置(cluster.defaults.conf;可在 cluster.conf 覆盖)

| 变量 | 默认 | 说明 |
|---|---|---|
| `IMAGE_PUSH_PARALLEL_LAYERS` | `4` | 单镜像内并发层数;1=串行 |
| `IMAGE_PUSH_PARALLEL_IMAGES` | `2` | 首个镜像之后的同时推送镜像数;1=顺序 |
| `IMAGE_PUSH_PRECOMPUTE_DIGESTS` | `true` | 跳过 registry 已有层 |
| `IMAGE_PUSH_RETRY_TIMES` | `5` | skopeo 内部重试;0=不传 |

**调参建议**
- 默认(4 层 × 2 镜像)适合 8-16 核、万兆以内网络;
- 核多/网络快: 层 8、镜像 3-4(观察 CPU 与 registry 磁盘);
- 核少/网络慢: 层 2、镜像 1,避免压缩与上传互相抢资源。

## 4. benchmark 方法(集群恢复后)

> ⚠ config-digest 幂等会让"已推过的镜像"秒过;测加速必须让目标 tag 不存在,
> 或使用一个 scratch registry/临时 tag,不能用同一份已推内容反复测。

```bash
# 基线: 串行层 + 串行镜像
sudo IMAGE_PUSH_PARALLEL_LAYERS=1 IMAGE_PUSH_PARALLEL_IMAGES=1 \
  ./deploy-cluster.sh --steps model_images

# 仅层并行
sudo IMAGE_PUSH_PARALLEL_LAYERS=4 IMAGE_PUSH_PARALLEL_IMAGES=1 \
  ./deploy-cluster.sh --steps model_images

# 层 + 跨镜像并行(推荐)
sudo IMAGE_PUSH_PARALLEL_LAYERS=4 IMAGE_PUSH_PARALLEL_IMAGES=2 \
  ./deploy-cluster.sh --steps model_images

# 观察:
#   推送侧: top(skopeo/gzip CPU)、iftop/sar -n DEV(网络)、容器内 skopeo 日志;
#   registry 侧: kubectl -n kube-system exec <registry-pod> -- df -h /var/lib/registry;
#                 registry 所在节点 iostat -x 1; ceph -s(ceph-block 后端时)
```

> 第二轮起 config-digest 命中会跳过,耗时接近 0 —— 这是预期行为,不是 benchmark。

## 5. 边界与后续

- **skopeo 仍会重压缩**: 当前版本没有"保留源层压缩"的开关;层并行只是把压缩分摊到多核。
  若压缩 CPU 仍是瓶颈,可考虑:
  - 引入静态二进制 `crane` / `regctl`(可原样复制压缩 blob,`--concurrency` 控并发);
  - 离线资产改为 **OCI layout**(层已压缩),再用支持 blob 原样复制的工具推送;
- **registry 后端可能才是瓶颈**: 默认 `ceph-block`(3 副本);并行推送受 Ceph/网络限制时,
  先看 registry 节点 `iostat` 与 `ceph -s`,再考虑 local-path/更高吞吐池;
- **registry HTTP timeout**: distribution 默认 `http.timeout` 可能截断超长 blob 上传
  (慢链路 + 10G 层);出问题时可把 `http.timeout` 调大(需改 registry 配置并重启);
- **直接节点预载**: 若目标只是"节点能拉到镜像",用 `ctr -n k8s.io images import` 直接导入
  各节点(参考 `tools/images/ceph-sync-images.sh`)通常比 registry push 更快,但绕过 registry
  的集中管理与 GC;
- **验证边界**: 本文的 skopeo 行为数据来自本地 `registry:2.8.1` + `nginx.tar` 实测;
  集群当前不可用,端到端加速比需在集群恢复后按 §4 复测。
