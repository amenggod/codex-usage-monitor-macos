#!/usr/bin/env bash
# shellcheck disable=SC2016 # Workflow contracts are intentionally literal shell source.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/ci.yml"
INSTALLER="$ROOT/Scripts/install-xcodegen.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

[[ -x "$INSTALLER" ]] || fail "missing executable XcodeGen installer: $INSTALLER"

fixture_root="$TMP/fixture"
fixture_archive="$TMP/xcodegen.zip"
mkdir -p "$fixture_root/xcodegen/bin"
cat >"$fixture_root/xcodegen/bin/xcodegen" <<'XCODEGEN'
#!/usr/bin/env bash
echo "Version: 2.45.4"
XCODEGEN
chmod +x "$fixture_root/xcodegen/bin/xcodegen"
ditto -c -k --keepParent "$fixture_root/xcodegen" "$fixture_archive"
fixture_sha256="$(shasum -a 256 "$fixture_archive" | awk '{print $1}')"

extract_dir="$TMP/xcodegen-2.45.4"
install_bin="$(
  bash "$INSTALLER" \
    "$fixture_archive" \
    "$fixture_sha256" \
    "$extract_dir" \
    2.45.4
)"
[[ "$install_bin" == "$extract_dir/xcodegen/bin" ]] ||
  fail "installer returned wrong bin path: $install_bin"
[[ -x "$install_bin/xcodegen" ]] ||
  fail "installer did not produce an executable XcodeGen"
[[ "$("$install_bin/xcodegen" --version | awk '{print $NF}')" == "2.45.4" ]] ||
  fail "installed fixture has the wrong version"

bad_checksum_dir="$TMP/bad-checksum"
if bash "$INSTALLER" \
  "$fixture_archive" \
  0000000000000000000000000000000000000000000000000000000000000000 \
  "$bad_checksum_dir" \
  2.45.4 \
  >/dev/null 2>&1
then
  fail "installer accepted an invalid checksum"
fi
[[ ! -e "$bad_checksum_dir" ]] ||
  fail "installer extracted before validating the checksum"

wrong_layout_root="$TMP/wrong-layout"
wrong_layout_archive="$TMP/wrong-layout.zip"
mkdir -p "$wrong_layout_root/bin"
cp "$fixture_root/xcodegen/bin/xcodegen" "$wrong_layout_root/bin/xcodegen"
ditto -c -k --keepParent "$wrong_layout_root/bin" "$wrong_layout_archive"
wrong_layout_sha256="$(
  shasum -a 256 "$wrong_layout_archive" |
    awk '{print $1}'
)"
if bash "$INSTALLER" \
  "$wrong_layout_archive" \
  "$wrong_layout_sha256" \
  "$TMP/wrong-layout-extract" \
  2.45.4 \
  >/dev/null 2>&1
then
  fail "installer accepted an archive without xcodegen/bin/xcodegen"
fi

assert_count \
  2 \
  'sudo xcode-select -s /Applications/Xcode_26.3.app/Contents/Developer'
assert_count 2 'test "$(xcodebuild -version | head -1)" = "Xcode 26.3"'

assert_contains \
  'XCODEGEN_URL: "https://github.com/yonaskolb/XcodeGen/releases/download/2.45.4/xcodegen.zip"'
assert_contains \
  'XCODEGEN_SHA256: "090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"'
assert_contains 'bash Scripts/install-xcodegen.sh'
assert_contains 'echo "$install_bin" >> "$GITHUB_PATH"'

assert_contains \
  'git diff --exit-code -- CodexUsageMonitor.xcodeproj Config'
assert_contains \
  'test -z "$(git status --porcelain --untracked-files=all -- CodexUsageMonitor.xcodeproj Config)"'

assert_contains \
  'ditto -x -k dist/Codex-Usage-Monitor-macOS.zip "$archive_dir"'
assert_contains 'test "$app_count" = "1"'
assert_contains \
  'bash Scripts/verify-bundle.sh "$archived_app"'

echo "CI workflow and XcodeGen installer positive/negative contracts verified."

bash "$ROOT/Scripts/test-idle-cpu-contracts.sh"
