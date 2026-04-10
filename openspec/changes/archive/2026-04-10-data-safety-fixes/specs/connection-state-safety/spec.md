## MODIFIED Requirements

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

## ADDED Requirements

### Requirement: All continuation resumes in the NWConnection state handler execute on the actor

Every call to `continuation.resume()` or `continuation.resume(throwing:)` within the NWConnection `stateUpdateHandler` closure SHALL be dispatched via `Task { ... }` rather than called directly from the closure. This ensures that resumption executes on the `IMAPService` actor's executor, not on the arbitrary thread used by the Network framework.

#### Scenario: .failed case resumes via Task
- **WHEN** the NWConnection transitions to `.failed`
- **THEN** the error continuation resume is wrapped in a `Task { }` call rather than invoked directly from the stateUpdateHandler closure

#### Scenario: .cancelled case resumes via Task
- **WHEN** the NWConnection transitions to `.cancelled`
- **THEN** the cancellation continuation resume is wrapped in a `Task { }` call rather than invoked directly from the stateUpdateHandler closure
