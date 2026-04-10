## ADDED Requirements

### Requirement: IMAP list-line parsing returns nil on invalid range
The `parseListLine(_:)` method SHALL use safe optional unwrapping for all `Range(_:in:)` conversions and SHALL return `nil` if any capture group range cannot be converted, rather than force-unwrapping and crashing.

#### Scenario: Well-formed IMAP LIST response line
- **WHEN** `parseListLine` receives a valid IMAP LIST response such as `* LIST (\HasNoChildren) "." "INBOX"`
- **THEN** an `IMAPFolder` is returned with correct name, delimiter, and flags

#### Scenario: Malformed IMAP response with invalid range
- **WHEN** `parseListLine` receives a line where a regex capture group range cannot be converted to a Swift `Range<String.Index>`
- **THEN** the method returns `nil` without crashing

#### Scenario: Empty or unrecognized line
- **WHEN** `parseListLine` receives a line that does not match the expected pattern
- **THEN** the method returns `nil` without crashing

### Requirement: OAuth authorization URL is built safely
The `buildAuthURL` method (or equivalent URL construction in `GoogleOAuthService`) SHALL use a `guard let` to unwrap `URLComponents.url` and SHALL throw `GoogleOAuthError.notConfigured` if the URL cannot be constructed, rather than force-unwrapping.

#### Scenario: Valid OAuth configuration produces a URL
- **WHEN** all `URLComponents` fields contain valid, encodable values
- **THEN** the method returns a valid `URL` without error

#### Scenario: Invalid component character causes graceful failure
- **WHEN** a query item value contains a character that prevents `URLComponents.url` from producing a URL
- **THEN** the method throws `GoogleOAuthError.notConfigured` without crashing

### Requirement: OAuth presentation anchor never crashes
The `PresentationContextProvider.presentationAnchor(for:)` method SHALL return a valid `ASPresentationAnchor` without force-unwrapping, even when the application has no key window or no windows at all.

#### Scenario: Application has a key window
- **WHEN** `NSApplication.shared.keyWindow` is non-nil at the time of the call
- **THEN** the key window is returned as the presentation anchor

#### Scenario: Application has windows but no key window
- **WHEN** `NSApplication.shared.keyWindow` is nil
- **AND** `NSApplication.shared.windows` is non-empty
- **THEN** `windows.first` is returned as the presentation anchor without crashing

#### Scenario: Application has no windows
- **WHEN** both `keyWindow` and `windows.first` are nil (e.g., headless launch or early startup)
- **THEN** a fallback `NSWindow()` is returned and no crash occurs

### Requirement: Schedule date calculation handles absent day component
The next-scheduled-date calculation in `BackupManager+Scheduling` SHALL use safe optional binding when incrementing `DateComponents.day` and SHALL behave gracefully if the `.day` field is absent.

#### Scenario: Day component is present and tomorrow is calculated correctly
- **WHEN** `components.day` is populated by `Calendar.dateComponents`
- **THEN** `components.day` is incremented by 1 to produce a next-day date

#### Scenario: Day component is absent
- **WHEN** `Calendar.dateComponents` does not populate the `.day` field
- **THEN** the increment is skipped without crashing, and `calendar.date(from:)` is still called with the unchanged components
