import Foundation

/// Service for managing backup history
@MainActor
class BackupHistoryService: ObservableObject {
    static let shared = BackupHistoryService()

    @Published private(set) var entries: [BackupHistoryEntry] = []

    private let maxEntries = 100
    /// Legacy key — used only for one-time migration from UserDefaults to the file store.
    private let legacyHistoryKey = "BackupHistory"

    private init() {
        migrateFromUserDefaultsIfNeeded()
        loadHistory()
    }

    // MARK: - History Management

    func startEntry(for accountEmail: String) -> UUID {
        let entry = BackupHistoryEntry(accountEmail: accountEmail)
        entries.insert(entry, at: 0)
        trimOldEntries()
        saveHistory()
        return entry.id
    }

    func updateEntry(
        id: UUID,
        emailsDownloaded: Int? = nil,
        totalEmails: Int? = nil,
        bytesDownloaded: Int64? = nil,
        foldersProcessed: Int? = nil,
        error: String? = nil
    ) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }

        if let emails = emailsDownloaded {
            entries[index].emailsDownloaded = emails
        }
        if let total = totalEmails {
            entries[index].totalEmails = total
        }
        if let bytes = bytesDownloaded {
            entries[index].bytesDownloaded = bytes
        }
        if let folders = foldersProcessed {
            entries[index].foldersProcessed = folders
        }
        if let err = error {
            entries[index].errors.append(err)
        }
    }

    func completeEntry(id: UUID, status: BackupHistoryStatus) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }

        entries[index].endTime = Date()
        entries[index].status = status
        saveHistory()
    }

    func clearHistory() {
        entries.removeAll()
        saveHistory()
    }

    func entriesForAccount(_ email: String) -> [BackupHistoryEntry] {
        entries.filter { $0.accountEmail == email }
    }

    // MARK: - Persistence

    /// URL for `backup_history.json` in Application Support.
    private func historyFileURL() -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let dir = appSupport.appendingPathComponent("MailKeep", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("backup_history.json")
    }

    private func loadHistory() {
        guard let url = historyFileURL() else {
            logError("BackupHistoryService: could not resolve history file URL")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            entries = try JSONDecoder().decode([BackupHistoryEntry].self, from: data)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // First run — file not yet created; start with empty entries.
        } catch {
            logError("BackupHistoryService: failed to load history: \(error)")
            entries = []
        }
    }

    private func saveHistory() {
        guard let url = historyFileURL() else {
            logError("BackupHistoryService: could not resolve history file URL for save")
            return
        }
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            logError("BackupHistoryService: failed to save history: \(error)")
        }
    }

    /// One-time migration: if a legacy UserDefaults entry exists and the file store is
    /// not yet present, copy the entries to the file store and remove the UserDefaults key.
    private func migrateFromUserDefaultsIfNeeded() {
        guard let url = historyFileURL(),
              !FileManager.default.fileExists(atPath: url.path) else { return }

        guard let data = UserDefaults.standard.data(forKey: legacyHistoryKey),
              let decoded = try? JSONDecoder().decode([BackupHistoryEntry].self, from: data) else {
            return
        }

        if let encoded = try? JSONEncoder().encode(decoded) {
            try? encoded.write(to: url, options: .atomic)
        }
        UserDefaults.standard.removeObject(forKey: legacyHistoryKey)
    }

    private func trimOldEntries() {
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
    }
}
