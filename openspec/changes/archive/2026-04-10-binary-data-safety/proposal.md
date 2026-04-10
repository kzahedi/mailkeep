## Why

`readResponse()` silently returns an empty string when it receives non-UTF-8 bytes (e.g., binary attachment data or non-UTF-8 server error text). Any `while true` loop that calls it — including the IDLE reader and `sendCommand` — will spin indefinitely on an empty string that never matches a termination condition, hanging the app. Separately, the streaming fetch path (`performStreamingFetch`) round-trips raw bytes through `String(data:encoding:.utf8)` before writing to disk, silently dropping bytes that are not valid UTF-8, corrupting binary email bodies. Both bugs are triggered by ordinary emails with binary attachments.

## What Changes

- `readResponse()` gains a safe UTF-8 decode path: when `String(data:encoding:.utf8)` fails it falls back to `.isoLatin1` (which never fails for arbitrary bytes), ensuring the read loop always receives a non-empty string and can reach its tagged-response termination condition.
- `performStreamingFetch` replaces its `readResponse()`-based body-write path with a raw `Data` receive loop that writes bytes directly to the file handle, matching the approach already used by `fetchEmailWithLiteralParsing`.
- No public API surface changes; no Swift protocols or types are added or removed.

## Capabilities

### New Capabilities

- `non-utf8-response-handling`: `readResponse()` never returns an empty string due to encoding failure; all read loops that call it are protected from infinite spin on non-UTF-8 server data.
- `streaming-binary-fetch`: `performStreamingFetch` preserves every byte of binary email bodies by operating on raw `Data` throughout, without any String round-trip.

### Modified Capabilities

<!-- No existing spec-level requirements are changing; these are new correctness guarantees. -->

## Impact

- **`IMAPBackup/Services/IMAPService.swift`**: `readResponse()` (lines 799–821) and `performStreamingFetch` (lines 577–681) are the two change sites.
- **All callers of `readResponse()`**: `sendCommand`, `waitForIDLENotification`, `fetchNewUIDs`, `sendDone` — all benefit passively; no call-site changes required.
- **Backup correctness**: emails with binary attachments will no longer be silently corrupted on the streaming path.
- **No dependency changes** and no new frameworks required.
