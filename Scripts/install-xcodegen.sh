#!/usr/bin/env bash
set -euo pipefail

ARCHIVE="${1:?usage: install-xcodegen.sh archive sha256 extract-dir version}"
EXPECTED_SHA256="${2:?usage: install-xcodegen.sh archive sha256 extract-dir version}"
EXTRACT_DIR="${3:?usage: install-xcodegen.sh archive sha256 extract-dir version}"
EXPECTED_VERSION="${4:?usage: install-xcodegen.sh archive sha256 extract-dir version}"

fail() {
  echo "XcodeGen installation failed: $*" >&2
  exit 1
}

[[ -f "$ARCHIVE" ]] || fail "archive does not exist: $ARCHIVE"

actual_sha256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[[ "$actual_sha256" == "$EXPECTED_SHA256" ]] ||
  fail "checksum mismatch: $actual_sha256"

rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
ditto -x -k "$ARCHIVE" "$EXTRACT_DIR"

tool="$EXTRACT_DIR/xcodegen/bin/xcodegen"
[[ -x "$tool" ]] ||
  fail "archive is missing executable xcodegen/bin/xcodegen"

installed_version="$("$tool" --version | awk '{print $NF}')"
[[ "$installed_version" == "$EXPECTED_VERSION" ]] ||
  fail "expected version $EXPECTED_VERSION (found $installed_version)"

printf '%s\n' "$EXTRACT_DIR/xcodegen/bin"
