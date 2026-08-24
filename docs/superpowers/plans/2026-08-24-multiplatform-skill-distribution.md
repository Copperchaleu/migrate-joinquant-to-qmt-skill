# Multi-Platform JoinQuant-to-QMT Skill Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish one JoinQuant-to-QMT migration skill that installs safely on Codex, Claude Code, OpenCode, OpenClaw, and Hermes Agent from a versioned public GitHub release.

**Architecture:** Keep `skill/migrate-joinquant-to-qmt` as the only source of migration behavior. Two dependency-free platform launchers copy or download that exact directory into runtime-specific roots; repository tests enforce directory mapping and lifecycle parity, while GitHub Actions produces an immutable ZIP plus SHA-256 manifest.

**Tech Stack:** Agent Skills `SKILL.md`, Python standard library with Python 3.6-compatible skill scripts, POSIX shell, Windows PowerShell 5.1+, GitHub Actions, GitHub CLI.

**Spec:** `docs/superpowers/specs/2026-08-24-multiplatform-skill-distribution-design.md`

## Global Constraints

- The public repository is `Copperchaleu/migrate-joinquant-to-qmt-skill`, visibility `public`, default branch `main`.
- The initial release tag is exactly `v1.0.0`; subsequent tags follow `vMAJOR.MINOR.PATCH`.
- The canonical skill name and directory are exactly `migrate-joinquant-to-qmt`.
- Skill frontmatter uses only common `name` and `description` fields; `agents/openai.yaml` remains an optional Codex-only UI file.
- The five supported runtimes are Codex, Claude Code, OpenCode, OpenClaw, and Nous Research Hermes Agent.
- The skill must retain K-line timestamps on every active log, fail closed on unresolved instrument names, and enforce `abs((runtime - bar_time).total_seconds()) <= 180` at both `handlebar` and the final order adapter.
- Installers have no third-party language or package dependency. POSIX may require standard `curl`, `unzip`, and one of `sha256sum`/`shasum`; Windows uses built-in PowerShell cmdlets.
- Remote installs use GitHub Releases, never mutable `main`; one-line examples pin a concrete release tag.
- Existing targets are never overwritten without `--force`/`-Force`; forced replacement creates a timestamped recoverable backup.
- Hermes project scope fails explicitly. No installer silently changes the requested platform or scope.
- The repository does not contain QMT credentials, brokerage credentials, user strategies, or copies of full JoinQuant/QMT documentation.

---

### Task 1: Bootstrap the canonical skill package and regression harness

**Files:**
- Create: `.gitignore`
- Create: `LICENSE`
- Create: `skill/migrate-joinquant-to-qmt/**`
- Create: `tests/test_skill.py`
- Create: `tests/fixtures/freshness_good.py`
- Create: `tests/fixtures/freshness_bad_threshold.py`
- Create: `tests/fixtures/freshness_bad_one_sided.py`
- Create: `tests/fixtures/freshness_missing_depth.py`
- Create: `tests/fixtures/bad_unknown_name.py`
- Create: `tests/fixtures/bad_log_time.py`

**Interfaces:**
- Consumes: the installed baseline at `/Users/graypaul/.codex/skills/migrate-joinquant-to-qmt`.
- Produces: `SKILL_ROOT = repository/skill/migrate-joinquant-to-qmt`; `python3 -m unittest tests.test_skill` as the canonical skill regression command.

- [ ] **Step 1: Write the failing structure and policy tests**

Create `tests/test_skill.py` with standard-library `unittest`. Load the checker by file path so tests exercise the shipped script rather than an installed module:

```python
import ast
import importlib.util
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SKILL = REPO / "skill" / "migrate-joinquant-to-qmt"
CHECKER_PATH = SKILL / "scripts" / "check_qmt_strategy.py"
FIXTURES = REPO / "tests" / "fixtures"


def load_checker():
    spec = importlib.util.spec_from_file_location("qmt_checker", str(CHECKER_PATH))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SkillPackageTests(unittest.TestCase):
    def test_required_files_exist(self):
        required = [
            "SKILL.md",
            "agents/openai.yaml",
            "scripts/audit_jq_strategy.py",
            "scripts/check_qmt_strategy.py",
            "references/official-sources.md",
            "references/parity-checklist.md",
        ]
        for relative in required:
            self.assertTrue((SKILL / relative).is_file(), relative)

    def test_frontmatter_name_matches_directory(self):
        text = (SKILL / "SKILL.md").read_text(encoding="utf-8")
        self.assertRegex(text, r"(?m)^name: migrate-joinquant-to-qmt$")

    def test_skill_scripts_parse_as_python36(self):
        for path in sorted((SKILL / "scripts").glob("*.py")):
            source = path.read_text(encoding="utf-8")
            ast.parse(source, filename=str(path), feature_version=(3, 6))

    def test_live_freshness_policy(self):
        checker = load_checker()
        expectations = {
            "freshness_good.py": set(),
            "freshness_bad_threshold.py": {"live-bar-window"},
            "freshness_bad_one_sided.py": {"live-bar-window"},
            "freshness_missing_depth.py": {"live-bar-depth"},
        }
        for filename, expected in expectations.items():
            findings = checker.check(FIXTURES / filename)["findings"]
            symbols = {item["symbol"] for item in findings}
            self.assertTrue(expected.issubset(symbols), (filename, findings))
            if filename == "freshness_good.py":
                self.assertNotIn("live-bar-window", symbols)
                self.assertNotIn("live-bar-depth", symbols)

    def test_name_and_log_fail_closed(self):
        checker = load_checker()
        unknown = checker.check(FIXTURES / "bad_unknown_name.py")["findings"]
        bad_log = checker.check(FIXTURES / "bad_log_time.py")["findings"]
        self.assertIn("instrument-name", {item["symbol"] for item in unknown})
        self.assertIn("print", {item["symbol"] for item in bad_log})


if __name__ == "__main__":
    unittest.main()
```

Create fixture strategies by extracting the already verified minimal strategy shape from the installed checker tests. The good fixture must define `LIVE_FRESHNESS_SECONDS = 180`, use `abs((runtime - bar_time).total_seconds())`, call `qmt_live_bar_fresh` in both `handlebar` and the function containing `passorder`, and contain the required deal fields. Derive the negative fixtures with only these changes:

```text
freshness_bad_threshold.py: LIVE_FRESHNESS_SECONDS = 181
freshness_bad_one_sided.py: replace `abs((runtime - bar_time).total_seconds())` with the signed delta
freshness_missing_depth.py: remove the guard call from the passorder function
bad_unknown_name.py: add an "未知名称" fallback
bad_log_time.py: call print directly from handlebar
```

- [ ] **Step 2: Run the test to verify RED**

Run: `python3 -m unittest tests.test_skill -v`

Expected: FAIL because `skill/migrate-joinquant-to-qmt` and the fixtures do not exist.

- [ ] **Step 3: Copy the canonical baseline and add repository metadata**

Copy the installed directory byte-for-byte, excluding `__pycache__` and `.pyc` files, into `skill/migrate-joinquant-to-qmt`. Add:

```gitignore
__pycache__/
*.py[cod]
.DS_Store
.pytest_cache/
dist/
*.backup.*
```

Use the standard MIT license text with copyright line:

```text
Copyright (c) 2026 Copperchaleu
```

Add the six fixtures using GBK-compatible source text and `#coding:gbk` on line 1.

- [ ] **Step 4: Run the regression suite to verify GREEN**

Run: `python3 -m unittest tests.test_skill -v`

Expected: all tests pass, including the established `instrument-name` finding for a silent unknown-name fallback.

- [ ] **Step 5: Commit the canonical baseline**

```bash
git add .gitignore LICENSE skill tests
git commit -m "feat: add canonical JoinQuant to QMT skill package"
```

---

### Task 2: Make the skill runtime-neutral and document platform routing

**Files:**
- Modify: `skill/migrate-joinquant-to-qmt/SKILL.md`
- Create: `skill/migrate-joinquant-to-qmt/references/runtime-compatibility.md`
- Modify: `tests/test_skill.py`
- Create: `tests/forward/platform-routing-prompt.txt`

**Interfaces:**
- Consumes: canonical package from Task 1.
- Produces: a common Agent Skills body with a direct route to `references/runtime-compatibility.md`; a reusable forward-test prompt.

- [ ] **Step 1: Capture the RED forward-test result before editing the skill**

Use a fresh subagent with no surrounding conversation and this exact prompt saved to `tests/forward/platform-routing-prompt.txt`:

```text
You need to install and use the migrate-joinquant-to-qmt skill on Codex, Claude Code, OpenCode, OpenClaw, and Nous Research Hermes Agent. Read the skill directory provided to you. Return a table with user-level path, project-level path or unsupported status, invocation style, and any platform-specific limitation. Then state the three non-negotiable QMT migration safeguards for logs, instrument names, and LIVE bar freshness. Do not modify files.
```

Run once against the Task 1 skill. Record the response in the task execution log, not in the skill. RED is established if any platform path/scope/invocation is absent or if the answer invents platform-specific tool calls.

- [ ] **Step 2: Add failing static routing tests**

Append to `tests/test_skill.py`:

```python
    def test_runtime_compatibility_reference_is_routed(self):
        skill_text = (SKILL / "SKILL.md").read_text(encoding="utf-8")
        runtime_ref = SKILL / "references" / "runtime-compatibility.md"
        self.assertTrue(runtime_ref.is_file())
        self.assertIn("references/runtime-compatibility.md", skill_text)
        text = runtime_ref.read_text(encoding="utf-8")
        for term in ("Codex", "Claude Code", "OpenCode", "OpenClaw", "Hermes"):
            self.assertIn(term, text)
        self.assertIn("Hermes", text)
        self.assertRegex(text, r"Hermes[^\n]+项目[^\n]+不支持")

    def test_core_safeguards_remain_in_skill(self):
        text = (SKILL / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn("K线时间", text)
        self.assertIn("未知名称", text)
        self.assertIn("total_seconds()) <= 180", text)
```

- [ ] **Step 3: Run the static tests to verify RED**

Run: `python3 -m unittest tests.test_skill.SkillPackageTests.test_runtime_compatibility_reference_is_routed -v`

Expected: FAIL because `runtime-compatibility.md` does not exist.

- [ ] **Step 4: Add the runtime compatibility reference and neutral routing**

Create `runtime-compatibility.md` with these exact sections:

```markdown
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
```

At the start of `SKILL.md` resource routing, add an instruction to read this reference whenever runtime installation, discovery, invocation, or tool availability matters. Replace only genuinely Codex-specific tool names in the body with the neutral capability terms above; keep QMT API names unchanged.

- [ ] **Step 5: Run static tests and the GREEN forward test**

Run: `python3 -m unittest tests.test_skill -v`

Expected: PASS.

Run the exact saved forward prompt in a fresh subagent against the edited skill. Expected: all five path rows match the reference, Hermes project scope is unsupported, and the three safeguards are stated without weakening.

- [ ] **Step 6: Commit runtime compatibility**

```bash
git add skill/migrate-joinquant-to-qmt tests
git commit -m "feat: add cross-runtime skill compatibility guidance"
```

---

### Task 3: Implement the POSIX local installer lifecycle

**Files:**
- Create: `installers/install.sh`
- Create: `tests/test_installer.sh`

**Interfaces:**
- Consumes: a local canonical skill directory via `--source PATH`.
- Produces: `install.sh --platform PLATFORM --scope SCOPE`; exit 0 for install/no-op/dry-run/successful uninstall and nonzero for unsafe or unsupported operations.

- [ ] **Step 1: Write failing POSIX lifecycle tests**

Create `tests/test_installer.sh` with `set -eu`, a private `mktemp -d`, and cleanup trap. Copy the canonical source into a fixture directory and test these exact mappings under an overridden HOME:

```text
codex:user       $HOME/.codex/skills/migrate-joinquant-to-qmt
claude:user      $HOME/.claude/skills/migrate-joinquant-to-qmt
opencode:user    $HOME/.config/opencode/skills/migrate-joinquant-to-qmt
openclaw:user    $HOME/.openclaw/skills/migrate-joinquant-to-qmt
hermes:user      $HOME/.hermes/skills/migrate-joinquant-to-qmt
codex:project    $PROJECT/.agents/skills/migrate-joinquant-to-qmt
claude:project   $PROJECT/.claude/skills/migrate-joinquant-to-qmt
opencode:project $PROJECT/.opencode/skills/migrate-joinquant-to-qmt
openclaw:project $PROJECT/skills/migrate-joinquant-to-qmt
```

For every mapping run:

```sh
HOME="$TEST_HOME" installers/install.sh \
  --platform "$platform" --scope "$scope" \
  --project-dir "$PROJECT" --source "$SOURCE"
test -f "$expected/SKILL.md"
test -f "$expected/.jq2qmt-install"
```

Also assert:

```sh
HOME="$TEST_HOME" installers/install.sh --platform hermes --scope project \
  --project-dir "$PROJECT" --source "$SOURCE" && exit 1 || true

before="$(find "$TEST_HOME" "$PROJECT" -print | sort)"
HOME="$TEST_HOME" installers/install.sh --platform codex --source "$SOURCE" --dry-run
after="$(find "$TEST_HOME" "$PROJECT" -print | sort)"
test "$before" = "$after"
```

Test same-content no-op, changed-content refusal, forced backup, `--uninstall --yes`, and uninstall refusal when `.jq2qmt-install` is missing.

Create temporary executable stubs named `codex`, `claude`, `opencode`, `openclaw`, and `hermes` under a private `PATH` directory. Assert that no explicit platform succeeds only when exactly one stub is present, fails when zero or two stubs are present, and never selects an uninstalled platform. Run `--platform all` with all five stubs for user scope and assert all five targets are installed; run it for project scope and assert the four supported project targets succeed while Hermes is reported as unsupported.

- [ ] **Step 2: Run POSIX tests to verify RED**

Run: `sh tests/test_installer.sh`

Expected: FAIL because `installers/install.sh` does not exist.

- [ ] **Step 3: Implement argument parsing and exact target resolution**

Start `install.sh` with:

```sh
#!/bin/sh
set -eu

SKILL_NAME=migrate-joinquant-to-qmt
PLATFORM=
SCOPE=user
PROJECT_DIR=$(pwd)
SOURCE_DIR=
VERSION=
FORCE=0
DRY_RUN=0
UNINSTALL=0
ASSUME_YES=0
```

Parse long options with a `while [ "$#" -gt 0 ]`/`case "$1"` loop, reject missing values and unknown options, and implement `resolve_target()` with the nine exact mappings in Step 1. Expand HOME only from the actual `HOME` environment value; never use `eval`. Normalize `PROJECT_DIR` by entering it and calling `pwd -P`. Hermes/project returns exit 2 with a Chinese and English actionable message.

Implement `detect_platforms()` by checking the five exact CLI names with `command -v`. With no `--platform`, require exactly one detected CLI. For `--platform all`, iterate detected platforms in the fixed order `codex claude opencode openclaw hermes`, continue past only the documented Hermes/project unsupported result, and return nonzero if no installation target succeeds or any other platform fails.

- [ ] **Step 4: Implement validation, hashing, staging, backup, and uninstall**

Required functions and contracts:

```sh
validate_skill SOURCE_DIR
# Requires SKILL.md, scripts/audit_jq_strategy.py,
# scripts/check_qmt_strategy.py, references/official-sources.md.
# Requires exact frontmatter line: name: migrate-joinquant-to-qmt.

hash_tree DIRECTORY
# Emits one stable SHA-256 for sorted relative paths and file hashes.
# Uses sha256sum when available, otherwise shasum -a 256.

install_local SOURCE TARGET
# Stages under TARGET's parent, writes .jq2qmt-install with
# platform, scope, version/source and content hash, then renames.

uninstall_target TARGET
# Requires exact basename and install marker unless FORCE=1.
# Requires ASSUME_YES=1 in noninteractive mode.
```

Use `umask 077`, `mktemp -d "${TMPDIR:-/tmp}/jq2qmt.XXXXXX"`, and a trap that removes only the resolved temporary directory. Backups use `${TARGET}.backup.$(date -u +%Y%m%dT%H%M%SZ)`. Before any `rm -rf`, require both exact target basename and target parent matching the selected platform root. `--dry-run` must return before `mkdir`, `mktemp`, copy, backup, or marker creation.

- [ ] **Step 5: Run POSIX lifecycle tests to verify GREEN**

Run: `sh tests/test_installer.sh`

Expected: PASS with a final line `POSIX installer tests passed`.

Run: `sh -n installers/install.sh`

Expected: exit 0.

- [ ] **Step 6: Commit the local POSIX installer**

```bash
git add installers/install.sh tests/test_installer.sh
git commit -m "feat: add safe POSIX skill installer"
```

---

### Task 4: Add deterministic release packaging and POSIX remote installs

**Files:**
- Create: `scripts/build_release.py`
- Create: `tests/test_release.py`
- Modify: `installers/install.sh`
- Modify: `tests/test_installer.sh`

**Interfaces:**
- Consumes: canonical skill directory and release tag.
- Produces: `dist/migrate-joinquant-to-qmt-vTAG.zip`, `dist/SHA256SUMS`, and remote installer support for latest stable or `--version TAG`.

- [ ] **Step 1: Write failing deterministic package tests**

Create `tests/test_release.py`:

```python
import hashlib
import subprocess
import sys
import unittest
import zipfile
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
DIST = REPO / "dist"
ARCHIVE = DIST / "migrate-joinquant-to-qmt-v1.0.0.zip"


class ReleasePackageTests(unittest.TestCase):
    def setUp(self):
        if DIST.exists():
            for path in DIST.iterdir():
                path.unlink()
        else:
            DIST.mkdir()

    def test_release_archive_and_checksum(self):
        subprocess.run(
            [sys.executable, "scripts/build_release.py", "--tag", "v1.0.0"],
            cwd=str(REPO), check=True,
        )
        self.assertTrue(ARCHIVE.is_file())
        names = zipfile.ZipFile(str(ARCHIVE)).namelist()
        self.assertIn("migrate-joinquant-to-qmt/SKILL.md", names)
        self.assertFalse(any(name.startswith("/") or ".." in Path(name).parts for name in names))
        line = (DIST / "SHA256SUMS").read_text(encoding="ascii").strip()
        expected = hashlib.sha256(ARCHIVE.read_bytes()).hexdigest()
        self.assertEqual(line, expected + "  " + ARCHIVE.name)

    def test_build_is_deterministic(self):
        command = [sys.executable, "scripts/build_release.py", "--tag", "v1.0.0"]
        subprocess.run(command, cwd=str(REPO), check=True)
        first = hashlib.sha256(ARCHIVE.read_bytes()).hexdigest()
        subprocess.run(command, cwd=str(REPO), check=True)
        second = hashlib.sha256(ARCHIVE.read_bytes()).hexdigest()
        self.assertEqual(first, second)
```

- [ ] **Step 2: Run package tests to verify RED**

Run: `python3 -m unittest tests.test_release -v`

Expected: FAIL because `scripts/build_release.py` does not exist.

- [ ] **Step 3: Implement deterministic ZIP and checksum generation**

`build_release.py` must use only the Python standard library. Parse `--tag` with `argparse`, require regex `^v[0-9]+\.[0-9]+\.[0-9]+$`, iterate regular files in sorted relative-path order, reject symlinks, and create each `ZipInfo` with timestamp `(1980, 1, 1, 0, 0, 0)` and mode `0o644` except shipped shell scripts use `0o755`. Write the skill under archive root `migrate-joinquant-to-qmt/`. Write exactly one ASCII checksum line for the archive.

- [ ] **Step 4: Add failing remote-source tests to the POSIX harness**

Build `v1.0.0`, place archive and checksum in a temporary `releases/download/v1.0.0` directory, and run a local `python3 -m http.server` bound to `127.0.0.1`. Set test-only `JQ2QMT_RELEASE_ROOT=http://127.0.0.1:$PORT/releases/download` and run:

```sh
HOME="$REMOTE_HOME" JQ2QMT_RELEASE_ROOT="$RELEASE_ROOT" \
  installers/install.sh --platform codex --version v1.0.0
test -f "$REMOTE_HOME/.codex/skills/$SKILL_NAME/SKILL.md"
```

Corrupt the ZIP without updating `SHA256SUMS` and assert nonzero exit with no target directory. Add a fixture redirect endpoint for `JQ2QMT_LATEST_URL` and assert a no-version install resolves `v1.0.0` before downloading.

- [ ] **Step 5: Implement POSIX release resolution and safe extraction**

Production defaults:

```sh
REPOSITORY=Copperchaleu/migrate-joinquant-to-qmt-skill
RELEASE_ROOT=${JQ2QMT_RELEASE_ROOT:-https://github.com/$REPOSITORY/releases/download}
LATEST_URL=${JQ2QMT_LATEST_URL:-https://github.com/$REPOSITORY/releases/latest}
```

When no `--source` is supplied, resolve missing version with `curl -fsSL -o /dev/null -w '%{url_effective}' "$LATEST_URL"`, take only a final segment matching the tag regex, then download the tag-specific archive and checksum. Verify the matching checksum line before extraction. Use `unzip -Z1` to reject absolute entries and any `..` path component before extraction; reject symlinks reported by `unzip -Z -l`; extract into the private temp directory, validate the resulting skill, then call the Task 3 lifecycle.

- [ ] **Step 6: Run release and POSIX remote tests**

Run: `python3 -m unittest tests.test_release -v`

Run: `sh tests/test_installer.sh`

Expected: both pass; the corruption case must leave no installed target.

- [ ] **Step 7: Commit packaging and remote POSIX support**

```bash
git add scripts/build_release.py installers/install.sh tests
git commit -m "feat: add verified release packaging and downloads"
```

---

### Task 5: Implement the PowerShell installer with lifecycle parity

**Files:**
- Create: `installers/install.ps1`
- Create: `tests/test_installer.ps1`
- Create: `tests/platform-paths.json`
- Modify: `tests/test_installer.sh`

**Interfaces:**
- Consumes: the same local source or GitHub Release assets as POSIX.
- Produces: PowerShell parameters `-Platform`, `-Scope`, `-ProjectDir`, `-Version`, `-Source`, `-Force`, `-DryRun`, `-Uninstall`, `-Yes` with the same exit semantics.

- [ ] **Step 1: Create shared path vectors and make POSIX read them**

Create `tests/platform-paths.json`:

```json
[
  {"platform":"codex","scope":"user","relative":".codex/skills/migrate-joinquant-to-qmt"},
  {"platform":"claude","scope":"user","relative":".claude/skills/migrate-joinquant-to-qmt"},
  {"platform":"opencode","scope":"user","relative":".config/opencode/skills/migrate-joinquant-to-qmt"},
  {"platform":"openclaw","scope":"user","relative":".openclaw/skills/migrate-joinquant-to-qmt"},
  {"platform":"hermes","scope":"user","relative":".hermes/skills/migrate-joinquant-to-qmt"},
  {"platform":"codex","scope":"project","relative":".agents/skills/migrate-joinquant-to-qmt"},
  {"platform":"claude","scope":"project","relative":".claude/skills/migrate-joinquant-to-qmt"},
  {"platform":"opencode","scope":"project","relative":".opencode/skills/migrate-joinquant-to-qmt"},
  {"platform":"openclaw","scope":"project","relative":"skills/migrate-joinquant-to-qmt"}
]
```

Keep POSIX behavior tests authoritative; add a Python one-liner in both installer harnesses that reads this JSON and emits tab-separated vectors, avoiding `jq`.

- [ ] **Step 2: Write failing PowerShell tests**

Create `tests/test_installer.ps1` with `$ErrorActionPreference = 'Stop'`, private temp directories, a `try/finally` cleanup, and an `Assert-True` function that throws on false. For every JSON vector, override `$env:USERPROFILE` and `$env:HOME`, invoke `install.ps1 -Source`, and assert `SKILL.md` plus `.jq2qmt-install`. Repeat same-content, changed-content refusal, force backup, dry-run zero-write, safe uninstall, Hermes project rejection, fixed-version local HTTP install, and corrupt-checksum failure.

- [ ] **Step 3: Run PowerShell tests to verify RED**

Run on a machine with PowerShell: `pwsh -NoProfile -File tests/test_installer.ps1`

Expected: FAIL because `installers/install.ps1` does not exist.

- [ ] **Step 4: Implement PowerShell target resolution and lifecycle**

Start with an advanced parameter block:

```powershell
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('codex','claude','opencode','openclaw','hermes','all')]
    [string]$Platform,
    [ValidateSet('user','project')]
    [string]$Scope = 'user',
    [string]$ProjectDir = (Get-Location).Path,
    [string]$Version,
    [string]$Source,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
$SkillName = 'migrate-joinquant-to-qmt'
```

Implement functions `Resolve-Target`, `Test-Skill`, `Get-TreeHash`, `Install-LocalSkill`, `Remove-InstalledSkill`, `Resolve-ReleaseTag`, and `Expand-VerifiedRelease`. Use `[System.IO.Path]::GetFullPath`, `Get-FileHash -Algorithm SHA256`, `Expand-Archive`, and `Move-Item`. Reject archive entries before extraction by opening `[System.IO.Compression.ZipFile]` and checking each `FullName` for rooted paths or `..` components; reject entries with Unix symlink mode or Windows reparse attributes. Backups and install marker fields match the POSIX installer.

- [ ] **Step 5: Implement remote download parity**

Use the same repository, asset names, tag regex, `JQ2QMT_RELEASE_ROOT`, and `JQ2QMT_LATEST_URL`. Resolve the latest redirect to its final URI, download with `Invoke-WebRequest`, select the exact archive line from `SHA256SUMS`, and compare lowercase hashes with ordinal equality. A mismatch throws before target parent creation.

- [ ] **Step 6: Run PowerShell and shared-vector tests to verify GREEN**

Run: `pwsh -NoProfile -File tests/test_installer.ps1`

Run: `sh tests/test_installer.sh`

Expected: both pass and report the same nine path vectors.

- [ ] **Step 7: Commit PowerShell parity**

```bash
git add installers/install.ps1 tests
git commit -m "feat: add PowerShell skill installer"
```

---

### Task 6: Write bilingual user documentation and five platform guides

**Files:**
- Create: `README.md`
- Create: `README.en.md`
- Create: `docs/install-codex.md`
- Create: `docs/install-claude-code.md`
- Create: `docs/install-opencode.md`
- Create: `docs/install-openclaw.md`
- Create: `docs/install-hermes.md`
- Create: `tests/test_docs.py`

**Interfaces:**
- Consumes: final installer flags and path matrix from Tasks 3–5.
- Produces: public install/use/update/uninstall contract; `python3 -m unittest tests.test_docs` verifies commands do not drift.

- [ ] **Step 1: Write failing documentation contract tests**

Create `tests/test_docs.py` that reads both READMEs and all platform guides and asserts:

```python
def test_readmes_pin_release_install_examples(self):
    for path in (REPO / "README.md", REPO / "README.en.md"):
        text = path.read_text(encoding="utf-8")
        self.assertIn("v1.0.0", text)
        self.assertNotIn("raw.githubusercontent.com/Copperchaleu/migrate-joinquant-to-qmt-skill/main", text)
        self.assertIn("--platform", text)
        self.assertIn("--uninstall", text)

def test_each_platform_guide_has_path_install_call_and_limit(self):
    expectations = {
        "codex": ("~/.codex/skills", "$migrate-joinquant-to-qmt"),
        "claude-code": ("~/.claude/skills", "/migrate-joinquant-to-qmt"),
        "opencode": ("~/.config/opencode/skills", "migrate-joinquant-to-qmt"),
        "openclaw": ("~/.openclaw/skills", "/migrate-joinquant-to-qmt"),
        "hermes": ("~/.hermes/skills", "/migrate-joinquant-to-qmt"),
    }
    for name, required in expectations.items():
        text = (REPO / "docs" / ("install-" + name + ".md")).read_text(encoding="utf-8")
        for value in required:
            self.assertIn(value, text)
        self.assertIn("已知限制", text)
```

Also load `tests/platform-paths.json` and assert every relative path appears in the relevant guide.

- [ ] **Step 2: Run docs tests to verify RED**

Run: `python3 -m unittest tests.test_docs -v`

Expected: FAIL because public docs do not exist.

- [ ] **Step 3: Write README.md and README.en.md**

Use this exact section order in both languages:

```text
Purpose
Supported platforms
Prerequisites
30-second install
Pinned-version and local install
Use
Update
Backup and restore
Uninstall
Security model
Troubleshooting
Platform guides
License and official sources
```

The safe short path is clone/download Release then run the local installer. The optional one-line command must fetch `v1.0.0` installer content, never `main`. Show `--dry-run` before force replacement. State that the skill does not ship QMT, market data, accounts, or credentials.

- [ ] **Step 4: Write platform guides from the tested matrix**

Each guide includes user install, supported project install or explicit unsupported status, invocation, discovery/restart behavior, update, uninstall, and known limitations. Link to the matching primary source from the spec. Hermes must name Nous Research Hermes Agent and explicitly reject project scope.

- [ ] **Step 5: Run documentation tests and manually execute every local command**

Run: `python3 -m unittest tests.test_docs -v`

Run every local-source install, dry-run, and uninstall command shown in README against a temporary HOME/project. Expected: tests pass and commands exit as documented.

- [ ] **Step 6: Commit public documentation**

```bash
git add README.md README.en.md docs/install-*.md tests/test_docs.py
git commit -m "docs: add multi-platform installation and usage guides"
```

---

### Task 7: Add CI and immutable GitHub release automation

**Files:**
- Create: `.github/workflows/test.yml`
- Create: `.github/workflows/release.yml`
- Modify: `tests/test_release.py`

**Interfaces:**
- Consumes: repository tests and `scripts/build_release.py`.
- Produces: required multi-OS CI and tag-triggered release assets.

- [ ] **Step 1: Add failing workflow contract tests**

Append to `tests/test_release.py` tests that require both workflows and assert these literal contracts:

```python
    def test_test_workflow_has_three_operating_systems(self):
        text = (REPO / ".github/workflows/test.yml").read_text(encoding="utf-8")
        for runner in ("ubuntu-latest", "macos-latest", "windows-latest"):
            self.assertIn(runner, text)

    def test_release_workflow_is_tag_only_and_uploads_checksums(self):
        text = (REPO / ".github/workflows/release.yml").read_text(encoding="utf-8")
        self.assertIn("v*.*.*", text)
        self.assertIn("^v[0-9]+\\.[0-9]+\\.[0-9]+$", text)
        self.assertIn("scripts/build_release.py", text)
        self.assertIn("SHA256SUMS", text)
        self.assertIn("softprops/action-gh-release", text)
```

- [ ] **Step 2: Run workflow tests to verify RED**

Run: `python3 -m unittest tests.test_release -v`

Expected: FAIL because workflow files do not exist.

- [ ] **Step 3: Implement test.yml**

Create jobs:

```text
skill-and-docs (ubuntu-latest): unittest test_skill, test_release, test_docs
posix-linux (ubuntu-latest): sh tests/test_installer.sh
posix-macos (macos-latest): sh tests/test_installer.sh
powershell (windows-latest): pwsh -NoProfile -File tests/test_installer.ps1
```

Use `actions/checkout` and `actions/setup-python`; pin action major versions. Trigger on pull requests and pushes to `main`. Set minimal read-only contents permissions.

- [ ] **Step 4: Implement release.yml**

Use the GitHub tag glob `v*.*.*`, then make the first job step reject any `GITHUB_REF_NAME` that does not match the exact shell regex `^v[0-9]+\.[0-9]+\.[0-9]+$`. Set `contents: write`. Run the entire Linux static/POSIX suite, build with `python scripts/build_release.py --tag "${GITHUB_REF_NAME}"`, then use a pinned release action to upload:

```text
dist/migrate-joinquant-to-qmt-${GITHUB_REF_NAME}.zip
dist/SHA256SUMS
installers/install.sh
installers/install.ps1
```

Configure the action to fail if the release already exists or asset upload would overwrite an existing asset.

Before the release action, use `gh api "repos/${GITHUB_REPOSITORY}/releases/tags/${GITHUB_REF_NAME}"` as a guard: status 0 means the workflow exits nonzero with `release already exists`; status 404 allows creation; authentication or other API errors fail closed. This prevents an existing release or its assets from being overwritten.

- [ ] **Step 5: Run workflow contracts and local full suite**

Run: `python3 -m unittest discover -s tests -p 'test_*.py' -v`

Run: `sh tests/test_installer.sh`

Run where available: `pwsh -NoProfile -File tests/test_installer.ps1`

Expected: all pass.

- [ ] **Step 6: Commit CI and release automation**

```bash
git add .github/workflows tests/test_release.py
git commit -m "ci: test and publish versioned skill releases"
```

---

### Task 8: Perform independent forward verification and install the canonical Codex copy

**Files:**
- Modify only if a forward-test gap is found: `skill/migrate-joinquant-to-qmt/SKILL.md`
- Modify only if a forward-test gap is found: `skill/migrate-joinquant-to-qmt/references/runtime-compatibility.md`
- Modify only if a regression gap is found: `tests/test_skill.py`
- External target after tests: `/Users/graypaul/.codex/skills/migrate-joinquant-to-qmt`

**Interfaces:**
- Consumes: completed repository and all local tests.
- Produces: independent evidence of runtime routing and migration-policy compliance; updated default Codex installation with backup.

- [ ] **Step 1: Run the complete local verification from a clean checkout state**

Run:

```bash
git status --short
python3 -m unittest discover -s tests -p 'test_*.py' -v
sh tests/test_installer.sh
python3 scripts/build_release.py --tag v1.0.0
```

Expected: clean status before generated ignored `dist/`, all tests pass, package and checksum are generated.

- [ ] **Step 2: Run two fresh forward tests**

Forward test A uses `tests/forward/platform-routing-prompt.txt` against the canonical skill. Forward test B uses this migration request without revealing expected rules:

```text
Use the provided migrate-joinquant-to-qmt skill to outline a production-safe migration of a JoinQuant strategy that logs from scheduled callbacks, trades symbols whose names currently show as unknown, and may receive cached or future-labelled bars in QMT LIVE mode. Give concrete QMT helper contracts and acceptance tests. Do not modify files.
```

Expected evidence:

- A returns all five path/scope/call rows and does not claim Hermes project support.
- B requires K-line time on every active log, fails closed on empty names using normalized QMT codes and `get_instrument_detail`, and uses inclusive absolute `±180` seconds at both guard layers.

- [ ] **Step 3: Close only demonstrated gaps with RED-GREEN**

If either forward test fails, first add a minimal assertion to `tests/test_skill.py` that reproduces the missing contract, run it to see RED, edit only the relevant skill/reference sentence, rerun static and forward tests, then commit:

```bash
git add skill/migrate-joinquant-to-qmt tests/test_skill.py
git commit -m "fix: close cross-runtime skill guidance gap"
```

If both pass initially, do not create this commit.

- [ ] **Step 4: Install the verified canonical skill into Codex**

Run the repository installer with local source, explicit force, and user scope:

```bash
installers/install.sh --platform codex --scope user \
  --source skill/migrate-joinquant-to-qmt --force
```

This action requires approval to write outside the repository. Verify the installer reports the exact backup path and new content hash.

- [ ] **Step 5: Verify the installed copy is byte-equivalent**

Compare canonical and installed trees while excluding `.jq2qmt-install` and backup directories. Run the installed checker regression by loading `/Users/graypaul/.codex/skills/migrate-joinquant-to-qmt/scripts/check_qmt_strategy.py`. Expected: no content diff and the same policy results.

---

### Task 9: Authenticate GitHub, publish main, and verify v1.0.0

**Files:**
- No repository file changes unless GitHub Actions exposes a reproducible defect; any such defect follows a new failing local test before patching.
- External state: GitHub repository, Actions runs, tag, and Release.

**Interfaces:**
- Consumes: clean, fully verified local `main`.
- Produces: public repository URL, successful CI, immutable `v1.0.0` tag, downloadable Release assets, and verified checksums.

- [ ] **Step 1: Verify repository state and commit history**

Run:

```bash
git status --short
git log --oneline --decorate -10
```

Expected: clean working tree and all Tasks 1–8 represented by focused commits.

- [ ] **Step 2: Re-authenticate GitHub CLI**

Run: `gh auth status`

If the existing `Copperchaleu` token remains invalid, run `gh auth login -h github.com --web --git-protocol https` and let the user complete browser/device authorization. Then rerun `gh auth status` and require an authenticated `Copperchaleu` account before continuing.

- [ ] **Step 3: Create and push the public repository**

First verify nonexistence:

```bash
gh repo view Copperchaleu/migrate-joinquant-to-qmt-skill
```

Expected before creation: repository-not-found. Then run:

```bash
gh repo create Copperchaleu/migrate-joinquant-to-qmt-skill \
  --public --source . --remote origin --push \
  --description "Cross-platform Agent Skill for migrating JoinQuant strategies to QMT"
```

If the repository already exists under the authenticated owner, stop and inspect its default branch and contents; do not overwrite an unrelated repository.

- [ ] **Step 4: Wait for main CI and fix only test-backed defects**

Run: `gh run list --branch main --limit 5`

Run the selected test workflow with `gh run watch RUN_ID --exit-status`. Expected: every OS job succeeds. On failure, retrieve logs, reproduce locally with a failing test, patch, rerun locally, commit, push, and watch the replacement run.

- [ ] **Step 5: Create and push the immutable release tag**

Run:

```bash
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
```

Watch the tag-triggered release workflow to success.

- [ ] **Step 6: Download and independently verify release assets**

Use a new temporary directory:

```bash
gh release download v1.0.0 \
  --repo Copperchaleu/migrate-joinquant-to-qmt-skill \
  --dir RELEASE_TEMP
```

Verify the ZIP hash against `SHA256SUMS`, inspect ZIP entries for the expected single skill root, and run both installers in dry-run mode against `--version v1.0.0`. Then perform one real remote Codex install into a temporary HOME and assert `SKILL.md`, references, scripts, and marker exist.

- [ ] **Step 7: Report final public artifacts**

Return:

```text
Repository: https://github.com/Copperchaleu/migrate-joinquant-to-qmt-skill
Release: https://github.com/Copperchaleu/migrate-joinquant-to-qmt-skill/releases/tag/v1.0.0
```

Include the shortest pinned install command for each platform, the checksum verification result, GitHub Actions run URL, default Codex backup path, and the explicit Hermes project-scope limitation.
