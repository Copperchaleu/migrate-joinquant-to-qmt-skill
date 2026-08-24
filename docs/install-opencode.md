# 在 OpenCode 中安装

技能目录和发现规则以 [OpenCode Agent Skills 官方文档](https://opencode.ai/docs/skills) 为准。本仓库的安装器只复制经验证的通用技能目录。

先下载并检查固定 Release `v1.0.0`，或使用可信本地源码；先 dry-run 再安装。

## 用户级安装

目标为 `~/.config/opencode/skills/migrate-joinquant-to-qmt`；共享相对路径是 `.config/opencode/skills/migrate-joinquant-to-qmt`。

```sh
sh installers/install.sh --platform opencode --scope user --source skill/migrate-joinquant-to-qmt --dry-run
sh installers/install.sh --platform opencode --scope user --source skill/migrate-joinquant-to-qmt
```

```powershell
& .\installers\install.ps1 -Platform opencode -Scope user -Source .\skill\migrate-joinquant-to-qmt -DryRun
& .\installers\install.ps1 -Platform opencode -Scope user -Source .\skill\migrate-joinquant-to-qmt
```

## 项目级安装

目标为 `<project>/.opencode/skills/migrate-joinquant-to-qmt`；共享相对路径是 `.opencode/skills/migrate-joinquant-to-qmt`。

```sh
sh installers/install.sh --platform opencode --scope project --project-dir "$PROJECT_DIR" --source skill/migrate-joinquant-to-qmt --dry-run
sh installers/install.sh --platform opencode --scope project --project-dir "$PROJECT_DIR" --source skill/migrate-joinquant-to-qmt
```

PowerShell 使用 `-Platform opencode -Scope project -ProjectDir $env:PROJECT_DIR`。

## 调用

在请求中明确加载或使用技能，例如：

```text
使用 migrate-joinquant-to-qmt 技能审计 path/to/jq_strategy.py，并保留原调度和下单语义。
```

## 发现与重启

安装后启动新的 OpenCode 会话。若未自动发现，检查目标路径、`SKILL.md` frontmatter 和当前项目根；再完全重启 OpenCode，并在请求中明确写出技能名。

## 更新

保持 `--platform opencode` 和原作用域，先对新的固定 Release 或本地源码执行 `--dry-run`。确认后用 `--force`；PowerShell 对应 `-Force`。原副本会保存在同级时间戳备份中。

## 卸载

```sh
sh installers/install.sh --platform opencode --scope user --uninstall --yes
sh installers/install.sh --platform opencode --scope project --project-dir "$PROJECT_DIR" --uninstall --yes
```

PowerShell 对应 `-Platform opencode -Uninstall -Yes`，项目级还需 `-Scope project -ProjectDir`。

## 已知限制

- OpenCode 是否自动选择某个技能取决于当前运行时发现与请求语境；关键任务应明确写出技能名。
- `agents/openai.yaml` 不参与 OpenCode 的迁移行为。
- 技能不打包 QMT 客户端、行情数据、交易账户或凭据；依赖 QMT 的步骤必须在用户环境中验证。
