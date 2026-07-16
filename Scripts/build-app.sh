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
cp "$ROOT/Config/App-Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string CodexUsageMonitor "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.amenggod.CodexUsageMonitor "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string 0.2.0 "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string 2 "$APP/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string 14.0 "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "$APP"
