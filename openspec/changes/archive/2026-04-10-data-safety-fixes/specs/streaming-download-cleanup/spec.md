## ADDED Requirements

### Requirement: Streaming temp files are deleted on retry and final failure

When a streaming email download fails, the temp file written so far SHALL be deleted before the next retry attempt begins, and unconditionally after all retry attempts are exhausted. A partial temp file MUST NOT persist on disk after the download has failed.

#### Scenario: Temp file deleted before retry sleep
- **WHEN** a streaming download attempt throws an error
- **AND** retry attempts remain
- **THEN** the temp file at `tempURL` is removed from disk before the retry delay begins

#### Scenario: Temp file deleted after final failure
- **WHEN** all retry attempts for a streaming download have been exhausted
- **AND** `lastError` is non-nil
- **THEN** the temp file at `tempURL` is removed from disk before the error is recorded in progress

#### Scenario: Missing temp file on cleanup does not throw
- **WHEN** cleanup of the temp file is attempted
- **AND** the temp file does not exist (e.g. was never written or already removed)
- **THEN** no error is thrown and the retry or failure path continues normally
