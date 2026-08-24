import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
READMES = (REPO / "README.md", REPO / "README.en.md")
GUIDES = {
    "codex": REPO / "docs" / "install-codex.md",
    "claude": REPO / "docs" / "install-claude-code.md",
    "opencode": REPO / "docs" / "install-opencode.md",
    "openclaw": REPO / "docs" / "install-openclaw.md",
    "hermes": REPO / "docs" / "install-hermes.md",
}
SKILL_NAME = "migrate-joinquant-to-qmt"
PLATFORM_PATHS = {}

for vector in json.loads((REPO / "tests" / "platform-paths.json").read_text(encoding="utf-8")):
    PLATFORM_PATHS.setdefault(vector["platform"], {})[vector["scope"]] = Path(vector["relative"])


def fenced_blocks(text, info):
    pattern = re.compile(
        r"^```" + re.escape(info) + r"\s*$\n(.*?)^```\s*$",
        re.MULTILINE | re.DOTALL,
    )
    return [match.group(1).strip() for match in pattern.finditer(text)]


def all_fenced_blocks(text):
    pattern = re.compile(r"^```([^\n]+)\s*$\n(.*?)^```\s*$", re.MULTILINE | re.DOTALL)
    return [
        (match.group(1).strip(), match.group(2).strip())
        for match in pattern.finditer(text)
    ]


def markdown_h2s(text):
    return re.findall(r"(?m)^## ([^\n]+)$", text)


def _strip_quotes(value):
    return value.strip().strip('"').strip("'")


def _option_value(command, *names):
    for name in names:
        match = re.search(rf"(?:^|\\s){re.escape(name)}\\s+([^\s]+)", command)
        if match:
            return _strip_quotes(match.group(1))
    return ""


def _normalize_command(line, language, env):
    if language == "sh":
        return (
            line.replace("/path/to/project", "$PROJECT_DIR")
            .replace("/path/to/workspace", "$PROJECT_DIR")
            .replace("/path/to/releasedir", env.get("RELEASE_ROOT", "$RELEASE_ROOT"))
        )
    return (
        line.replace("\\", "/")
        .replace("C:\\path\\to\\project", "$env:PROJECT_DIR")
        .replace("C:\\path\\to\\workspace", "$env:PROJECT_DIR")
    )


def _resolve_placeholder_token(value, env):
    if not value:
        return value
    if value in ("$PROJECT_DIR", '"$PROJECT_DIR"'):
        return env["PROJECT_DIR"]
    if value in ("$env:PROJECT_DIR", '$env:PROJECT_DIR'):
        return env["PROJECT_DIR"]
    if value.startswith("$env:"):
        key = value[5:]
        return env.get(key, value)
    if value in ("$REPO_ROOT", '"$REPO_ROOT"'):
        return env["REPO_ROOT"]
    return value


def _installer_target(env, command):
    platform = _option_value(command, "--platform", "-Platform")
    if not platform:
        return None
    scope = _option_value(command, "--scope", "-Scope") or "user"
    if scope not in ("user", "project"):
        return None
    if platform not in PLATFORM_PATHS or scope not in PLATFORM_PATHS[platform]:
        return None

    if scope == "user":
        base = env.get("HOME") or env.get("USERPROFILE")
    else:
        base = _resolve_placeholder_token(
            _option_value(command, "--project-dir", "-ProjectDir"), env
        )

    if not base:
        return None
    return Path(base) / PLATFORM_PATHS[platform][scope]


def _ensure_target_for_uninstall(env, command):
    target = _installer_target(env, command)
    if target is None or target.exists():
        return

    platform = _option_value(command, "--platform", "-Platform")
    scope = _option_value(command, "--scope", "-Scope") or "user"
    project_dir = _resolve_placeholder_token(
        _option_value(command, "--project-dir", "-ProjectDir") or '"$PROJECT_DIR"',
        env,
    )
    source = f'"{Path(env["REPO_ROOT"]) / "skill" / SKILL_NAME}"'
    installer = f'"{Path(env["REPO_ROOT"]) / "installers" / "install.sh"}"'

    if scope == "project":
        command_line = (
            f"sh {installer} --platform {platform} --scope {scope} "
            f"--project-dir \"{project_dir}\" --source {source}"
        )
    else:
        command_line = f"sh {installer} --platform {platform} --scope {scope} --source {source}"

    result = subprocess.run(
        ["sh", "-eu", "-c", command_line],
        cwd=str(REPO),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if result.returncode != 0:
        raise AssertionError(f"preinstall for uninstall failed:\n{result.stdout}")


def _iter_installer_blocks(paths):
    for path in paths:
        text = path.read_text(encoding="utf-8")
        for language, block in all_fenced_blocks(text):
            lang = language.split()[0]
            if lang not in ("sh", "powershell"):
                continue

            lines = [line.strip() for line in block.splitlines() if line.strip()]
            if not any("install.sh" in line or "install.ps1" in line for line in lines):
                continue
            if any("releases/download" in line for line in lines):
                continue

            installer_lines = [
                line
                for line in lines
                if "install.sh" in line
                or "install.ps1" in line
                or "--platform" in line
                or "-Platform" in line
            ]
            if installer_lines:
                yield path, lang, language, installer_lines


def _run_posix_lines(test_case, env, lines, repo_root=REPO):
    for line in lines:
        command = _normalize_command(line, "sh", env)
        if "--platform" not in command and "-Platform" not in command:
            continue
        if "$RELEASE_ROOT" in command:
            continue

        target = _installer_target(env, command)
        if "--uninstall" in command and target is not None:
            _ensure_target_for_uninstall(env, command)

        result = subprocess.run(
            ["sh", "-eu", "-c", command],
            cwd=str(repo_root),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        test_case.assertEqual(result.returncode, 0, result.stdout)

        if target is None:
            continue
        if "--dry-run" in command:
            test_case.assertFalse(target.exists())
        elif "--uninstall" in command:
            test_case.assertFalse(target.exists())
        else:
            test_case.assertTrue((target / "SKILL.md").is_file())
            test_case.assertTrue((target / ".jq2qmt-install").is_file())


def _run_powershell_lines(test_case, env, lines):
    pwsh = shutil.which("pwsh")
    if pwsh is None:
        portable = Path("/private/tmp/powershell-7.6.4/pwsh")
        if portable.is_file():
            pwsh = str(portable)
    if pwsh is None:
        test_case.skipTest("pwsh is unavailable; PowerShell lifecycle has its own Windows suite")

    for line in lines:
        command = _normalize_command(line, "powershell", env)
        if "--platform" not in command and "-Platform" not in command:
            continue

        target = _installer_target(env, command)
        if "-Uninstall" in command and target is not None:
            _ensure_target_for_uninstall(env, command)

        result = subprocess.run(
            [pwsh, "-NoProfile", "-Command", command],
            cwd=str(REPO),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        test_case.assertEqual(result.returncode, 0, result.stdout)

        if target is None:
            continue
        if "-WhatIf" in command:
            test_case.assertFalse(target.exists())
        elif "-DryRun" in command:
            test_case.assertFalse(target.exists())
        elif "-Uninstall" in command:
            test_case.assertFalse(target.exists())
        else:
            test_case.assertTrue((target / "SKILL.md").is_file())
            test_case.assertTrue((target / ".jq2qmt-install").is_file())


class DocumentationContractTests(unittest.TestCase):
    def test_readmes_follow_the_public_contract(self):
        expected_sections = {
            "README.md": [
                "用途",
                "支持的平台",
                "运行前提",
                "30 秒安装",
                "固定版本与本地安装",
                "使用",
                "更新",
                "备份与恢复",
                "卸载",
                "安全模型",
                "故障排查",
                "平台指南",
                "许可证与官方来源",
            ],
            "README.en.md": [
                "Purpose",
                "Supported platforms",
                "Prerequisites",
                "30-second install",
                "Pinned-version and local install",
                "Use",
                "Update",
                "Backup and restore",
                "Uninstall",
                "Security model",
                "Troubleshooting",
                "Platform guides",
                "License and official sources",
            ],
        }
        for path in READMES:
            text = path.read_text(encoding="utf-8")
            self.assertEqual(markdown_h2s(text), expected_sections[path.name])
            self.assertIn("v1.0.0", text)
            self.assertNotIn(
                "raw.githubusercontent.com/Copperchaleu/"
                "migrate-joinquant-to-qmt-skill/main",
                text,
            )
            self.assertLess(text.index("--dry-run"), text.index("--force"))
            self.assertIn("--platform", text)
            self.assertIn("--uninstall", text)

    def test_readmes_disclose_security_and_distribution_boundaries(self):
        chinese = READMES[0].read_text(encoding="utf-8")
        english = READMES[1].read_text(encoding="utf-8")
        for term in ("QMT 客户端", "行情数据", "交易账户", "凭据"):
            self.assertIn(term, chinese)
        for term in ("QMT client", "market data", "trading accounts", "credentials"):
            self.assertIn(term, english)
        for text in (chinese, english):
            self.assertIn(
                "https://github.com/Copperchaleu/"
                "migrate-joinquant-to-qmt-skill/releases/download/v1.0.0/",
                text,
            )

    def test_guides_match_the_shared_platform_path_matrix(self):
        vectors = json.loads(
            (REPO / "tests" / "platform-paths.json").read_text(encoding="utf-8")
        )
        invocations = {
            "codex": "$migrate-joinquant-to-qmt",
            "claude": "/migrate-joinquant-to-qmt",
            "opencode": "migrate-joinquant-to-qmt",
            "openclaw": "/migrate-joinquant-to-qmt",
            "hermes": "/migrate-joinquant-to-qmt",
        }
        by_platform = {}
        for vector in vectors:
            by_platform.setdefault(vector["platform"], []).append(vector)

        for platform, path in GUIDES.items():
            text = path.read_text(encoding="utf-8")
            for vector in by_platform[platform]:
                self.assertIn(vector["relative"], text, (platform, vector))
            self.assertIn("## 用户级安装", text)
            self.assertIn("## 项目级安装", text)
            self.assertIn("## 调用", text)
            self.assertIn("## 发现与重启", text)
            self.assertIn("## 更新", text)
            self.assertIn("## 卸载", text)
            self.assertIn("## 已知限制", text)
            self.assertIn("--platform " + platform, text)
            self.assertIn(invocations[platform], text)

        hermes = GUIDES["hermes"].read_text(encoding="utf-8")
        self.assertIn("Nous Research Hermes Agent", hermes)
        self.assertRegex(hermes, r"(?s)--scope project.*不支持")

    def test_guides_link_the_primary_platform_sources(self):
        expected = {
            "codex": "https://agentskills.io/specification",
            "claude": "https://code.claude.com/docs/en/skills",
            "opencode": "https://opencode.ai/docs/skills",
            "openclaw": "https://docs.openclaw.ai/tools/skills",
            "hermes": (
                "https://github.com/NousResearch/hermes-agent/blob/main/"
                "website/docs/guides/work-with-skills.md"
            ),
        }
        for platform, url in expected.items():
            self.assertIn(url, GUIDES[platform].read_text(encoding="utf-8"))

    def test_documented_posix_local_lifecycle_commands_execute(self):
        for path in READMES:
            text = path.read_text(encoding="utf-8")
            blocks = fenced_blocks(text, "sh local-lifecycle")
            self.assertEqual(len(blocks), 1, path.name)
            commands = [line for line in blocks[0].splitlines() if line.strip()]
            self.assertEqual(len(commands), 3, (path.name, commands))

            with tempfile.TemporaryDirectory(prefix="jq2qmt-docs-sh-") as root:
                root_path = Path(root)
                home = root_path / "home"
                project = root_path / "project"
                home.mkdir()
                project.mkdir()
                target = home / ".codex" / "skills" / SKILL_NAME
                env = os.environ.copy()
                env.update(
                    {
                        "HOME": str(home),
                        "PROJECT_DIR": str(project),
                        "REPO_ROOT": str(REPO),
                    }
                )

                _run_posix_lines(self, env, commands)
                self.assertFalse(target.exists())

    def test_documented_powershell_project_lifecycle_commands_execute(self):
        for path in READMES:
            text = path.read_text(encoding="utf-8")
            blocks = fenced_blocks(text, "powershell project-lifecycle")
            self.assertEqual(len(blocks), 1, path.name)
            commands = [line for line in blocks[0].splitlines() if line.strip()]
            self.assertEqual(len(commands), 3, (path.name, commands))

            with tempfile.TemporaryDirectory(prefix="jq2qmt-docs-ps-") as root:
                root_path = Path(root)
                home = root_path / "home"
                project = root_path / "project"
                runtime_home = root_path / "runtime-home"
                home.mkdir()
                project.mkdir()
                runtime_home.mkdir()
                target = project / ".agents" / "skills" / SKILL_NAME
                env = os.environ.copy()
                env.update(
                    {
                        "HOME": str(runtime_home),
                        "USERPROFILE": str(home),
                        "PROJECT_DIR": str(project),
                        "REPO_ROOT": str(REPO),
                    }
                )

                _run_powershell_lines(self, env, commands)
                self.assertFalse(target.exists())

    def test_release_root_extracted_workflow_commands_execute(self):
        for path in READMES:
            text = path.read_text(encoding="utf-8")
            blocks = fenced_blocks(text, "sh release-root-lifecycle")
            if not blocks:
                continue
            self.assertEqual(len(blocks), 1, path.name)
            commands = [line for line in blocks[0].splitlines() if line.strip()]
            with tempfile.TemporaryDirectory(prefix="jq2qmt-release-") as root:
                build_root = Path(root) / "release-root"
                build_root.mkdir()

                subprocess.run(
                    [sys.executable, "scripts/build_release.py", "--tag", "v1.0.0"],
                    cwd=str(REPO),
                    check=True,
                )
                with zipfile.ZipFile(REPO / "dist" / "migrate-joinquant-to-qmt-v1.0.0.zip") as archive:
                    archive.extractall(path=str(build_root))

                home = Path(root) / "home"
                project = Path(root) / "project"
                home.mkdir()
                project.mkdir()
                env = os.environ.copy()
                env.update(
                    {
                        "HOME": str(home),
                        "PROJECT_DIR": str(project),
                        "REPO_ROOT": str(REPO),
                        "RELEASE_ROOT": str(build_root),
                    }
                )
                _run_posix_lines(self, env, commands)

    def test_documented_installer_blocks_execute(self):
        all_paths = list(READMES) + list(GUIDES.values())
        for path, lang, _tag, lines in _iter_installer_blocks(all_paths):
            with tempfile.TemporaryDirectory(prefix="jq2qmt-docs-all-") as root:
                root_path = Path(root)
                home = root_path / "home"
                project = root_path / "project"
                runtime_home = root_path / "runtime-home"
                home.mkdir()
                project.mkdir()
                runtime_home.mkdir()
                env = os.environ.copy()
                env.update(
                    {
                        "HOME": str(home),
                        "USERPROFILE": str(runtime_home),
                        "PROJECT_DIR": str(project),
                        "REPO_ROOT": str(REPO),
                    }
                )

                if lang == "sh":
                    _run_posix_lines(self, env, lines)
                else:
                    _run_powershell_lines(self, env, lines)


if __name__ == "__main__":
    unittest.main()
