#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/.build/xcode-derived"
APP="$ROOT/dist/Codex Usage Monitor.app"
ZIP="$ROOT/dist/Codex-Usage-Monitor-macOS.zip"
SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"

case "$SIGNING_ALLOWED" in
  YES|NO) ;;
  *)
    echo "CODE_SIGNING_ALLOWED must be YES or NO (found: $SIGNING_ALLOWED)" >&2
    exit 1
    ;;
esac

if [[ "$SIGNING_ALLOWED" == "YES" ]]; then
  [[ -n "${DEVELOPMENT_TEAM:-}" ]] || {
    echo "DEVELOPMENT_TEAM is required when CODE_SIGNING_ALLOWED=YES" >&2
    exit 1
  }
  [[ -n "${CODE_SIGN_STYLE:-}" ]] || {
    echo "CODE_SIGN_STYLE is required when CODE_SIGNING_ALLOWED=YES" >&2
    exit 1
  }
fi

cd "$ROOT"
rm -rf "$DERIVED" "$APP" "$ZIP"
mkdir -p "$ROOT/dist"

xcodebuild_args=(
  -project CodexUsageMonitor.xcodeproj
  -scheme CodexUsageMonitor
  -configuration Release
  -derivedDataPath "$DERIVED"
  "CODE_SIGNING_ALLOWED=$SIGNING_ALLOWED"
)

if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  xcodebuild_args+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi
if [[ -n "${CODE_SIGN_STYLE:-}" ]]; then
  xcodebuild_args+=("CODE_SIGN_STYLE=$CODE_SIGN_STYLE")
fi

xcodebuild "${xcodebuild_args[@]}" build

SOURCE_APP="$DERIVED/Build/Products/Release/Codex Usage Monitor.app"
test -d "$SOURCE_APP"
ditto "$SOURCE_APP" "$APP"

if [[ "$SIGNING_ALLOWED" == "NO" ]]; then
  mkdir -p "$APP/Contents/Resources"
  printf '%s\n' \
    "UNSIGNED VALIDATION BUILD — compilation and bundle-structure verification only." \
    "This artifact has no bundle resource seal or identity-backed signature." \
    "Mach-O executables may carry ad-hoc or linker signatures." \
    "This artifact is not an installable, notarized release." \
    > "$APP/Contents/Resources/UNSIGNED_BUILD.txt"
fi

bash Scripts/verify-bundle.sh "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [[ "$SIGNING_ALLOWED" == "NO" ]]; then
  echo "WARNING: validation artifact has no bundle resource seal or identity-backed signature." >&2
  echo "Mach-O executables may carry ad-hoc or linker signatures; this is not an installable or notarized release." >&2
fi
echo "$APP"
echo "$ZIP"
