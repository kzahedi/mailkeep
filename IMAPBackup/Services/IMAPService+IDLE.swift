import Foundation

// MARK: - IDLE Notification

/// Result of waiting for an IMAP IDLE notification (RFC 2177).
enum IDLENotification {
    /// New messages arrived in the mailbox (server sent `* N EXISTS`).
    case exists(Int)
    /// Keepalive timeout elapsed — connection has been disconnected.
    /// The caller (IDLEManager) should reconnect immediately.
    case timeout
}

// MARK: - IMAPService IDLE Extension

extension IMAPService {

    // MARK: - Public IDLE API

    /// Wait for a server-pushed notification while in IMAP IDLE mode.
    ///
    /// Protocol flow (RFC 2177):
    /// 1. Sends `TAG IDLE\r\n`
    /// 2. Reads until server sends continuation response (`+ idling`)
    /// 3. Loops reading untagged server responses:
    ///    - `* N EXISTS` → sends `DONE\r\n`, waits for `TAG OK`, returns `.exists(N)`
    ///    - `* N EXPUNGE` / `* N FETCH (FLAGS ...)` → ignored (handled by scheduled backups)
    /// 4. If `timeout` seconds elapse with no EXISTS:
    ///    - Cancels the reader (which disconnects the connection via onCancel)
    ///    - Returns `.timeout` — caller must reconnect before next IDLE
    ///
    /// RFC 2177 §3 recommends clients re-IDLE at least every 29 minutes to prevent
    /// server-side connection expiry. Pass `timeout = 25 * 60`.
    func waitForIDLENotification(timeout: TimeInterval) async throws -> IDLENotification {
        let idleTag = nextTag()

        // Send IDLE command
        try await sendRaw("\(idleTag) IDLE\r\n")

        // Read until server sends the continuation response (e.g., "+ idling")
        while true {
            let chunk = try await readResponse()
            if chunk.hasPrefix("+") || chunk.contains("\r\n+") { break }
            if chunk.contains("\(idleTag) NO") || chunk.contains("\(idleTag) BAD") {
                throw IMAPError.commandFailed("IDLE rejected: \(chunk.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        // Race the reader against the keepalive timeout
        let notification = try await withThrowingTaskGroup(of: IDLENotification.self) { group in

            // Reader task: loop reading server push responses
            group.addTask { [self] in
                try await withTaskCancellationHandler {
                    while true {
                        let chunk = try await readResponse()
                        if let count = parseExistsCount(from: chunk) {
                            // New mail — send DONE and return result
                            try await sendDone(idleTag: idleTag)
                            return IDLENotification.exists(count)
                        }
                        // Ignore EXPUNGE and FLAGS responses (handled by scheduled backup)
                        try Task.checkCancellation()
                    }
                } onCancel: {
                    // Disconnect so the pending NWConnection receive fires with an error,
                    // allowing the reader task to complete and the group to unblock.
                    Task { await self.disconnect() }
                }
            }

            // Timeout task: fire after `timeout` seconds
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return IDLENotification.timeout
            }

            // First task to complete wins
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
        // .exists: DONE was sent inside the reader. Connection ready for next command.
        // .timeout: disconnect() was called via onCancel. IDLEManager must reconnect.
        return notification
    }

    /// Fetch UIDs of messages that arrived after `lastUID`.
    ///
    /// Issues `UID SEARCH UID (lastUID+1):*`.
    /// Returns an empty array if no new messages exist.
    func fetchNewUIDs(after lastUID: UInt32) async throws -> [UInt32] {
        let tag = nextTag()
        let nextUID = lastUID + 1
        try await sendRaw("\(tag) UID SEARCH UID \(nextUID):*\r\n")

        var fullResponse = ""
        while true {
            let chunk = try await readResponse()
            fullResponse += chunk
            if chunk.contains("\(tag) OK") || chunk.contains("\(tag) NO") || chunk.contains("\(tag) BAD") {
                break
            }
        }

        return parseSearchResponse(fullResponse).sorted()
    }

    /// Return the highest UID in the currently selected folder, or 0 if the folder is empty.
    func fetchLastUID() async throws -> UInt32 {
        let uids = try await searchAll()
        return uids.max() ?? 0
    }

    // MARK: - Internal Helpers

    /// Send `DONE\r\n` to exit IDLE mode and read until the server's tagged OK.
    ///
    /// Any additional EXISTS lines received during the drain are silently ignored —
    /// the next IDLE cycle will detect them.
    func sendDone(idleTag: String) async throws {
        try await sendRaw("DONE\r\n")
        while true {
            let chunk = try await readResponse()
            if chunk.contains("\(idleTag) OK") ||
               chunk.contains("\(idleTag) NO") ||
               chunk.contains("\(idleTag) BAD") {
                return
            }
        }
    }

    /// Parse an EXISTS count from an IMAP untagged response.
    ///
    /// RFC 3501 §7.3.1 format: `* <count> EXISTS\r\n`
    /// Case-insensitive for the EXISTS keyword per RFC 3501 §9.
    nonisolated func parseExistsCount(from response: String) -> Int? {
        let lines = response.components(separatedBy: "\r\n")
        for line in lines {
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
            if parts.count >= 3,
               parts[0] == "*",
               let count = Int(parts[1]),
               parts[2].uppercased() == "EXISTS" {
                return count
            }
        }
        return nil
    }
}
