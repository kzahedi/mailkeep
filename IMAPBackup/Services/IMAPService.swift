import Foundation
import Network

// MARK: - Sensitive Data Redaction

/// Redacts sensitive data from log messages to prevent credential leakage
private func redactSensitiveData(_ message: String) -> String {
    var result = message

    // Redact LOGIN command passwords: LOGIN "user" "password" -> LOGIN "user" "[REDACTED]"
    if let loginRange = result.range(of: #"LOGIN\s+"[^"]*"\s+"[^"]*""#, options: .regularExpression) {
        // Find the second quoted string (password) and redact it
        let loginPart = String(result[loginRange])
        if let passwordMatch = loginPart.range(of: #""\s+"[^"]*"$"#, options: .regularExpression) {
            let redacted = loginPart.replacingCharacters(in: passwordMatch, with: "\" \"[REDACTED]\"")
            result = result.replacingCharacters(in: loginRange, with: redacted)
        }
    }

    // Redact AUTHENTICATE XOAUTH2 tokens: AUTHENTICATE XOAUTH2 <token> -> AUTHENTICATE XOAUTH2 [REDACTED]
    if let authRange = result.range(of: #"AUTHENTICATE\s+XOAUTH2\s+\S+"#, options: .regularExpression) {
        result = result.replacingCharacters(in: authRange, with: "AUTHENTICATE XOAUTH2 [REDACTED]")
    }

    // Redact any base64-encoded OAuth tokens (they start with eyJ for JWT)
    result = result.replacingOccurrences(
        of: #"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
        with: "[REDACTED_TOKEN]",
        options: .regularExpression
    )

    // Redact any standalone base64 strings that look like tokens (40+ chars of base64)
    result = result.replacingOccurrences(
        of: #"(?<![A-Za-z0-9])[A-Za-z0-9+/=]{40,}(?![A-Za-z0-9])"#,
        with: "[REDACTED_TOKEN]",
        options: .regularExpression
    )

    return result
}

// Simple trace logging to file and stderr with sensitive data redaction
private func trace(_ msg: String) {
    let sanitizedMsg = redactSensitiveData(msg)
    let line = "\(Date()): \(sanitizedMsg)\n"

    #if DEBUG
    fputs(line, stderr)
    #endif

    // Also write to Documents folder (only in debug builds for security)
    #if DEBUG
    let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let logURL = docsURL.appendingPathComponent("imap_trace.log")
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let fh = try? FileHandle(forWritingTo: logURL) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            }
        } else {
            try? data.write(to: logURL)
        }
    }
    #endif
}

/// IMAP Service for connecting to mail servers and fetching emails
actor IMAPService {
    private var connection: NWConnection?
    private var isConnected = false
    private var responseBuffer = ""
    private(set) var tagCounter = 0
    private var currentFolder: String?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 3

    private let account: EmailAccount
    private var throttleTracker: ThrottleTracker?
    private var rateLimitSettings: RateLimitSettings

    init(account: EmailAccount) {
        self.account = account
        self.rateLimitSettings = RateLimitSettings.default
    }

    /// Configure rate limiting for this service with a shared tracker
    /// The tracker should be shared between accounts on the same server
    func configureRateLimit(settings: RateLimitSettings, sharedTracker: ThrottleTracker? = nil) {
        self.rateLimitSettings = settings
        if let tracker = sharedTracker {
            self.throttleTracker = tracker
        } else {
            self.throttleTracker = ThrottleTracker(settings: settings)
        }
    }

    /// Update rate limit settings on a running service
    /// This allows settings changes to take effect immediately without restarting the backup
    func updateRateLimitSettings(_ settings: RateLimitSettings) async {
        self.rateLimitSettings = settings
        await self.throttleTracker?.updateSettings(settings)
    }

    /// Get or create throttle tracker
    private func getThrottleTracker() -> ThrottleTracker {
        if let tracker = throttleTracker {
            return tracker
        }
        let tracker = ThrottleTracker(settings: rateLimitSettings)
        throttleTracker = tracker
        return tracker
    }

    /// Apply rate limiting before a request
    private func applyRateLimit() async {
        guard rateLimitSettings.isEnabled else { return }
        await getThrottleTracker().waitForRateLimit()
    }

    /// Record throttling response from server
    private func recordThrottle() async {
        await getThrottleTracker().recordThrottle()
    }

    /// Record successful request
    private func recordSuccess() async {
        await getThrottleTracker().recordSuccess()
    }

    // MARK: - Connection Recovery

    /// Check if the connection appears to be healthy
    private func isConnectionHealthy() -> Bool {
        guard let conn = connection else { return false }
        return conn.state == .ready && isConnected
    }

    /// Attempt to reconnect with exponential backoff
    private func attemptReconnect() async throws {
        guard reconnectAttempts < maxReconnectAttempts else {
            logError("Max reconnection attempts (\(maxReconnectAttempts)) reached")
            throw IMAPError.connectionFailed("Max reconnection attempts reached")
        }

        reconnectAttempts += 1
        let delay = UInt64(pow(2.0, Double(reconnectAttempts - 1))) * Constants.nanosecondsPerSecond
        logInfo("Attempting reconnect (attempt \(reconnectAttempts)/\(maxReconnectAttempts)) after \(reconnectAttempts)s delay")

        try await Task.sleep(nanoseconds: delay)

        // Disconnect cleanly first
        await disconnect()

        // Reconnect
        try await connect()
        try await login()

        // Re-select folder if we had one selected
        if let folder = currentFolder {
            _ = try await selectFolder(folder)
        }

        logInfo("Reconnection successful")
        reconnectAttempts = 0  // Reset on success
    }

    /// Execute a command with automatic reconnection on failure
    private func executeWithRecovery<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            // Check if this is a connection error that we can recover from
            if isRecoverableError(error) {
                logWarning("Connection error detected: \(error.localizedDescription). Attempting recovery...")
                try await attemptReconnect()
                // Retry the operation once after reconnecting
                return try await operation()
            }
            throw error
        }
    }

    /// Determine if an error is recoverable via reconnection
    private func isRecoverableError(_ error: Error) -> Bool {
        if let imapError = error as? IMAPError {
            switch imapError {
            case .notConnected, .connectionFailed, .sendFailed, .receiveFailed:
                return true
            default:
                return false
            }
        }
        // Network errors are generally recoverable
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain ||
               nsError.domain == "NWError" ||
               nsError.code == -1009 || // No internet connection
               nsError.code == -1001    // Request timed out
    }

    // MARK: - Connection Management

    func connect() async throws {
        trace("[DEBUG] connect() START for \(account.email)")
        trace("connect() START for \(account.email)")
        let host = NWEndpoint.Host(account.imapServer)
        let port = NWEndpoint.Port(integerLiteral: UInt16(account.port))

        let tlsOptions = NWProtocolTLS.Options()
        let tcpOptions = NWProtocolTCP.Options()
        let params = NWParameters(tls: account.useSSL ? tlsOptions : nil, tcp: tcpOptions)

        connection = NWConnection(host: host, port: port, using: params)

        class ContinuationState {
            private let lock = NSLock()
            private var _hasResumed = false
            func tryResume() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard !_hasResumed else { return false }
                _hasResumed = true
                return true
            }
        }
        let state = ContinuationState()

        logInfo("Connecting to \(account.imapServer):\(account.port)...")

        return try await withCheckedThrowingContinuation { continuation in
            connection?.stateUpdateHandler = { [weak self] connectionState in
                trace("connect() state=\(connectionState)")
                switch connectionState {
                case .ready:
                    trace("[DEBUG] connect() READY")
                    trace("connect() READY")
                    guard state.tryResume() else { return }
                    Task { [weak self] in
                        await self?.setConnected(true)
                        continuation.resume()
                    }
                case .failed(let error):
                    trace("connect() FAILED: \(error)")
                    guard state.tryResume() else { return }
                    continuation.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    trace("connect() CANCELLED")
                    guard state.tryResume() else { return }
                    continuation.resume(throwing: IMAPError.connectionCancelled)
                default:
                    break
                }
            }
            connection?.start(queue: .global(qos: .userInitiated))
        }
    }

    private func setConnected(_ value: Bool) {
        isConnected = value
    }

    func disconnect() async {
        connection?.cancel()
        connection = nil
        isConnected = false
    }

    // MARK: - IMAP Commands

    func login(password: String? = nil) async throws {
        trace("login() START")
        // Read server greeting
        trace("login() reading greeting")
        _ = try await readResponse()
        trace("login() got greeting")

        // Check authentication type
        trace("[DEBUG] login() authType=\(account.authType)")
        if account.authType == .oauth2 {
            trace("[DEBUG] login() calling loginWithOAuth2()")
            try await loginWithOAuth2()
        } else {
            try await loginWithPassword(password: password)
        }
        trace("login() DONE")
    }

    /// Login with traditional password authentication
    private func loginWithPassword(password: String? = nil) async throws {
        trace("loginWithPassword() START")
        // Trim whitespace from credentials
        let username = account.username.trimmingCharacters(in: .whitespacesAndNewlines)

        // Get password from parameter or Keychain
        trace("loginWithPassword() getting password")
        let pwd: String
        if let p = password {
            pwd = p.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let p = await account.getPassword() {
            trace("loginWithPassword() got password from keychain")
            pwd = p.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            throw IMAPError.authenticationFailed
        }

        // Escape special characters in credentials
        let escapedUsername = username
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedPassword = pwd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // Send LOGIN command
        let response = try await sendCommand("LOGIN \"\(escapedUsername)\" \"\(escapedPassword)\"")

        // Check for success (OK) or failure (NO/BAD)
        if response.contains(" NO ") || response.contains(" BAD ") {
            throw IMAPError.authenticationFailed
        }

        guard response.contains("OK") else {
            throw IMAPError.authenticationFailed
        }
    }

    /// Login with OAuth2 XOAUTH2 SASL mechanism
    private func loginWithOAuth2() async throws {
        trace("[DEBUG] loginWithOAuth2() START for \(account.email)")
        // Get valid access token (refreshing if needed)
        let accessToken: String
        do {
            trace("[DEBUG] Getting access token...")
            accessToken = try await account.getValidAccessToken()
            trace("[DEBUG] Got access token (length: \(accessToken.count))")
        } catch {
            trace("[DEBUG] Failed to get OAuth access token: \(error.localizedDescription)")
            logError("Failed to get OAuth access token: \(error.localizedDescription)")
            throw IMAPError.authenticationFailed
        }

        // Generate XOAUTH2 token
        trace("[DEBUG] Generating XOAUTH2 token...")
        let xoauth2Token = GoogleOAuthService.generateXOAuth2Token(
            email: account.email,
            accessToken: accessToken
        )
        trace("[DEBUG] XOAUTH2 token generated (length: \(xoauth2Token.count))")

        // First, check CAPABILITY to ensure XOAUTH2 is supported
        trace("[DEBUG] Sending CAPABILITY command...")
        let capResponse = try await sendCommand("CAPABILITY")
        trace("[DEBUG] CAPABILITY response: \(capResponse.prefix(200))")
        guard capResponse.uppercased().contains("AUTH=XOAUTH2") else {
            trace("[DEBUG] Server does not support XOAUTH2!")
            logError("Server does not support XOAUTH2 authentication")
            throw IMAPError.authenticationFailed
        }

        // Send AUTHENTICATE XOAUTH2 command
        trace("[DEBUG] Sending AUTHENTICATE XOAUTH2 command...")
        let response = try await sendCommand("AUTHENTICATE XOAUTH2 \(xoauth2Token)")
        trace("[DEBUG] AUTHENTICATE response: \(response.prefix(200))")

        // Check for success (OK) or failure (NO/BAD)
        if response.contains(" NO ") || response.contains(" BAD ") {
            // Try to parse error for better debugging
            if response.contains("Invalid credentials") || response.contains("AUTHENTICATIONFAILED") {
                logError("OAuth2 authentication failed - token may be invalid or revoked")
            }
            throw IMAPError.authenticationFailed
        }

        guard response.contains("OK") else {
            throw IMAPError.authenticationFailed
        }

        logInfo("Successfully authenticated with OAuth2")
    }

    func logout() async throws {
        _ = try await sendCommand("LOGOUT")
        await disconnect()
    }

    func listFolders() async throws -> [IMAPFolder] {
        let response = try await sendCommand("LIST \"\" \"*\"")
        return parseListResponse(response)
    }

    func selectFolder(_ folder: String) async throws -> FolderStatus {
        // Encode folder name to IMAP modified UTF-7 for the server
        let encodedFolder = folder.encodingIMAPUTF7()
        let escapedFolder = encodedFolder.replacingOccurrences(of: "\"", with: "\\\"")
        let response = try await sendCommand("SELECT \"\(escapedFolder)\"")
        currentFolder = folder  // Track for reconnection (store decoded name)
        return parseFolderStatus(response)
    }

    func fetchEmailHeaders(uids: ClosedRange<UInt32>) async throws -> [EmailHeader] {
        let response = try await sendCommand(
            "UID FETCH \(uids.lowerBound):\(uids.upperBound) (UID FLAGS BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)] BODYSTRUCTURE)"
        )
        return parseEmailHeaders(response)
    }

    func fetchEmail(uid: UInt32) async throws -> Data {
        // Apply rate limiting before request
        await applyRateLimit()

        // Must use binary-safe fetch for emails with attachments
        let result = try await fetchEmailWithLiteralParsing(uid: uid)

        // Record success for adaptive rate limiting
        await recordSuccess()
        return result
    }

    /// Fetch email with proper IMAP literal parsing
    private func fetchEmailWithLiteralParsing(uid: UInt32) async throws -> Data {
        trace("fetchEmailWithLiteralParsing(\(uid)) START")
        guard let connection = connection else {
            throw IMAPError.notConnected
        }

        tagCounter += 1
        let tag = "A\(String(format: "%04d", tagCounter))"
        let command = "\(tag) UID FETCH \(uid) BODY.PEEK[]\r\n"

        // Send command
        trace("fetchEmailWithLiteralParsing: sending command")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: command.data(using: .utf8), completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: IMAPError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
        trace("fetchEmailWithLiteralParsing: command sent")

        // Simple state machine
        var allData = Data()
        var emailData = Data()
        var literalSize: Int? = nil
        var literalOffset: Int = 0

        while true {
            trace("fetchEmailWithLiteralParsing: reading chunk...")
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                    if let error = error {
                        continuation.resume(throwing: IMAPError.receiveFailed(error.localizedDescription))
                    } else if let data = data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: IMAPError.receiveFailed("No data received"))
                    }
                }
            }
            trace("fetchEmailWithLiteralParsing: got \(chunk.count) bytes")

            allData.append(chunk)
            trace("fetchEmailWithLiteralParsing: total \(allData.count) bytes, literalSize=\(literalSize ?? -1)")

            // Try to find literal size if we don't have it yet
            // IMPORTANT: Search in RAW BYTES, not string - because email body may contain binary data
            if literalSize == nil {
                // Search for {digits}\r\n pattern in raw bytes
                // ASCII codes: { = 123, } = 125, \r = 13, \n = 10, 0-9 = 48-57
                let openBrace: UInt8 = 123  // {
                let closeBrace: UInt8 = 125 // }
                let cr: UInt8 = 13          // \r
                let lf: UInt8 = 10          // \n

                // Find { in first 200 bytes (IMAP header is small)
                if let bracePos = allData.prefix(200).firstIndex(of: openBrace) {
                    // Find } after {
                    var endPos = bracePos + 1
                    var sizeDigits: [UInt8] = []
                    while endPos < allData.count && allData[endPos] != closeBrace {
                        let byte = allData[endPos]
                        if byte >= 48 && byte <= 57 { // 0-9
                            sizeDigits.append(byte)
                        }
                        endPos += 1
                    }

                    // Check for }\r\n sequence
                    if endPos < allData.count && allData[endPos] == closeBrace {
                        let hasFullSequence = endPos + 2 < allData.count &&
                                              allData[endPos + 1] == cr &&
                                              allData[endPos + 2] == lf

                        if hasFullSequence && !sizeDigits.isEmpty {
                            if let sizeStr = String(bytes: sizeDigits, encoding: .ascii),
                               let size = Int(sizeStr) {
                                literalSize = size
                                literalOffset = endPos + 3 // After }\r\n
                                trace("fetchEmailWithLiteralParsing: FOUND literal size=\(size), offset=\(literalOffset)")
                            }
                        }
                    }
                }
            }

            // If we know the literal size, check if we have all the data
            if let size = literalSize {
                let availableBytes = allData.count - literalOffset
                trace("fetchEmailWithLiteralParsing: need \(size) bytes, have \(availableBytes)")

                if availableBytes >= size {
                    // We have all the literal data
                    emailData = Data(allData[literalOffset..<(literalOffset + size)])
                    trace("fetchEmailWithLiteralParsing: extracted \(emailData.count) bytes of email")

                    // Check if tagged response is present after the literal
                    // The tagged response should be ASCII text after the binary literal
                    let afterLiteralStart = literalOffset + size
                    let afterLiteral = allData.suffix(from: afterLiteralStart)
                    trace("fetchEmailWithLiteralParsing: afterLiteral has \(afterLiteral.count) bytes")

                    // Convert to string - this part should be ASCII (IMAP protocol)
                    if let afterStr = String(data: afterLiteral, encoding: .utf8) ?? String(data: afterLiteral, encoding: .ascii) {
                        trace("fetchEmailWithLiteralParsing: afterStr='\(afterStr.prefix(80).replacingOccurrences(of: "\r\n", with: "\\r\\n"))'")
                        if afterStr.contains("\(tag) OK") || afterStr.contains("\(tag) NO") || afterStr.contains("\(tag) BAD") {
                            trace("fetchEmailWithLiteralParsing: COMPLETE - found tagged response")
                            break
                        }
                    } else {
                        // Even if we can't convert, check raw bytes for tag
                        let tagBytes = Data(tag.utf8)
                        let okBytes = Data(" OK".utf8)
                        let noBytes = Data(" NO".utf8)
                        let badBytes = Data(" BAD".utf8)

                        if afterLiteral.range(of: tagBytes + okBytes) != nil ||
                           afterLiteral.range(of: tagBytes + noBytes) != nil ||
                           afterLiteral.range(of: tagBytes + badBytes) != nil {
                            trace("fetchEmailWithLiteralParsing: COMPLETE - found tagged response in raw bytes")
                            break
                        }
                    }
                }
            }

            // Safety check - don't accumulate more than maxEmailSizeBytes
            if allData.count > Constants.maxEmailSizeBytes {
                throw IMAPError.receiveFailed("Response too large")
            }
        }

        trace("fetchEmailWithLiteralParsing: DONE, got \(emailData.count) bytes")
        return emailData
    }

    /// Fetch email size without downloading the full body
    func fetchEmailSize(uid: UInt32) async throws -> Int {
        // Apply rate limiting before request
        await applyRateLimit()

        let response = try await sendCommand("UID FETCH \(uid) RFC822.SIZE")
        let size = extractEmailSize(from: response)

        // Record success for adaptive rate limiting
        await recordSuccess()
        return size
    }

    /// Stream email directly to file for large messages
    func streamEmailToFile(uid: UInt32, destinationURL: URL) async throws -> Int64 {
        // Apply rate limiting before request
        await applyRateLimit()

        let result = try await performStreamingFetch(uid: uid, destinationURL: destinationURL)

        // Record success for adaptive rate limiting
        await recordSuccess()
        return result
    }

    /// Perform streaming fetch directly to disk
    private func performStreamingFetch(uid: UInt32, destinationURL: URL) async throws -> Int64 {
        guard let connection = connection else {
            throw IMAPError.notConnected
        }

        tagCounter += 1
        let tag = "A\(String(format: "%04d", tagCounter))"
        let command = "\(tag) UID FETCH \(uid) BODY.PEEK[]\r\n"

        // Create temp file for streaming
        let tempURL = destinationURL.appendingPathExtension("streaming")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tempURL)

        defer {
            try? fileHandle.close()
        }

        // Send command
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: command.data(using: .utf8),
                completion: .contentProcessed { error in
                    if let error = error {
                        continuation.resume(throwing: IMAPError.sendFailed(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                }
            )
        }

        // Read response and stream to file
        var totalBytesWritten: Int64 = 0
        var headerBuffer = ""
        var literalSize: Int = 0
        var literalBytesReceived: Int = 0
        var isComplete = false

        // Phase 1: String-based header scan to locate {size}\r\n.
        // IMAP headers and status lines are ASCII, so readResponse() is safe here.
        // readResponse() now falls back to .isoLatin1 so non-ASCII server text won't
        // stall the loop by returning "".
        while !isComplete {
            let chunk = try await readResponse()
            headerBuffer += chunk

            if let braceStart = headerBuffer.range(of: "{"),
               let braceEnd = headerBuffer.range(of: "}", range: braceStart.upperBound..<headerBuffer.endIndex) {

                let sizeString = String(headerBuffer[braceStart.upperBound..<braceEnd.lowerBound])
                if let size = Int(sizeString) {
                    literalSize = size
                    logDebug("Streaming email UID \(uid): \(size) bytes")

                    // Write any body bytes that arrived in the same chunk as the header.
                    // Use .isoLatin1 (bijective for all 256 byte values) so binary bytes
                    // in the pre-body overshoot are preserved exactly (C3).
                    if let dataStart = headerBuffer.range(of: "}\r\n")?.upperBound {
                        let remainingStr = String(headerBuffer[dataStart...])
                        if let data = remainingStr.data(using: .isoLatin1) {
                            let bytesToWrite = min(data.count, literalSize)
                            if bytesToWrite > 0 {
                                try fileHandle.write(contentsOf: data.prefix(bytesToWrite))
                                literalBytesReceived += bytesToWrite
                                totalBytesWritten += Int64(bytesToWrite)
                            }
                        }
                    }
                    break  // Found literal size — switch to raw Data phase
                }
            }

            // Tagged response may arrive in the same chunk as the header (e.g. empty body)
            if chunk.contains("\(tag) OK") || chunk.contains("\(tag) NO") || chunk.contains("\(tag) BAD") {
                isComplete = true
            }
        }

        // Phase 2: Raw Data receive loop — reads bytes directly from NWConnection without
        // any String conversion, so binary email content is written to disk intact (C3).
        while !isComplete {
            let rawData: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                    if let error = error {
                        continuation.resume(throwing: IMAPError.receiveFailed(error.localizedDescription))
                    } else if let data = data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: IMAPError.receiveFailed("No data received"))
                    }
                }
            }

            // Write body bytes up to the declared literal size
            let bytesRemaining = literalSize - literalBytesReceived
            if bytesRemaining > 0 {
                let bytesToWrite = min(rawData.count, bytesRemaining)
                if bytesToWrite > 0 {
                    try fileHandle.write(contentsOf: rawData.prefix(bytesToWrite))
                    literalBytesReceived += bytesToWrite
                    totalBytesWritten += Int64(bytesToWrite)
                }
            }

            // Check for the IMAP tagged response after all body bytes are received.
            // The tagged response is ASCII; searching raw bytes for the tag is safe.
            if literalBytesReceived >= literalSize {
                let tagBytes = Data(tag.utf8)
                if rawData.range(of: tagBytes + Data(" OK".utf8)) != nil ||
                   rawData.range(of: tagBytes + Data(" NO".utf8)) != nil ||
                   rawData.range(of: tagBytes + Data(" BAD".utf8)) != nil {
                    isComplete = true
                }
            }
        }

        // Close file handle
        try fileHandle.close()

        // Move temp file to final destination
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)

        return totalBytesWritten
    }

    /// Extract email size from RFC822.SIZE response
    private func extractEmailSize(from response: String) -> Int {
        // Response format: * uid FETCH (RFC822.SIZE size)
        let pattern = #"RFC822\.SIZE\s+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
              let sizeRange = Range(match.range(at: 1), in: response) else {
            return 0
        }
        return Int(response[sizeRange]) ?? 0
    }

    func searchAll() async throws -> [UInt32] {
        // Apply rate limiting before request
        await applyRateLimit()

        let response = try await sendCommand("UID SEARCH ALL")
        let uids = parseSearchResponse(response)

        // Record success for adaptive rate limiting
        await recordSuccess()
        return uids
    }

    // MARK: - Internal helpers for extension files

    /// Generate the next IMAP command tag (e.g., "A0001").
    /// Shared with IMAPService+IDLE.swift for non-standard send/receive patterns.
    func nextTag() -> String {
        tagCounter += 1
        return "A\(String(format: "%04d", tagCounter))"
    }

    /// Send raw bytes over the connection without automatic tag handling.
    /// Use for commands with non-standard send/receive sequences (e.g., IDLE, DONE).
    func sendRaw(_ string: String) async throws {
        guard let connection = connection else {
            throw IMAPError.notConnected
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: string.data(using: .utf8), completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: IMAPError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - Low-level Communication

    private func sendCommand(_ command: String) async throws -> String {
        trace("sendCommand(\(command.prefix(30))...)")
        guard let connection = connection else {
            throw IMAPError.notConnected
        }

        tagCounter += 1
        let tag = "A\(String(format: "%04d", tagCounter))"
        let fullCommand = "\(tag) \(command)\r\n"

        // Send command
        trace("sendCommand: sending...")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: fullCommand.data(using: .utf8),
                completion: .contentProcessed { error in
                    if let error = error {
                        trace("sendCommand: send error \(error)")
                        continuation.resume(throwing: IMAPError.sendFailed(error.localizedDescription))
                    } else {
                        trace("sendCommand: sent OK")
                        continuation.resume()
                    }
                }
            )
        }

        // Read response until we get the tagged response
        trace("sendCommand: reading response...")
        trace("[DEBUG] sendCommand: reading response for tag \(tag)...")
        var fullResponse = ""
        while true {
            let chunk = try await readResponse()
            fullResponse += chunk
            trace("sendCommand: got chunk \(chunk.count) chars")
            trace("[DEBUG] sendCommand: got chunk: \(chunk.prefix(200))")

            // Check for SASL continuation (+ response) - need to handle auth errors
            if chunk.hasPrefix("+ ") || chunk.contains("\r\n+ ") {
                trace("[DEBUG] sendCommand: got SASL continuation, sending empty response")
                // Send empty response to complete SASL exchange
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    connection.send(content: "\r\n".data(using: .utf8), completion: .contentProcessed { error in
                        if let error = error {
                            continuation.resume(throwing: IMAPError.sendFailed(error.localizedDescription))
                        } else {
                            continuation.resume()
                        }
                    })
                }
                continue
            }

            // Check if we have the complete tagged response
            if chunk.contains("\(tag) OK") || chunk.contains("\(tag) NO") || chunk.contains("\(tag) BAD") {
                trace("sendCommand: got tagged response")
                trace("[DEBUG] sendCommand: got tagged response")
                break
            }
        }

        return fullResponse
    }

    func readResponse() async throws -> String {
        guard let connection = connection else {
            throw IMAPError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error = error {
                    trace("readResponse: error \(error)")
                    continuation.resume(throwing: IMAPError.receiveFailed(error.localizedDescription))
                    return
                }

                if let data = data, !data.isEmpty {
                    // Attempt UTF-8 first; fall back to ISO Latin-1 which is bijective over
                    // all 256 byte values and never fails. This prevents non-UTF-8 bytes
                    // (binary attachments, non-UTF-8 server error text) from returning ""
                    // and causing while-true read loops to spin forever (C2).
                    let response = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1)
                        ?? ""
                    trace("readResponse: got \(data.count) bytes")
                    continuation.resume(returning: response)
                } else {
                    trace("readResponse: no data")
                    continuation.resume(returning: "")
                }
            }
        }
    }

    // MARK: - Response Parsing

    private func parseListResponse(_ response: String) -> [IMAPFolder] {
        var folders: [IMAPFolder] = []
        let lines = response.components(separatedBy: "\r\n")

        for line in lines {
            // Parse lines like: * LIST (\HasNoChildren) "/" "INBOX"
            if line.hasPrefix("* LIST") || line.hasPrefix("* LSUB") {
                if let folder = parseListLine(line) {
                    folders.append(folder)
                }
            }
        }

        return folders
    }

    private func parseListLine(_ line: String) -> IMAPFolder? {
        // Match pattern: * LIST (flags) "delimiter" "name"
        let pattern = #"\* (?:LIST|LSUB) \(([^)]*)\) "(.)" "?([^"]+)"?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }

        guard let flagsRange = Range(match.range(at: 1), in: line),
              let delimiterRange = Range(match.range(at: 2), in: line),
              let nameRange = Range(match.range(at: 3), in: line) else {
            return nil
        }

        let flags = String(line[flagsRange])
        let delimiter = String(line[delimiterRange])
        let rawName = String(line[nameRange])

        // Decode IMAP modified UTF-7 encoding (RFC 3501)
        let name = rawName.decodingIMAPUTF7()

        return IMAPFolder(
            name: name,
            delimiter: delimiter,
            flags: flags.components(separatedBy: " "),
            path: name.replacingOccurrences(of: delimiter, with: "/")
        )
    }

    private func parseFolderStatus(_ response: String) -> FolderStatus {
        var exists = 0
        var recent = 0
        var uidNext: UInt32 = 0
        var uidValidity: UInt32 = 0

        let lines = response.components(separatedBy: "\r\n")
        for line in lines {
            if line.contains("EXISTS") {
                exists = Int(line.components(separatedBy: " ").first(where: { Int($0) != nil }) ?? "0") ?? 0
            }
            if line.contains("RECENT") {
                recent = Int(line.components(separatedBy: " ").first(where: { Int($0) != nil }) ?? "0") ?? 0
            }
            if line.contains("UIDNEXT") {
                if let match = line.range(of: #"UIDNEXT (\d+)"#, options: .regularExpression) {
                    let numStr = line[match].replacingOccurrences(of: "UIDNEXT ", with: "")
                    uidNext = UInt32(numStr) ?? 0
                }
            }
            if line.contains("UIDVALIDITY") {
                if let match = line.range(of: #"UIDVALIDITY (\d+)"#, options: .regularExpression) {
                    let numStr = line[match].replacingOccurrences(of: "UIDVALIDITY ", with: "")
                    uidValidity = UInt32(numStr) ?? 0
                }
            }
        }

        return FolderStatus(exists: exists, recent: recent, uidNext: uidNext, uidValidity: uidValidity)
    }

    private func parseEmailHeaders(_ response: String) -> [EmailHeader] {
        // Simplified parsing - in production, use a proper MIME parser
        var headers: [EmailHeader] = []
        // TODO: Implement proper FETCH response parsing
        return headers
    }

    func parseSearchResponse(_ response: String) -> [UInt32] {
        var uids: [UInt32] = []
        let lines = response.components(separatedBy: "\r\n")

        for line in lines {
            if line.hasPrefix("* SEARCH") {
                let parts = line.replacingOccurrences(of: "* SEARCH", with: "").trimmingCharacters(in: .whitespaces)
                for part in parts.components(separatedBy: " ") {
                    if let uid = UInt32(part) {
                        uids.append(uid)
                    }
                }
            }
        }

        return uids
    }

    private func extractEmailData(from response: String) -> Data {
        // Extract the literal email data from FETCH response
        // IMAP FETCH response format: * UID FETCH (BODY[] {size}\r\n<data>\r\n)

        // Find the literal size marker {size}
        // Look for pattern like "BODY[] {" or just find the first {digits}
        guard let braceStart = response.range(of: "{") else {
            logError("extractEmailData: No '{' found. Response length: \(response.count), preview: \(String(response.prefix(500)))")
            return Data()
        }

        guard let braceEnd = response.range(of: "}", range: braceStart.upperBound..<response.endIndex) else {
            logError("extractEmailData: No '}' found. Response preview: \(String(response.prefix(500)))")
            return Data()
        }

        // Parse the size
        let sizeString = String(response[braceStart.upperBound..<braceEnd.lowerBound])
        guard let size = Int(sizeString), size > 0 else {
            logError("extractEmailData: Invalid size '\(sizeString)'. Response preview: \(String(response.prefix(500)))")
            return Data()
        }

        // The data starts after }\r\n
        // Convert to UTF8 bytes for accurate positioning
        let responseData = Data(response.utf8)

        // Find the position of } in the data
        let braceEndUtf8Offset = response[..<braceEnd.upperBound].utf8.count

        // Skip past }\r\n (typically 3 bytes: }, \r, \n)
        var dataStart = braceEndUtf8Offset
        if dataStart < responseData.count && responseData[dataStart] == 0x0D { // \r
            dataStart += 1
        }
        if dataStart < responseData.count && responseData[dataStart] == 0x0A { // \n
            dataStart += 1
        }

        // Extract exactly 'size' bytes
        let dataEnd = min(dataStart + size, responseData.count)
        if dataStart < dataEnd {
            return responseData[dataStart..<dataEnd]
        }

        return Data()
    }
}

// MARK: - Supporting Types

struct IMAPFolder: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let delimiter: String
    let flags: [String]
    let path: String

    var isSelectable: Bool {
        !flags.contains("\\Noselect")
    }
}

struct FolderStatus {
    let exists: Int
    let recent: Int
    let uidNext: UInt32
    let uidValidity: UInt32
}

struct EmailHeader {
    let uid: UInt32
    let messageId: String
    let from: String
    let subject: String
    let date: Date
    let hasAttachments: Bool
    let size: Int
}

// MARK: - Errors

enum IMAPError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case connectionCancelled
    case authenticationFailed
    case sendFailed(String)
    case receiveFailed(String)
    case folderNotFound(String)
    case fetchFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to server"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .connectionCancelled:
            return "Connection was cancelled"
        case .authenticationFailed:
            return "Authentication failed - check username and password"
        case .sendFailed(let reason):
            return "Failed to send command: \(reason)"
        case .receiveFailed(let reason):
            return "Failed to receive response: \(reason)"
        case .folderNotFound(let name):
            return "Folder not found: \(name)"
        case .fetchFailed(let reason):
            return "Failed to fetch email: \(reason)"
        case .commandFailed(let reason):
            return "Command failed: \(reason)"
        }
    }
}

// MARK: - IMAP Modified UTF-7 Decoding (RFC 3501)

extension String {
    /// Decode IMAP modified UTF-7 encoding to UTF-8
    /// IMAP uses a modified UTF-7 where:
    /// - ASCII printable chars (except &) pass through unchanged
    /// - "&" is encoded as "&-"
    /// - Non-ASCII chars are encoded as "&" + modified base64 + "-"
    /// - Modified base64 uses "," instead of "/" and encodes UTF-16BE
    func decodingIMAPUTF7() -> String {
        var result = ""
        var i = startIndex

        while i < endIndex {
            let char = self[i]

            if char == "&" {
                // Start of encoded sequence
                let nextIndex = index(after: i)
                if nextIndex < endIndex && self[nextIndex] == "-" {
                    // "&-" represents literal "&"
                    result.append("&")
                    i = index(after: nextIndex)
                } else {
                    // Find the end of the encoded sequence
                    if let dashIndex = self[nextIndex...].firstIndex(of: "-") {
                        let encodedPart = String(self[nextIndex..<dashIndex])
                        // Convert from modified base64 to standard base64
                        let standardBase64 = encodedPart.replacingOccurrences(of: ",", with: "/")
                        // Add padding if needed
                        let paddedBase64 = standardBase64.padding(toLength: ((standardBase64.count + 3) / 4) * 4,
                                                                   withPad: "=",
                                                                   startingAt: 0)
                        // Decode base64 to UTF-16BE bytes
                        if let data = Data(base64Encoded: paddedBase64) {
                            // Convert UTF-16BE to String
                            let utf16Codes = stride(from: 0, to: data.count, by: 2).compactMap { offset -> UInt16? in
                                guard offset + 1 < data.count else { return nil }
                                return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
                            }
                            if let decoded = String(utf16CodeUnits: utf16Codes, count: utf16Codes.count) as String? {
                                result.append(decoded)
                            }
                        }
                        i = index(after: dashIndex)
                    } else {
                        // Malformed, just append the character
                        result.append(char)
                        i = index(after: i)
                    }
                }
            } else {
                result.append(char)
                i = index(after: i)
            }
        }

        return result
    }

    /// Encode string to IMAP modified UTF-7
    func encodingIMAPUTF7() -> String {
        var result = ""
        var nonAsciiBuffer: [UInt16] = []

        func flushBuffer() {
            guard !nonAsciiBuffer.isEmpty else { return }
            // Convert UTF-16 to bytes (big-endian)
            var bytes = Data()
            for code in nonAsciiBuffer {
                bytes.append(UInt8(code >> 8))
                bytes.append(UInt8(code & 0xFF))
            }
            // Encode to base64 and convert to modified base64
            var base64 = bytes.base64EncodedString()
            // Remove padding
            base64 = base64.replacingOccurrences(of: "=", with: "")
            // Use "," instead of "/"
            base64 = base64.replacingOccurrences(of: "/", with: ",")
            result.append("&\(base64)-")
            nonAsciiBuffer.removeAll()
        }

        for scalar in unicodeScalars {
            if scalar.value >= 0x20 && scalar.value <= 0x7E {
                // ASCII printable
                flushBuffer()
                if scalar == "&" {
                    result.append("&-")
                } else {
                    result.append(Character(scalar))
                }
            } else {
                // Non-ASCII, buffer for UTF-16 encoding
                for code in Character(scalar).utf16 {
                    nonAsciiBuffer.append(code)
                }
            }
        }

        flushBuffer()
        return result
    }
}
