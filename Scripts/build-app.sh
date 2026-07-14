#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/Codex Usage Monitor.app"
ZIP="$ROOT/dist/Codex-Usage-Monitor-macOS.zip"

rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CodexUsageMonitor" "$APP/Contents/MacOS/CodexUsageMonitor"
cp "$ROOT/Config/Info.plist" "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "$APP"
