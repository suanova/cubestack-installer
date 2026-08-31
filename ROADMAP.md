# CubeStack Installer — Roadmap

> 由 [github-planning skill](.claude/skills/github-planning/SKILL.md) 生成 · 2026-08-31 11:20

> 数据源: GitHub `suanova/cubestack-installer` · 里程碑「CubeStack Installer 开发 Roadmap」

## 总览

| 里程碑 | 总 issue | 已完成 | 剩余 | 进度 |
|---|---|---|---|---|
| CubeStack Installer 开发 Roadmap | 27 | 7 | 20 | **26%** |

完成度 **26%**

## ✅ 已完成 (closed)

- [x] #3 registry VIP 冲突检测与自动避让(多集群网段)
- [x] #4 宿主机 /etc/hosts 收敛(换环境不残留旧集群 IP)
- [x] #5 单节点集群 control-plane 可调度收敛
- [x] #7 offline-files 冗余清理(仅保留部署必需镜像/二进制)
- [x] #8 MinIO 下载排除 virtual-machine(按需下载)
- [x] #9 CLI 容器镜像时区/依赖规范化
- [x] #10 NTP 同步逻辑重构

## 📋 未完成 (open)

- [ ] #1 Feature: 部署基座稳定性(离线 kubespray + addon 基座)
- [ ] #2 Epic: 基座稳定性加固
- [ ] #6 Epic: 离线资源管理
- [ ] #11 GitLab 侧 gp 适配 + roadmap 落地
- [ ] #12 Feature: 组件覆盖(GPU/LWS/监控/存储/网关)
- [ ] #13 Epic: 计算组件
- [ ] #14 GPU Operator 镜像全量同步与 registry 可靠性
- [ ] #15 LWS 部署链路验证
- [ ] #16 Epic: 存储与网关
- [ ] #17 Ceph 存储 + CSI 验证
- [ ] #18 Envoy 网关二件套验证
- [ ] #19 Feature: 工具链与质量
- [ ] #20 验证套件增强
- [ ] #21 Feature: 发布与文档
- [ ] #22 发布说明与里程碑跟踪
- [ ] #23 部署文档完善
- [ ] #24 Feature: P2 能力增强模块落地(Keycloak/Kueue)
- [ ] #25 Epic: P2 身份与队列治理
- [ ] #26 Keycloak 统一认证落地
- [ ] #27 Kueue 队列治理落地

---

_由 github-planning skill 生成, 手工改动可能会被后续 `gp update-milestone` 覆盖。_
