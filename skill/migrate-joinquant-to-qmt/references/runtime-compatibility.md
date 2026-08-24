# 运行时兼容性

## 技能发现与调用

| 运行时 | 用户级目录 | 项目级目录 | 调用 |
|---|---|---|---|
| Codex | `~/.codex/skills/<name>` | `.agents/skills/<name>` | `$migrate-joinquant-to-qmt` |
| Claude Code | `~/.claude/skills/<name>` | `.claude/skills/<name>` | `/migrate-joinquant-to-qmt` 或自然语言 |
| OpenCode | `~/.config/opencode/skills/<name>` | `.opencode/skills/<name>` | 技能发现或明确加载 |
| OpenClaw | `~/.openclaw/skills/<name>` | `<workspace>/skills/<name>` | 斜杠命令或自然语言 |
| Hermes Agent | `~/.hermes/skills/<name>` | 项目级安装不支持 | 斜杠命令或自然语言 |

## 能力映射

将“读取文件、搜索文本、执行命令、打开官方网页、编辑文件”映射到当前运行时提供的等价工具。不要假设 `apply_patch`、`web.run`、`terminal` 或其他专有工具名必然存在。缺少联网能力时，请用户提供官方文档快照，并把未核实 API 标为阻塞项。

## 脚本执行

从运行时提供的技能根目录解析 `scripts/` 和 `references/`。不要依赖当前工作目录，也不要把用户策略复制进技能目录。

## 共同验收

所有运行时必须保留 K 线时间日志、非空标的名称及 `abs((runtime - bar_time).total_seconds()) <= 180` 双层 LIVE 守卫。
