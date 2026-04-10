import Foundation
import UserNotifications

/// Service for managing system notifications
class NotificationService {
    static let shared = NotificationService()

    private init() {
        requestAuthorization()
    }

    // MARK: - Authorization

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification authorization error: \(error)")
            }
        }
    }

    // MARK: - Backup Notifications

    func notifyBackupCompleted(account: String, emailsDownloaded: Int, totalEmails: Int, errors: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Backup Complete"

        if errors > 0 {
            content.body = "\(account): Downloaded \(emailsDownloaded) of \(totalEmails) emails (\(errors) errors)"
            content.sound = .default
        } else if emailsDownloaded > 0 {
            content.body = "\(account): Downloaded \(emailsDownloaded) new emails"
            content.sound = .default
        } else {
            content.body = "\(account): Already up to date"
            // No sound for "already up to date"
        }

        content.categoryIdentifier = "BACKUP_COMPLETE"

        let request = UNNotificationRequest(
            identifier: "backup-complete-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    func notifyBackupFailed(account: String, error: String) {
        let content = UNMutableNotificationContent()
        content.title = "Backup Failed"
        content.body = "\(account): \(error)"
        content.sound = .default
        content.categoryIdentifier = "BACKUP_ERROR"

        let request = UNNotificationRequest(
            identifier: "backup-error-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    func notifyAllBackupsCompleted(totalAccounts: Int, totalDownloaded: Int, totalErrors: Int) {
        guard totalAccounts > 1 else { return } // Only show summary for multiple accounts

        let content = UNMutableNotificationContent()
        content.title = "All Backups Complete"

        if totalErrors > 0 {
            content.body = "\(totalAccounts) accounts: \(totalDownloaded) emails downloaded, \(totalErrors) errors"
        } else if totalDownloaded > 0 {
            content.body = "\(totalAccounts) accounts: \(totalDownloaded) emails downloaded"
        } else {
            content.body = "All \(totalAccounts) accounts are up to date"
        }

        content.sound = .default
        content.categoryIdentifier = "BACKUP_SUMMARY"

        let request = UNNotificationRequest(
            identifier: "backup-summary-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Notification Categories (for actions)

    func setupNotificationCategories() {
        let viewAction = UNNotificationAction(
            identifier: "VIEW_DETAILS",
            title: "View Details",
            options: [.foreground]
        )

        let errorCategory = UNNotificationCategory(
            identifier: "BACKUP_ERROR",
            actions: [viewAction],
            intentIdentifiers: [],
            options: []
        )

        let completeCategory = UNNotificationCategory(
            identifier: "BACKUP_COMPLETE",
            actions: [viewAction],
            intentIdentifiers: [],
            options: []
        )

        let summaryCategory = UNNotificationCategory(
            identifier: "BACKUP_SUMMARY",
            actions: [viewAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            errorCategory,
            completeCategory,
            summaryCategory
        ])
    }
}
