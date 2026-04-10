## Context

`IMAPService` communicates with IMAP servers over `NWConnection`. All response reading is funnelled through `readResponse()`, which wraps a single `NWConnection.receive` call and returns a `String`. The current implementation attempts `String(data:encoding:.utf8)` and falls back to returning `""` when decoding fails. Because every control loop in the codebase (IDLE reader, `sendCommand`, `performStreamingFetch`, `fetchNewUIDs`, `sendDone`) drives on a non-empty tagged-response substring, an empty string from `readResponse()` causes those loops to spin forever.

`performStreamingFetch` additionally uses `String` as the transport for the email body bytes. Binary content that is not valid UTF-8 (raw attachment data, 8-bit encoded bodies) is silently dropped by `String(data:encoding:.utf8)`, producing a truncated file on disk. The in-memory path `fetchEmailWithLiteralParsing` already operates entirely on raw `Data` and is not affected.

## Goals / Non-Goals

**Goals:**
- `readResponse()` MUST always return a non-empty string (or throw) so no read loop can spin on empty input.
- `performStreamingFetch` MUST write every byte from the server to disk without any UTF-8 round-trip.
- Changes MUST NOT alter the observable protocol behaviour for well-formed UTF-8 responses.

**Non-Goals:**
- Refactoring all call-sites of `readResponse()` beyond making them safe with the encoding fix.
- Replacing `NWConnection` with a different networking layer.
- Handling IMAP server responses that use non-ASCII encodings in their protocol text (the IMAP wire protocol is ASCII/UTF-8 for all tagged and untagged status lines; only literal body content is binary).

## Decisions

### D1 — `readResponse()` falls back to `.isoLatin1` instead of throwing

**Decision:** When `String(data:encoding:.utf8)` fails, decode with `.isoLatin1` (ISO 8859-1) rather than throwing `IMAPError.receiveFailed`.

**Rationale:** ISO 8859-1 is a strict superset of ASCII and maps every possible byte value 0x00–0xFF to a Unicode code point; it can never fail. This means `readResponse()` always returns a non-empty string for any non-empty `Data`. Tagged response substrings (e.g., `A0001 OK`) are always pure ASCII and survive the fallback without distortion, so all termination checks continue to work correctly. Throwing instead would require every call-site to handle a new error path that did not previously exist, which is a larger, riskier change.

**Alternative considered:** Throw `IMAPError.receiveFailed("Non-UTF-8 response")`. Rejected because: (a) it would surface as a user-visible error for ordinary emails with binary attachments, (b) it is a larger diff touching all callers, and (c) the root cause (binary body bytes arriving in `readResponse`) is better addressed at the streaming layer (D2).

### D2 — `performStreamingFetch` uses a raw `Data` receive loop for the body

**Decision:** Once the literal size and start offset are known, `performStreamingFetch` uses `NWConnection.receive` directly (the same pattern as `fetchEmailWithLiteralParsing`) to read body chunks as `Data` and writes them to `FileHandle` without any String conversion.

**Rationale:** `fetchEmailWithLiteralParsing` already proves this approach works and handles all binary content correctly. Reusing the same `Data`-native loop removes the corruption entirely. The header scan (searching for `{size}\r\n`) can remain String-based because the IMAP fetch response header is guaranteed ASCII.

**Alternative considered:** Pass a `Data`-returning variant of `readResponse()` through all existing callers. Rejected: it duplicates the transport layer and all existing callers only need the String version for protocol text.

### D3 — Header parsing in `performStreamingFetch` remains String-based

**Decision:** The phase that scans for `{size}\r\n` continues to use `readResponse()` (String) because the IMAP fetch response header (everything before the literal) is pure ASCII by RFC 3501. Only the subsequent literal bytes switch to raw `Data` receive calls.

**Rationale:** Keeps the change minimal. The bug is in the body-writing phase, not the header-scanning phase.

## Risks / Trade-offs

- **ISO 8859-1 round-trip in IDLE reader**: The IDLE reader now decodes binary bytes as ISO 8859-1 if they ever appear. In practice the IDLE protocol stream is entirely ASCII; the fallback is a safety net only.
- **Partial-chunk boundary at literal start**: The first `readResponse()` call in `performStreamingFetch` may return bytes that span the `}\r\n` boundary and include the first bytes of the literal body. The new raw-`Data` loop must correctly account for bytes already received in the header phase — this is the same bookkeeping already solved in `fetchEmailWithLiteralParsing`.

## Migration Plan

1. Modify `readResponse()` — single-line change, no call-site updates needed.
2. Rewrite the body-write section of `performStreamingFetch` to use raw `Data` receives.
3. Build and run existing unit tests; add new tests per specs.
4. No data migration or rollback strategy needed; the change is entirely in-process.

## Open Questions

- None. Both fixes are well-bounded with clear precedent in the existing codebase.
