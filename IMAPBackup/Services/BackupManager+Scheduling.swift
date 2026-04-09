import Foundation

extension BackupManager {

    // MARK: - Scheduling

    func loadSchedule() {
        if let savedSchedule = UserDefaults.standard.string(forKey: scheduleKey),
           let schedule = BackupSchedule(rawValue: savedSchedule) {
            self.schedule = schedule
        }

        if let savedTimeInterval = UserDefaults.standard.object(forKey: scheduleTimeKey) as? TimeInterval {
            self.scheduledTime = Date(timeIntervalSince1970: savedTimeInterval)
        }

        if let configData = UserDefaults.standard.data(forKey: scheduleConfigKey),
           let config = try? JSONDecoder().decode(ScheduleConfiguration.self, from: configData) {
            self.scheduleConfiguration = config
        }
    }

    func setSchedule(_ newSchedule: BackupSchedule) {
        schedule = newSchedule
        UserDefaults.standard.set(newSchedule.rawValue, forKey: scheduleKey)
        updateScheduler()
    }

    func setScheduledTime(_ time: Date) {
        scheduledTime = time
        UserDefaults.standard.set(time.timeIntervalSince1970, forKey: scheduleTimeKey)
        updateScheduler()
    }

    func setScheduleConfiguration(_ config: ScheduleConfiguration) {
        scheduleConfiguration = config
        if let encoded = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(encoded, forKey: scheduleConfigKey)
        }
        updateScheduler()
    }

    var scheduledTimeFormatted: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: scheduledTime)
    }

    func updateScheduler() {
        // Cancel existing timer
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        nextScheduledBackup = nil

        guard schedule != .manual else { return }

        // Calculate next backup time
        nextScheduledBackup = calculateNextBackupTime()

        // Set up timer to check every minute if it's time to backup
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkScheduledBackup()
            }
        }
    }

    func calculateNextBackupTime() -> Date? {
        let calendar = Calendar.current
        let now = Date()

        switch schedule {
        case .manual:
            return nil

        case .hourly:
            // Next hour
            return calendar.date(byAdding: .hour, value: 1, to: now)

        case .daily:
            // Today or tomorrow at scheduled time
            let hour = calendar.component(.hour, from: scheduledTime)
            let minute = calendar.component(.minute, from: scheduledTime)

            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            components.second = 0

            if let todayBackup = calendar.date(from: components), todayBackup > now {
                return todayBackup
            } else {
                // Tomorrow
                components.day! += 1
                return calendar.date(from: components)
            }

        case .weekly:
            // Next occurrence of the selected weekday at scheduled time
            let hour = calendar.component(.hour, from: scheduledTime)
            let minute = calendar.component(.minute, from: scheduledTime)
            let targetWeekday = scheduleConfiguration.weekday.rawValue

            // Find the next occurrence of the target weekday
            var components = calendar.dateComponents([.year, .month, .day, .weekday], from: now)
            let currentWeekday = components.weekday!

            var daysUntilTarget = targetWeekday - currentWeekday
            if daysUntilTarget < 0 {
                daysUntilTarget += 7
            }

            // If it's the target day, check if the time has passed
            if daysUntilTarget == 0 {
                var todayComponents = calendar.dateComponents([.year, .month, .day], from: now)
                todayComponents.hour = hour
                todayComponents.minute = minute
                todayComponents.second = 0

                if let todayBackup = calendar.date(from: todayComponents), todayBackup > now {
                    return todayBackup
                } else {
                    // Same day but time passed, schedule for next week
                    daysUntilTarget = 7
                }
            }

            if let targetDate = calendar.date(byAdding: .day, value: daysUntilTarget, to: now) {
                var targetComponents = calendar.dateComponents([.year, .month, .day], from: targetDate)
                targetComponents.hour = hour
                targetComponents.minute = minute
                targetComponents.second = 0
                return calendar.date(from: targetComponents)
            }
            return nil

        case .custom:
            // Calculate based on custom interval
            let interval = scheduleConfiguration.customUnit.toSeconds(scheduleConfiguration.customInterval)

            // For custom schedules, we calculate from the scheduled time today
            let hour = calendar.component(.hour, from: scheduledTime)
            let minute = calendar.component(.minute, from: scheduledTime)

            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            components.second = 0

            if let baseDate = calendar.date(from: components) {
                if baseDate > now {
                    return baseDate
                } else {
                    // Add one interval
                    return baseDate.addingTimeInterval(interval)
                }
            }
            return nil
        }
    }

    func checkScheduledBackup() {
        guard !isBackingUp,
              let nextBackup = nextScheduledBackup,
              Date() >= nextBackup else { return }

        startBackupAll()

        // Calculate next backup time
        nextScheduledBackup = calculateNextBackupTime()
    }
}
