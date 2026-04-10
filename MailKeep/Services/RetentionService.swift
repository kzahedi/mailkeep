import Foundation

/// Retention policy options
enum RetentionPolicy: String, Codable, CaseIterable {
    case keepAll = "Keep All"
    case byAge = "By Age"
    case byCount = "By Count"
}

/// Retention settings for an account or globally
struct RetentionSettings: Codable {
    var policy: RetentionPolicy = .keepAll
    var maxAgeDays: Int = 365  // Delete backups older than this
    var maxCount: Int = 1000   // Keep only this many newest backups

    static let `default` = RetentionSettings()
}

/// Service for managing backup retention policies
@MainActor
class RetentionService: ObservableObject {
    static let shared = RetentionService()

    @Published var globalSettings: RetentionSettings {
        didSet { saveSettings() }
    }

    private let settingsKey = "RetentionSettings"
    private let fileManager = FileManager.default

    private init() {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let settings = try? JSONDecoder().decode(RetentionSettings.self, from: data) {
            self.globalSettings = settings
        } else {
            self.globalSettings = RetentionSettings.default
        }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(globalSettings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    // MARK: - Retention Execution

    /// Apply retention policy to a backup directory
    func applyRetention(to directory: URL, settings: RetentionSettings? = nil) async -> RetentionResult {
        let effectiveSettings = settings ?? globalSettings

        guard effectiveSettings.policy != .keepAll else {
            return RetentionResult(filesDeleted: 0, bytesFreed: 0)
        }

        logInfo("Applying retention policy (\(effectiveSettings.policy.rawValue)) to \(directory.lastPathComponent)")

        let result = await Task.detached(priority: .utility) {
            let emlFiles = self.getEmlFiles(in: directory)
            switch effectiveSettings.policy {
            case .keepAll:
                return RetentionResult(filesDeleted: 0, bytesFreed: 0)
            case .byAge:
                return self.deleteByAge(files: emlFiles, maxAgeDays: effectiveSettings.maxAgeDays)
            case .byCount:
                return self.deleteByCount(files: emlFiles, maxCount: effectiveSettings.maxCount)
            }
        }.value

        if result.filesDeleted > 0 {
            logInfo("Retention completed: deleted \(result.filesDeleted) files, freed \(ByteCountFormatter.string(fromByteCount: result.bytesFreed, countStyle: .file))")
        }

        return result
    }

    /// Apply retention to all account directories
    func applyRetentionToAll(backupLocation: URL) async -> RetentionResult {
        let accountDirs = await Task.detached(priority: .utility) {
            (try? FileManager.default.contentsOfDirectory(
                at: backupLocation,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) ?? []
        }.value

        var totalResult = RetentionResult(filesDeleted: 0, bytesFreed: 0)
        for accountDir in accountDirs {
            let result = await applyRetention(to: accountDir)
            totalResult.filesDeleted += result.filesDeleted
            totalResult.bytesFreed += result.bytesFreed
        }
        return totalResult
    }

    // MARK: - Retention Strategies

    nonisolated private func deleteByAge(files: [FileInfo], maxAgeDays: Int) -> RetentionResult {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date()) ?? Date()
        var deleted = 0
        var bytesFreed: Int64 = 0

        for file in files {
            if file.modificationDate < cutoffDate {
                do {
                    try FileManager.default.removeItem(at: file.url)
                    deleted += 1
                    bytesFreed += file.size
                    logDebug("Deleted old backup: \(file.url.lastPathComponent) (age: \(file.modificationDate))")
                } catch {
                    logWarning("Failed to delete \(file.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        return RetentionResult(filesDeleted: deleted, bytesFreed: bytesFreed)
    }

    nonisolated private func deleteByCount(files: [FileInfo], maxCount: Int) -> RetentionResult {
        guard files.count > maxCount else {
            return RetentionResult(filesDeleted: 0, bytesFreed: 0)
        }

        let sortedFiles = files.sorted { $0.modificationDate > $1.modificationDate }
        let filesToDelete = sortedFiles.dropFirst(maxCount)
        var deleted = 0
        var bytesFreed: Int64 = 0

        for file in filesToDelete {
            do {
                try FileManager.default.removeItem(at: file.url)
                deleted += 1
                bytesFreed += file.size
                logDebug("Deleted excess backup: \(file.url.lastPathComponent)")
            } catch {
                logWarning("Failed to delete \(file.url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return RetentionResult(filesDeleted: deleted, bytesFreed: bytesFreed)
    }

    // MARK: - File Enumeration

    private struct FileInfo: Sendable {
        let url: URL
        let size: Int64
        let modificationDate: Date
    }

    nonisolated private func getEmlFiles(in directory: URL) -> [FileInfo] {
        var files: [FileInfo] = []

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return files
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "eml",
                  let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }

            let size = Int64(resourceValues.fileSize ?? 0)
            let date = resourceValues.contentModificationDate ?? Date.distantPast

            files.append(FileInfo(url: fileURL, size: size, modificationDate: date))
        }

        return files
    }

    // MARK: - Preview

    /// Preview what would be deleted without actually deleting
    func previewRetention(at directory: URL, settings: RetentionSettings? = nil) -> RetentionResult {
        let effectiveSettings = settings ?? globalSettings

        guard effectiveSettings.policy != .keepAll else {
            return RetentionResult(filesDeleted: 0, bytesFreed: 0)
        }

        let emlFiles = getEmlFiles(in: directory)
        var wouldDelete = 0
        var wouldFree: Int64 = 0

        switch effectiveSettings.policy {
        case .keepAll:
            break

        case .byAge:
            let cutoffDate = Calendar.current.date(byAdding: .day, value: -effectiveSettings.maxAgeDays, to: Date()) ?? Date()
            for file in emlFiles {
                if file.modificationDate < cutoffDate {
                    wouldDelete += 1
                    wouldFree += file.size
                }
            }

        case .byCount:
            if emlFiles.count > effectiveSettings.maxCount {
                let sortedFiles = emlFiles.sorted { $0.modificationDate > $1.modificationDate }
                for file in sortedFiles.dropFirst(effectiveSettings.maxCount) {
                    wouldDelete += 1
                    wouldFree += file.size
                }
            }
        }

        return RetentionResult(filesDeleted: wouldDelete, bytesFreed: wouldFree)
    }
}

/// Result of a retention operation
struct RetentionResult {
    var filesDeleted: Int
    var bytesFreed: Int64

    var bytesFreedFormatted: String {
        ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
    }
}
