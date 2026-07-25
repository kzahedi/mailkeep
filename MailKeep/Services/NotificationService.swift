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

    // MARK: - Repeated-Failure Escalation

    /// Pure gate: at most one health notification per account per minInterval.
    static func shouldSendHealthNotification(lastSent: Date?,
                                             now: Date = Date(),
                                             minInterval: TimeInterval = 86_400) -> Bool {
        guard let lastSent else { return true }
        return now.timeIntervalSince(lastSent) >= minInterval
    }

    /// Shared per-account 24h dedupe gate used by both the repeated-failure
    /// escalation and the credential-problem notification: at most one alert
    /// per account per day, deliberately, so a broken account can't be missed
    /// OR become noise. Returns false (and does nothing) if the gate is
    /// still closed for `account`.
    @discardableResult
    private func recordNotificationIfDue(account: String, defaultsKey: String) -> Bool {
        var sent = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double]) ?? [:]
        let last = sent[account].map { Date(timeIntervalSince1970: $0) }
        guard Self.shouldSendHealthNotification(lastSent: last) else { return false }
        sent[account] = Date().timeIntervalSince1970
        UserDefaults.standard.set(sent, forKey: defaultsKey)
        return true
    }

    /// Escalation for an account that keeps failing: unlike the per-run failure
    /// notification, this one names the streak and is rate-limited to one per
    /// account per 24 h so a broken account can't be missed OR become noise.
    func notifyRepeatedFailures(account: String,
                                consecutiveFailures: Int,
                                lastError: String,
                                defaultsKey: String = "HealthNotificationLastSent") {
        guard recordNotificationIfDue(account: account, defaultsKey: defaultsKey) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Backups failing for \(account)"
        content.body = "\(consecutiveFailures) backups in a row have failed. Last error: \(lastError)"
        content.sound = .default
        content.categoryIdentifier = "BACKUP_ERROR"
        let request = UNNotificationRequest(identifier: "backup-health-\(UUID().uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Notification for the credential probe: the stored credential is
    /// present but the server rejects it (dead password / revoked OAuth
    /// grant). Distinct from `notifyRepeatedFailures` because zero *backups*
    /// have necessarily failed yet — the probe found the problem first, so
    /// the copy must not claim a backup failure streak that didn't happen.
    /// Shares the same per-account 24h dedupe store deliberately: one
    /// credential/failure alert per account per day.
    func notifyCredentialProblem(account: String,
                                  reason: String,
                                  defaultsKey: String = "HealthNotificationLastSent") {
        guard recordNotificationIfDue(account: account, defaultsKey: defaultsKey) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Credential problem for \(account)"
        content.body = "The stored password or Google authorization no longer works. Last error: \(reason)"
        content.sound = .default
        content.categoryIdentifier = "BACKUP_ERROR"
        let request = UNNotificationRequest(identifier: "backup-health-\(UUID().uuidString)",
                                            content: content, trigger: nil)
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
