import hashlib
import os
import stat
import subprocess
import sys
import unittest
import zipfile
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
DIST = REPO / "dist"
ARCHIVE = DIST / "migrate-joinquant-to-qmt-v1.0.0.zip"
SKILL = REPO / "skill" / "migrate-joinquant-to-qmt"
CANONICAL_ARCHIVE_NAMES = [
    "migrate-joinquant-to-qmt/SKILL.md",
    "migrate-joinquant-to-qmt/agents/openai.yaml",
    "migrate-joinquant-to-qmt/references/live-scheduling-and-execution.md",
    "migrate-joinquant-to-qmt/references/mapping-guide.md",
    "migrate-joinquant-to-qmt/references/market-data-and-subscriptions.md",
    "migrate-joinquant-to-qmt/references/migration-report-template.md",
    "migrate-joinquant-to-qmt/references/observability-and-symbols.md",
    "migrate-joinquant-to-qmt/references/official-sources.md",
    "migrate-joinquant-to-qmt/references/parity-checklist.md",
    "migrate-joinquant-to-qmt/references/runtime-compatibility.md",
    "migrate-joinquant-to-qmt/scripts/audit_jq_strategy.py",
    "migrate-joinquant-to-qmt/scripts/check_qmt_strategy.py",
]


class ReleasePackageTests(unittest.TestCase):
    def setUp(self):
        DIST.mkdir(exist_ok=True)
        for path in DIST.iterdir():
            if path.is_file() or path.is_symlink():
                path.unlink()

    def build(self):
        subprocess.run(
            [sys.executable, "scripts/build_release.py", "--tag", "v1.0.0"],
            cwd=str(REPO),
            check=True,
        )

    def test_release_archive_has_safe_reproducible_metadata_and_checksum(self):
        self.build()

        self.assertTrue(ARCHIVE.is_file())
        with zipfile.ZipFile(str(ARCHIVE)) as release_zip:
            entries = release_zip.infolist()
        names = [entry.filename for entry in entries]
        self.assertEqual(names, CANONICAL_ARCHIVE_NAMES)
        self.assertFalse(
            any(name.startswith("/") or ".." in Path(name).parts for name in names)
        )
        self.assertTrue(all(entry.date_time == (1980, 1, 1, 0, 0, 0) for entry in entries))
        for entry in entries:
            expected_mode = 0o755 if entry.filename.endswith(".sh") else 0o644
            self.assertEqual(stat.S_IMODE(entry.external_attr >> 16), expected_mode)

        lines = (DIST / "SHA256SUMS").read_text(encoding="ascii").splitlines()
        expected = hashlib.sha256(ARCHIVE.read_bytes()).hexdigest()
        self.assertEqual(lines, [expected + "  " + ARCHIVE.name])

    def test_build_is_byte_for_byte_deterministic(self):
        self.build()
        first = ARCHIVE.read_bytes()

        self.build()
        second = ARCHIVE.read_bytes()

        self.assertEqual(first, second)

    def test_generated_debris_is_excluded_from_the_archive(self):
        pycache = SKILL / "scripts" / "__pycache__"
        pycache_existed = pycache.exists()
        debris = [
            SKILL / ".DS_Store",
            SKILL / ".jq2qmt-install",
            pycache / "release_test.cpython-313.pyc",
        ]
        created = []
        try:
            for path in debris:
                path.parent.mkdir(parents=True, exist_ok=True)
                if not path.exists():
                    path.write_bytes(b"generated debris")
                    created.append(path)

            self.build()
            with zipfile.ZipFile(str(ARCHIVE)) as release_zip:
                names = release_zip.namelist()
        finally:
            for path in created:
                path.unlink()
            if not pycache_existed and pycache.is_dir():
                pycache.rmdir()

        self.assertEqual(names, CANONICAL_ARCHIVE_NAMES)

    def test_malformed_release_tag_is_rejected_without_artifacts(self):
        result = subprocess.run(
            [sys.executable, "scripts/build_release.py", "--tag", "latest"],
            cwd=str(REPO),
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("vMAJOR.MINOR.PATCH", result.stderr)
        self.assertEqual(list(DIST.iterdir()), [])

    @unittest.skipUnless(hasattr(os, "symlink"), "symlinks are unavailable")
    def test_symlink_in_skill_tree_is_rejected_without_artifacts(self):
        link = SKILL / "release-test-symlink"
        try:
            link.symlink_to("SKILL.md")
            result = subprocess.run(
                [sys.executable, "scripts/build_release.py", "--tag", "v1.0.0"],
                cwd=str(REPO),
                capture_output=True,
                text=True,
            )
        finally:
            if link.is_symlink():
                link.unlink()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symbolic link", result.stderr)
        self.assertEqual(list(DIST.iterdir()), [])

    def test_unexpected_root_file_is_rejected_without_artifacts(self):
        unexpected = SKILL / "release-test-secret.txt"
        try:
            unexpected.write_text("must not ship\n", encoding="utf-8")
            result = subprocess.run(
                [sys.executable, "scripts/build_release.py", "--tag", "v1.0.0"],
                cwd=str(REPO),
                capture_output=True,
                text=True,
            )
        finally:
            if unexpected.exists():
                unexpected.unlink()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected file", result.stderr)
        self.assertEqual(list(DIST.iterdir()), [])

if __name__ == "__main__":
    unittest.main()
