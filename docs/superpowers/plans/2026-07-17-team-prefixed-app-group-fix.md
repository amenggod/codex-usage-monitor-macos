# Team-Prefixed App Group Widget Fix Implementation Plan

> **For Codex:** Execute this plan inline with test-driven development. The user has already authorized implementation.

**Goal:** Make the installed macOS desktop widget read the same fresh usage snapshot as the main app, so the widget shows the current weekly remainder (73% in the reproduced case) instead of “数据不可用”.

**Architecture:** The main app and WidgetKit extension continue sharing one privacy-safe JSON snapshot through a single App Group container. Replace the rejected unprefixed group identifier with the Apple-team-prefixed identifier required by macOS, keep the Swift constant, generated entitlements, build verification, and documentation in sync, then validate the installed signed bundle against the real container and system log.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI/WidgetKit, XcodeGen, macOS App Groups, codesign, shell contract tests.

---

### Task 1: Lock the accepted App Group into a failing test

**Files:**
- Modify: `Tests/CodexUsageSharedTests/WidgetUsageSnapshotTests.swift`

1. Add a test requiring `WidgetSnapshotStore.appGroupIdentifier` to equal `ZD9PK3NY5Z.CodexUsageMonitor.shared` and to begin with the signing team identifier.
2. Run only the new Swift test and confirm it fails because the current identifier is `group.com.amenggod.CodexUsageMonitor`.

### Task 2: Apply the minimal App Group correction

**Files:**
- Modify: `Sources/CodexUsageShared/WidgetSnapshotStore.swift`
- Modify: `project.yml`
- Modify: `Scripts/verify-bundle.sh`
- Modify: `Scripts/test-verify-bundle-signing.sh`
- Regenerate: `Config/CodexUsageMonitor.entitlements`
- Regenerate: `Config/CodexUsageMonitorWidget.entitlements`
- Regenerate: `CodexUsageMonitor.xcodeproj/project.pbxproj`

1. Change every production and verification reference to `ZD9PK3NY5Z.CodexUsageMonitor.shared`.
2. Update signing-test fixtures so a valid bundle carries the new group, while wrong/mismatched/whitespace cases remain rejected.
3. Bump the application to version `0.2.2` build `4` so macOS recognizes the corrected widget bundle as a new install.
4. Regenerate the Xcode project and entitlements from `project.yml`.
5. Run the focused Swift test and signing contract test; confirm they pass.

### Task 3: Update installation documentation

**Files:**
- Modify: `README.md`

1. Replace the old group identifier in setup, signing, and troubleshooting guidance.
2. Explain that this repository’s signed build uses the team-prefixed group and that both app targets must use exactly the same identifier.

### Task 4: Verify, build, and install

**Files:**
- Verify only: all source, generated project, and scripts
- Build artifact: `dist/Codex Usage Monitor.app`
- Install target: `/Applications/Codex Usage Monitor.app`

1. Run the complete Swift test suite, CI contract tests, project-generation cleanliness check, and bundle signing tests.
2. Build with Apple Development signing for team `ZD9PK3NY5Z` and verify the signed app and widget entitlements.
3. Replace the installed app, launch it, and confirm a fresh snapshot is written under `~/Library/Group Containers/ZD9PK3NY5Z.CodexUsageMonitor.shared/`.
4. Trigger a widget reload and confirm the widget process no longer logs an App Group `REJECTED` event and reads the current weekly remainder.

### Task 5: Publish the verified fix

**Files:**
- Commit all intentional changes on `codex/usage-monitor-v2`

1. Review the final diff for unrelated changes.
2. Commit and push the branch.
3. Update the existing draft pull request summary with the App Group root cause and real-device verification evidence.
4. Confirm GitHub Actions passes for the pushed commit.
