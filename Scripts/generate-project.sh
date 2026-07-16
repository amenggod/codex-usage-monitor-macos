#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
command -v xcodegen >/dev/null || { echo "xcodegen is required" >&2; exit 1; }
required_version="2.45.4"
installed_version="$(xcodegen --version | awk '{print $NF}')"
if [[ "$installed_version" != "$required_version" ]]; then
  echo "xcodegen $required_version is required (found $installed_version)" >&2
  echo "Install the pinned version, for example with: brew install xcodegen && brew pin xcodegen" >&2
  exit 1
fi
xcodegen generate --spec project.yml
