# 聚宽到 QMT 多平台技能发行设计

日期：2026-08-24  
目标仓库：`Copperchaleu/migrate-joinquant-to-qmt-skill`  
首发版本：`v1.0.0`  
许可证：MIT

## 1. 背景与目标

现有 `migrate-joinquant-to-qmt` 技能安装在 Codex 用户技能目录，包含量化迁移流程、官方资料索引、迁移检查器和验收规则。本项目将其改造成可由 Codex、Claude Code、OpenCode、OpenClaw 和 Nous Research Hermes Agent 共同使用的公开技能发行包。

目标：

1. 量化迁移规则只维护一份，五个平台不得出现功能分叉。
2. 提供 macOS、Linux、WSL 和 Windows 的安装、更新、验证与卸载脚本。
3. 为每个平台提供准确的用户级和项目级安装使用说明。
4. 保留现有关键规则，包括日志 K 线时间、标的名称解析和 LIVE 行情新鲜度固定双向 `±180` 秒。
5. 建立自动测试、GitHub Actions、语义化版本和 GitHub Release 发行流程。

非目标：

- 不迁移或托管用户的交易策略、账户配置、券商凭据或 QMT 客户端数据。
- 不镜像聚宽或 QMT 官方文档全文，只保留链接、必要摘要和迁移规则。
- 首版不发布到 Claude 插件市场、ClawHub 或 Hermes 官方 Skills Hub；GitHub Release 是唯一发行源。
- 不为每个平台维护独立的量化迁移正文。

## 2. 总体架构

仓库采用“标准技能源码 + 薄安装适配层”：

```text
migrate-joinquant-to-qmt-skill/
├── README.md
├── README.en.md
├── LICENSE
├── skill/
│   └── migrate-joinquant-to-qmt/
│       ├── SKILL.md
│       ├── agents/
│       │   └── openai.yaml
│       ├── references/
│       │   ├── runtime-compatibility.md
│       │   └── ...
│       └── scripts/
│           ├── audit_jq_strategy.py
│           └── check_qmt_strategy.py
├── installers/
│   ├── install.sh
│   └── install.ps1
├── docs/
│   ├── install-codex.md
│   ├── install-claude-code.md
│   ├── install-opencode.md
│   ├── install-openclaw.md
│   ├── install-hermes.md
│   └── superpowers/specs/
├── tests/
│   ├── test_skill.py
│   ├── test_installer.sh
│   ├── test_installer.ps1
│   └── fixtures/
└── .github/workflows/
    ├── test.yml
    └── release.yml
```

`skill/migrate-joinquant-to-qmt` 是唯一技能源码。安装器不得修改其中的迁移规则，只负责选择目标目录、复制、记录安装元数据和验证结果。`agents/openai.yaml` 为 Codex 展示元数据，其他平台忽略该文件。

`SKILL.md` 使用共同支持的 `name` 和 `description` frontmatter。正文使用平台中立的能力表达，例如读取文件、执行脚本、搜索并打开官方文档，不依赖某个平台专有工具名。平台差异集中记录在 `references/runtime-compatibility.md` 和仓库级安装文档中。

## 3. 平台适配矩阵

| 平台 | 用户级目标 | 项目级目标 | 典型调用 |
|---|---|---|---|
| Codex | `~/.codex/skills/migrate-joinquant-to-qmt` | `.agents/skills/migrate-joinquant-to-qmt` | `$migrate-joinquant-to-qmt` |
| Claude Code | `~/.claude/skills/migrate-joinquant-to-qmt` | `.claude/skills/migrate-joinquant-to-qmt` | `/migrate-joinquant-to-qmt` 或自然语言 |
| OpenCode | `~/.config/opencode/skills/migrate-joinquant-to-qmt` | `.opencode/skills/migrate-joinquant-to-qmt` | 明确要求加载技能或自然语言触发 |
| OpenClaw | `~/.openclaw/skills/migrate-joinquant-to-qmt` | `<workspace>/skills/migrate-joinquant-to-qmt` | `/migrate-joinquant-to-qmt` 或自然语言 |
| Hermes Agent | `~/.hermes/skills/migrate-joinquant-to-qmt` | 不提供隐式项目级安装 | `/migrate-joinquant-to-qmt` 或自然语言 |

Hermes 的 `--scope project` 必须明确失败并给出用户级安装建议，不能静默改为用户级。OpenClaw 若检测到可用 CLI，可以使用其本地目录安装能力；否则直接复制到公开文档规定的技能根目录。两条路径的最终目录内容必须一致。

平台依据：

- Claude Code Agent Skills：<https://code.claude.com/docs/en/skills>
- OpenCode Agent Skills：<https://opencode.ai/docs/skills>
- OpenClaw Skills：<https://docs.openclaw.ai/tools/skills>
- Hermes Skills：<https://github.com/NousResearch/hermes-agent/blob/main/website/docs/guides/work-with-skills.md>
- Agent Skills 开放规范：<https://agentskills.io/specification>

## 4. 安装器接口

POSIX 安装器：

```text
install.sh \
  --platform codex|claude|opencode|openclaw|hermes|all \
  [--scope user|project] \
  [--project-dir PATH] \
  [--version TAG] \
  [--source PATH] \
  [--force] \
  [--dry-run] \
  [--uninstall] \
  [--yes]
```

PowerShell 安装器提供语义一致的命名参数：`-Platform`、`-Scope`、`-ProjectDir`、`-Version`、`-Source`、`-Force`、`-DryRun`、`-Uninstall` 和 `-Yes`。

行为规则：

1. `--platform` 缺省时检查 `codex`、`claude`、`opencode`、`openclaw` 和 `hermes` 可执行文件。恰好检测到一个平台时使用它；检测不到或检测到多个时停止并要求显式选择。
2. `--scope` 默认为 `user`。`project` 作用域以 `--project-dir` 为根；未提供时使用当前目录。
3. `--source PATH` 从本地仓库或已解压发行包安装，供开发、离线和测试使用。
4. 未指定 `--source` 时，从 GitHub Releases 查询最新稳定版本，将其解析为不可变标签后下载对应 ZIP 和 `SHA256SUMS`。`--version` 指定标签时不得自动升级。
5. 一行安装示例必须固定到具体 Release 标签；不得直接执行 `main` 分支脚本。
6. `all` 只安装本机可识别且支持所选作用域的平台；输出逐平台结果。若没有目标则失败。

## 5. 安全、幂等与失败处理

安装流程：

1. 创建私有临时目录。
2. 获取或读取发行包。
3. 对远程包校验 SHA-256；失败立即停止。
4. 验证发行包中只有一个预期技能根，并拒绝绝对路径、`..` 路径和越界符号链接。
5. 验证 `SKILL.md` frontmatter 名称等于目录名，关键 references 和 scripts 均存在。
6. 在目标父目录创建 staging 目录并完整复制。
7. 写入安装元数据，包含平台、作用域、版本、来源和技能内容哈希。
8. 若目标不存在，以原子重命名完成安装。
9. 若目标内容哈希相同，报告 already installed，不写文件。
10. 若目标不同且未传 `--force`，停止并保留原目录。
11. 若传 `--force`，先把原目录重命名为带 UTC 时间戳的备份，再提交 staging；失败时恢复备份。

卸载只针对精确解析后的 `migrate-joinquant-to-qmt` 目录。交互模式要求确认；非交互模式必须同时传 `--uninstall --yes`。安装器不得递归删除用户主目录、技能根目录或未解析的平台路径。若安装元数据缺失，默认停止；`--force --uninstall --yes` 才允许删除已确认的精确技能目录。

`--dry-run` 不创建临时文件、备份或目标目录，只输出来源、版本、平台、作用域、目标路径和计划动作。日志不得输出 GitHub 凭据、代理凭据或券商信息。

## 6. 技能内容迁移

从当前默认安装位置复制现有技能作为首版基线，并进行以下兼容性改造：

1. 保留全部量化迁移参考、审计脚本和检查脚本。
2. 将平台专有工具名改写为能力描述；必须使用平台专有操作时，通过 runtime compatibility 参考路由。
3. 确保所有相对链接均以技能根目录为基准。
4. 在 `runtime-compatibility.md` 中记录平台发现、调用、脚本执行和官方资料访问差异。
5. 不弱化现有检查：所有日志必须带触发日志的 K 线时间；名称解析失败必须显式失败，不能显示“未知名称”；LIVE 新鲜度必须使用 `abs((runtime - bar_time).total_seconds()) <= 180`，并在 `handlebar` 与最终下单层双重守卫。
6. 对不具备联网或浏览能力的运行时，要求用户提供文档快照或明确标记未核实项，不允许编造 API。

## 7. 用户文档

`README.md` 是中文入口，`README.en.md` 是英文完整速查。两者包含：

- 技能用途、支持平台和运行前提；
- 30 秒安装、固定版本安装、本地安装；
- 更新、备份恢复和卸载；
- 各平台调用示例；
- 最小迁移示例；
- 安全说明和故障排查；
- 仓库、Release 和问题反馈入口。

五份平台文档分别说明用户级与项目级路径、安装命令、技能重新发现或重启要求、显式调用方式和已知限制。Hermes 文档明确只由通用安装器提供用户级安装；如需使用 Hermes tap 或官方 Hub，作为未来独立发布工作处理。

文档明确说明技能不包含 QMT 客户端、行情数据、交易权限或券商账户配置。聚宽和 QMT 文档仅链接到官方站点，不复制完整受版权保护内容。

## 8. 测试策略

### 8.1 技能回归

- 校验目录结构、frontmatter、相对链接和必需文件。
- 通过 AST 解析验证 Python 3.6 语法兼容性。
- 对 `audit_jq_strategy.py` 和 `check_qmt_strategy.py` 运行代表性正反样例。
- 保留以下回归断言：
  - 阈值 120、181 或单向时间差触发 `live-bar-window`；绝对时间差 `<= 180` 通过；
  - 缺少 `handlebar` 或最终下单守卫触发 `live-bar-depth`；
  - 业务日志缺少 K 线时间被拒绝；
  - 名称为空或使用“未知名称”静默回退被拒绝。

### 8.2 安装器测试

每个平台在隔离临时 HOME 和临时项目目录中覆盖：

- 首次用户级安装；
- 支持平台的项目级安装；
- 相同内容重复安装；
- 不同内容无 `force` 失败；
- 强制更新产生可恢复备份；
- dry-run 零写入；
- 安全卸载；
- 非法包路径、错误哈希和缺失文件失败关闭；
- 包含空格和非 ASCII 字符的路径。

POSIX 脚本在 Linux 与 macOS runner 上运行；PowerShell 脚本在 Windows runner 上运行。核心目标路径和行为必须由共享测试向量校验，避免两个安装器语义漂移。

### 8.3 技能前向测试

按 RED-GREEN-REFACTOR 进行：

1. 不加载跨平台参考，让独立代理回答五个平台的安装目录、调用方式和共同源码策略，记录遗漏或错误。
2. 加载新版技能后重复真实迁移与安装场景。
3. 验证代理能选择正确平台路径、调用正确检查器，并保留关键量化约束。
4. 若出现新的平台专有假设，收紧正文或 runtime compatibility 参考并重测。

## 9. CI 与发布

`test.yml` 在 pull request 和 `main` push 上运行：

- Linux/macOS 的 Python 与 Shell 测试；
- Windows 的 PowerShell 测试；
- 技能结构、链接、语法和量化规则回归；
- 安装产物与源码内容一致性检查。

`release.yml` 只在符合 `vMAJOR.MINOR.PATCH` 的标签触发：

1. 重新运行全部验证。
2. 从 `skill/migrate-joinquant-to-qmt` 生成只含技能目录的 ZIP。
3. 生成 `SHA256SUMS`。
4. 把技能 ZIP、两个安装器和校验文件附加到 GitHub Release。
5. 若同名 Release 或资源已存在则失败，不覆盖历史发布。

首发步骤：

1. 在本地独立仓库完成实现和测试。
2. 使用已重新认证的 GitHub CLI 创建公开仓库 `Copperchaleu/migrate-joinquant-to-qmt-skill`。
3. 推送 `main`。
4. 确认 GitHub Actions 成功。
5. 创建并推送 `v1.0.0` 标签。
6. 确认 Release 资源和 SHA-256 可下载并匹配。

## 10. 验收标准

项目完成必须同时满足：

1. 五个平台可从同一技能源码完成用户级安装；支持项目作用域的平台可正确安装到项目目录。
2. 两个安装器在对应系统的隔离测试中通过安装、幂等、更新、备份、dry-run 和卸载场景。
3. README 和五份平台文档中的命令与测试实际使用的命令一致。
4. 技能结构、Python 3.6 语法和量化规则回归全部通过。
5. 独立前向测试能正确应用跨平台路径并保留日志、名称和 `±180` 秒规则。
6. GitHub 公共仓库可访问，`main` 与本地提交一致。
7. `v1.0.0` Release 包、安装器和 `SHA256SUMS` 可下载且校验通过。
8. 最终交付包含仓库 URL、Release URL、各平台最短安装命令及任何仍存在的平台限制。

