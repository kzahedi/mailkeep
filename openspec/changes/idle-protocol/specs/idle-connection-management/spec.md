## ADDED Requirements

### Requirement: Every IMAPService created by IDLEManager has rate limiting configured

`IDLEManager.runMonitor(for:)` creates a new `IMAPService` on every reconnect iteration. Each such instance SHALL have `configureRateLimit(...)` called on it before `connect()` is invoked, using the same rate-limit parameters applied to services created by `BackupManager`. Without this, rapid reconnect cycles (e.g., repeated errors within seconds) can issue unthrottled `connect` and `login` commands to the IMAP server.

#### Scenario: Reconnect after error calls configureRateLimit before connect

- **WHEN** `runMonitor(for:)` creates a new `IMAPService` after a connection error and the 30-second retry delay
- **THEN** `configureRateLimit(...)` is called on the new service instance before `service.connect()` is called

#### Scenario: Reconnect after keepalive timeout calls configureRateLimit before connect

- **WHEN** `runMonitor(for:)` creates a new `IMAPService` after a `.timeout` notification causes the inner IDLE loop to break
- **THEN** `configureRateLimit(...)` is called on the new service instance before `service.connect()` is called

#### Scenario: First connection on monitoring start calls configureRateLimit before connect

- **WHEN** `runMonitor(for:)` creates the very first `IMAPService` for an account (initial monitoring start, not a reconnect)
- **THEN** `configureRateLimit(...)` is called on the service instance before `service.connect()` is called

### Requirement: Rate limit parameters match those used by BackupManager

The rate-limit values configured on IDLE services SHALL be identical to those configured on services created by `BackupManager`, so that IDLE connections and backup connections are subject to the same per-server throttling policy. Diverging values between the two code paths would allow one path to bypass intended throttling.

#### Scenario: IDLE service uses same rate-limit values as BackupManager service

- **WHEN** both `IDLEManager` and `BackupManager` create an `IMAPService` for the same account
- **THEN** both services have `configureRateLimit` called with the same parameter values (max requests, time window, or equivalent)
