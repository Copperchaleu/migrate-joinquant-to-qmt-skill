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
            report = checker.check(FIXTURES / filename)
            findings = report["findings"]
            symbols = {item["symbol"] for item in findings}
            self.assertTrue(expected.issubset(symbols), (filename, findings))
            if filename == "freshness_good.py":
                errors = [
                    item for item in findings if item["severity"] == "error"
                ]
                self.assertEqual([], errors, report)

    def test_name_and_log_fail_closed(self):
        checker = load_checker()
        unknown = checker.check(FIXTURES / "bad_unknown_name.py")["findings"]
        code_fallback = checker.check(
            FIXTURES / "bad_code_as_name.py"
        )["findings"]
        bad_log = checker.check(FIXTURES / "bad_log_time.py")["findings"]
        self.assertIn("instrument-name", {item["symbol"] for item in unknown})
        self.assertIn(
            "instrument-name", {item["symbol"] for item in code_fallback}
        )
        self.assertIn("print", {item["symbol"] for item in bad_log})


if __name__ == "__main__":
    unittest.main()
