# 如何使用本 Skill(兼容各 AI 工具)

本目录遵循 **Anthropic Agent Skills 标准**(`SKILL.md` + YAML frontmatter: `name` / `description`),可被主流 AI 编码工具直接加载。

## 目录结构

```
skills/cubestack-deploy-scripts/
├── SKILL.md                      # 技能主文件(规范核心 + 操作指引)
└── reference/                    # 附属参考文档(SKILL.md 通过相对路径引用)
    ├── scripts-development-spec.md   # 完整开发规范(详版)
    └── cluster-components-plan.md    # P1/P2/P3 组件规划与进度追踪
```

## 各工具加载方式

### Claude Code(Anthropic 官方)

Claude Code 默认从 `./skills/<skill-name>/SKILL.md` 发现项目级技能(或通过 settings 配置的额外目录)。用法:

```bash
# 在项目根目录运行, 技能自动可用
claude
```

或在对话中显式引用:

```
请加载 cubestack-deploy-scripts 技能, 然后按规范新增一个 xxx 部署模块
```

### Cursor / Windsurf

在 `.cursor/rules/` 或项目规则中引用本文件:

```text
@skills/cubestack-deploy-scripts/SKILL.md
```

或直接把 `SKILL.md` 内容并入规则文件。

### 其他 Agent(Copilot / 自定义)

- **GitHub Copilot**: 将 `SKILL.md` 内容加入 `.github/copilot-instructions.md`,或在提示中引用。
- **通用 LLM 工具**: 把 `SKILL.md` + `reference/` 两个文件作为上下文提供给模型,或直接说"请阅读 skills/cubestack-deploy-scripts/SKILL.md 并遵循其规范"。

## 核心规则速记(供工具在无完整文档时使用)

1. **目录**: 模块在 `deployments/scripts/modules/<阶段>/`,工具在 `deployments/scripts/tools/<领域>/`
2. **命名**: 模块 `NN_category_action.sh`,元数据头注释 `MODULE/DESC/PHASE/DEFAULT/REPEAT/TOGGLE`
3. **配置**: 一切从 `config/cluster.conf` 读取(环境变量可覆盖),禁止硬编码 IP/密码/路径
4. **阶段**: `env`(部署前准备) → `k8s`(离线部署,VM/裸金属无关) → `addon`(附加组件, 01~19 中间件 / 20 起自研)
5. **新增模块**: 放一个文件 + 写元数据头即可,不改任何注册表/入口
6. **未实现组件**: 用 `lib-common.sh` 的 `addon_stub` 写伪代码占位
7. **隔离性**: 模块间不互相 source;修改一个模块不影响其他模块
