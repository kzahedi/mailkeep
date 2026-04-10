## 1. Fix StorageService: move-before-delete in checkAndHandleDuplicate

- [x] 1.1 In `StorageService.swift`, read `checkAndHandleDuplicate()` and locate the `removeItem` → `moveItem` sequence
- [x] 1.2 Replace with: move `existingURL` to a side-step temp path (e.g. `existingURL.path + ".dedup-tmp"`) → delete `newFileURL` → rename temp to `newFileURL`; if any step fails, attempt to restore the temp back to `existingURL` before propagating
- [x] 1.3 Build and confirm zero errors

## 2. Fix BackupManager+Execution: clean up streaming temp files on failure

- [x] 2.1 In `BackupManager+Execution.swift`, locate the streaming download retry loop (the `for attempt in 1...3` block that calls `streamEmailToFile`)
- [x] 2.2 Identify where `tempURL` is created; ensure it is captured in the outer scope so cleanup can reference it
- [x] 2.3 In the `catch` block inside the retry loop, add `try? FileManager.default.removeItem(at: tempURL)` before the retry sleep
- [x] 2.4 After the retry loop, if `lastError != nil`, add the same cleanup call unconditionally
- [x] 2.5 Build and confirm zero errors

## 3. Fix BackupManager+Accounts: await Keychain before publishing account

- [x] 3.1 Change `addAccount(_:password:)` signature from `func addAccount(...) -> Bool` to `func addAccount(...) async throws -> Bool`
- [x] 3.2 Move the Keychain save (`KeychainService.shared.savePassword`) before `accounts.append(mutableAccount)` and `saveAccounts()`, using `try await` directly (no detached Task)
- [x] 3.3 Update callers: search for `addAccount(` in `MailKeep/` and update each call site to `await`/`try await` as appropriate
- [x] 3.4 Build and confirm zero errors

## 4. Fix IMAPService: Task-wrap continuation resumes in stateUpdateHandler

- [x] 4.1 In `IMAPService.swift`, locate `connect()` and the `stateUpdateHandler` closure
- [x] 4.2 Wrap the `.failed` case `continuation.resume(throwing:)` call in `Task { continuation.resume(throwing: ...) }`
- [x] 4.3 Wrap the `.cancelled` case `continuation.resume(throwing:)` call in `Task { continuation.resume(throwing: ...) }`
- [x] 4.4 Confirm the `.ready` case is already wrapped (it was fixed in a prior change); if not, wrap it too
- [x] 4.5 Build and confirm zero errors

## 5. Fix RateLimitService: log saveSettings encoding failures

- [x] 5.1 In `RateLimitService.swift`, locate `saveSettings()`
- [x] 5.2 Replace each `if let data = try? JSONEncoder().encode(...)` block with a `do { let data = try ...; UserDefaults... } catch { logError(...) }` block
- [x] 5.3 Build and confirm zero errors

## 6. Fix IDLEManager: exponential backoff with failure cap

- [x] 6.1 In `IDLEManager.swift`, locate `runMonitor(for:)` and the outer `while true` loop's `catch` block
- [x] 6.2 Add a `var consecutiveFailures = 0` counter before the loop
- [x] 6.3 In the catch block, increment `consecutiveFailures`; if it reaches 10, log an error (`logError("IDLE: \(account.email) failed \(consecutiveFailures) consecutive times, stopping monitor")`) and `break`
- [x] 6.4 Replace the flat 30 s sleep with exponential backoff: `let delay = min(30.0 * pow(2.0, Double(consecutiveFailures - 1)), 300.0)`
- [x] 6.5 Reset `consecutiveFailures = 0` at the top of the successful inner IDLE loop (after `connect()` succeeds)
- [x] 6.6 Build and confirm zero errors

## 7. Verification

- [x] 7.1 Run full test suite (`xcodebuild test`) and confirm all tests pass
- [x] 7.2 Search for any remaining `removeItem` before `moveItem` patterns in `StorageService.swift`
- [x] 7.3 Confirm `addAccount` call sites compile with the new `async throws` signature
