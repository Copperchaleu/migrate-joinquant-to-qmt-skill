# JoinQuant-to-QMT migration skill for five agent runtimes

[中文](README.md)

## Purpose

`migrate-joinquant-to-qmt` audits JoinQuant strategies and helps migrate them to QMT's embedded Python runtime. It aims to preserve trading intent and timing semantics while checking lifecycle hooks, market and financial data, symbols and instrument names, adjustment, suspension filling, scheduling, portfolio state, order semantics, K-line timestamps, and backtest differences.

The skill does not connect to a trading counter or place unauthorized live orders. Without a QMT client and equivalent data, the result must remain “static migration complete; QMT runtime not verified.”

## Supported platforms

| Platform | User scope | Project scope | Invocation |
|---|---|---|---|
| Codex | supported | supported | `$migrate-joinquant-to-qmt` |
| Claude Code | supported | supported | `/migrate-joinquant-to-qmt` or natural language |
| OpenCode | supported | supported | explicitly load the skill or use natural language |
| OpenClaw | supported | supported | `/migrate-joinquant-to-qmt` or natural language |
| Nous Research Hermes Agent | supported | unsupported | `/migrate-joinquant-to-qmt` or natural language |

Use the POSIX installer on macOS, Linux, and WSL. Use the PowerShell 5.1+ installer on Windows. All five runtimes consume the same skill source; there are no platform-specific forks.

## Prerequisites

- A local install needs only a downloaded repository or extracted Release; the installer has no third-party package dependency.
- Remote Release installation on POSIX needs `curl`, `unzip`, and either `sha256sum` or `shasum`; Windows uses built-in PowerShell cmdlets.
- Running the audit scripts requires Python 3. Generated QMT strategies are checked against QMT's embedded Python 3.6.8 ceiling.
- You must install and configure the QMT client, download the required market data, and verify brokerage permissions yourself.

## 30-second install

The safest short path is to download the pinned `v1.0.0` source first, inspect it locally, and then run the local installer. This example installs for Codex at user scope; replace `--platform` for another runtime.

```sh
git clone --branch v1.0.0 --depth 1 https://github.com/Copperchaleu/migrate-joinquant-to-qmt-skill.git
cd migrate-joinquant-to-qmt-skill
sh installers/install.sh --platform codex --scope user --source skill/migrate-joinquant-to-qmt --dry-run
sh installers/install.sh --platform codex --scope user --source skill/migrate-joinquant-to-qmt
```

Windows PowerShell:

```powershell
git clone --branch v1.0.0 --depth 1 https://github.com/Copperchaleu/migrate-joinquant-to-qmt-skill.git
Set-Location migrate-joinquant-to-qmt-skill
& .\installers\install.ps1 -Platform codex -Scope user -Source .\skill\migrate-joinquant-to-qmt -DryRun
& .\installers\install.ps1 -Platform codex -Scope user -Source .\skill\migrate-joinquant-to-qmt
```

If the target already exists with different content, the installer refuses to overwrite it by default.

## Pinned-version and local install

From a repository root or extracted Release, these three POSIX commands form the executable, tested user-scope lifecycle. `REPO_ROOT` is the absolute repository path; the documentation test runs dry-run, install, and uninstall against an isolated `HOME`.

```sh local-lifecycle
sh "$REPO_ROOT/installers/install.sh" --platform codex --scope user --source "$REPO_ROOT/skill/migrate-joinquant-to-qmt" --dry-run
sh "$REPO_ROOT/installers/install.sh" --platform codex --scope user --source "$REPO_ROOT/skill/migrate-joinquant-to-qmt"
sh "$REPO_ROOT/installers/install.sh" --platform codex --scope user --uninstall --yes
```

These PowerShell commands exercise the tested project-scope path; `PROJECT_DIR` must name an existing project directory.

```powershell project-lifecycle
& (Join-Path $env:REPO_ROOT 'installers/install.ps1') -Platform codex -Scope project -ProjectDir $env:PROJECT_DIR -Source (Join-Path $env:REPO_ROOT 'skill/migrate-joinquant-to-qmt') -DryRun
& (Join-Path $env:REPO_ROOT 'installers/install.ps1') -Platform codex -Scope project -ProjectDir $env:PROJECT_DIR -Source (Join-Path $env:REPO_ROOT 'skill/migrate-joinquant-to-qmt')
& (Join-Path $env:REPO_ROOT 'installers/install.ps1') -Platform codex -Scope project -ProjectDir $env:PROJECT_DIR -Uninstall -Yes
```

If you explicitly prefer a one-line remote install, use the installer from a pinned Release and inspect the script in a browser first. The example also passes `--version v1.0.0` so the skill archive is immutable; it never executes an installer from a mutable default branch.

```sh
curl -fsSL https://github.com/Copperchaleu/migrate-joinquant-to-qmt-skill/releases/download/v1.0.0/install.sh | sh -s -- --platform codex --scope user --version v1.0.0
```

```powershell
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing https://github.com/Copperchaleu/migrate-joinquant-to-qmt-skill/releases/download/v1.0.0/install.ps1).Content)) -Platform codex -Scope user -Version v1.0.0
```

A remote install downloads the pinned ZIP and `SHA256SUMS`, verifies SHA-256, and validates archive paths before writing a target. Omitting `--version`/`-Version` resolves the latest stable Release; this documentation always pins `v1.0.0` for reproducibility.

## Use

After installation, start a fresh session, invoke the skill for your runtime, and provide the JoinQuant source or project path, run mode, instruments, bar period, backtest range, and known platform parameters. For example:

```text
$migrate-joinquant-to-qmt Migrate strategies/etf_rotation.py to QMT. Preserve the original selection and scheduling semantics, produce a static audit, QMT file, and acceptance report first, and do not connect a live account.
```

You can also run the scripts directly from the repository or installed skill:

```sh
python3 skill/migrate-joinquant-to-qmt/scripts/audit_jq_strategy.py path/to/jq_strategy.py --format markdown
python3 skill/migrate-joinquant-to-qmt/scripts/check_qmt_strategy.py path/to/qmt_strategy.py --format markdown
```

Every runtime preserves three safeguards: all active strategy logs include the QMT runtime strategy name and real K-line time; failed instrument-name lookup is explicit and never silently becomes “unknown”; and LIVE freshness uses `abs((runtime - bar_time).total_seconds()) <= 180` in both `handlebar` and the final order adapter.

## Update

Fetch and inspect a new pinned Release or local source, then preview it. Use forced replacement only after confirming the target and backup location:

```sh
sh installers/install.sh --platform codex --scope user --source skill/migrate-joinquant-to-qmt --dry-run
sh installers/install.sh --platform codex --scope user --source skill/migrate-joinquant-to-qmt --force
```

```powershell
& .\installers\install.ps1 -Platform codex -Scope user -Source .\skill\migrate-joinquant-to-qmt -DryRun
& .\installers\install.ps1 -Platform codex -Scope user -Source .\skill\migrate-joinquant-to-qmt -Force
```

Without `--source`/`-Source`, use `--version v1.0.0`/`-Version v1.0.0` for a pinned Release update. Identical content reports `already installed` and does not rewrite the marker or create a backup.

## Backup and restore

An update with `--force`/`-Force` first renames the old target beside itself as `migrate-joinquant-to-qmt.backup.<UTC timestamp>`, then activates the new directory. The installer does not remove backups automatically.

To restore, exit the runtime, verify the selected backup, move the current exact skill directory somewhere safe, and rename the backup to `migrate-joinquant-to-qmt`. Never delete or replace the whole `skills` root. Restart the runtime and verify `SKILL.md` and `.jq2qmt-install` afterward.

## Uninstall

A noninteractive uninstall requires explicit confirmation:

```sh
sh installers/install.sh --platform codex --scope user --uninstall --yes
```

```powershell
& .\installers\install.ps1 -Platform codex -Scope user -Uninstall -Yes
```

If `.jq2qmt-install` is missing, removal is refused by default. Use `--force --uninstall --yes` or `-Force -Uninstall -Yes` only after confirming that the exact target is this skill. Uninstall does not remove sibling backups.

## Security model

- Remote sources are GitHub Releases only. Pinned examples use `v1.0.0`, and the ZIP is checked against its SHA-256 manifest.
- Before installation, archive roots, traversal, links, skill frontmatter, and required files are validated. Same-parent staging prevents half-installed targets.
- Different content is never overwritten without `--force`/`-Force`; a forced update creates a recoverable backup first. Dry-run creates no temporary directory, target, marker, or backup.
- The skill does not bundle the QMT client, market data, trading accounts, brokerage permissions, API keys, other credentials, or user strategies.
- It does not write real account identifiers into output or place live orders without user authorization. JoinQuant and QMT official materials are linked and summarized as needed, not copied wholesale.

## Troubleshooting

- “zero or multiple platforms detected”: pass `--platform codex|claude|opencode|openclaw|hermes` explicitly instead of relying on auto-detection.
- “target already exists with different content”: inspect the difference and dry-run output; use `--force` only after recording the generated backup path.
- “Hermes project scope is unsupported”: use `--platform hermes --scope user`; the installer never silently changes scope.
- Skill not discovered: verify the path and `SKILL.md`, then fully restart the runtime or open a new session. See the platform guides below for discovery behavior.
- Remote download or checksum failure: never bypass verification. Check the proxy and ensure the tag, ZIP, and `SHA256SUMS` are from the same Release, or use verified local source.
- QMT checks incomplete: address data, API, and Python 3.6 findings. Keep client- or permission-dependent items marked “not run”; do not claim unperformed backtests or live validation.

## Platform guides

- [Codex](docs/install-codex.md)
- [Claude Code](docs/install-claude-code.md)
- [OpenCode](docs/install-opencode.md)
- [OpenClaw](docs/install-openclaw.md)
- [Nous Research Hermes Agent](docs/install-hermes.md)

## License and official sources

This repository is licensed under the [MIT License](LICENSE). See the [GitHub repository](https://github.com/Copperchaleu/migrate-joinquant-to-qmt-skill) and [Releases](https://github.com/Copperchaleu/migrate-joinquant-to-qmt-skill/releases). Discovery behavior follows the [open Agent Skills specification](https://agentskills.io/specification) and each platform's primary documentation linked from its guide. Re-check quantitative APIs against the JoinQuant/QMT primary pages listed in the skill's `references/official-sources.md`.
