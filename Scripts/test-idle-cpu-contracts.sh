#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIEW="$ROOT/Sources/CodexUsageMonitor/Presentation/UsagePopoverView.swift"
POLICY="$ROOT/Sources/CodexUsageMonitor/Presentation/UsagePresentationPolicy.swift"
HELPER="$ROOT/Sources/CodexUsageMenuBar"

if grep -q 'TimelineView' "$VIEW"; then
  echo 'main usage view still contains TimelineView' >&2
  exit 1
fi
if grep -q 'refreshInterval' "$POLICY"; then
  echo 'presentation policy still exposes a one-second refresh interval' >&2
  exit 1
fi
if grep -R -q 'scheduledTimer.*1\|by: 1' "$HELPER"; then
  echo 'menu helper contains a one-second timer' >&2
  exit 1
fi

echo 'Idle UI refresh contract verified.'
