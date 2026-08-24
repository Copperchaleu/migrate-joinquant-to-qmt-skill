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
        expected_names = sorted(
            "migrate-joinquant-to-qmt/" + path.relative_to(SKILL).as_posix()
            for path in SKILL.rglob("*")
            if path.is_file()
        )
        self.assertEqual(names, expected_names)
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

if __name__ == "__main__":
    unittest.main()
