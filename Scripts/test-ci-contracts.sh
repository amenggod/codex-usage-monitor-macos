#!/usr/bin/env bash
# shellcheck disable=SC2016 # Workflow contracts are intentionally literal shell source.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/ci.yml"

fail() {
  echo "CI contract failed: $*" >&2
  exit 1
}

assert_contains() {
  local expected="$1"
  grep -Fq -- "$expected" "$WORKFLOW" ||
    fail "missing workflow contract: $expected"
}

assert_count() {
  local expected_count="$1"
  local expected="$2"
  local actual_count
  actual_count="$(grep -Fc -- "$expected" "$WORKFLOW" || true)"
  [[ "$actual_count" == "$expected_count" ]] ||
    fail "expected $expected_count occurrences of '$expected' (found $actual_count)"
}

assert_count \
  2 \
  'sudo xcode-select -s /Applications/Xcode_26.3.app/Contents/Developer'
assert_count 2 'test "$(xcodebuild -version | head -1)" = "Xcode 26.3"'

assert_contains \
  'XCODEGEN_URL: "https://github.com/yonaskolb/XcodeGen/releases/download/2.45.4/xcodegen.zip"'
assert_contains \
  'XCODEGEN_SHA256: "090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"'
assert_contains \
  'echo "$XCODEGEN_SHA256  $archive" | shasum -a 256 -c -'
assert_contains 'ditto -x -k "$archive" "$install_dir"'
assert_contains 'echo "$install_dir/bin" >> "$GITHUB_PATH"'
assert_contains \
  'test "$("$install_dir/bin/xcodegen" --version | awk '\''{print $NF}'\'')" = "$XCODEGEN_VERSION"'

assert_contains \
  'git diff --exit-code -- CodexUsageMonitor.xcodeproj Config'
assert_contains \
  'test -z "$(git status --porcelain --untracked-files=all -- CodexUsageMonitor.xcodeproj Config)"'

assert_contains \
  'ditto -x -k dist/Codex-Usage-Monitor-macOS.zip "$archive_dir"'
assert_contains 'test "$app_count" = "1"'
assert_contains \
  'bash Scripts/verify-bundle.sh "$archived_app"'

echo "CI workflow contracts verified."
