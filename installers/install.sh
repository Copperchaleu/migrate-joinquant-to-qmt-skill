#!/bin/sh
set -eu

SKILL_NAME=migrate-joinquant-to-qmt
REPOSITORY=Copperchaleu/migrate-joinquant-to-qmt-skill
RELEASE_ROOT=${JQ2QMT_RELEASE_ROOT:-https://github.com/$REPOSITORY/releases/download}
LATEST_URL=${JQ2QMT_LATEST_URL:-https://github.com/$REPOSITORY/releases/latest}
PLATFORM=
SCOPE=user
PROJECT_DIR=$(pwd)
SOURCE_DIR=
VERSION=
FORCE=0
DRY_RUN=0
UNINSTALL=0
ASSUME_YES=0

TARGET=
TARGET_ROOT=
TEMP_DIR=
TEMP_PARENT=
STAGE_DIR=
SOURCE_DESCRIPTION=

umask 077

usage_error() {
    echo "Error: $*" >&2
    echo "Usage: install.sh [--platform codex|claude|opencode|openclaw|hermes|all] [--scope user|project] [--project-dir PATH] [--source PATH] [--version TAG] [--force] [--dry-run] [--uninstall] [--yes]" >&2
    exit 64
}

require_value() {
    option=$1
    count=$2
    [ "$count" -ge 2 ] || usage_error "$option requires a value"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --platform)
            require_value "$1" "$#"
            PLATFORM=$2
            shift 2
            ;;
        --scope)
            require_value "$1" "$#"
            SCOPE=$2
            shift 2
            ;;
        --project-dir)
            require_value "$1" "$#"
            PROJECT_DIR=$2
            shift 2
            ;;
        --source)
            require_value "$1" "$#"
            SOURCE_DIR=$2
            shift 2
            ;;
        --version)
            require_value "$1" "$#"
            VERSION=$2
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --uninstall)
            UNINSTALL=1
            shift
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        *)
            usage_error "unknown option: $1"
            ;;
    esac
done

case "$SCOPE" in
    user|project) ;;
    *) usage_error "unsupported scope: $SCOPE" ;;
esac

case "$PLATFORM" in
    ''|codex|claude|opencode|openclaw|hermes|all) ;;
    *) usage_error "unsupported platform: $PLATFORM" ;;
esac

if ! PROJECT_DIR=$(CDPATH= cd -- "$PROJECT_DIR" 2>/dev/null && pwd -P); then
    usage_error "project directory does not exist: $PROJECT_DIR"
fi

cleanup() {
    exit_status=$?
    trap - EXIT HUP INT TERM

    if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
        stage_parent=${STAGE_DIR%/*}
        stage_name=${STAGE_DIR##*/}
        case "$stage_name" in
            .jq2qmt.*)
                if [ "$stage_parent" = "$TARGET_ROOT" ]; then
                    rm -rf "$STAGE_DIR"
                else
                    echo "Warning: refused to remove unexpected staging path: $STAGE_DIR" >&2
                fi
                ;;
            *)
                echo "Warning: refused to remove unexpected staging path: $STAGE_DIR" >&2
                ;;
        esac
    fi

    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        temp_parent=${TEMP_DIR%/*}
        temp_name=${TEMP_DIR##*/}
        case "$temp_name" in
            jq2qmt.*)
                if [ "$temp_parent" = "$TEMP_PARENT" ]; then
                    rm -rf "$TEMP_DIR"
                else
                    echo "Warning: refused to remove unexpected temporary path: $TEMP_DIR" >&2
                fi
                ;;
            *)
                echo "Warning: refused to remove unexpected temporary path: $TEMP_DIR" >&2
                ;;
        esac
    fi

    exit "$exit_status"
}
trap cleanup EXIT HUP INT TERM

prepare_temp() {
    [ -n "$TEMP_DIR" ] && return 0
    requested_temp_parent=${TMPDIR:-/tmp}
    if ! TEMP_PARENT=$(CDPATH= cd -- "$requested_temp_parent" 2>/dev/null && pwd -P); then
        echo "Error: temporary directory does not exist: $requested_temp_parent" >&2
        return 1
    fi
    if ! TEMP_DIR=$(mktemp -d "$TEMP_PARENT/jq2qmt.XXXXXX"); then
        echo "Error: could not create private temporary directory" >&2
        return 1
    fi
    TEMP_DIR=$(CDPATH= cd -- "$TEMP_DIR" && pwd -P)
}

validate_skill() {
    source_path=$1
    for required in \
        SKILL.md \
        scripts/audit_jq_strategy.py \
        scripts/check_qmt_strategy.py \
        references/official-sources.md
    do
        if [ ! -f "$source_path/$required" ]; then
            echo "Error: invalid skill source; missing $required" >&2
            return 1
        fi
    done

    if ! awk '
        NR == 1 {
            if ($0 != "---") exit 1
            next
        }
        $0 == "---" {
            closed = 1
            exit
        }
        $0 == "name: migrate-joinquant-to-qmt" {
            found = 1
        }
        END {
            if (!closed || !found) exit 1
        }
    ' "$source_path/SKILL.md"; then
        echo "Error: SKILL.md frontmatter must contain exact name: $SKILL_NAME" >&2
        return 1
    fi
}

is_release_tag() {
    candidate_tag=$1
    [ "$(printf '%s\n' "$candidate_tag" | awk '
        NR == 1 && $0 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ { valid = 1; next }
        { valid = 0 }
        END { if (valid && NR == 1) print "yes" }
    ')" = yes ]
}

resolve_release_tag() {
    if [ -n "$VERSION" ]; then
        if ! is_release_tag "$VERSION"; then
            usage_error "--version must match vMAJOR.MINOR.PATCH"
        fi
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: curl is required for remote installation" >&2
        return 1
    fi
    if ! effective_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$LATEST_URL"); then
        echo "Error: could not resolve latest release" >&2
        return 1
    fi
    while [ "${effective_url%/}" != "$effective_url" ]; do
        effective_url=${effective_url%/}
    done
    resolved_tag=${effective_url##*/}
    if ! is_release_tag "$resolved_tag"; then
        echo "Error: latest release did not resolve to a SemVer tag" >&2
        return 1
    fi
    VERSION=$resolved_tag
}

download_release_file() {
    remote_url=$1
    destination=$2
    if ! curl -fsSL -o "$destination" "$remote_url"; then
        echo "Error: could not download release asset: $remote_url" >&2
        return 1
    fi
}

validate_archive_entries() {
    archive_path=$1
    if ! command -v unzip >/dev/null 2>&1; then
        echo "Error: unzip is required for remote installation" >&2
        return 1
    fi
    if ! archive_entries=$(unzip -Z1 "$archive_path"); then
        echo "Error: could not list release archive" >&2
        return 1
    fi
    if [ -z "$archive_entries" ]; then
        echo "Error: release archive is empty" >&2
        return 1
    fi
    while IFS= read -r archive_entry; do
        case "$archive_entry" in
            /*|../*|*/../*|*/..)
                echo "Error: release archive contains an unsafe path: $archive_entry" >&2
                return 1
                ;;
            "$SKILL_NAME"/*) ;;
            *)
                echo "Error: release archive contains an unexpected root: $archive_entry" >&2
                return 1
                ;;
        esac
    done <<EOF
$archive_entries
EOF

    if ! archive_listing=$(unzip -Z -l "$archive_path"); then
        echo "Error: could not inspect release archive entry types" >&2
        return 1
    fi
    if printf '%s\n' "$archive_listing" | awk '
        substr($1, 1, 1) == "l" { found = 1 }
        END { exit(found ? 0 : 1) }
    '; then
        echo "Error: release archive contains a symbolic link" >&2
        return 1
    fi
}

prepare_remote_source() {
    resolve_release_tag
    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: curl is required for remote installation" >&2
        return 1
    fi
    prepare_temp

    archive_name=$SKILL_NAME-$VERSION.zip
    archive_url=$RELEASE_ROOT/$VERSION/$archive_name
    checksum_url=$RELEASE_ROOT/$VERSION/SHA256SUMS
    archive_path=$TEMP_DIR/$archive_name
    checksum_path=$TEMP_DIR/SHA256SUMS
    download_release_file "$archive_url" "$archive_path"
    download_release_file "$checksum_url" "$checksum_path"

    if ! expected_hash=$(awk -v archive_name="$archive_name" '
        NF == 2 && $2 == archive_name && length($1) == 64 &&
            $1 !~ /[^0123456789abcdefABCDEF]/ {
                count += 1
                digest = tolower($1)
            }
        END {
            if (count != 1) exit 1
            print digest
        }
    ' "$checksum_path"); then
        echo "Error: SHA256SUMS does not contain exactly one valid checksum for $archive_name" >&2
        return 1
    fi
    if ! actual_hash=$(hash_file "$archive_path"); then
        echo "Error: could not hash downloaded release archive" >&2
        return 1
    fi
    actual_hash=$(printf '%s\n' "$actual_hash" | tr 'ABCDEF' 'abcdef')
    if [ "$actual_hash" != "$expected_hash" ]; then
        echo "Error: release archive checksum mismatch" >&2
        return 1
    fi

    validate_archive_entries "$archive_path"
    extract_root=$TEMP_DIR/extracted
    mkdir "$extract_root"
    if ! unzip -q "$archive_path" -d "$extract_root"; then
        echo "Error: could not extract release archive" >&2
        return 1
    fi
    SOURCE_DIR=$extract_root/$SKILL_NAME
    SOURCE_DESCRIPTION=$archive_url
    validate_skill "$SOURCE_DIR"
}

hash_file() {
    file_path=$1
    if command -v sha256sum >/dev/null 2>&1; then
        if ! hash_output=$(sha256sum "$file_path"); then
            echo "Error: failed to hash file: $file_path" >&2
            return 1
        fi
    elif command -v shasum >/dev/null 2>&1; then
        if ! hash_output=$(shasum -a 256 "$file_path"); then
            echo "Error: failed to hash file: $file_path" >&2
            return 1
        fi
    else
        echo "Error: sha256sum or shasum is required" >&2
        return 1
    fi
    file_hash=${hash_output%% *}
    case "$file_hash" in
        ''|*[!0123456789abcdefABCDEF]*)
            echo "Error: hash command returned an invalid digest for: $file_path" >&2
            return 1
            ;;
    esac
    if [ "${#file_hash}" -ne 64 ]; then
        echo "Error: hash command returned an invalid digest for: $file_path" >&2
        return 1
    fi
    printf '%s\n' "$file_hash"
}

hash_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        if ! hash_output=$(sha256sum); then
            echo "Error: failed to hash tree manifest" >&2
            return 1
        fi
    elif command -v shasum >/dev/null 2>&1; then
        if ! hash_output=$(shasum -a 256); then
            echo "Error: failed to hash tree manifest" >&2
            return 1
        fi
    else
        echo "Error: sha256sum or shasum is required" >&2
        return 1
    fi
    manifest_hash=${hash_output%% *}
    case "$manifest_hash" in
        ''|*[!0123456789abcdefABCDEF]*)
            echo "Error: hash command returned an invalid tree digest" >&2
            return 1
            ;;
    esac
    if [ "${#manifest_hash}" -ne 64 ]; then
        echo "Error: hash command returned an invalid tree digest" >&2
        return 1
    fi
    printf '%s\n' "$manifest_hash"
}

hash_tree() {
    tree_path=$1
    if ! unsorted_paths=$(
        CDPATH= cd -- "$tree_path" || exit 1
        find . -type f ! -name .jq2qmt-install -print
    ); then
        echo "Error: failed to enumerate skill tree: $tree_path" >&2
        return 1
    fi
    if [ -n "$unsorted_paths" ]; then
        if ! sorted_paths=$(printf '%s\n' "$unsorted_paths" | LC_ALL=C sort); then
            echo "Error: failed to sort skill tree manifest" >&2
            return 1
        fi
    else
        sorted_paths=
    fi
    if ! manifest=$(
        CDPATH= cd -- "$tree_path" || exit 1
        if [ -n "$sorted_paths" ]; then
            while IFS= read -r relative_path; do
                if ! file_hash=$(hash_file "$relative_path"); then
                    exit 1
                fi
                printf '%s  %s\n' "$file_hash" "$relative_path"
            done <<EOF
$sorted_paths
EOF
        fi
    ); then
        echo "Error: failed to build complete skill tree manifest" >&2
        return 1
    fi
    if [ -n "$manifest" ]; then
        printf '%s\n' "$manifest" | hash_stdin
    else
        printf '%s' "$manifest" | hash_stdin
    fi
}

resolve_target() {
    selected_platform=$1

    if [ "$SCOPE" = user ]; then
        case ${HOME-} in
            /*) ;;
            '')
                echo "Error: HOME is required for user-scope installation" >&2
                return 1
                ;;
            *)
                echo "Error: HOME must be an absolute path" >&2
                return 1
                ;;
        esac
        case "$selected_platform" in
            codex) TARGET_ROOT=$HOME/.codex/skills ;;
            claude) TARGET_ROOT=$HOME/.claude/skills ;;
            opencode) TARGET_ROOT=$HOME/.config/opencode/skills ;;
            openclaw) TARGET_ROOT=$HOME/.openclaw/skills ;;
            hermes) TARGET_ROOT=$HOME/.hermes/skills ;;
            *)
                echo "Error: unsupported platform: $selected_platform" >&2
                return 1
                ;;
        esac
    else
        case "$selected_platform" in
            codex) TARGET_ROOT=$PROJECT_DIR/.agents/skills ;;
            claude) TARGET_ROOT=$PROJECT_DIR/.claude/skills ;;
            opencode) TARGET_ROOT=$PROJECT_DIR/.opencode/skills ;;
            openclaw) TARGET_ROOT=$PROJECT_DIR/skills ;;
            hermes)
                echo "错误：Hermes Agent 不支持项目级安装；请使用 --scope user。 Error: Hermes Agent project scope is unsupported; use --scope user." >&2
                return 2
                ;;
            *)
                echo "Error: unsupported platform: $selected_platform" >&2
                return 1
                ;;
        esac
    fi

    TARGET=$TARGET_ROOT/$SKILL_NAME
}

validate_exact_target() {
    target_path=$1
    target_parent=${target_path%/*}
    target_name=${target_path##*/}

    if [ "$target_name" != "$SKILL_NAME" ] || [ "$target_parent" != "$TARGET_ROOT" ]; then
        echo "Error: refusing unsafe target path: $target_path" >&2
        return 1
    fi

    if [ -d "$TARGET_ROOT" ]; then
        resolved_root=$(CDPATH= cd -- "$TARGET_ROOT" && pwd -P)
        resolved_parent=$(CDPATH= cd -- "$target_parent" && pwd -P)
        if [ "$resolved_parent" != "$resolved_root" ]; then
            echo "Error: target parent does not match the selected platform root" >&2
            return 1
        fi
    fi
}

install_local() {
    source_path=$1
    target_path=$2
    if ! source_hash=$(hash_tree "$source_path"); then
        echo "Error: could not hash source skill tree" >&2
        return 1
    fi
    target_exists=0
    planned_action=install

    if [ -L "$target_path" ]; then
        echo "Error: refusing symbolic-link target: $target_path" >&2
        return 1
    fi
    if [ -d "$target_path" ]; then
        target_exists=1
        if ! target_hash=$(hash_tree "$target_path"); then
            echo "Error: could not hash installed skill tree" >&2
            return 1
        fi
        if [ "$source_hash" = "$target_hash" ]; then
            echo "already installed: platform=$PLATFORM scope=$SCOPE target=$target_path hash=$source_hash"
            return 0
        fi
        if [ "$FORCE" -ne 1 ]; then
            echo "Error: target has different content; rerun with --force to create a backup: $target_path" >&2
            return 1
        fi
        planned_action=backup-and-replace
    elif [ -e "$target_path" ]; then
        echo "Error: target exists and is not a directory: $target_path" >&2
        return 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "dry-run: source=$source_path version=${VERSION:-local} platform=$PLATFORM scope=$SCOPE target=$target_path action=$planned_action hash=$source_hash"
        return 0
    fi

    validate_exact_target "$target_path"
    prepare_temp
    mkdir -p "$TARGET_ROOT"
    validate_exact_target "$target_path"

    STAGE_DIR=$(mktemp -d "$TARGET_ROOT/.jq2qmt.XXXXXX")
    if ! cp -R "$source_path"/. "$STAGE_DIR"/; then
        echo "Error: failed to stage skill content" >&2
        return 1
    fi
    {
        printf 'platform=%s\n' "$PLATFORM"
        printf 'scope=%s\n' "$SCOPE"
        printf 'version=%s\n' "${VERSION:-local}"
        printf 'source=%s\n' "${SOURCE_DESCRIPTION:-$source_path}"
        printf 'content_hash=%s\n' "$source_hash"
    } >"$STAGE_DIR/.jq2qmt-install"

    if [ "$target_exists" -eq 1 ]; then
        if [ ! -d "$target_path" ] || [ -L "$target_path" ]; then
            echo "Error: target changed while the update was being staged" >&2
            return 1
        fi
        backup_path=$target_path.backup.$(date -u +%Y%m%dT%H%M%SZ)
        if [ -e "$backup_path" ] || [ -L "$backup_path" ]; then
            echo "Error: backup path already exists: $backup_path" >&2
            return 1
        fi
        mv "$target_path" "$backup_path"
        if ! mv "$STAGE_DIR" "$target_path"; then
            echo "Error: failed to activate staged skill; restoring backup" >&2
            if ! mv "$backup_path" "$target_path"; then
                echo "Error: automatic backup restoration also failed: $backup_path" >&2
            fi
            return 1
        fi
        STAGE_DIR=
        echo "installed: platform=$PLATFORM scope=$SCOPE target=$target_path hash=$source_hash backup=$backup_path"
    else
        if [ -e "$target_path" ] || [ -L "$target_path" ]; then
            echo "Error: target appeared while the install was being staged" >&2
            return 1
        fi
        if ! mv "$STAGE_DIR" "$target_path"; then
            echo "Error: failed to activate staged skill" >&2
            return 1
        fi
        STAGE_DIR=
        echo "installed: platform=$PLATFORM scope=$SCOPE target=$target_path hash=$source_hash"
    fi
}

confirm_uninstall() {
    if [ "$ASSUME_YES" -eq 1 ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        echo "Error: noninteractive uninstall requires --yes" >&2
        return 1
    fi
    printf 'Uninstall %s? [y/N] ' "$TARGET" >&2
    read -r answer || answer=
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *)
            echo "Uninstall cancelled" >&2
            return 1
            ;;
    esac
}

uninstall_target() {
    target_path=$1

    validate_exact_target "$target_path"
    if [ -L "$target_path" ]; then
        echo "Error: refusing to uninstall a symbolic-link target: $target_path" >&2
        return 1
    fi
    if [ ! -d "$target_path" ]; then
        echo "not installed: platform=$PLATFORM scope=$SCOPE target=$target_path"
        return 0
    fi
    if [ ! -f "$target_path/.jq2qmt-install" ] && [ "$FORCE" -ne 1 ]; then
        echo "Error: install marker is missing; refusing uninstall without --force: $target_path" >&2
        return 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "dry-run: platform=$PLATFORM scope=$SCOPE target=$target_path action=uninstall"
        return 0
    fi

    confirm_uninstall
    validate_exact_target "$target_path"
    rm -rf "$target_path"
    echo "uninstalled: platform=$PLATFORM scope=$SCOPE target=$target_path"
}

detect_platforms() {
    DETECTED_PLATFORMS=
    DETECTED_COUNT=0
    for candidate in codex claude opencode openclaw hermes; do
        if command -v "$candidate" >/dev/null 2>&1; then
            DETECTED_PLATFORMS="${DETECTED_PLATFORMS}${DETECTED_PLATFORMS:+ }$candidate"
            DETECTED_COUNT=$((DETECTED_COUNT + 1))
        fi
    done
}

process_platform() {
    selected_platform=$1
    PLATFORM=$selected_platform
    resolve_target "$selected_platform" || return $?
    if [ "$UNINSTALL" -eq 1 ]; then
        uninstall_target "$TARGET"
    else
        install_local "$SOURCE_DIR" "$TARGET"
    fi
}

if [ "$UNINSTALL" -ne 1 ]; then
    if [ -z "$SOURCE_DIR" ]; then
        prepare_remote_source
    else
        if ! SOURCE_DIR=$(CDPATH= cd -- "$SOURCE_DIR" 2>/dev/null && pwd -P); then
            usage_error "source directory does not exist: $SOURCE_DIR"
        fi
        SOURCE_DESCRIPTION=$SOURCE_DIR
        if [ -n "$VERSION" ] && ! is_release_tag "$VERSION"; then
            usage_error "--version must match vMAJOR.MINOR.PATCH"
        fi
        validate_skill "$SOURCE_DIR"
    fi
fi

if [ -z "$PLATFORM" ]; then
    detect_platforms
    if [ "$DETECTED_COUNT" -ne 1 ]; then
        echo "Error: detected $DETECTED_COUNT supported platform CLIs; specify --platform explicitly" >&2
        exit 1
    fi
    PLATFORM=$DETECTED_PLATFORMS
fi

if [ "$PLATFORM" = all ]; then
    detect_platforms
    if [ "$DETECTED_COUNT" -eq 0 ]; then
        echo "Error: --platform all found no supported platform CLI" >&2
        exit 1
    fi
    successful_targets=0
    for candidate in codex claude opencode openclaw hermes; do
        case " $DETECTED_PLATFORMS " in
            *" $candidate "*) ;;
            *) continue ;;
        esac
        if process_platform "$candidate"; then
            successful_targets=$((successful_targets + 1))
        else
            result=$?
            if [ "$candidate" = hermes ] && [ "$SCOPE" = project ] && [ "$result" -eq 2 ]; then
                continue
            fi
            exit "$result"
        fi
    done
    if [ "$successful_targets" -eq 0 ]; then
        echo "Error: no supported installation target succeeded" >&2
        exit 1
    fi
else
    process_platform "$PLATFORM"
fi
