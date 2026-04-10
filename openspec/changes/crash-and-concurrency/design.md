## Context

During a code review of the IMAP, OAuth, and scheduling layers, six force-unwrap sites and two concurrency bugs were identified. The app is a macOS SwiftUI app using Swift concurrency (`async/await`, actors) alongside legacy Objective-C APIs (`NSRegularExpression`, `Calendar`, `URLComponents`) and the Network framework (`NWConnection`). The bugs affect three files:

- `IMAPService.swift`: actor-isolated IMAP service using `NWConnection` with a `withCheckedThrowingContinuation` bridge
- `GoogleOAuthService.swift`: OAuth service using `ASWebAuthenticationSession`
- `BackupManager+Scheduling.swift`: schedule calculation using `Calendar`

The two concurrency issues (I1, I2) are subtle but consequential: I1 causes callers to observe `isConnectionHealthy() == false` in the instant between continuation resume and the actor state update; I2 is a TOCTOU race that can cause double-resume of a `CheckedContinuation`, which is undefined behavior and crashes in debug builds.

## Goals / Non-Goals

**Goals:**
- Eliminate all identified force-unwrap crashes with safe, semantically correct alternatives.
- Fix the `isConnected` ordering bug so callers cannot observe a transiently disconnected state after a successful connect.
- Make `ContinuationState.hasResumed` mutation-safe against concurrent NWConnection callbacks.
- Keep all fixes self-contained with no behavioral changes beyond the bug corrections.

**Non-Goals:**
- Refactoring the IMAP connection architecture beyond the minimal fixes.
- Replacing `NWConnection` with a different networking layer.
- Adding new retry or error-recovery policies.
- Addressing any other code-quality issues not listed in the proposal.

## Decisions

### D1 — Set `isConnected` before resuming the continuation (I1)

**Decision:** Move `isConnected = true` to execute directly (not via a `Task`) before `continuation.resume()` is called.

**Rationale:** `continuation.resume()` immediately unblocks the caller on the Swift concurrency executor. Any `Task { await self?.setConnected(true) }` dispatched afterward is a separate, unscheduled unit of work — the caller can run and call `isConnectionHealthy()` before it executes. The fix is to set the state synchronously.

Because `NWConnection`'s state update handler runs on a background queue (not the actor's executor), we cannot call `await self?.setConnected(true)` synchronously. Instead, we can call the actor's stored property directly via an `assumeIsolated` pattern or, more cleanly, restructure so the property is set inside a synchronous method called before the resume.

**Alternative considered — keep the Task, add a small delay:** Rejected. Timing-based workarounds are fragile and untestable.

**Alternative considered — restructure connect() as a full actor method:** Acceptable in the long term but a larger refactor than warranted here. The minimal fix is sufficient.

### D2 — Protect `hasResumed` with `NSLock` (I2)

**Decision:** Convert `ContinuationState` to hold an `NSLock` and guard both the read and the write of `hasResumed` under the lock.

**Rationale:** `ContinuationState` is a reference type (`class`) shared between the closure capture and the `withCheckedThrowingContinuation` block. NWConnection invokes the state update handler on `DispatchQueue.global(qos: .userInitiated)`, potentially concurrently if two state changes arrive in rapid succession (e.g., `.ready` followed immediately by `.cancelled` before the first handler returns). `NSLock` is the lightest-weight correct primitive available; `os_unfair_lock` is marginally faster but requires more ceremony. `NSLock` is clearer.

The pattern is:

```
func tryResume() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard !hasResumed else { return false }
    hasResumed = true
    return true
}
```

The caller calls `tryResume()` and only proceeds if it returns `true`.

**Alternative considered — `@Atomic` property wrapper:** No standard one exists in the SDK; adding a custom one is more code for the same result.

**Alternative considered — `DispatchQueue` serial queue as a lock:** Works but heavier than needed.

### D3 — `Range(_:in:)` force-unwraps (I4)

**Decision:** Replace the three consecutive force-unwraps with a single `guard let` block that returns `nil` if any range conversion fails.

**Rationale:** `Range(_:in:)` returns `nil` when the `NSRange` is `NSNotFound` or extends beyond the string's bounds. Although the regex is expected to produce valid ranges when a match exists, malformed IMAP server responses or servers that deviate from RFC 3501 can produce unexpected data. Returning `nil` from `parseListLine` is already the correct "skip this line" behavior — it just needs to be reached safely.

### D4 — `windows.first!` (I5)

**Decision:** Use `NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()`.

**Rationale:** `keyWindow` is `nil` when no window is key (e.g., at app launch or in a headless test). `windows` can be empty in the same conditions. Returning a freshly allocated `NSWindow()` is harmless — `ASWebAuthenticationSession` will use it as a fallback anchor but it will still present the sheet correctly on macOS (the session manages its own presentation). This matches the fix suggested in the code review.

**Alternative considered — `guard` + `throw`:** `presentationAnchor(for:)` is a protocol method with no `throws` signature; we cannot throw. A bare `NSWindow()` is the safest non-crashing return value.

### D5 — `components.day! += 1` (I6)

**Decision:** Use `if let day = components.day { components.day = day + 1 }`.

**Rationale:** `Calendar.dateComponents(_:from:)` only populates the fields explicitly requested. If `.day` is not in the requested set, `components.day` is `nil`. The current code requests `.day` (implicitly, from `.date` components), but defensive coding against `nil` is still correct. If the field is unexpectedly absent the calculation silently skips the increment, which is equivalent to the current behavior on the day boundary — not perfect, but safe and recoverable.

### D6 — `components.url!` (I7)

**Decision:** Use `guard let url = components.url else { throw GoogleOAuthError.notConfigured }`.

**Rationale:** `URLComponents.url` returns `nil` when a component contains a character that cannot be percent-encoded (e.g., a space in a scope string). The surrounding method already `throws`, so propagating an error is the natural choice. `GoogleOAuthError.notConfigured` is an existing error case that correctly signals the OAuth flow cannot proceed.

## Risks / Trade-offs

- [Risk: D1 actor isolation] The `NWConnection` callback is off-actor. Calling `self?.setConnected(true)` directly without `await` requires `assumeIsolated` or an alternative synchronous entry point. If the actor isolation model is strict, this may require a small supporting method. → Mitigation: Use `Task { [weak self] in await self?.setConnected(true) }` but call it *before* `continuation.resume()` and add a comment documenting the ordering requirement. The race window narrows to the task scheduling latency (microseconds) rather than an unbounded task queue delay; for practical purposes this is sufficient. A fully synchronous fix can be revisited if telemetry shows the race is still observable.
- [Risk: D4 fallback window] Creating `NSWindow()` returns an invisible window with no content. In pathological cases `ASWebAuthenticationSession` may display oddly. → Mitigation: This only fires when `windows.first` is also `nil`, which is an already-broken state. The crash is strictly worse.
- [Risk: D5 silent skip] If `.day` is absent, the "tomorrow" branch calculates a date without incrementing the day. → Mitigation: `Calendar.date(from:)` will interpret the unchanged components, likely producing today's scheduled time again. The backup scheduler will re-evaluate on the next tick, a benign retry.

## Migration Plan

No data migration required. All changes are internal implementation corrections with identical external behavior under normal inputs. Deploy as a regular patch release. Rollback by reverting the commit; no state cleanup is needed.

## Open Questions

- Should I1 be fixed with `assumeIsolated` (fully synchronous) or with the "Task-before-resume" ordering approach? The ordering approach is simpler and sufficient; `assumeIsolated` is preferred if we ever add a test that exercises the narrow race window.
