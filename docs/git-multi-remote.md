# 多仓库同步(GitHub / GitLab)最佳实践

本仓库同一份代码维护在多个远端,核心原则是 **单一权威源 + 镜像同步**,避免历史分叉。

## 仓库布局

| remote | URL | 角色 |
|---|---|---|
| `origin` | https://glab.isuanova.com/cubestack/cubestack-installer.git | **权威源**(GitLab org),所有人从这里 clone |
| `origin-github` | git@github.com:suanova/cubestack-installer.git | GitHub 镜像 |
| `liqcui` | https://glab.isuanova.com/cuiliquan/cubestack-installer.git | 个人 fork(可选镜像) |

## 工作流(日常)

1. 只在本地 `main` 上开发,提交后**一次推送所有远端**:

   ```bash
   git pushall        # = git push origin main && git push origin-github main
   ```

2. **绝不从镜像(origin-github / liqcui)执行 `pull` / `merge` / `rebase`** —— 镜像只接受本地推送,历史必须完全一致。
3. 需要同步第三方改动时,走 GitHub PR 或 GitLab MR 合入权威源,再本地 pull 权威源。
   - 注意:只能从 `origin`(权威源)拉取,不要从镜像拉取。

## 一次性校准(历史已分叉时)

2026-09-01 本地 `main` 与 GitLab `origin/main` 曾分叉(历史被重写),已核对本地为**严格超集**
(`git diff origin/main HEAD` 无删除文件, 20 个冲突文件内 origin 独有行为 0)。
校准方式 —— 本地为权威,强制推送到 GitLab:

```bash
git push --force-with-lease origin main
```

`--force-with-lease` 仅在远端未被人再次推送时生效,避免误覆盖他人新提交。
之后所有远端 SHA 对齐,回归 `git pushall` 日常流程。

## 新增/移除同步远端

```bash
# 增加推送目标(如 liqcui fork)
git config alias.pushall '!git push origin main && git push origin-github main && git push liqcui main'

# 查看当前 pushall 定义
git config --get alias.pushall
```

## 常见问题

- **`git push` 被拒(non-fast-forward)**: 说明本地与远端已分叉。先核对本地是否为超集
  (`git diff <remote>/main HEAD` 无删除文件),确认后 `git push --force-with-lease <remote> main`,再恢复 `pushall`。
- **推送时 GitLab 提示输入凭据**: HTTPS 需 PAT 或账号密码;配置 credential helper 后免密。
