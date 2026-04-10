## ADDED Requirements

### Requirement: Connected state is visible before continuation resumes
After a successful IMAP connection, the `isConnected` flag SHALL be set to `true` before the `withCheckedThrowingContinuation` continuation is resumed, so that any code executing immediately after `await connect()` returns will observe the connected state.

#### Scenario: Caller checks health immediately after connect
- **WHEN** `IMAPService.connect()` resolves successfully
- **THEN** `isConnectionHealthy()` returns `true` on the very next call without any intermediate suspension point

#### Scenario: No spurious reconnect triggered by health check
- **WHEN** a health check is performed synchronously after `connect()` returns
- **THEN** the system does NOT initiate a reconnect attempt due to observing `isConnected == false`

#### Scenario: Connection failure still sets connected to false
- **WHEN** the NWConnection transitions to `.failed`
- **THEN** `isConnected` remains `false` and the continuation throws the appropriate `IMAPError`

### Requirement: Continuation resume guard is concurrency-safe
The `ContinuationState.hasResumed` flag SHALL be read and written atomically so that concurrent NWConnection state callbacks cannot both pass the guard check and both attempt to resume the same continuation.

#### Scenario: Two callbacks arrive concurrently in the ready state
- **WHEN** two NWConnection state-update handler invocations execute concurrently
- **AND** both evaluate `hasResumed` before either sets it
- **THEN** exactly one continuation resume occurs and the other is a no-op

#### Scenario: Ready callback followed immediately by cancelled callback
- **WHEN** the `.ready` callback fires and begins processing
- **AND** a `.cancelled` callback fires on a concurrent thread before `hasResumed` is set
- **THEN** only the `.ready` path resumes the continuation; the `.cancelled` path is silently discarded

#### Scenario: Lock is released on all code paths
- **WHEN** a callback enters the lock-protected guard section
- **THEN** the lock is always released regardless of whether the callback resumes the continuation or returns early
