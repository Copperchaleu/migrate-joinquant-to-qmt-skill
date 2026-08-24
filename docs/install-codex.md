# 在 Codex 中安装

本指南安装同一份 `migrate-joinquant-to-qmt` 技能源码。目录约定遵循 [Agent Skills 开放规范](https://agentskills.io/specification)；仓库附带的 `agents/openai.yaml` 仅提供 Codex UI 元数据。

先下载并检查固定 Release `v1.0.0`，或进入可信的本地仓库。建议先 dry-run，再实际写入。

## 用户级安装

目标为 `~/.codex/skills/migrate-joinquant-to-qmt`，适用于当前用户的所有 Codex 项目。

```sh
sh installers/install.sh --platform codex --scope user --source skill/migrate-joinquant-to-qmt --dry-run
sh installers/install.sh --platform codex --scope user --source skill/migrate-joinquant-to-qmt
```

```powershell
& .\installers\install.ps1 -Platform codex -Scope user -Source .\skill\migrate-joinquant-to-qmt -DryRun
& .\installers\install.ps1 -Platform codex -Scope user -Source .\skill\migrate-joinquant-to-qmt
```

## 项目级安装

目标为 `<project>/.agents/skills/migrate-joinquant-to-qmt`；共享路径向量是 `.agents/skills/migrate-joinquant-to-qmt`。

```sh
sh installers/install.sh --platform codex --scope project --project-dir "$PROJECT_DIR" --source skill/migrate-joinquant-to-qmt --dry-run
sh installers/install.sh --platform codex --scope project --project-dir "$PROJECT_DIR" --source skill/migrate-joinquant-to-qmt
```

PowerShell 使用 `-Scope project -ProjectDir $env:PROJECT_DIR`。项目目录必须已存在。

## 调用

开启新任务后显式调用：

```text
$migrate-joinquant-to-qmt 请审计并迁移 path/to/jq_strategy.py；先做静态检查，不连接实盘账户。
```

## 发现与重启

安装完成后新建 Codex 任务。若技能列表仍未出现，确认目标下存在 `SKILL.md`，完全退出并重启 Codex；不要移动技能内部的 `scripts/` 或 `references/`。项目级安装只应在该项目根目录对应的工作区中发现。

## 更新

获取新的固定 Release 后，用同一平台和作用域先运行 `--dry-run`。目标内容不同且确认要替换时加 `--force`；安装器会先创建同级时间戳备份。PowerShell 对应 `-DryRun` 和 `-Force`。

## 卸载

```sh
sh installers/install.sh --platform codex --scope user --uninstall --yes
sh installers/install.sh --platform codex --scope project --project-dir "$PROJECT_DIR" --uninstall --yes
```

PowerShell 对应 `-Platform codex -Scope user -Uninstall -Yes`。安装标记缺失时默认拒绝删除；卸载不会删除备份。

## 已知限制

- `agents/openai.yaml` 是可选的 Codex 展示元数据，不改变迁移规则。
- 用户级和项目级都安装时，应显式确认当前任务发现的是预期副本，避免版本混淆。
- 技能不包含 QMT 客户端、行情数据、账户、券商权限或凭据；没有 QMT 环境时只能完成静态验证。
