#!/usr/bin/env bash
set -euo pipefail

BASE_APP="${1:?usage: test-verify-bundle-signing.sh /path/to/unsigned/app}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$ROOT/Scripts/verify-bundle.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STUB="$TMP/codesign-stub"
LOG="$TMP/codesign.log"

cat >"$STUB" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

path=""
operation="verify"
previous_argument=""
requirement=""
entitlements_target=""
strict="NO"
for argument in "$@"; do
  path="$argument"
  if [[ "$previous_argument" == "-R" || "$previous_argument" == "--test-requirement" ]]; then
    requirement="$argument"
  fi
  if [[ "$previous_argument" == "--entitlements" ]]; then
    entitlements_target="$argument"
  fi
  case "$argument" in
    -d*) operation="display" ;;
    --entitlements) operation="entitlements" ;;
    -R|--test-requirement) operation="requirement" ;;
    --strict) strict="YES" ;;
  esac
  previous_argument="$argument"
done
printf '%s|%s\n' "$operation" "$path" >>"${CODESIGN_LOG:?}"

if [[ "$operation" != "display" && "$operation" != "entitlements" && "$strict" != "YES" ]]; then
  echo "codesign verification omitted --strict" >&2
  exit 2
fi
if [[ "$operation" == "requirement" && "$requirement" != "=anchor apple generic" ]]; then
  echo "codesign verification used the wrong Apple anchor requirement" >&2
  exit 2
fi

profile="${SIGNING_PROFILE:?}"
team="TEAM123456"
authority="Apple Development: Fixture"

if [[ "$profile" == "different-team" && "$path" == *CodexUsageMonitorWidget* ]]; then
  team="OTHER98765"
fi
if [[ "$profile" == "self-signed" ]]; then
  authority="Local Self-Signed Fixture"
fi
if [[ "$profile" == "nested-ad-hoc" && "$path" == *CodexUsageMonitorWidget* ]]; then
  team="not set"
  authority=""
fi

if [[ "$operation" == "requirement" ]]; then
  if [[ "$profile" == "self-signed" || "$profile" == "unsigned" ]]; then
    exit 1
  fi
  if [[ "$profile" == "nested-ad-hoc" && "$path" == *CodexUsageMonitorWidget* ]]; then
    exit 1
  fi
  exit 0
fi

if [[ "$operation" == "entitlements" ]]; then
  if [[ "$entitlements_target" != ":-" ]]; then
    echo "codesign entitlement extraction did not use :-" >&2
    exit 2
  fi

  group="group.com.amenggod.CodexUsageMonitor"
  include_group="YES"
  case "$profile" in
    missing-entitlement)
      if [[ "$path" == *CodexUsageMonitorWidget.appex ]]; then
        include_group="NO"
      fi
      ;;
    wrong-group)
      group="group.com.example.WrongUsageMonitor"
      ;;
    whitespace-group)
      group="group.com.amenggod.CodexUsageMonitor "
      ;;
    app-widget-mismatch)
      if [[ "$path" == *CodexUsageMonitorWidget.appex ]]; then
        group="group.com.example.WidgetMismatch"
      fi
      ;;
  esac

  if [[ "$include_group" == "YES" ]]; then
    printf '%s\n' \
      '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0">' \
      '<dict>' \
      '  <key>com.apple.security.application-groups</key>' \
      '  <array>' \
      "    <string>$group</string>" \
      '  </array>' \
      '</dict>' \
      '</plist>'
  else
    printf '%s\n' \
      '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0">' \
      '<dict/>' \
      '</plist>'
  fi
  exit 0
fi

if [[ "$operation" == "display" ]]; then
  if [[ -n "$authority" ]]; then
    echo "Authority=$authority" >&2
  else
    echo "Signature=adhoc" >&2
  fi
  echo "TeamIdentifier=$team" >&2
  exit 0
fi

exit 0
STUB
chmod +x "$STUB"
ln -s "$STUB" "$TMP/codesign"

failures=0

make_fixture() {
  local profile="$1"
  local app="$TMP/$profile.app"
  rm -rf "$app"
  ditto "$BASE_APP" "$app"
  rm -f "$app/Contents/Resources/UNSIGNED_BUILD.txt"
  printf '%s\n' "$app"
}

expect_rejected() {
  local profile="$1"
  local app
  app="$(make_fixture "$profile")"
  : >"$LOG"
  if PATH="$TMP:$PATH" \
    CODESIGN_BIN="$STUB" \
    CODESIGN_LOG="$LOG" \
    SIGNING_PROFILE="$profile" \
    bash "$VERIFY" "$app" \
    >/dev/null 2>&1
  then
    echo "expected signed profile '$profile' to be rejected" >&2
    failures=$((failures + 1))
  fi
}

expect_rejected self-signed
expect_rejected nested-ad-hoc
expect_rejected different-team
expect_rejected missing-entitlement
expect_rejected wrong-group
expect_rejected whitespace-group
expect_rejected app-widget-mismatch

marked_signed_app="$TMP/marked-signed.app"
ditto "$BASE_APP" "$marked_signed_app"
: >"$LOG"
if PATH="$TMP:$PATH" \
  CODESIGN_BIN="$STUB" \
  CODESIGN_LOG="$LOG" \
  SIGNING_PROFILE=valid \
  bash "$VERIFY" "$marked_signed_app" \
  >/dev/null 2>&1
then
  echo "expected identity-backed code with an unsigned marker to be rejected" >&2
  failures=$((failures + 1))
fi

valid_app="$(make_fixture valid)"
: >"$LOG"
if ! PATH="$TMP:$PATH" \
  CODESIGN_BIN="$STUB" \
  CODESIGN_LOG="$LOG" \
  SIGNING_PROFILE=valid \
  bash "$VERIFY" "$valid_app" \
  >/dev/null
then
  echo "expected Apple identity-backed fixture to be accepted" >&2
  failures=$((failures + 1))
fi

signed_paths=(
  "$valid_app"
  "$valid_app/Contents/MacOS/CodexUsageMonitor"
  "$valid_app/Contents/PlugIns/CodexUsageMonitorWidget.appex"
  "$valid_app/Contents/PlugIns/CodexUsageMonitorWidget.appex/Contents/MacOS/CodexUsageMonitorWidget"
  "$valid_app/Contents/Library/LoginItems/CodexUsageMonitorLoginItem.app"
  "$valid_app/Contents/Library/LoginItems/CodexUsageMonitorLoginItem.app/Contents/MacOS/CodexUsageMonitorLoginItem"
  "$valid_app/Contents/Frameworks/CodexUsageShared.framework"
  "$valid_app/Contents/Frameworks/CodexUsageShared.framework/CodexUsageShared"
  "$valid_app/Contents/Library/LoginItems/CodexUsageMonitorLoginItem.app/Contents/Frameworks/CodexUsageShared.framework"
  "$valid_app/Contents/Library/LoginItems/CodexUsageMonitorLoginItem.app/Contents/Frameworks/CodexUsageShared.framework/CodexUsageShared"
)

for path in "${signed_paths[@]}"; do
  for operation in verify requirement display; do
    if ! grep -Fq "$operation|$path" "$LOG"; then
      echo "missing $operation check for signed path: $path" >&2
      failures=$((failures + 1))
    fi
  done
done

entitlement_paths=(
  "$valid_app"
  "$valid_app/Contents/PlugIns/CodexUsageMonitorWidget.appex"
)
for path in "${entitlement_paths[@]}"; do
  if ! grep -Fq "entitlements|$path" "$LOG"; then
    echo "missing signed entitlement extraction for: $path" >&2
    failures=$((failures + 1))
  fi
done

: >"$LOG"
if ! PATH="$TMP:$PATH" \
  CODESIGN_BIN="$STUB" \
  CODESIGN_LOG="$LOG" \
  SIGNING_PROFILE=unsigned \
  bash "$VERIFY" "$BASE_APP" \
  >/dev/null
then
  echo "expected unsigned fixture to remain accepted" >&2
  failures=$((failures + 1))
fi
if grep -q '^entitlements|' "$LOG"; then
  echo "unsigned verification unexpectedly extracted signed entitlements" >&2
  failures=$((failures + 1))
fi

if ! grep -q 'no bundle resource seal or identity-backed signature' \
  "$BASE_APP/Contents/Resources/UNSIGNED_BUILD.txt"
then
  echo "unsigned marker does not describe the missing bundle resource seal" >&2
  failures=$((failures + 1))
fi
if ! grep -q 'Mach-O executables may carry ad-hoc or linker signatures' \
  "$BASE_APP/Contents/Resources/UNSIGNED_BUILD.txt"
then
  echo "unsigned marker does not allow ad-hoc/linker Mach-O signatures" >&2
  failures=$((failures + 1))
fi

((failures == 0)) || exit 1
echo "Signed and unsigned bundle verification contracts passed."
