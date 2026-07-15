#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
command -v xcodegen >/dev/null || { echo "xcodegen is required" >&2; exit 1; }
xcodegen generate --spec project.yml
