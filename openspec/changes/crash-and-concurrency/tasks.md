## 1. Connection State Safety (I1, I2)

- [x] 1.1 In `IMAPService.connect()`, move the `setConnected(true)` call to execute before `continuation.resume()` in the `.ready` case, ensuring the actor state is updated (or enqueued) prior to unblocking the caller
- [x] 1.2 Add `NSLock` to `ContinuationState` and replace the bare `guard !state.hasResumed` check with a lock-protected `tryResume() -> Bool` method that atomically reads and sets `hasResumed`
- [x] 1.3 Update all three `state.hasResumed = true` sites (`.ready`, `.failed`, `.cancelled`) to use the new `tryResume()` method and guard on its return value
- [x] 1.4 Verify that no code path can call `continuation.resume` or `continuation.resume(throwing:)` more than once (read the surrounding code and confirm single-resume invariant)

## 2. Force-Unwrap Elimination — IMAP Parsing (I4)

- [x] 2.1 In `IMAPService.parseListLine(_:)`, replace the three force-unwrap `Range(match.range(at: N), in: line)!` calls (lines 849–851) with a single `guard let` block that binds `flagsRange`, `delimiterRange`, and `nameRange`; return `nil` if any binding fails

## 3. Force-Unwrap Elimination — OAuth URL Building (I7)

- [x] 3.1 In `GoogleOAuthService`, replace `return components.url!` (line 208) with `guard let url = components.url else { throw GoogleOAuthError.notConfigured }; return url`

## 4. Force-Unwrap Elimination — OAuth Presentation Anchor (I5)

- [x] 4.1 In `GoogleOAuthService.PresentationContextProvider.presentationAnchor(for:)` (line 361), replace `NSApplication.shared.windows.first!` with `NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()`

## 5. Force-Unwrap Elimination — Schedule Date Calculation (I6)

- [x] 5.1 In `BackupManager+Scheduling`, replace `components.day! += 1` (line 94) with `if let day = components.day { components.day = day + 1 }`

## 6. Verification

- [x] 6.1 Build the project with no warnings treated as errors and confirm zero new warnings introduced by the changes
- [x] 6.2 Run the existing test suite and confirm all tests pass
- [x] 6.3 Manually exercise the IMAP connect flow against a test account and confirm no spurious reconnect occurs immediately after connect
- [x] 6.4 Confirm the app launches and presents an OAuth sheet without crashing when triggered from a state with no key window (e.g., immediately at app launch before any window becomes key)
