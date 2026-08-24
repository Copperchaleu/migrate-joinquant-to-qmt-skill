# 聚宽策略迁移到 QMT：多平台技能

[English](README.en.md)

## 用途

`migrate-joinquant-to-qmt` 帮助你审计聚宽策略，并迁移为迅投 QMT 内置 Python 策略。它以交易意图和时序语义等价为目标，重点检查生命周期、行情与财务数据、证券代码和名称、复权、停牌填充、调度、账户持仓、下单语义、K 线时间日志及回测差异。

技能不会替你连接交易柜台或执行未经授权的实盘操作。没有 QMT 客户端和同口径数据时，结果只能标记为“静态迁移完成，QMT 运行未验证”。

## 支持的平台

| 平台 | 用户级安装 | 项目级安装 | 调用方式 |
|---|---|---|---|
| Codex | 支持 | 支持 | `$migrate-joinquant-to-qmt` |
| Claude Code | 支持 | 支持 | `/migrate-joinquant-to-qmt` 或自然语言 |
| OpenCode | 支持 | 支持 | 明确加载技能或自然语言 |
| OpenClaw | 支持 | 支持 | `/migrate-joinquant-to-qmt` 或自然语言 |
| Nous Research Hermes Agent | 支持 | 不支持 | `/migrate-joinquant-to-qmt` 或自然语言 |

macOS、Linux 和 WSL 使用 POSIX 安装器；Windows 使用 PowerShell 5.1+ 安装器。五个平台共享同一个技能源码，不维护平台分叉。

## 运行前提

- 本地安装只需要已下载的仓库或已解压的 Release；安装器本身没有第三方包依赖。
- 从 Release 远程安装时，POSIX 环境需要 `curl`、`unzip` 和 `sha256sum` 或 `shasum`；Windows 使用内置 PowerShell cmdlet。
- 运行技能审计脚本需要 Python 3；生成的 QMT 策略按 QMT 内置 Python 3.6.8 上限检查。
- 使用者需要自行安装并配置 QMT 客户端、下载所需行情数据，并核对券商权限。

## 30 秒安装

最安全的短路径是先把固定版本 `v1.0.0` 下载到本地、检查内容，再运行本地安装器。下面以 Codex 用户级安装为例；其他平台只需替换 `--platform`。

```sh
git clone --branch v1.0.0 --depth 1 https://github.com/Copperchaleu/migrate-joinquant-to-qmt-skill.git
cd migrate-joinquant-to-qmt-skill
sh installers/install.sh --platform codex --scope user --source skill/migrate-joinquant-to-qmt --dry-run
sh installers/install.sh --platform codex --scope user --source skill/migrate-joinquant-to-qmt
```

Windows PowerShell：

```powershell
git clone --branch v1.0.0 --depth 1 https://github.com/Copperchaleu/migrate-joinquant-to-qmt-skill.git
Set-Location migrate-joinquant-to-qmt-skill
& .\installers\install.ps1 -Platform codex -Scope user -Source .\skill\migrate-joinquant-to-qmt -DryRun
& .\installers\install.ps1 -Platform codex -Scope user -Source .\skill\migrate-joinquant-to-qmt
```

目标已存在且内容不同的时候，安装器默认拒绝覆盖。

## 固定版本与本地安装

在仓库或已解压 Release 根目录内，下面三条 POSIX 命令构成经过自动测试的本地用户级生命周期。`REPO_ROOT` 是仓库绝对路径；测试会在隔离的 `HOME` 下真实执行 dry-run、安装和卸载。

注意：Release zip 仅包含 `migrate-joinquant-to-qmt/`，不包含仓库中的 `installers/`。若你只拿到已解压 Release，安装时请先准备本仓库的 `installers/`（或改用下一段的固定远程安装脚本）。

```sh local-lifecycle
sh "$REPO_ROOT/installers/install.sh" --platform codex --scope user --source "$REPO_ROOT/skill/migrate-joinquant-to-qmt" --dry-run
sh "$REPO_ROOT/installers/install.sh" --platform codex --scope user --source "$REPO_ROOT/skill/migrate-joinquant-to-qmt"
sh "$REPO_ROOT/installers/install.sh" --platform codex --scope user --uninstall --yes
```

若你手上只有 Release zip，解包后目标路径是 `migrate-joinquant-to-qmt/`，可直接把该路径作为 `--source`（前提是你使用本仓库的安装脚本执行）：

```sh release-root-lifecycle
RELEASE_ROOT=/path/to/releasedir
sh "$REPO_ROOT/installers/install.sh" --platform codex --scope user --source "$RELEASE_ROOT/migrate-joinquant-to-qmt" --dry-run
sh "$REPO_ROOT/installers/install.sh" --platform codex --scope user --source "$RELEASE_ROOT/migrate-joinquant-to-qmt"
sh "$REPO_ROOT/installers/install.sh" --platform codex --scope user --source "$RELEASE_ROOT/migrate-joinquant-to-qmt" --uninstall --yes
```

下面三条 PowerShell 命令测试项目级路径；`PROJECT_DIR` 必须是已存在的项目目录。

```powershell project-lifecycle
& (Join-Path $env:REPO_ROOT 'installers/install.ps1') -Platform codex -Scope project -ProjectDir $env:PROJECT_DIR -Source (Join-Path $env:REPO_ROOT 'skill/migrate-joinquant-to-qmt') -DryRun
& (Join-Path $env:REPO_ROOT 'installers/install.ps1') -Platform codex -Scope project -ProjectDir $env:PROJECT_DIR -Source (Join-Path $env:REPO_ROOT 'skill/migrate-joinquant-to-qmt')
& (Join-Path $env:REPO_ROOT 'installers/install.ps1') -Platform codex -Scope project -ProjectDir $env:PROJECT_DIR -Uninstall -Yes
```

如确实需要一行远程安装，可以使用固定 Release 的安装器；请先在浏览器中检查脚本。示例同时用 `--version v1.0.0` 固定技能包，绝不从可变的默认分支执行脚本。

```sh
curl -fsSL https://github.com/Copperchaleu/migrate-joinquant-to-qmt-skill/releases/download/v1.0.0/install.sh | sh -s -- --platform codex --scope user --version v1.0.0
```

```powershell
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing https://github.com/Copperchaleu/migrate-joinquant-to-qmt-skill/releases/download/v1.0.0/install.ps1).Content)) -Platform codex -Scope user -Version v1.0.0
```

远程安装会下载固定标签的 ZIP 和 `SHA256SUMS`，校验 SHA-256 并检查压缩包路径后才写入目标目录。省略 `--version`/`-Version` 会解析最新稳定 Release；为了可复现，文档示例始终固定 `v1.0.0`。

## 使用

安装后重新打开会话，按平台调用技能，并提供聚宽源码或项目路径、运行模式、品种、周期、回测区间及已知平台参数。例如：

```text
$migrate-joinquant-to-qmt 请把 strategies/etf_rotation.py 迁移到 QMT；保留原选股和调度语义，先生成静态审计、QMT 文件和验收报告，不要连接实盘账户。
```

也可直接运行仓库或已安装技能中的脚本：

```sh
python3 skill/migrate-joinquant-to-qmt/scripts/audit_jq_strategy.py path/to/jq_strategy.py --format markdown
python3 skill/migrate-joinquant-to-qmt/scripts/check_qmt_strategy.py path/to/qmt_strategy.py --format markdown
```

技能要求保留三个共同安全边界：所有策略主动日志包含 QMT 运行时策略名和真实 K 线时间；标的名称解析失败显式报错，不以“未知名称”静默继续；LIVE 在 `handlebar` 和最终下单适配器两层都使用固定双向 `abs((runtime - bar_time).total_seconds()) <= 180` 新鲜度守卫。

## 更新

先获取并检查新的固定 Release 或本地源码，再预演。只有确认目标和备份位置正确后才强制替换：

```sh
sh installers/install.sh --platform codex --scope user --source skill/migrate-joinquant-to-qmt --dry-run
sh installers/install.sh --platform codex --scope user --source skill/migrate-joinquant-to-qmt --force
```

```powershell
& .\installers\install.ps1 -Platform codex -Scope user -Source .\skill\migrate-joinquant-to-qmt -DryRun
& .\installers\install.ps1 -Platform codex -Scope user -Source .\skill\migrate-joinquant-to-qmt -Force
```

不提供 `--source`/`-Source` 时可用 `--version v1.0.0`/`-Version v1.0.0` 从固定 Release 更新。相同内容会报告 `already installed`，不会重写安装标记或生成备份。

## 备份与恢复

`--force`/`-Force` 更新会先把原目标目录改名为同级的 `migrate-joinquant-to-qmt.backup.<UTC 时间戳>`，再启用新目录。安装器不会自动删除备份。

恢复时先退出对应运行时，确认要恢复的备份完整，然后把当前精确技能目录移到安全位置，再把选定备份改回 `migrate-joinquant-to-qmt`。不要把整个 `skills` 根目录删除或覆盖。恢复后重新启动运行时并检查 `SKILL.md` 和 `.jq2qmt-install`。

## 卸载

非交互卸载必须显式确认：

```sh
sh installers/install.sh --platform codex --scope user --uninstall --yes
```

```powershell
& .\installers\install.ps1 -Platform codex -Scope user -Uninstall -Yes
```

安装标记 `.jq2qmt-install` 缺失时，安装器默认拒绝删除。只有你确认目标就是该技能目录时，才使用 `--force --uninstall --yes` 或 `-Force -Uninstall -Yes`。卸载不删除同级备份。

## 安全模型

- 远程来源只使用 GitHub Releases；固定示例锁定 `v1.0.0`，并校验 ZIP 的 SHA-256。
- 安装前验证压缩包根目录、路径穿越、符号链接、技能 frontmatter 和必需文件；安装使用同目录 staging，避免半成品目标。
- 不带 `--force`/`-Force` 不覆盖不同内容；强制更新先创建可恢复备份。dry-run 不创建临时目录、目标、标记或备份。
- 技能包不附带 QMT 客户端、行情数据、交易账户、券商权限、API 密钥或其他凭据，也不附带用户策略。
- 技能不会把真实账号写进输出，也不会在缺少用户授权时发送实盘委托。聚宽和 QMT 官方资料只提供链接和必要摘要，不复制完整文档。

## 故障排查

- “检测到零个或多个平台”：明确传入 `--platform codex|claude|opencode|openclaw|hermes`；不要依赖自动检测。
- “target already exists with different content”：先检查差异和 dry-run；确认后再用 `--force`，并记录生成的备份路径。
- “Hermes project scope is unsupported”：改用 `--platform hermes --scope user`。安装器不会静默换作用域。
- 技能没有被发现：确认路径和 `SKILL.md`，完全重启运行时或开启新会话；各平台的发现行为见下方指南。
- 远程下载或校验失败：不要绕过校验。检查代理、Release 标签、ZIP 和 `SHA256SUMS` 是否来自同一版本，或改用已验证的本地源码。
- QMT 检查未通过：按报告处理数据、API 和 Python 3.6 兼容问题；没有客户端或权限时保持“未运行”，不要宣称已回测或实盘验证。

## 平台指南

- [Codex](docs/install-codex.md)
- [Claude Code](docs/install-claude-code.md)
- [OpenCode](docs/install-opencode.md)
- [OpenClaw](docs/install-openclaw.md)
- [Nous Research Hermes Agent](docs/install-hermes.md)

## 许可证与官方来源

本仓库使用 [MIT License](LICENSE)。项目主页和版本资源见 [GitHub 仓库](https://github.com/Copperchaleu/migrate-joinquant-to-qmt-skill) 与 [Releases](https://github.com/Copperchaleu/migrate-joinquant-to-qmt-skill/releases)。平台发现规则以 [Agent Skills 开放规范](https://agentskills.io/specification) 和各平台指南中的官方资料为准；量化 API 仍须按技能 `references/official-sources.md` 所列聚宽/QMT 官方页面重新核对。
