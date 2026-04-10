## Why

Three protocol-correctness bugs in the IMAP IDLE implementation violate RFC 2177 semantics and bypass rate limiting: a `NO` response to `DONE` is silently ignored (leaving connection state undefined), the keepalive timeout path disconnects without first sending `DONE` (violating RFC 2177 §3), and `IDLEManager` creates fresh `IMAPService` instances on every reconnect without configuring rate limiting (allowing unthrottled server hammering under aggressive reconnect conditions). These must be fixed before the IDLE feature ships to users.

## What Changes

- `sendDone(idleTag:)` in `IMAPService+IDLE.swift`: throw `IMAPError.commandFailed` when the server responds with a tagged `NO` instead of silently returning.
- `waitForIDLENotification(timeout:)` in `IMAPService+IDLE.swift`: send `DONE\r\n` in the timeout task branch before cancelling the reader task and disconnecting, so the server is notified per RFC 2177 §3.
- `runMonitor(for:)` in `IDLEManager.swift`: call `configureRateLimit(...)` on the newly created `IMAPService` after construction, or accept a factory closure from `startMonitoring` to allow injection of a pre-configured service.

## Capabilities

### New Capabilities

- `idle-command-correctness`: RFC 2177-compliant handling of the IDLE/DONE command exchange — correct error propagation on `NO` responses and proper `DONE` delivery before connection teardown (covers I9 and I10).
- `idle-connection-management`: Rate-limit enforcement on every `IMAPService` instance created by `IDLEManager` during reconnect cycles (covers I11).

### Modified Capabilities

## Impact

- `IMAPBackup/Services/IMAPService+IDLE.swift`: changes to `sendDone(idleTag:)` and the timeout branch of `waitForIDLENotification(timeout:)`.
- `IMAPBackup/Services/IDLEManager.swift`: change to `runMonitor(for:)` service construction.
- No public API changes; `IDLEManager` and `IMAPService` remain the same types with the same call sites.
- No new dependencies.
