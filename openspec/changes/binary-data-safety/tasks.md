## 1. Fix readResponse() encoding fallback

- [x] 1.1 In `IMAPService.readResponse()` (IMAPService.swift ~line 812), replace the `String(data:encoding:.utf8)` guard with a two-step decode: attempt UTF-8 first, fall back to `.isoLatin1` if that fails, so the method never returns `""` due to an encoding failure
- [x] 1.2 Verify that the `else` branch (currently `continuation.resume(returning: "")`) now only fires when `data` is nil or empty — not on encoding failure
- [x] 1.3 Add a unit test: inject raw bytes containing 0x80–0xFF into a mock `NWConnection`; assert `readResponse()` returns a non-empty string
- [x] 1.4 Add a unit test: inject a chunk mixing non-UTF-8 bytes with the ASCII string `A0001 OK\r\n`; assert the returned string contains `A0001 OK`

## 2. Fix performStreamingFetch binary body corruption

- [x] 2.1 In `performStreamingFetch` (IMAPService.swift ~line 618), keep the existing `readResponse()`-based header scan loop that locates `{size}\r\n` and captures any body bytes already received in the header chunk as `Data` (not `String`)
- [x] 2.2 Replace the streaming body-write loop (lines ~649–663) with a raw `Data` receive loop using `NWConnection.receive` directly, mirroring the pattern in `fetchEmailWithLiteralParsing`; write each received `Data` chunk directly to `FileHandle` without converting to `String`
- [x] 2.3 Ensure the bookkeeping for `literalBytesReceived` / `totalBytesWritten` is updated in the new `Data`-based loop
- [x] 2.4 Ensure the completion check (detection of the tagged response line after the literal body) still works in the new loop; the tagged response is ASCII and survives `String(data:encoding:.utf8)` or `.ascii` decoding on the trailing bytes
- [x] 2.5 Remove the now-unused `chunk.data(using: .utf8) ?? chunk.data(using: .ascii)` conversion calls from the streaming section

## 3. Tests for streaming binary fetch

- [x] 3.1 Add a unit test: create a mock IMAP fetch response containing a binary literal (bytes 0x00–0xFF in sequence); assert the output file matches the input bytes exactly (no bytes dropped)
- [x] 3.2 Add a unit test: assert that the output file byte count equals the `{N}` literal size advertised in the mock server response
- [x] 3.3 Add a unit test: fetch a pure-ASCII email body via `performStreamingFetch` and assert the output matches the input bytes, confirming no regression for the common case

## 4. Regression check

- [x] 4.1 Run the full test suite (`xcodebuild test`) and confirm all existing IMAP and IDLE tests pass
- [ ] 4.2 Manually test backup of an account that contains emails with binary attachments; confirm downloaded `.eml` files open correctly in Mail.app
