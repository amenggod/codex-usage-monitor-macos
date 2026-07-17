#!/usr/bin/env bash
set -euo pipefail

APP="${1:?usage: verify-bundle.sh /path/to/app}"
CODESIGN_BIN="${CODESIGN_BIN:-/usr/bin/codesign}"
EXPECTED_APP_GROUP="ZD9PK3NY5Z.CodexUsageMonitor.shared"

fail() {
  echo "bundle verification failed: $*" >&2
  exit 1
}

require_directory() {
  [[ -d "$1" ]] || fail "missing directory: $1"
}

require_executable() {
  [[ -x "$1" ]] || fail "missing executable: $1"
  file "$1" | grep -q 'Mach-O' || fail "not a Mach-O executable: $1"
}

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print $key" "$plist" 2>/dev/null ||
    fail "missing plist key $key in $plist"
}

assert_plist_value() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(plist_value "$plist" "$key")"
  [[ "$actual" == "$expected" ]] ||
    fail "$plist $key is '$actual' (expected '$expected')"
}

assert_unique_bundle() {
  local root="$1"
  local name="$2"
  local expected_path="$3"
  local count
  count="$(find "$root" -type d -name "$name" -print | wc -l | tr -d '[:space:]')"
  [[ "$count" == "1" ]] || fail "expected one $name under $root (found $count)"
  require_directory "$expected_path"
}

verify_signed_code() {
  local path="$1"
  local details
  local team_identifier

  "$CODESIGN_BIN" --verify --strict "$path" >/dev/null 2>&1 ||
    fail "invalid signature: $path"
  "$CODESIGN_BIN" \
    --verify \
    --strict \
    -R '=anchor apple generic' \
    "$path" \
    >/dev/null 2>&1 ||
    fail "signature is not anchored by Apple: $path"

  details="$("$CODESIGN_BIN" -dvvv "$path" 2>&1)" ||
    fail "unable to inspect signature: $path"
  grep -q '^Authority=' <<<"$details" ||
    fail "signature is ad-hoc or lacks an identity: $path"
  if grep -q '^Signature=adhoc' <<<"$details"; then
    fail "ad-hoc signature is not distributable: $path"
  fi

  team_identifier="$(
    sed -n 's/^TeamIdentifier=//p' <<<"$details" |
      head -n 1
  )"
  [[ -n "$team_identifier" && "$team_identifier" != "not set" ]] ||
    fail "missing TeamIdentifier: $path"

  if [[ -z "${EXPECTED_TEAM_IDENTIFIER:-}" ]]; then
    EXPECTED_TEAM_IDENTIFIER="$team_identifier"
  elif [[ "$team_identifier" != "$EXPECTED_TEAM_IDENTIFIER" ]]; then
    fail \
      "TeamIdentifier mismatch for $path: $team_identifier (expected $EXPECTED_TEAM_IDENTIFIER)"
  fi
}

extract_app_groups() {
  local path="$1"
  local output="$2"
  local groups

  "$CODESIGN_BIN" -d --entitlements :- "$path" >"$output" 2>/dev/null ||
    fail "unable to extract signed entitlements: $path"
  plutil -lint "$output" >/dev/null ||
    fail "invalid signed entitlements plist: $path"
  groups="$(
    plutil \
      -extract 'com\.apple\.security\.application-groups' \
      json \
      -o - \
      "$output" \
      2>/dev/null
  )" || fail "missing App Group entitlement: $path"
  printf '%s\n' "$groups"
}

require_directory "$APP"

APP_PLIST="$APP/Contents/Info.plist"
WIDGET="$APP/Contents/PlugIns/CodexUsageMonitorWidget.appex"
WIDGET_PLIST="$WIDGET/Contents/Info.plist"
LOGIN_ITEM="$APP/Contents/Library/LoginItems/CodexUsageMonitorLoginItem.app"
LOGIN_ITEM_PLIST="$LOGIN_ITEM/Contents/Info.plist"
SHARED_FRAMEWORK="$APP/Contents/Frameworks/CodexUsageShared.framework"
SHARED_FRAMEWORK_PLIST="$SHARED_FRAMEWORK/Resources/Info.plist"
LOGIN_SHARED_FRAMEWORK="$LOGIN_ITEM/Contents/Frameworks/CodexUsageShared.framework"
LOGIN_SHARED_FRAMEWORK_PLIST="$LOGIN_SHARED_FRAMEWORK/Resources/Info.plist"

assert_unique_bundle "$APP/Contents/PlugIns" '*.appex' "$WIDGET"
assert_unique_bundle "$APP/Contents/Library/LoginItems" '*.app' "$LOGIN_ITEM"
assert_unique_bundle "$APP" 'CodexUsageMonitorWidget.appex' "$WIDGET"
assert_unique_bundle "$APP" 'CodexUsageMonitorLoginItem.app' "$LOGIN_ITEM"

require_directory "$SHARED_FRAMEWORK"
require_directory "$LOGIN_SHARED_FRAMEWORK"
framework_count="$(
  find "$APP" -type d -name 'CodexUsageShared.framework' -print |
    wc -l |
    tr -d '[:space:]'
)"
[[ "$framework_count" == "2" ]] ||
  fail "expected two embedded CodexUsageShared frameworks (found $framework_count)"

for plist in \
  "$APP_PLIST" \
  "$WIDGET_PLIST" \
  "$LOGIN_ITEM_PLIST" \
  "$SHARED_FRAMEWORK_PLIST" \
  "$LOGIN_SHARED_FRAMEWORK_PLIST"
do
  [[ -f "$plist" ]] || fail "missing plist: $plist"
  plutil -lint "$plist" >/dev/null || fail "invalid plist: $plist"
done

assert_plist_value "$APP_PLIST" :CFBundleIdentifier com.amenggod.CodexUsageMonitor
assert_plist_value "$APP_PLIST" :CFBundlePackageType APPL
assert_plist_value "$APP_PLIST" :CFBundleExecutable CodexUsageMonitor
assert_plist_value "$APP_PLIST" :LSMinimumSystemVersion 14.0
assert_plist_value \
  "$APP_PLIST" \
  :CFBundleURLTypes:0:CFBundleURLSchemes:0 \
  codexusagemonitor
if /usr/libexec/PlistBuddy \
  -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:1' \
  "$APP_PLIST" \
  >/dev/null 2>&1
then
  fail "unexpected additional URL scheme"
fi
if /usr/libexec/PlistBuddy \
  -c 'Print :CFBundleURLTypes:1' \
  "$APP_PLIST" \
  >/dev/null 2>&1
then
  fail "unexpected additional URL type"
fi

assert_plist_value \
  "$WIDGET_PLIST" \
  :CFBundleIdentifier \
  com.amenggod.CodexUsageMonitor.Widget
assert_plist_value "$WIDGET_PLIST" :CFBundlePackageType 'XPC!'
assert_plist_value "$WIDGET_PLIST" :CFBundleExecutable CodexUsageMonitorWidget
assert_plist_value \
  "$WIDGET_PLIST" \
  :NSExtension:NSExtensionPointIdentifier \
  com.apple.widgetkit-extension

assert_plist_value \
  "$LOGIN_ITEM_PLIST" \
  :CFBundleIdentifier \
  com.amenggod.CodexUsageMonitor.LoginItem
assert_plist_value "$LOGIN_ITEM_PLIST" :CFBundlePackageType APPL
assert_plist_value \
  "$LOGIN_ITEM_PLIST" \
  :CFBundleExecutable \
  CodexUsageMonitorLoginItem

assert_plist_value \
  "$SHARED_FRAMEWORK_PLIST" \
  :CFBundleIdentifier \
  com.amenggod.CodexUsageMonitor.Shared
assert_plist_value \
  "$LOGIN_SHARED_FRAMEWORK_PLIST" \
  :CFBundleIdentifier \
  com.amenggod.CodexUsageMonitor.Shared

require_executable "$APP/Contents/MacOS/CodexUsageMonitor"
require_executable "$WIDGET/Contents/MacOS/CodexUsageMonitorWidget"
require_executable "$LOGIN_ITEM/Contents/MacOS/CodexUsageMonitorLoginItem"
require_executable "$SHARED_FRAMEWORK/CodexUsageShared"
require_executable "$LOGIN_SHARED_FRAMEWORK/CodexUsageShared"

marketing_version="$(plist_value "$APP_PLIST" :CFBundleShortVersionString)"
build_version="$(plist_value "$APP_PLIST" :CFBundleVersion)"
[[ "$marketing_version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] ||
  fail "invalid marketing version: $marketing_version"
[[ "$build_version" =~ ^[0-9]+$ ]] ||
  fail "invalid build version: $build_version"

for plist in \
  "$WIDGET_PLIST" \
  "$LOGIN_ITEM_PLIST" \
  "$SHARED_FRAMEWORK_PLIST" \
  "$LOGIN_SHARED_FRAMEWORK_PLIST"
do
  assert_plist_value "$plist" :CFBundleShortVersionString "$marketing_version"
  assert_plist_value "$plist" :CFBundleVersion "$build_version"
done

UNSIGNED_MARKER="$APP/Contents/Resources/UNSIGNED_BUILD.txt"
if [[ -f "$UNSIGNED_MARKER" ]]; then
  grep -q '^UNSIGNED VALIDATION BUILD' "$UNSIGNED_MARKER" ||
    fail "invalid unsigned-build marker"
  grep -q 'no bundle resource seal or identity-backed signature' "$UNSIGNED_MARKER" ||
    fail "unsigned-build marker misstates signing coverage"
  grep -q 'Mach-O executables may carry ad-hoc or linker signatures' "$UNSIGNED_MARKER" ||
    fail "unsigned-build marker misstates executable signatures"
  grep -q 'not an installable, notarized release' "$UNSIGNED_MARKER" ||
    fail "unsigned-build marker lacks distribution warning"
  resource_seal_count="$(
    find "$APP" -type f -path '*/_CodeSignature/CodeResources' -print |
      wc -l |
      tr -d '[:space:]'
  )"
  [[ "$resource_seal_count" == "0" ]] ||
    fail "validation artifact unexpectedly contains bundle resource seals"
  validation_executables=(
    "$APP/Contents/MacOS/CodexUsageMonitor"
    "$WIDGET/Contents/MacOS/CodexUsageMonitorWidget"
    "$LOGIN_ITEM/Contents/MacOS/CodexUsageMonitorLoginItem"
    "$SHARED_FRAMEWORK/CodexUsageShared"
    "$LOGIN_SHARED_FRAMEWORK/CodexUsageShared"
  )
  for path in "${validation_executables[@]}"; do
    if "$CODESIGN_BIN" \
      --verify \
      --strict \
      -R '=anchor apple generic' \
      "$path" \
      >/dev/null 2>&1
    then
      fail "validation artifact unexpectedly contains Apple identity-backed code: $path"
    fi
  done
  echo "Bundle structure verified: no bundle resource seal or identity-backed signature."
  echo "Mach-O executables may carry ad-hoc or linker signatures; artifact is not installable or notarized."
else
  EXPECTED_TEAM_IDENTIFIER=""
  signed_paths=(
    "$APP"
    "$APP/Contents/MacOS/CodexUsageMonitor"
    "$WIDGET"
    "$WIDGET/Contents/MacOS/CodexUsageMonitorWidget"
    "$LOGIN_ITEM"
    "$LOGIN_ITEM/Contents/MacOS/CodexUsageMonitorLoginItem"
    "$SHARED_FRAMEWORK"
    "$SHARED_FRAMEWORK/CodexUsageShared"
    "$LOGIN_SHARED_FRAMEWORK"
    "$LOGIN_SHARED_FRAMEWORK/CodexUsageShared"
  )
  for path in "${signed_paths[@]}"; do
    verify_signed_code "$path"
  done

  previous_umask="$(umask)"
  umask 077
  entitlements_tmp="$(
    mktemp -d "${TMPDIR:-/tmp}/codex-usage-entitlements.XXXXXX"
  )" || fail "unable to create entitlement verification directory"
  umask "$previous_umask"
  trap 'rm -rf -- "$entitlements_tmp"' EXIT
  app_groups="$(
    extract_app_groups "$APP" "$entitlements_tmp/app-entitlements.plist"
  )"
  widget_groups="$(
    extract_app_groups "$WIDGET" "$entitlements_tmp/widget-entitlements.plist"
  )"
  expected_groups="[\"$EXPECTED_APP_GROUP\"]"
  [[ "$app_groups" == "$widget_groups" ]] ||
    fail "App Group entitlements differ between main app and Widget"
  [[ "$app_groups" == "$expected_groups" ]] ||
    fail \
      "App Group entitlements are '$app_groups' (expected the single group '$EXPECTED_APP_GROUP')"

  echo \
    "Bundle structure, App Group entitlements, and Apple identity-backed signatures verified for team $EXPECTED_TEAM_IDENTIFIER."
fi
