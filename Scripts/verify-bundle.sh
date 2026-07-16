#!/usr/bin/env bash
set -euo pipefail

APP="${1:?usage: verify-bundle.sh /path/to/app}"

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
  grep -q '^UNSIGNED BUILD' "$UNSIGNED_MARKER" ||
    fail "invalid unsigned-build marker"
  grep -q 'not an installable, notarized release' "$UNSIGNED_MARKER" ||
    fail "unsigned-build marker lacks distribution warning"
  signature_count="$(
    find "$APP" -type d -name _CodeSignature -print |
      wc -l |
      tr -d '[:space:]'
  )"
  [[ "$signature_count" == "0" ]] ||
    fail "unsigned build unexpectedly contains code signatures"
  if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    fail "unsigned build unexpectedly passes signature verification"
  fi
  echo "Bundle structure verified: unsigned build only; not installable or notarized."
else
  codesign --verify --deep --strict "$APP" >/dev/null 2>&1 ||
    fail "bundle is unsigned or has an invalid signature and lacks the unsigned marker"
  signature_details="$(codesign -dvv "$APP" 2>&1)" ||
    fail "unable to inspect bundle signature"
  grep -q '^Authority=' <<<"$signature_details" ||
    fail "ad-hoc signatures are not accepted as distributable signing"
  echo "Bundle structure and identity-backed signature verified."
fi
