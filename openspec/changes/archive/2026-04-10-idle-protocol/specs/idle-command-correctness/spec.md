## ADDED Requirements

### Requirement: DONE command rejection is propagated as an error

When the server responds to an IDLE session's `DONE` command with a tagged `NO`, the client SHALL throw an error rather than return normally. A `NO` response indicates the server rejected the command and the connection's IDLE state is undefined; silent continuation would risk issuing further commands on a broken session.

#### Scenario: Server responds NO to DONE

- **WHEN** `sendDone(idleTag:)` reads a server response containing the tagged `NO` (e.g., `A001 NO DONE rejected`)
- **THEN** the function throws `IMAPError.commandFailed` with a message containing "DONE rejected with NO" and the server response chunk

#### Scenario: Server responds OK to DONE

- **WHEN** `sendDone(idleTag:)` reads a server response containing the tagged `OK`
- **THEN** the function returns without throwing and the connection is ready for the next command

#### Scenario: Server responds BAD to DONE

- **WHEN** `sendDone(idleTag:)` reads a server response containing the tagged `BAD`
- **THEN** the function throws `IMAPError.commandFailed` (existing behaviour is preserved)

### Requirement: DONE is sent before connection teardown on keepalive timeout

Per RFC 2177 §3, a client in IDLE mode SHALL send `DONE\r\n` to the server before closing the connection. The keepalive timeout path MUST send `DONE\r\n` on the active connection before the reader task is cancelled and the connection is disconnected.

#### Scenario: Keepalive timeout fires while IDLE is active

- **WHEN** the timeout task in `waitForIDLENotification(timeout:)` fires because no EXISTS notification arrived within the configured interval
- **THEN** `DONE\r\n` is written to the server on the current connection before `group.cancelAll()` is called

#### Scenario: DONE send fails on timeout path

- **WHEN** the timeout task attempts to send `DONE\r\n` and the underlying connection has already been dropped by the server
- **THEN** the send failure is silently ignored (treated as `try?`) and `.timeout` is still returned to the caller so the reconnect cycle proceeds normally

#### Scenario: Normal EXISTS path still sends DONE via sendDone

- **WHEN** the reader task receives a `* N EXISTS` response
- **THEN** `sendDone(idleTag:)` is called as before and the full tagged OK exchange completes before `.exists(N)` is returned
