## Context

The IMAP IDLE implementation spans two files: `IMAPService+IDLE.swift` (the low-level protocol layer — sending IDLE/DONE commands, reading server push responses, and racing a timeout task) and `IDLEManager.swift` (the reconnect supervisor — one `Task` per monitored account, outer retry loop, inner IDLE loop). Three correctness issues were found in code review:

- I9: `sendDone(idleTag:)` silently returns on a tagged `NO` response, leaving the caller unaware that the DONE command was rejected and the connection is in an undefined state.
- I10: The keepalive timeout path cancels the reader task (triggering `disconnect()` via `onCancel`) without first sending `DONE\r\n`, violating RFC 2177 §3 which requires the client to notify the server before closing.
- I11: `runMonitor(for:)` constructs a bare `IMAPService(account:)` on every reconnect iteration and never calls `configureRateLimit(...)`, so rapid reconnects (e.g., after repeated errors) hammer the server without throttling.

## Goals / Non-Goals

**Goals:**

- Make `sendDone(idleTag:)` throw on tagged `NO` so the error propagates up the call stack.
- Send `DONE\r\n` on the timeout path before disconnecting, so the server receives a proper exit signal per RFC 2177 §3.
- Ensure every `IMAPService` created by `IDLEManager` has rate limiting configured before `connect()` is called.

**Non-Goals:**

- Changing the public API surface of `IMAPService`, `IDLEManager`, or `IMAPServiceProtocol`.
- Altering reconnect delay policy (30 s on error, immediate on timeout).
- Handling `DONE` draining for multiple in-flight EXISTS responses beyond what already exists.

## Decisions

### D1: Throw on `NO` in `sendDone`, not return

**Decision:** Replace the `return` on the `NO` branch with `throw IMAPError.commandFailed("DONE rejected with NO: \(chunk)")`.

**Rationale:** A `NO` response means the server rejected the command. The connection's IDLE state is unknown — the client cannot safely issue further commands. Propagating a thrown error causes the outer `do/catch` in `runMonitor` to log, wait 30 s, and reconnect, which is the correct recovery action. Silently continuing would risk sending commands on a broken session.

**Alternative considered:** Log a warning and continue. Rejected — the connection is in an undefined state and any subsequent command would likely produce a `BAD` or disconnect.

### D2: Send `DONE` synchronously in the timeout task before cancelling the reader

**Decision:** In `waitForIDLENotification(timeout:)`, when the timeout task fires, send `DONE\r\n` on the connection before returning `.timeout`. The reader task is cancelled immediately after (via `group.cancelAll()`), which triggers `disconnect()` via `onCancel` as before.

**Rationale:** RFC 2177 §3 states the client MUST send `DONE` before closing a connection that is in IDLE state. Sending it in the timeout task (before `group.cancelAll()` runs) is the earliest safe point. The `DONE` write does not need to wait for the server's tagged OK in this path — the purpose is notification, not clean command completion. The reader task will be cancelled immediately after.

**Alternative considered:** Call `sendDone` fully (including reading the tagged OK). Rejected — introduces latency on every 25-minute keepalive cycle and can block if the server is slow. The RFC requires sending `DONE`, not waiting for the full exchange, before closing.

**Alternative considered:** Move `DONE` to `onCancel`. Rejected — `onCancel` is a `nonisolated` synchronous handler; async writes cannot be issued there.

### D3: Call `configureRateLimit` immediately after constructing `IMAPService` in `runMonitor`

**Decision:** In `IDLEManager.runMonitor(for:)`, after `let service = IMAPService(account: account)`, add a `service.configureRateLimit(...)` call using the same parameters already used elsewhere in the codebase (by `BackupManager`).

**Rationale:** This is the minimal, lowest-risk fix: one line added in the one place where IDLE services are created. The rate limiter is stateful per-service, so each new `IMAPService` must configure its own.

**Alternative considered:** Accept a factory closure `(_ account: EmailAccount) -> IMAPServiceProtocol` as a parameter to `startMonitoring`. This allows callers to inject pre-configured or mock services and improves testability. The trade-off is a slightly wider API change. This is a valid future improvement but is out of scope for this bugfix change.

**Alternative considered:** Store a shared `RateLimiter` on `IDLEManager` and pass it in. Rejected — each server connection should have independent throttling; sharing a single limiter across accounts would cause cross-account interference.

## Risks / Trade-offs

- [Risk: `DONE` send on timeout may fail if the connection is already dropped by the server] → The `sendRaw` call should be wrapped in `try?` on the timeout path; a failure to deliver `DONE` before a dead connection is not a hard error and should not prevent the keepalive reconnect.
- [Risk: Throwing on `NO` changes observable behavior for callers that currently tolerate silent failure] → The only caller of `sendDone` is the reader task inside `waitForIDLENotification`, which already propagates errors up to `runMonitor`'s catch block — no change in recovery logic needed.
- [Risk: `configureRateLimit` parameters may diverge from `BackupManager` over time] → Centralise the rate-limit configuration values into a constants struct or `IMAPService` extension in a follow-up.

## Migration Plan

All three changes are internal implementation fixes. No migrations or feature flags are required. No user-visible behaviour changes. Deploy as a standard patch release.

## Open Questions

- What are the exact `configureRateLimit` parameters currently used by `BackupManager`? Confirm they are appropriate for IDLE connections (which hold a long-lived socket rather than issuing burst commands).
