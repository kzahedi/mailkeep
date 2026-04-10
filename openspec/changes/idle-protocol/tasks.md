## 1. DONE Command Rejection — Throw on NO (I9)

- [x] 1.1 In `IMAPService+IDLE.swift` `sendDone(idleTag:)`, replace the `return` on the `NO` branch with `throw IMAPError.commandFailed("DONE rejected with NO: \(chunk.trimmingCharacters(in: .whitespacesAndNewlines))")`
- [x] 1.2 Verify the `BAD` branch still throws as before and the `OK` branch still returns without throwing
- [x] 1.3 Confirm the thrown error propagates through `waitForIDLENotification` up to `runMonitor`'s `catch` block (no silent swallowing at any intermediate call site)

## 2. DONE Before Disconnect on Timeout (I10)

- [x] 2.1 In `waitForIDLENotification(timeout:)`, add a `try? await sendRaw("DONE\r\n")` call inside the timeout task, immediately before the task returns `.timeout`
- [x] 2.2 Ensure the `sendRaw` call is wrapped in `try?` so a failed write (dead connection) does not prevent `.timeout` from being returned
- [x] 2.3 Verify `group.cancelAll()` still runs after `group.next()` returns, so the reader task's `onCancel` triggers `disconnect()` as before
- [x] 2.4 Update the inline comment on the timeout task to describe the new `DONE` send step and cite RFC 2177 §3

## 3. Rate Limiting on IDLEManager Reconnect (I11)

- [x] 3.1 Locate the `configureRateLimit(...)` call in `BackupManager` and note the exact parameter values used
- [x] 3.2 In `IDLEManager.runMonitor(for:)`, after `let service = IMAPService(account: account)`, add `service.configureRateLimit(...)` with the same parameter values identified in 3.1
- [x] 3.3 Confirm `configureRateLimit` is called before `service.connect()` on every iteration of the outer `while` loop (both the initial start and all reconnect iterations)

## 4. Verification

- [x] 4.1 Build the project with no Swift compiler errors or warnings introduced by these changes
- [x] 4.2 Run any existing IDLE-related unit tests; confirm all pass
- [ ] 4.3 Manually test keepalive timeout path: after 25 min (or with a reduced timeout in debug) confirm the server receives `DONE` before the connection closes (check server logs or a packet capture)
- [ ] 4.4 Manually test error retry path: simulate a connection drop and confirm the reconnected service is rate-limited (no rapid-fire burst of `connect`/`login` visible in logs)
