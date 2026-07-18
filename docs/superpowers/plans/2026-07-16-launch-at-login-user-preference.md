# Login Item User Preference Transaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route every UI login-item user action through one controller transaction that migrates first, performs only necessary helper changes, and returns the real final state.

**Architecture:** Add `applyUserPreference(enabled:) throws -> Bool` to the launch-at-login service. The concrete controller owns migration, status comparison, ServiceManagement writes, final status read, and error classification; Settings and the first-run prompt only consume this operation.

**Tech Stack:** Swift 6, SwiftUI, Observation, ServiceManagement, Swift Testing

## Global Constraints

- Keep `AppLaunchCoordinator.migrateLegacyRegistrationIfNeeded()` as the explicit non-interactive startup migration.
- Production UI must not directly call `setEnabled` or compose migration with helper registration.
- Migration failure must stop the user preference change and retain migration error and marker state.
- UI state must use the controller's returned real helper state.

---

### Task 1: Controller transaction

**Files:**
- Modify: `Sources/CodexUsageMonitor/Services/LaunchAtLoginController.swift`
- Test: `Tests/CodexUsageMonitorTests/LaunchAtLoginControllerTests.swift`

**Interfaces:**
- Consumes: `migrateLegacyRegistrationIfNeeded() throws`, `adapter.registrationStatus`
- Produces: `applyUserPreference(enabled: Bool) throws -> Bool`

- [ ] **Step 1: Write failing controller tests**

Add tests that call `applyUserPreference` for legacy enabled + target true, legacy requiresApproval + target false, already-matching helper status, migration failure followed by successful retry, and unknown final helper status. Assert exact adapter operations, return value, marker retry behavior, and error classification.

- [ ] **Step 2: Run controller tests and verify RED**

Run: `swift test --filter LaunchAtLoginControllerTests`

Expected: compile failure because `applyUserPreference(enabled:)` is not defined.

- [ ] **Step 3: Implement the minimal transaction**

Add the protocol requirement and implement:

```swift
@discardableResult
func applyUserPreference(enabled: Bool) throws -> Bool {
    try migrateLegacyRegistrationIfNeeded()
    let current = try resolvedEnabledState()
    if current != enabled {
        try setEnabled(enabled)
    }
    return try resolvedEnabledState()
}
```

`resolvedEnabledState()` maps `.enabled` to true, `.notRegistered`/`.notFound`/`.requiresApproval` to false, and `.unknown` to a visible ordinary preference error. Migration errors must remain untouched because `setEnabled` is never reached after migration throws.

- [ ] **Step 4: Run controller tests and verify GREEN**

Run: `swift test --filter LaunchAtLoginControllerTests`

Expected: all controller tests pass.

### Task 2: Settings and first-run prompt consumers

**Files:**
- Modify: `Sources/CodexUsageMonitor/Presentation/SettingsView.swift`
- Modify: `Sources/CodexUsageMonitor/Presentation/UsagePopoverView.swift`
- Test: `Tests/CodexUsageMonitorTests/AppPresentationStateTests.swift`
- Test: `Tests/CodexUsageMonitorTests/AppLaunchCoordinatorTests.swift`

**Interfaces:**
- Consumes: `applyUserPreference(enabled:) throws -> Bool`
- Produces: Settings toggle and prompt Enable paths with no direct `setEnabled` calls

- [ ] **Step 1: Write failing presentation tests**

Update the service spies to record `applyUserPreference` requests. Add Settings tests proving retry-after-startup-migration failure succeeds through the one operation and failed migration preserves true state/error. Add a prompt state test proving Enable calls the same operation once, clears error on success, and preserves migration error on failure.

- [ ] **Step 2: Run presentation tests and verify RED**

Run: `swift test --filter AppPresentationStateTests`

Expected: compile/test failure because Settings and the prompt still use the old composed calls.

- [ ] **Step 3: Implement the minimal consumers**

Settings must assign the returned Bool:

```swift
isLaunchAtLoginEnabled = try launchAtLogin.applyUserPreference(enabled: enabled)
```

On error, re-read `launchAtLogin.isEnabled`, `lastErrorDescription`, and `hasMigrationError`. Extract prompt action state into a small observable helper that calls `applyUserPreference(enabled: true)` and exposes its error; wire the confirmation button and footer to that state.

- [ ] **Step 4: Prove production UI has one user-intent entry point**

Run: `rg -n 'setEnabled|migrateLegacyRegistrationIfNeeded' Sources/CodexUsageMonitor/Presentation`

Expected: no direct UI calls; only controller/launch coordinator use low-level operations.

- [ ] **Step 5: Run presentation and launch tests**

Run: `swift test --filter AppPresentationStateTests`

Run: `swift test --filter AppLaunchCoordinatorTests`

Expected: both suites pass.

### Task 3: Verification, report, and implementation commit

**Files:**
- Modify: `.superpowers/sdd/task-5-report.md`

**Interfaces:**
- Consumes: completed controller and presentation changes
- Produces: verified commit and Task 5 third-review evidence

- [ ] **Step 1: Run focused verification**

Run controller, AppPresentationState, and AppLaunchCoordinator suites; run helper typecheck and `git diff --check`. Expected: exit 0 and zero failures.

- [ ] **Step 2: Run full regression alone**

Run: `swift test`

Expected: 215 or more tests pass with zero failures. Do not run this concurrently with helper typechecking because existing UsageViewModel timing tests are load-sensitive.

- [ ] **Step 3: Append the TDD report**

Record RED evidence, final counts, changed files, remaining real-app ServiceManagement smoke-test concern, and any timing-test observations in `.superpowers/sdd/task-5-report.md`.

- [ ] **Step 4: Commit implementation**

```text
git add <controller, presentation, tests>
git commit -m "fix: unify login item user preferences"
```

- [ ] **Step 5: Verify the committed state**

Run `swift test` alone, helper typecheck, `git status --short`, and `git log -1`. Expected: tests and typecheck pass, worktree has no tracked changes, and the final subject matches.
