import Foundation
import AppKit

extension BackupManager {

    // MARK: - Backup Location

    var isUsingICloud: Bool {
        backupLocation.path.contains("Mobile Documents") ||
        backupLocation.path.contains("iCloud")
    }

    var iCloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    var iCloudDriveURL: URL? {
        // iCloud Drive location for documents
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            return iCloudURL.appendingPathComponent("Documents").appendingPathComponent("MailKeep")
        }
        // Fallback to ~/Library/Mobile Documents/com~apple~CloudDocs/
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let iCloudDocs = homeDir.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/MailKeep")
        return iCloudDocs
    }

    func setBackupLocation(_ url: URL) {
        backupLocation = url
        UserDefaults.standard.set(url.path, forKey: backupLocationKey)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func useICloudDrive() {
        guard let iCloudURL = iCloudDriveURL else { return }
        setBackupLocation(iCloudURL)
    }

    func useLocalStorage() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let localURL = documentsURL.appendingPathComponent("MailKeep")
        setBackupLocation(localURL)
    }

    /// Set the streaming threshold for large attachments
    func setStreamingThreshold(_ bytes: Int) {
        streamingThresholdBytes = bytes
        UserDefaults.standard.set(bytes, forKey: streamingThresholdKey)
    }

    func selectBackupLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose backup location"

        if panel.runModal() == .OK, let url = panel.url {
            setBackupLocation(url)
        }
    }
}
