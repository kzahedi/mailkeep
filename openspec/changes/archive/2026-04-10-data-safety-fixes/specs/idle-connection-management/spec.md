## MODIFIED Requirements

### Requirement: Every IMAPService created by IDLEManager has rate limiting configured

`IDLEManager.runMonitor(for:)` creates a new `IMAPService` on every reconnect iteration. Each such instance SHALL have `configureRateLimit(...)` called on it before `connect()` is invoked, using the same rate-limit parameters applied to services created by `BackupManager`. Without this, rapid reconnect cycles (e.g., repeated errors within seconds) can issue unthrottled `connect` and `login` commands to the IMAP server.

#### Scenario: Reconnect after error calls configureRateLimit before connect
- **WHEN** `runMonitor(for:)` creates a new `IMAPService` after a connection error and a retry delay
- **THEN** `configureRateLimit(...)` is called on the new service instance before `service.connect()` is called

#### Scenario: Reconnect after keepalive timeout calls configureRateLimit before connect
- **WHEN** `runMonitor(for:)` creates a new `IMAPService` after a `.timeout` notification causes the inner IDLE loop to break
- **THEN** `configureRateLimit(...)` is called on the new service instance before `service.connect()` is called

#### Scenario: First connection on monitoring start calls configureRateLimit before connect
- **WHEN** `runMonitor(for:)` creates the very first `IMAPService` for an account (initial monitoring start, not a reconnect)
- **THEN** `configureRateLimit(...)` is called on the service instance before `service.connect()` is called

### Requirement: Rate limit parameters match those used by BackupManager

The rate-limit values configured on IDLE services SHALL be identical to those configured on services created by `BackupManager`, so that IDLE connections and backup connections are subject to the same per-server throttling policy.

#### Scenario: IDLE service uses same rate-limit values as BackupManager service
- **WHEN** both `IDLEManager` and `BackupManager` create an `IMAPService` for the same account
- **THEN** both services have `configureRateLimit` called with the same parameter values

## ADDED Requirements

### Requirement: IDLE reconnect loop applies exponential backoff with a failure cap

The `IDLEManager.runMonitor(for:)` reconnect loop SHALL apply exponential backoff between consecutive failures and SHALL stop retrying after a configurable maximum number of consecutive failures, logging an error and exiting the loop cleanly.

#### Scenario: First failure waits the base delay
- **WHEN** the first consecutive connection failure occurs
- **THEN** the retry delay is the base interval (30 s)

#### Scenario: Subsequent failures double the delay up to the cap
- **WHEN** consecutive failures accumulate
- **THEN** each retry delay doubles the previous one, up to a maximum of 5 minutes

#### Scenario: Loop exits after maximum consecutive failures
- **WHEN** the number of consecutive failures reaches the maximum (10)
- **THEN** the loop exits, an error is logged, and no further reconnect is attempted for that account

#### Scenario: Successful connection resets the failure counter
- **WHEN** a reconnect attempt succeeds
- **THEN** the consecutive failure counter is reset to zero so that a subsequent failure starts the backoff sequence from the beginning
