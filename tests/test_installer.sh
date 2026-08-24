#!/bin/sh
set -eu

REPO=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
INSTALLER=$REPO/installers/install.sh
PLATFORM_PATHS=$REPO/tests/platform-paths.json
SKILL_NAME=migrate-joinquant-to-qmt
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/jq2qmt-test.XXXXXX")
HTTP_PID=

cleanup_test() {
    cleanup_status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$HTTP_PID" ]; then
        kill "$HTTP_PID" 2>/dev/null || true
        wait "$HTTP_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_ROOT"
    exit "$cleanup_status"
}
trap cleanup_test EXIT HUP INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_fails() {
    if "$@"; then
        fail "command unexpectedly succeeded: $*"
    fi
}

make_stub() {
    stub_dir=$1
    stub_name=$2
    mkdir -p "$stub_dir"
    printf '#!/bin/sh\nexit 0\n' >"$stub_dir/$stub_name"
    chmod +x "$stub_dir/$stub_name"
}

count_backups() {
    backup_target=$1
    backup_count=0
    for backup_path in "$backup_target".backup.*; do
        if [ -d "$backup_path" ]; then
            backup_count=$((backup_count + 1))
        fi
    done
    printf '%s\n' "$backup_count"
}

write_checksum() {
    checksum_archive=$1
    checksum_file=$2
    python3 - "$checksum_archive" "$checksum_file" <<'PY'
import hashlib
import pathlib
import sys

archive = pathlib.Path(sys.argv[1])
checksum = pathlib.Path(sys.argv[2])
checksum.write_text(
    hashlib.sha256(archive.read_bytes()).hexdigest() + "  " + archive.name + "\n",
    encoding="ascii",
)
PY
}

SOURCE=$TEST_ROOT/source/$SKILL_NAME
mkdir -p "$TEST_ROOT/source"
cp -R "$REPO/skill/$SKILL_NAME" "$SOURCE"
SOURCE=$(CDPATH= cd -- "$SOURCE" && pwd -P)

# A wrong mapping or omitted marker breaks at least one literal expected target.
MAPPING_HOME=$TEST_ROOT/mapping-home
MAPPING_PROJECT=$TEST_ROOT/mapping-project
mkdir -p "$MAPPING_HOME" "$MAPPING_PROJECT"
path_vectors=$(python3 -c 'import json, sys; [print("\t".join((v["platform"], v["scope"], v["relative"]))) for v in json.load(open(sys.argv[1], encoding="utf-8"))]' "$PLATFORM_PATHS")
tab=$(printf '\t')
while IFS="$tab" read -r platform scope relative; do
    case "$scope" in
        user) expected=$MAPPING_HOME/$relative ;;
        project) expected=$MAPPING_PROJECT/$relative ;;
        *) fail "unknown shared-vector scope: $scope" ;;
    esac
    HOME=$MAPPING_HOME "$INSTALLER" \
        --platform "$platform" --scope "$scope" \
        --project-dir "$MAPPING_PROJECT" --source "$SOURCE"
    test -f "$expected/SKILL.md" || fail "missing SKILL.md for $platform:$scope"
    test -f "$expected/.jq2qmt-install" || fail "missing marker for $platform:$scope"
done <<EOF
$path_vectors
EOF

# Hermes project scope must fail rather than silently installing elsewhere.
HERMES_LOG=$TEST_ROOT/hermes-project.log
set +e
HOME=$MAPPING_HOME "$INSTALLER" --platform hermes --scope project \
    --project-dir "$MAPPING_PROJECT" --source "$SOURCE" >"$HERMES_LOG" 2>&1
hermes_status=$?
set -e
test "$hermes_status" -eq 2 || fail "Hermes project scope returned $hermes_status instead of 2"
grep 'Hermes' "$HERMES_LOG" >/dev/null || fail "Hermes failure was not actionable"
grep -E '用户级|user' "$HERMES_LOG" >/dev/null || fail "Hermes failure omitted user-scope guidance"

# Dry-run must not create even a parent, staging, marker, backup, or temp path.
DRY_ROOT=$TEST_ROOT/dry-run
DRY_HOME=$DRY_ROOT/home
DRY_PROJECT=$DRY_ROOT/project
mkdir -p "$DRY_HOME" "$DRY_PROJECT"
before=$(find "$DRY_ROOT" -print | LC_ALL=C sort)
HOME=$DRY_HOME TMPDIR=$DRY_ROOT "$INSTALLER" --platform codex \
    --project-dir "$DRY_PROJECT" --source "$SOURCE" --dry-run
after=$(find "$DRY_ROOT" -print | LC_ALL=C sort)
test "$before" = "$after" || fail "dry-run wrote to the filesystem"

# Dry-run must succeed without initializing an unusable temp or target context.
LOCKED_DRY_ROOT=$TEST_ROOT/locked-dry-run
LOCKED_DRY_HOME=$LOCKED_DRY_ROOT/home
LOCKED_DRY_PROJECT=$LOCKED_DRY_ROOT/project
MISSING_TMPDIR=$LOCKED_DRY_ROOT/does-not-exist
mkdir -p "$LOCKED_DRY_HOME" "$LOCKED_DRY_PROJECT"
chmod 500 "$LOCKED_DRY_HOME" "$LOCKED_DRY_PROJECT"
HOME=$LOCKED_DRY_HOME TMPDIR=$MISSING_TMPDIR "$INSTALLER" --platform codex \
    --project-dir "$LOCKED_DRY_PROJECT" --source "$SOURCE" --dry-run
chmod 700 "$LOCKED_DRY_HOME" "$LOCKED_DRY_PROJECT"
test ! -e "$MISSING_TMPDIR" || fail "dry-run initialized nonexistent TMPDIR"
test ! -e "$LOCKED_DRY_HOME/.codex" || fail "dry-run wrote under protected HOME"

# A per-file hash failure must abort before any target is created.
HASH_FAIL_BIN=$TEST_ROOT/hash-fail-bin
HASH_FAIL_HOME=$TEST_ROOT/hash-fail-home
HASH_FAIL_PROJECT=$TEST_ROOT/hash-fail-project
mkdir -p "$HASH_FAIL_BIN" "$HASH_FAIL_HOME" "$HASH_FAIL_PROJECT"
if command -v sha256sum >/dev/null 2>&1; then
    REAL_HASH_COMMAND=$(command -v sha256sum)
    REAL_HASH_MODE=sha256sum
else
    REAL_HASH_COMMAND=$(command -v shasum)
    REAL_HASH_MODE=shasum
fi
printf '%s\n' \
    '#!/bin/sh' \
    'if [ "$#" -gt 0 ]; then exit 73; fi' \
    'if [ "$JQ2QMT_REAL_HASH_MODE" = sha256sum ]; then' \
    '    exec "$JQ2QMT_REAL_HASH_COMMAND"' \
    'fi' \
    'exec "$JQ2QMT_REAL_HASH_COMMAND" -a 256' \
    >"$HASH_FAIL_BIN/sha256sum"
chmod +x "$HASH_FAIL_BIN/sha256sum"
if HOME=$HASH_FAIL_HOME PATH="$HASH_FAIL_BIN:/usr/bin:/bin" \
    JQ2QMT_REAL_HASH_COMMAND=$REAL_HASH_COMMAND \
    JQ2QMT_REAL_HASH_MODE=$REAL_HASH_MODE \
    "$INSTALLER" --platform codex --project-dir "$HASH_FAIL_PROJECT" \
    --source "$SOURCE"
then
    fail "installer accepted a partial manifest after per-file hash failure"
fi
test ! -e "$HASH_FAIL_HOME/.codex" || fail "hash failure created an install target"

# Same content is a no-op; changed content is refused; force creates a backup.
LIFE_HOME=$TEST_ROOT/lifecycle-home
LIFE_PROJECT=$TEST_ROOT/lifecycle-project
LIFE_TARGET=$LIFE_HOME/.codex/skills/$SKILL_NAME
mkdir -p "$LIFE_HOME" "$LIFE_PROJECT"
HOME=$LIFE_HOME "$INSTALLER" --platform codex --scope user \
    --project-dir "$LIFE_PROJECT" --source "$SOURCE"
grep '^platform=codex$' "$LIFE_TARGET/.jq2qmt-install" >/dev/null || fail "marker omitted platform"
grep '^scope=user$' "$LIFE_TARGET/.jq2qmt-install" >/dev/null || fail "marker omitted scope"
grep '^version=local$' "$LIFE_TARGET/.jq2qmt-install" >/dev/null || fail "marker omitted local version"
grep "^source=$SOURCE\$" "$LIFE_TARGET/.jq2qmt-install" >/dev/null || fail "marker omitted source"
grep -E '^content_hash=[0-9a-f]{64}$' "$LIFE_TARGET/.jq2qmt-install" >/dev/null || fail "marker omitted SHA-256 content hash"
marker_before=$(cksum "$LIFE_TARGET/.jq2qmt-install")
noop_output=$(HOME=$LIFE_HOME "$INSTALLER" --platform codex --scope user \
    --project-dir "$LIFE_PROJECT" --source "$SOURCE")
marker_after=$(cksum "$LIFE_TARGET/.jq2qmt-install")
test "$marker_before" = "$marker_after" || fail "same-content install rewrote its marker"
test "$(count_backups "$LIFE_TARGET")" -eq 0 || fail "same-content install made a backup"
echo "$noop_output" | grep 'already installed' >/dev/null || fail "same-content no-op was not reported"

printf '\n# lifecycle change\n' >>"$SOURCE/SKILL.md"
installed_before=$(cksum "$LIFE_TARGET/SKILL.md")
assert_fails env HOME="$LIFE_HOME" "$INSTALLER" --platform codex --scope user \
    --project-dir "$LIFE_PROJECT" --source "$SOURCE"
installed_after=$(cksum "$LIFE_TARGET/SKILL.md")
test "$installed_before" = "$installed_after" || fail "refused update changed the target"
test "$(count_backups "$LIFE_TARGET")" -eq 0 || fail "refused update made a backup"

HOME=$LIFE_HOME "$INSTALLER" --platform codex --scope user \
    --project-dir "$LIFE_PROJECT" --source "$SOURCE" --force
test "$(count_backups "$LIFE_TARGET")" -eq 1 || fail "forced update did not make one backup"
grep '# lifecycle change' "$LIFE_TARGET/SKILL.md" >/dev/null || fail "forced update did not install new content"
backup_dir=
for backup_path in "$LIFE_TARGET".backup.*; do
    if [ -d "$backup_path" ]; then
        backup_dir=$backup_path
    fi
done
test -n "$backup_dir" || fail "forced update backup was not found"
if grep '# lifecycle change' "$backup_dir/SKILL.md" >/dev/null; then
    fail "forced update backup does not preserve old content"
fi

# Noninteractive uninstall needs --yes and unmanaged directories are protected.
assert_fails env HOME="$LIFE_HOME" "$INSTALLER" --platform codex --scope user \
    --project-dir "$LIFE_PROJECT" --uninstall </dev/null
test -d "$LIFE_TARGET" || fail "unconfirmed uninstall removed target"
HOME=$LIFE_HOME "$INSTALLER" --platform codex --scope user \
    --project-dir "$LIFE_PROJECT" --uninstall --yes
test ! -e "$LIFE_TARGET" || fail "confirmed uninstall left target behind"

HOME=$LIFE_HOME "$INSTALLER" --platform codex --scope user \
    --project-dir "$LIFE_PROJECT" --source "$SOURCE"
rm "$LIFE_TARGET/.jq2qmt-install"
assert_fails env HOME="$LIFE_HOME" "$INSTALLER" --platform codex --scope user \
    --project-dir "$LIFE_PROJECT" --uninstall --yes
test -d "$LIFE_TARGET" || fail "unmanaged target was removed"
HOME=$LIFE_HOME "$INSTALLER" --platform codex --scope user \
    --project-dir "$LIFE_PROJECT" --uninstall --yes --force
test ! -e "$LIFE_TARGET" || fail "forced uninstall left exact unmarked target behind"

# Missing required payload files and a wrong frontmatter name must be rejected.
INVALID_SOURCE=$TEST_ROOT/invalid-source
cp -R "$SOURCE" "$INVALID_SOURCE"
rm "$INVALID_SOURCE/references/official-sources.md"
INVALID_HOME=$TEST_ROOT/invalid-home
mkdir -p "$INVALID_HOME"
assert_fails env HOME="$INVALID_HOME" "$INSTALLER" --platform codex --source "$INVALID_SOURCE"
test ! -d "$INVALID_HOME/.codex" || fail "invalid source created a target parent"

WRONG_NAME_SOURCE=$TEST_ROOT/wrong-name-source
cp -R "$SOURCE" "$WRONG_NAME_SOURCE"
sed 's/^name: migrate-joinquant-to-qmt$/name: wrong-skill/' \
    "$WRONG_NAME_SOURCE/SKILL.md" >"$WRONG_NAME_SOURCE/SKILL.md.new"
mv "$WRONG_NAME_SOURCE/SKILL.md.new" "$WRONG_NAME_SOURCE/SKILL.md"
assert_fails env HOME="$INVALID_HOME" "$INSTALLER" --platform codex --source "$WRONG_NAME_SOURCE"
test ! -d "$INVALID_HOME/.codex" || fail "wrong-name source created a target parent"

# Auto-detection succeeds for exactly one real stub and chooses only that platform.
SYSTEM_PATH=/usr/bin:/bin
DETECT_ROOT=$TEST_ROOT/detect
ZERO_BIN=$DETECT_ROOT/zero-bin
ONE_BIN=$DETECT_ROOT/one-bin
TWO_BIN=$DETECT_ROOT/two-bin
mkdir -p "$ZERO_BIN" "$ONE_BIN" "$TWO_BIN"
ZERO_HOME=$DETECT_ROOT/zero-home
ONE_HOME=$DETECT_ROOT/one-home
TWO_HOME=$DETECT_ROOT/two-home
mkdir -p "$ZERO_HOME" "$ONE_HOME" "$TWO_HOME"
assert_fails env HOME="$ZERO_HOME" PATH="$ZERO_BIN:$SYSTEM_PATH" \
    "$INSTALLER" --source "$SOURCE"
make_stub "$ONE_BIN" openclaw
HOME=$ONE_HOME PATH="$ONE_BIN:$SYSTEM_PATH" "$INSTALLER" --source "$SOURCE"
test -f "$ONE_HOME/.openclaw/skills/$SKILL_NAME/SKILL.md" || fail "single detected platform was not installed"
test ! -e "$ONE_HOME/.codex" || fail "auto-detection selected an uninstalled platform"
make_stub "$TWO_BIN" codex
make_stub "$TWO_BIN" claude
assert_fails env HOME="$TWO_HOME" PATH="$TWO_BIN:$SYSTEM_PATH" \
    "$INSTALLER" --source "$SOURCE"
test ! -e "$TWO_HOME/.codex" || fail "ambiguous detection installed Codex"
test ! -e "$TWO_HOME/.claude" || fail "ambiguous detection installed Claude"

# --platform all installs every detected user target in fixed platform order.
ALL_BIN=$TEST_ROOT/all-bin
ALL_HOME=$TEST_ROOT/all-home
ALL_PROJECT=$TEST_ROOT/all-project
mkdir -p "$ALL_HOME" "$ALL_PROJECT"
for platform in codex claude opencode openclaw hermes; do
    make_stub "$ALL_BIN" "$platform"
done
HOME=$ALL_HOME PATH="$ALL_BIN:$SYSTEM_PATH" "$INSTALLER" \
    --platform all --scope user --project-dir "$ALL_PROJECT" --source "$SOURCE"
for expected in \
    "$ALL_HOME/.codex/skills/$SKILL_NAME" \
    "$ALL_HOME/.claude/skills/$SKILL_NAME" \
    "$ALL_HOME/.config/opencode/skills/$SKILL_NAME" \
    "$ALL_HOME/.openclaw/skills/$SKILL_NAME" \
    "$ALL_HOME/.hermes/skills/$SKILL_NAME"
do
    test -f "$expected/.jq2qmt-install" || fail "all:user missed $expected"
done

# Project-wide all skips only Hermes and reports that unsupported scope.
ALL_PROJECT_HOME=$TEST_ROOT/all-project-home
ALL_PROJECT_ROOT=$TEST_ROOT/all-project-root
ALL_PROJECT_LOG=$TEST_ROOT/all-project.log
mkdir -p "$ALL_PROJECT_HOME" "$ALL_PROJECT_ROOT"
HOME=$ALL_PROJECT_HOME PATH="$ALL_BIN:$SYSTEM_PATH" "$INSTALLER" \
    --platform all --scope project --project-dir "$ALL_PROJECT_ROOT" \
    --source "$SOURCE" >"$ALL_PROJECT_LOG" 2>&1
for expected in \
    "$ALL_PROJECT_ROOT/.agents/skills/$SKILL_NAME" \
    "$ALL_PROJECT_ROOT/.claude/skills/$SKILL_NAME" \
    "$ALL_PROJECT_ROOT/.opencode/skills/$SKILL_NAME" \
    "$ALL_PROJECT_ROOT/skills/$SKILL_NAME"
do
    test -f "$expected/.jq2qmt-install" || fail "all:project missed $expected"
done
test ! -e "$ALL_PROJECT_HOME/.hermes" || fail "all:project silently used Hermes user scope"
grep 'Hermes' "$ALL_PROJECT_LOG" >/dev/null || fail "all:project did not report Hermes unsupported"

# Versioned remote installs use real release bytes served over loopback HTTP.
python3 "$REPO/scripts/build_release.py" --tag v1.0.0
ARCHIVE_NAME=$SKILL_NAME-v1.0.0.zip
SERVER_ROOT=$TEST_ROOT/server
RELEASE_DIR=$SERVER_ROOT/releases/download/v1.0.0
mkdir -p "$RELEASE_DIR"
cp "$REPO/dist/$ARCHIVE_NAME" "$RELEASE_DIR/$ARCHIVE_NAME"
cp "$REPO/dist/SHA256SUMS" "$RELEASE_DIR/SHA256SUMS"
cp "$RELEASE_DIR/$ARCHIVE_NAME" "$TEST_ROOT/original-release.zip"

HTTP_PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
python3 "$REPO/tests/fixtures/release_server.py" --port "$HTTP_PORT" \
    --directory "$SERVER_ROOT" --tag v1.0.0 >"$TEST_ROOT/http.log" 2>&1 &
HTTP_PID=$!
RELEASE_ROOT=http://127.0.0.1:$HTTP_PORT/releases/download
attempt=0
until curl -fsS "$RELEASE_ROOT/v1.0.0/SHA256SUMS" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 50 ]; then
        fail "loopback release server did not become ready"
    fi
    sleep 0.1
done

REMOTE_HOME=$TEST_ROOT/remote-home
mkdir -p "$REMOTE_HOME"
HOME=$REMOTE_HOME JQ2QMT_RELEASE_ROOT=$RELEASE_ROOT "$INSTALLER" \
    --platform codex --version v1.0.0
REMOTE_TARGET=$REMOTE_HOME/.codex/skills/$SKILL_NAME
test -f "$REMOTE_TARGET/SKILL.md" || fail "fixed-version remote install missed SKILL.md"
grep '^version=v1.0.0$' "$REMOTE_TARGET/.jq2qmt-install" >/dev/null || \
    fail "fixed-version remote install marker omitted immutable tag"

# A corrupt asset must fail checksum verification before creating a target root.
printf 'corrupt release bytes\n' >>"$RELEASE_DIR/$ARCHIVE_NAME"
CORRUPT_HOME=$TEST_ROOT/corrupt-home
mkdir -p "$CORRUPT_HOME"
assert_fails env HOME="$CORRUPT_HOME" JQ2QMT_RELEASE_ROOT="$RELEASE_ROOT" \
    "$INSTALLER" --platform codex --version v1.0.0
test ! -e "$CORRUPT_HOME/.codex" || fail "checksum failure created a target root"

# A checksum-valid archive with a traversal entry is still unsafe.
python3 - "$RELEASE_DIR/$ARCHIVE_NAME" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("migrate-joinquant-to-qmt/../escape", "unsafe")
PY
write_checksum "$RELEASE_DIR/$ARCHIVE_NAME" "$RELEASE_DIR/SHA256SUMS"
UNSAFE_PATH_HOME=$TEST_ROOT/unsafe-path-home
mkdir -p "$UNSAFE_PATH_HOME"
assert_fails env HOME="$UNSAFE_PATH_HOME" JQ2QMT_RELEASE_ROOT="$RELEASE_ROOT" \
    "$INSTALLER" --platform codex --version v1.0.0
test ! -e "$UNSAFE_PATH_HOME/.codex" || fail "unsafe archive path created a target root"

# Absolute ZIP paths are independently rejected before extraction or target writes.
python3 - "$RELEASE_DIR/$ARCHIVE_NAME" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("/absolute-escape", "unsafe")
PY
write_checksum "$RELEASE_DIR/$ARCHIVE_NAME" "$RELEASE_DIR/SHA256SUMS"
ABSOLUTE_PATH_HOME=$TEST_ROOT/absolute-path-home
mkdir -p "$ABSOLUTE_PATH_HOME"
assert_fails env HOME="$ABSOLUTE_PATH_HOME" JQ2QMT_RELEASE_ROOT="$RELEASE_ROOT" \
    "$INSTALLER" --platform codex --version v1.0.0
test ! -e "$ABSOLUTE_PATH_HOME/.codex" || fail "absolute archive path created a target root"

# An otherwise valid release with a second top-level root is rejected.
cp "$TEST_ROOT/original-release.zip" "$RELEASE_DIR/$ARCHIVE_NAME"
python3 - "$RELEASE_DIR/$ARCHIVE_NAME" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "a") as archive:
    archive.writestr("unexpected-root/secret.txt", "must not extract")
PY
write_checksum "$RELEASE_DIR/$ARCHIVE_NAME" "$RELEASE_DIR/SHA256SUMS"
UNEXPECTED_ROOT_HOME=$TEST_ROOT/unexpected-root-home
mkdir -p "$UNEXPECTED_ROOT_HOME"
assert_fails env HOME="$UNEXPECTED_ROOT_HOME" JQ2QMT_RELEASE_ROOT="$RELEASE_ROOT" \
    "$INSTALLER" --platform codex --version v1.0.0
test ! -e "$UNEXPECTED_ROOT_HOME/.codex" || fail "unexpected archive root created a target root"

# A checksum-valid ZIP symlink is rejected before extraction or target writes.
python3 - "$RELEASE_DIR/$ARCHIVE_NAME" <<'PY'
import stat
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    link = zipfile.ZipInfo("migrate-joinquant-to-qmt/link")
    link.create_system = 3
    link.external_attr = (stat.S_IFLNK | 0o777) << 16
    archive.writestr(link, "../../outside")
PY
write_checksum "$RELEASE_DIR/$ARCHIVE_NAME" "$RELEASE_DIR/SHA256SUMS"
UNSAFE_LINK_HOME=$TEST_ROOT/unsafe-link-home
mkdir -p "$UNSAFE_LINK_HOME"
assert_fails env HOME="$UNSAFE_LINK_HOME" JQ2QMT_RELEASE_ROOT="$RELEASE_ROOT" \
    "$INSTALLER" --platform codex --version v1.0.0
test ! -e "$UNSAFE_LINK_HOME/.codex" || fail "ZIP symlink created a target root"

# Latest follows a real redirect, then pins the final SemVer segment for download.
cp "$TEST_ROOT/original-release.zip" "$RELEASE_DIR/$ARCHIVE_NAME"
write_checksum "$RELEASE_DIR/$ARCHIVE_NAME" "$RELEASE_DIR/SHA256SUMS"
LATEST_HOME=$TEST_ROOT/latest-home
mkdir -p "$LATEST_HOME"
HOME=$LATEST_HOME JQ2QMT_RELEASE_ROOT=$RELEASE_ROOT \
    JQ2QMT_LATEST_URL=http://127.0.0.1:$HTTP_PORT/releases/latest \
    "$INSTALLER" --platform codex
LATEST_TARGET=$LATEST_HOME/.codex/skills/$SKILL_NAME
test -f "$LATEST_TARGET/SKILL.md" || fail "latest redirect install missed SKILL.md"
grep '^version=v1.0.0$' "$LATEST_TARGET/.jq2qmt-install" >/dev/null || \
    fail "latest redirect did not resolve to an immutable tag"
grep '"GET /releases/latest HTTP/1.1" 302 ' "$TEST_ROOT/http.log" >/dev/null || \
    fail "latest endpoint did not emit an HTTP redirect"

vector_count=$(printf '%s\n' "$path_vectors" | awk 'NF { count += 1 } END { print count + 0 }')
echo "POSIX installer tests passed (shared path vectors: $vector_count)"
