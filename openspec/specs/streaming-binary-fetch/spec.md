### Requirement: performStreamingFetch preserves all bytes of email body
`performStreamingFetch` SHALL write every byte of the IMAP literal body to the destination file without loss, including bytes with values 0x80–0xFF. It SHALL NOT pass email body bytes through any `String` encoding or decoding step.

#### Scenario: Binary attachment bytes are written intact
- **WHEN** `performStreamingFetch` fetches an email whose IMAP literal body contains bytes that are not valid UTF-8 (e.g., a JPEG attachment encoded in binary)
- **THEN** the output file on disk contains exactly those bytes in the same order, with no bytes dropped or substituted

#### Scenario: File byte count matches server-advertised literal size
- **WHEN** the server responds with `{N}` where N is the literal size
- **THEN** the output file written by `performStreamingFetch` contains exactly N bytes of email body content

#### Scenario: Pure ASCII email body is unaffected
- **WHEN** `performStreamingFetch` fetches an email whose body is pure ASCII text
- **THEN** the output file matches the server-sent bytes exactly, identical to the result from `fetchEmailWithLiteralParsing` for the same message

### Requirement: performStreamingFetch uses raw Data receive for body bytes
The body-writing phase of `performStreamingFetch` SHALL call `NWConnection.receive` directly and work with `Data` values. It SHALL NOT call `readResponse()` for any chunk that is known to be part of the email body literal.

#### Scenario: No String round-trip during body write
- **WHEN** `performStreamingFetch` is writing the literal body portion of a fetch response
- **THEN** each received `Data` chunk is written directly to the `FileHandle` without conversion to `String`

### Requirement: Header scan phase remains unaffected
`performStreamingFetch` SHALL continue to use its existing string-based approach for scanning the IMAP fetch response header (the portion before the literal, which contains the `{size}` token). The switch to raw `Data` receive SHALL apply only after the `{size}\r\n` boundary has been identified.

#### Scenario: Literal size is correctly parsed before body streaming begins
- **WHEN** the server sends a fetch response header containing `{12345}\r\n`
- **THEN** `performStreamingFetch` correctly identifies 12345 as the expected body size before beginning the raw `Data` receive loop
