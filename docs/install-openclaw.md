# 在 OpenClaw 中安装

技能位置和加载行为以 [OpenClaw Skills 官方文档](https://docs.openclaw.ai/tools/skills) 为准。通用安装器的本地复制路径与该文档约定对齐。

先下载并检查固定 Release `v1.0.0`，或进入可信的本地仓库；先 dry-run。

## 用户级安装

目标为 `~/.openclaw/skills/migrate-joinquant-to-qmt`；共享相对路径是 `.openclaw/skills/migrate-joinquant-to-qmt`。

```sh
sh installers/install.sh --platform openclaw --scope user --source skill/migrate-joinquant-to-qmt --dry-run
sh installers/install.sh --platform openclaw --scope user --source skill/migrate-joinquant-to-qmt
```

```powershell
& .\installers\install.ps1 -Platform openclaw -Scope user -Source .\skill\migrate-joinquant-to-qmt -DryRun
& .\installers\install.ps1 -Platform openclaw -Scope user -Source .\skill\migrate-joinquant-to-qmt
```

## 项目级安装

OpenClaw 项目级目标是 `<workspace>/skills/migrate-joinquant-to-qmt`；共享相对路径是 `skills/migrate-joinquant-to-qmt`。

```sh
sh installers/install.sh --platform openclaw --scope project --project-dir /path/to/workspace --source skill/migrate-joinquant-to-qmt --dry-run
sh installers/install.sh --platform openclaw --scope project --project-dir /path/to/workspace --source skill/migrate-joinquant-to-qmt
```

PowerShell 使用 `-Platform openclaw -Scope project -ProjectDir C:\path\to\workspace`。

## 调用

可用斜杠命令或自然语言明确调用：

```text
/migrate-joinquant-to-qmt 审计并迁移 path/to/jq_strategy.py
```

## 发现与重启

安装后开启新的 OpenClaw 会话；项目级安装需从对应 workspace 使用。未发现时检查 `SKILL.md`、workspace 根目录和技能目录名，然后完全重启 OpenClaw。安装器不依赖 OpenClaw CLI 的内部复制命令。

## 更新

用新的固定 Release 或本地源码保持 `--platform openclaw` 与原作用域，先 `--dry-run`，确认后加 `--force`。PowerShell 使用 `-DryRun`、`-Force`。强制更新会保留原目录备份。

## 卸载

```sh
sh installers/install.sh --platform openclaw --scope user --uninstall --yes
sh installers/install.sh --platform openclaw --scope project --project-dir /path/to/workspace --uninstall --yes
```

PowerShell 对应 `-Platform openclaw -Uninstall -Yes`，项目级同时传 workspace 路径。

## 已知限制

- workspace 级路径不是 `.openclaw/skills`，而是 workspace 根下的 `skills/migrate-joinquant-to-qmt`；不要混用两个作用域。
- 发现或重载能力可能随 OpenClaw 版本变化；更新后新开会话是最可重复的验证方式。
- 技能不提供 QMT、行情数据、账户、券商权限或凭据，实机验证仍由用户完成。
