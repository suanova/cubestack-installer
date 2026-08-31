# github-planning skill 在本库(cubestack-installer)的适配说明

本 skill 从 ~/cubestack/.claude/skills/github-planning 复制而来, 用于把 PRD/设计文档/TODO
转化为结构化的 issue 规划(milestones/epics/stories + 依赖 + 优先级 + 故事点估计 + 发布说明)。

## ⚠ 本库差异(重要)

1. **主要适应 GitHub, GitLab 兼容为主**
   - 本库 remote: `https://glab.isuanova.com/cuiliquan/cubestack-installer.git`(GitLab)。
   - 方法论/清单结构/manifest 校验/发布说明模板等以 **GitHub** 为基准(与源 skill 一致)。
   - `scripts/gp` 底层用 `gh api`(GitHub CLI); 本库增补了 **GitLab 兼容分支**
     (设置 `GITLAB_BASE` + `GITLAB_TOKEN` 时走 GitLab REST), 响应字段归一
     (iid→number, id→node_id), 无需改 manifest。
   - 未设置 GITLAB_BASE 时保持原 GitHub(gh) 行为, 两者互不影响。

2. **gh CLI 未安装**
   - 本机只有 jq。跑 `gp` 的离线命令(`validate` / `--dry-run --state`)不需要 gh;
   - 实际写 GitHub 时需 `gh auth login`(或 GitLab 兼容用 `glab`/PAT)。

## 用法(离线部分可直接用)

```bash
# 校验 manifest 结构(离线)
cd .claude/skills/github-planning
bash scripts/gp validate <manifest.json>

# 离线 dry-run 预览(不连任何 API)
bash scripts/gp plan <owner>/<repo> <manifest.json> --dry-run --state <snapshot.json>

# 冒烟测试(离线, 证明无真实 API 调用)
bash tests/smoke-test.sh
```

## 文档结构

- `SKILL.md` — 完整方法论(分解/估计/优先级/清单 schema)
- `config/planning.json` — 标签/优先级/估计刻度(改标签改这里, 别改 gp)
- `references/issue-template.md` — issue 正文模板
- `scripts/gp` — 幂等助手 CLI(`gp help`)
- `tests/` — 离线测试

## GitLab 兼容分支(次选, 默认 GitHub)

`scripts/gp` 已支持 GitLab 后端: 设置以下环境变量后, gp 走 GitLab REST API:

```bash
export GITLAB_BASE=https://glab.isuanova.com    # GitLab 实例
export GITLAB_TOKEN=<personal access token>      # GitLab PAT(需 api scope)
```

- 用法与 GitHub 一致: `gp plan cuiliquan/cubestack-installer manifest.json` 等;
- 已适配: labels / milestones / issues(创建/更新)/ sub-issues(parent_id)/
  blocked_by(issue_links) / 标签 / release;
- 响应字段已归一(iid→number, id→node_id), 无需改 manifest;
- 未设置 GITLAB_BASE 时保持原 GitHub(gh) 行为, 两者互不影响。
- **主目标仍是 GitHub**: 一切新特性/规范以 GitHub 为准, GitLab 仅保证兼容可用。

## 本库 roadmap

`roadmap-cubestack.json` — 本库当前里程碑 manifest(milestone: CubeStack Installer
开发 Roadmap)。含已实现/部分实现/未实现三类故事, 建议使用前先 `gp validate` +
`--dry-run --state <snapshot>` 预览, 再决定是否落库。
