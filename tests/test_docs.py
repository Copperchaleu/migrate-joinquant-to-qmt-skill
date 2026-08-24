import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
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


def fenced_blocks(text, info):
    pattern = re.compile(
        r"^```" + re.escape(info) + r"\s*$\n(.*?)^```\s*$",
        re.MULTILINE | re.DOTALL,
    )
    return [match.group(1).strip() for match in pattern.finditer(text)]


def markdown_h2s(text):
    return re.findall(r"(?m)^## ([^\n]+)$", text)


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

                dry_run = subprocess.run(
                    ["sh", "-eu", "-c", commands[0]],
                    cwd=str(REPO), env=env, text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                )
                self.assertEqual(dry_run.returncode, 0, dry_run.stdout)
                self.assertIn("dry-run", dry_run.stdout)
                self.assertFalse(target.exists())

                install = subprocess.run(
                    ["sh", "-eu", "-c", commands[1]],
                    cwd=str(REPO), env=env, text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                )
                self.assertEqual(install.returncode, 0, install.stdout)
                self.assertTrue((target / "SKILL.md").is_file())
                self.assertTrue((target / ".jq2qmt-install").is_file())

                uninstall = subprocess.run(
                    ["sh", "-eu", "-c", commands[2]],
                    cwd=str(REPO), env=env, text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                )
                self.assertEqual(uninstall.returncode, 0, uninstall.stdout)
                self.assertFalse(target.exists())

    def test_documented_powershell_project_lifecycle_commands_execute(self):
        pwsh = shutil.which("pwsh")
        if pwsh is None:
            portable = Path("/private/tmp/powershell-7.6.4/pwsh")
            if portable.is_file():
                pwsh = str(portable)
        if pwsh is None:
            self.skipTest("pwsh is unavailable; PowerShell lifecycle has its own Windows suite")

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

                dry_run = subprocess.run(
                    [pwsh, "-NoProfile", "-Command", commands[0]],
                    cwd=str(REPO), env=env, text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                )
                self.assertEqual(dry_run.returncode, 0, dry_run.stdout)
                self.assertIn("dry-run", dry_run.stdout.lower())
                self.assertFalse(target.exists())

                install = subprocess.run(
                    [pwsh, "-NoProfile", "-Command", commands[1]],
                    cwd=str(REPO), env=env, text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                )
                self.assertEqual(install.returncode, 0, install.stdout)
                self.assertIn("installed", install.stdout.lower())
                self.assertTrue((target / "SKILL.md").is_file())
                self.assertTrue((target / ".jq2qmt-install").is_file())

                uninstall = subprocess.run(
                    [pwsh, "-NoProfile", "-Command", commands[2]],
                    cwd=str(REPO), env=env, text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                )
                self.assertEqual(uninstall.returncode, 0, uninstall.stdout)
                self.assertIn("uninstalled", uninstall.stdout.lower())
                self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
