#!/usr/bin/env python3
"""Build the canonical skill as a reproducible release archive."""

import argparse
import hashlib
import re
import stat
import sys
import zipfile
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SKILL_NAME = "migrate-joinquant-to-qmt"
SKILL_DIR = REPO / "skill" / SKILL_NAME
DIST_DIR = REPO / "dist"
FIXED_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
TAG_PATTERN = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
GENERATED_NAMES = {".DS_Store", ".jq2qmt-install"}
GENERATED_SUFFIXES = {".pyc", ".pyo"}


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    if not TAG_PATTERN.fullmatch(args.tag):
        parser.error("--tag must match vMAJOR.MINOR.PATCH")
    return args


def source_files():
    files = []
    for path in SKILL_DIR.rglob("*"):
        if path.is_symlink():
            raise ValueError("skill tree contains a symbolic link: " + str(path))
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError("skill tree contains a non-regular file: " + str(path))
        relative = path.relative_to(SKILL_DIR)
        if (
            "__pycache__" in relative.parts
            or relative.name in GENERATED_NAMES
            or relative.suffix in GENERATED_SUFFIXES
        ):
            continue
        if not is_canonical_file(relative):
            raise ValueError("skill tree contains an unexpected file: " + str(path))
        files.append(path)
    return sorted(files, key=lambda path: path.relative_to(SKILL_DIR).as_posix())


def is_canonical_file(relative):
    if relative.parts == ("SKILL.md",):
        return True
    if len(relative.parts) != 2:
        return False
    section = relative.parts[0]
    if section == "agents":
        return relative.suffix in {".yaml", ".yml"}
    if section == "references":
        return relative.suffix == ".md"
    if section == "scripts":
        return relative.suffix in {".py", ".sh"}
    return False


def build_release(tag):
    files = source_files()
    DIST_DIR.mkdir(exist_ok=True)
    archive = DIST_DIR / (SKILL_NAME + "-" + tag + ".zip")
    with zipfile.ZipFile(
        str(archive), "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
    ) as release_zip:
        for source in files:
            relative = source.relative_to(SKILL_DIR).as_posix()
            info = zipfile.ZipInfo(SKILL_NAME + "/" + relative, FIXED_TIMESTAMP)
            info.create_system = 3
            mode = 0o755 if source.suffix == ".sh" else 0o644
            info.external_attr = (stat.S_IFREG | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            release_zip.writestr(info, source.read_bytes(), compresslevel=9)

    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    checksum = digest + "  " + archive.name + "\n"
    (DIST_DIR / "SHA256SUMS").write_bytes(checksum.encode("ascii"))


def main():
    args = parse_args()
    try:
        build_release(args.tag)
    except ValueError as error:
        print("Error: " + str(error), file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
