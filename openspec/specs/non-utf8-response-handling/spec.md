### Requirement: readResponse never returns empty string due to encoding failure
`readResponse()` SHALL decode received bytes as UTF-8 when possible and SHALL fall back to ISO 8859-1 (which is defined for all byte values 0x00–0xFF) when UTF-8 decoding fails. The function SHALL NOT return an empty string as a result of an encoding failure. It SHALL return a non-empty string whenever the underlying `NWConnection.receive` callback delivers non-empty data.

#### Scenario: UTF-8 data is decoded normally
- **WHEN** `NWConnection.receive` delivers bytes that are valid UTF-8
- **THEN** `readResponse()` returns the decoded UTF-8 string unchanged

#### Scenario: Non-UTF-8 data falls back to ISO 8859-1
- **WHEN** `NWConnection.receive` delivers bytes that are not valid UTF-8 (e.g., raw binary attachment data containing byte values 0x80–0xFF)
- **THEN** `readResponse()` returns a non-empty string decoded as ISO 8859-1 rather than returning an empty string

#### Scenario: Tagged response survives ISO 8859-1 fallback
- **WHEN** `NWConnection.receive` delivers a chunk that mixes binary bytes with an ASCII tagged response such as `A0001 OK Completed\r\n`
- **THEN** the returned string contains the ASCII tagged-response substring intact so that callers can detect the termination condition

### Requirement: Read loops cannot spin indefinitely on encoding failure
All `while true` and `while !isComplete` loops that call `readResponse()` SHALL terminate normally whenever the server sends a tagged response, even if that response arrives in a chunk that also contains non-UTF-8 bytes.

#### Scenario: sendCommand loop terminates on binary chunk containing tagged OK
- **WHEN** the server sends a response chunk that contains non-UTF-8 bytes followed by `A0001 OK\r\n`
- **THEN** the `sendCommand` read loop exits after that chunk and does not spin

#### Scenario: IDLE reader loop terminates on binary chunk containing EXISTS
- **WHEN** the server sends a chunk containing non-UTF-8 bytes and a `* 5 EXISTS\r\n` line
- **THEN** `waitForIDLENotification` detects the EXISTS count and exits the read loop
