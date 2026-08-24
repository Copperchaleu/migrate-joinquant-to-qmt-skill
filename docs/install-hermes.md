# 在 Nous Research Hermes Agent 中安装

技能使用方式以 [Nous Research Hermes Agent 官方 Skills 指南](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/guides/work-with-skills.md) 为准。首版只通过本仓库通用安装器提供用户级安装，不发布 Hermes tap 或官方 Hub 包。

先下载并检查固定 Release `v1.0.0`，或使用可信本地源码；先 dry-run。

## 用户级安装

唯一支持的目标为 `~/.hermes/skills/migrate-joinquant-to-qmt`；共享相对路径是 `.hermes/skills/migrate-joinquant-to-qmt`。

```sh
sh installers/install.sh --platform hermes --scope user --source skill/migrate-joinquant-to-qmt --dry-run
sh installers/install.sh --platform hermes --scope user --source skill/migrate-joinquant-to-qmt
```

```powershell
& .\installers\install.ps1 -Platform hermes -Scope user -Source .\skill\migrate-joinquant-to-qmt -DryRun
& .\installers\install.ps1 -Platform hermes -Scope user -Source .\skill\migrate-joinquant-to-qmt
```

## 项目级安装

`--platform hermes --scope project` 明确不支持，并返回专用失败状态；PowerShell 的 `-Platform hermes -Scope project` 同样失败。安装器不会静默改为用户级，也不会向项目写入技能。请使用上面的用户级命令。

## 调用

安装后可使用斜杠命令或自然语言：

```text
/migrate-joinquant-to-qmt 审计 path/to/jq_strategy.py，并列出所有无法在 QMT 等价实现的项目。
```

## 发现与重启

安装后启动新的 Hermes Agent 会话。未发现时，确认 `~/.hermes/skills/migrate-joinquant-to-qmt/SKILL.md` 存在且 frontmatter 名称正确，然后完全重启 Hermes Agent。不要把用户级技能复制到临时项目路径来模拟项目作用域。

## 更新

保持 `--platform hermes --scope user`，对新的固定 Release 或本地源码先执行 `--dry-run`，确认后加 `--force`。PowerShell 对应 `-DryRun`、`-Force`；原目录会保存在同级时间戳备份中。

## 卸载

```sh
sh installers/install.sh --platform hermes --scope user --uninstall --yes
```

PowerShell 对应 `-Platform hermes -Scope user -Uninstall -Yes`。标记缺失时默认拒绝删除；卸载不删除同级备份。

## 已知限制

- Nous Research Hermes Agent 项目级安装不支持；这是显式边界，不是自动降级条件。
- 首版没有 Hermes tap 或官方 Skills Hub 发布，唯一发行源是本仓库的固定 GitHub Release。
- 技能不包含 QMT 客户端、行情数据、账户、券商权限或凭据；Hermes 的联网或工具能力不足时，应要求官方文档快照并把未核实 API 标为阻塞项。
