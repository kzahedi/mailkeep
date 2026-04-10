import SwiftUI

struct ScheduleSettingsView: View {
    @EnvironmentObject var backupManager: BackupManager
    @AppStorage("idleEnabled") private var idleEnabled = false

    var body: some View {
        Form {
            // Repeat/Frequency Section (like Calendar's "Repeat" row)
            Section {
                Picker("Repeat", selection: Binding(
                    get: { backupManager.schedule },
                    set: { backupManager.setSchedule($0) }
                )) {
                    Text("Never").tag(BackupSchedule.manual)
                    Text("Hourly").tag(BackupSchedule.hourly)
                    Text("Daily").tag(BackupSchedule.daily)
                    Text("Weekly").tag(BackupSchedule.weekly)
                    Text("Custom").tag(BackupSchedule.custom)
                }
                .pickerStyle(.menu)

                // Weekday selection for weekly (like Calendar's day picker)
                if backupManager.schedule.needsWeekdaySelection {
                    WeekdayPicker(
                        selectedWeekday: Binding(
                            get: { backupManager.scheduleConfiguration.weekday },
                            set: { newWeekday in
                                var config = backupManager.scheduleConfiguration
                                config.weekday = newWeekday
                                backupManager.setScheduleConfiguration(config)
                            }
                        )
                    )
                }

                // Custom interval configuration
                if backupManager.schedule.needsCustomConfiguration {
                    CustomIntervalPicker(
                        interval: Binding(
                            get: { backupManager.scheduleConfiguration.customInterval },
                            set: { newValue in
                                var config = backupManager.scheduleConfiguration
                                config.customInterval = newValue
                                backupManager.setScheduleConfiguration(config)
                            }
                        ),
                        unit: Binding(
                            get: { backupManager.scheduleConfiguration.customUnit },
                            set: { newValue in
                                var config = backupManager.scheduleConfiguration
                                config.customUnit = newValue
                                backupManager.setScheduleConfiguration(config)
                            }
                        )
                    )
                }

                // Time picker (like Calendar's time selection)
                if backupManager.schedule.needsTimeSelection {
                    DatePicker(
                        "Time",
                        selection: Binding(
                            get: { backupManager.scheduledTime },
                            set: { backupManager.setScheduledTime($0) }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    .datePickerStyle(.compact)
                }
            } header: {
                Text("Schedule")
            } footer: {
                if backupManager.schedule != .manual {
                    Text(scheduleDescription)
                }
            }

            // Next Backup Section
            Section("Next Backup") {
                if backupManager.schedule != .manual {
                    HStack {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundStyle(.blue)
                            .font(.title2)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 4) {
                            if let nextBackup = backupManager.nextScheduledBackup {
                                Text(nextBackup, style: .date)
                                    .font(.headline)
                                Text(nextBackup, style: .time)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Calculating...")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if let nextBackup = backupManager.nextScheduledBackup {
                            Text(nextBackup, style: .relative)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "calendar")
                            .foregroundStyle(.secondary)
                            .font(.title2)
                            .frame(width: 32)

                        Text("Automatic backup is disabled")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Last Backup Section
            Section("Last Backup") {
                if let lastAccount = backupManager.accounts.first(where: { $0.lastBackupDate != nil }),
                   let lastBackup = lastAccount.lastBackupDate {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.title2)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(lastBackup, style: .date)
                                .font(.headline)
                            Text(lastBackup, style: .time)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(lastBackup, style: .relative) + Text(" ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                            .font(.title2)
                            .frame(width: 32)

                        Text("No backups yet")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Real-time monitoring section
            Section {
                Toggle(isOn: Binding(
                    get: { idleEnabled },
                    set: { backupManager.setIDLEEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Monitor Inbox for New Mail")
                        Text("Keeps a persistent connection open per account. Uses more battery.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Real-Time Monitoring")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var scheduleDescription: String {
        switch backupManager.schedule {
        case .manual:
            return ""
        case .hourly:
            return "Backup will run every hour."
        case .daily:
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "Backup will run daily at \(formatter.string(from: backupManager.scheduledTime))."
        case .weekly:
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "Backup will run every \(backupManager.scheduleConfiguration.weekday.fullName) at \(formatter.string(from: backupManager.scheduledTime))."
        case .custom:
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            let interval = backupManager.scheduleConfiguration.customInterval
            let unit = backupManager.scheduleConfiguration.customUnit.displayName.lowercased()
            return "Backup will run every \(interval) \(interval == 1 ? String(unit.dropLast()) : unit) starting at \(formatter.string(from: backupManager.scheduledTime))."
        }
    }
}

/// Weekday picker styled like Apple Calendar
struct WeekdayPicker: View {
    @Binding var selectedWeekday: Weekday

    var body: some View {
        HStack {
            Text("Day")
            Spacer()
            HStack(spacing: 4) {
                ForEach(Weekday.allCases) { day in
                    Button(action: {
                        selectedWeekday = day
                    }) {
                        Text(day.shortName)
                            .font(.caption)
                            .fontWeight(selectedWeekday == day ? .semibold : .regular)
                            .frame(width: 36, height: 28)
                            .background(selectedWeekday == day ? Color.accentColor : Color.clear)
                            .foregroundStyle(selectedWeekday == day ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Custom interval picker for custom schedules
struct CustomIntervalPicker: View {
    @Binding var interval: Int
    @Binding var unit: ScheduleIntervalUnit

    var body: some View {
        HStack {
            Text("Every")
            Spacer()
            HStack(spacing: 8) {
                Picker("", selection: $interval) {
                    ForEach(1...30, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 60)

                Picker("", selection: $unit) {
                    ForEach(ScheduleIntervalUnit.allCases, id: \.self) { u in
                        Text(interval == 1 ? String(u.displayName.dropLast()) : u.displayName).tag(u)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 80)
            }
        }
    }
}
