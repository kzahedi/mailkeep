## Context

Six confirmed bugs were found in a code review. Two cause data loss (emails deleted from disk permanently), one causes actor isolation violations that could produce data races under concurrency, one allows accounts to be used before their credentials exist, one leaks temp files on disk, and one loops forever on broken accounts. All fixes are surgical — no API changes, no new dependencies.

## Goals / Non-Goals

**Goals:**
- Eliminate the delete-before-move data loss in `checkAndHandleDuplicate()`
- Clean up streaming temp files when a download fails all retries
- Make `addAccount()` await Keychain persistence before publishing the account
- Wrap all `continuation.resume()` calls in the NWConnection state handler inside a `Task` so they execute on the actor
- Replace silent `try?` in `RateLimitService.saveSettings()` with logged `do/catch`
- Cap IDLE reconnect retries with exponential backoff

**Non-Goals:**
- Refactoring `StorageService` deduplication beyond the atomic fix
- Changing the public API of any service
- Addressing performance or test-coverage gaps from the same review (separate change)

## Decisions

### D1 — `checkAndHandleDuplicate`: move-then-delete, not delete-then-move

Current: delete `newFileURL` → move `existingURL` → if move fails, both gone.  
Fix: move `existingURL` to a temp name in the same directory → delete `newFileURL` → rename temp to `newFileURL`. This keeps `existingURL` intact until the whole operation succeeds.

Alternative: copy-then-delete. Rejected — doubles disk I/O and risks partial writes on full disks.

### D2 — `addAccount()`: make it `async throws`, await Keychain before publish

Current: synchronous, appends to `accounts` immediately, saves Keychain in a detached Task.  
Fix: change `addAccount` to `async throws`. Save Keychain first (`try await`), then append and call `saveAccounts()`. Callers (`AddAccountView`, `MigrationService`) will need one `await` each.

Alternative: keep synchronous, use a "pending" state. Rejected — more complex and still races at backup start.

### D3 — `IMAPService.connect()`: Task-wrap all continuation resumes

The `.failed` and `.cancelled` cases in `stateUpdateHandler` call `continuation.resume()` directly from NWConnection's internal queue — outside the actor. Fix: wrap both in `Task { continuation.resume(...) }` (same pattern already used for `.ready`).

This is the minimal correct fix; the Task hop brings execution back onto the actor's executor.

### D4 — IDLE backoff: exponential up to 5 min, cap at 10 consecutive failures

Backoff sequence: 30 s, 60 s, 120 s, 240 s, 300 s (capped). After 10 consecutive failures, log an error and exit the loop — the account is effectively broken and burning resources. The per-account IDLE toggle is not changed.

### D5 — Streaming cleanup: delete temp on every retry failure

Before the `try? await Task.sleep(nanoseconds:)` backoff between retries, and unconditionally after the retry loop exhausts, delete the temp file if it exists. Use `try? FileManager.default.removeItem(at: tempURL)` — failure to clean up is non-fatal and should be logged, not thrown.

## Risks / Trade-offs

- **D2 async addAccount**: Changes call sites. `AddAccountView` must use a Task; if the Keychain write takes >1 s on a slow device, the UI blocks briefly. Mitigation: the await is within a button-tap Task, so the spinner covers it.
- **D4 IDLE exit after 10 failures**: A transient network outage longer than ~25 min total (sum of backoffs) will stop IDLE for that account until the user re-enables it. Mitigation: the UI toggle remains — the user can re-enable manually. Acceptable trade-off vs. infinite CPU burn.
- **D3 Task-wrap**: Adds a very small scheduling hop on connect. No observable latency impact.

## Migration Plan

No persistent data changes. All fixes are in-process logic. No migration needed.
