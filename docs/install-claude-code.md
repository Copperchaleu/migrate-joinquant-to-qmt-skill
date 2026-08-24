# 在 Claude Code 中安装

Claude Code 技能格式、发现目录和调用方式以 [Claude Code Agent Skills 官方文档](https://code.claude.com/docs/en/skills) 为准。本仓库只维护一份通用技能正文。

先下载并检查固定 Release `v1.0.0`，或进入可信的本地仓库。建议先 dry-run。

## 用户级安装

目标为 `~/.claude/skills/migrate-joinquant-to-qmt`；共享相对路径是 `.claude/skills/migrate-joinquant-to-qmt`。

```sh
sh installers/install.sh --platform claude --scope user --source skill/migrate-joinquant-to-qmt --dry-run
sh installers/install.sh --platform claude --scope user --source skill/migrate-joinquant-to-qmt
```

```powershell
& .\installers\install.ps1 -Platform claude -Scope user -Source .\skill\migrate-joinquant-to-qmt -DryRun
& .\installers\install.ps1 -Platform claude -Scope user -Source .\skill\migrate-joinquant-to-qmt
```

## 项目级安装

目标为 `<project>/.claude/skills/migrate-joinquant-to-qmt`；共享相对路径是 `.claude/skills/migrate-joinquant-to-qmt`。

```sh
sh installers/install.sh --platform claude --scope project --project-dir /path/to/project --source skill/migrate-joinquant-to-qmt --dry-run
sh installers/install.sh --platform claude --scope project --project-dir /path/to/project --source skill/migrate-joinquant-to-qmt
```

PowerShell 使用 `-Platform claude -Scope project -ProjectDir C:\path\to\project`。

## 调用

可使用斜杠命令或明确的自然语言请求：

```text
/migrate-joinquant-to-qmt 审计 path/to/jq_strategy.py 并生成 QMT 迁移报告
```

## 发现与重启

安装后开启新的 Claude Code 会话。未发现时检查目标下的 `SKILL.md` 和 frontmatter 名称，随后完全重启 Claude Code。项目级技能只应从对应项目目录启动的会话中使用。

## 更新

下载新的固定 Release，保持原 `--platform claude` 和作用域，先 `--dry-run`，确认后对不同内容使用 `--force`。PowerShell 对应 `-DryRun`、`-Force`；强制更新保留时间戳备份。

## 卸载

```sh
sh installers/install.sh --platform claude --scope user --uninstall --yes
sh installers/install.sh --platform claude --scope project --project-dir /path/to/project --uninstall --yes
```

PowerShell 对应 `-Platform claude -Uninstall -Yes`，项目级同时传 `-Scope project -ProjectDir`。

## 已知限制

- `agents/openai.yaml` 是 Codex 专用 UI 元数据，Claude Code 可忽略；迁移正文仍由 `SKILL.md` 提供。
- 同名用户级与项目级副本可能导致版本判断困难；更新后检查实际发现路径并重开会话。
- 技能不包含 QMT、行情、账户或凭据，也不会替代 QMT 客户端中的回测与权限验证。
