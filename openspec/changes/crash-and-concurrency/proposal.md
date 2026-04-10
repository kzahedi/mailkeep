## Why

Six force-unwrap crashes and two concurrency bugs have been identified via code review in the IMAP connection, OAuth, and scheduling layers. The force-unwraps can crash the app on real-world inputs (malformed IMAP responses, missing windows, empty calendar fields); the concurrency bugs can produce spurious reconnects and data races under concurrent network callbacks. These are correctness and stability issues that must be fixed before the next release.

## What Changes

- Replace three force-unwrap `Range(_:in:)` calls in `parseListLine` with safe `guard let` unwraps that return `nil` on failure.
- Replace `windows.first!` in `PresentationContextProvider.presentationAnchor` with a safe fallback chain that never crashes in a headless environment.
- Replace `components.day! += 1` in `BackupManager+Scheduling` with a safe `if let` unwrap.
- Replace `components.url!` in `GoogleOAuthService.buildAuthURL` with a `guard let` that throws `GoogleOAuthError.notConfigured` on failure.
- Set `isConnected = true` synchronously (before resuming the continuation) in `IMAPService.connect()` so callers cannot observe a transiently disconnected state immediately after a successful connect.
- Protect `ContinuationState.hasResumed` with `NSLock` so simultaneous NWConnection state callbacks cannot both pass the TOCTOU guard check.

## Capabilities

### New Capabilities

- `connection-state-safety`: Ensures the IMAP connection actor presents a consistent connected state immediately after the continuation resumes, and that `ContinuationState.hasResumed` is read/written atomically to prevent double-resume races.
- `force-unwrap-elimination`: Replaces all identified force-unwrap sites in IMAP parsing, OAuth URL building, OAuth window presentation, and schedule date calculation with safe alternatives that fail gracefully.

### Modified Capabilities

<!-- No existing specs require requirement-level changes. -->

## Impact

- `IMAPBackup/Services/IMAPService.swift`: `connect()` method (lines 228–235), `parseListLine(_:)` method (lines 849–851), `ContinuationState` inner class (line 217).
- `IMAPBackup/Services/GoogleOAuthService.swift`: `buildAuthURL` (line 208), `PresentationContextProvider.presentationAnchor` (line 361).
- `IMAPBackup/Services/BackupManager+Scheduling.swift`: `nextScheduledDate` (line 94).
- No public API or data-model changes; all fixes are internal implementation corrections.
- No new dependencies required.
