import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var backupManager: BackupManager
    @StateObject private var launchService = LaunchAtLoginService.shared
    @AppStorage("hideDockIcon") private var hideDockIcon = false
    @AppStorage("LogLevel") private var logLevel = 1  // Default: info

    var body: some View {
        Form {
            Section("Storage Location") {
                // Storage type picker
                Picker("Store backups in:", selection: Binding(
                    get: { backupManager.isUsingICloud ? "icloud" : "local" },
                    set: { newValue in
                        if newValue == "icloud" {
                            backupManager.useICloudDrive()
                        } else {
                            backupManager.useLocalStorage()
                        }
                    }
                )) {
                    HStack {
                        Image(systemName: "icloud.fill")
                        Text("iCloud Drive")
                    }
                    .tag("icloud")

                    HStack {
                        Image(systemName: "internaldrive.fill")
                        Text("Local Storage")
                    }
                    .tag("local")
                }
                .pickerStyle(.radioGroup)

                // Show current path
                HStack {
                    if backupManager.isUsingICloud {
                        Image(systemName: "icloud.fill")
                            .foregroundStyle(.blue)
                        Text("Syncing to iCloud Drive")
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                    }

                    Text(backupManager.backupLocation.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Button("Choose Custom Location...") {
                        backupManager.selectBackupLocation()
                    }

                    Spacer()

                    Button("Open in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: backupManager.backupLocation.path)
                    }
                }
            }

            Section("Startup") {
                Toggle("Start at login", isOn: $launchService.isEnabled)
                    .help("Automatically launch MailKeep when you log in")

                Toggle("Hide dock icon", isOn: $hideDockIcon)
                    .help("Run as menubar-only app (requires restart)")
                    .onChange(of: hideDockIcon) { _, newValue in
                        setDockIconVisibility(hidden: newValue)
                    }
            }

            Section("Logging") {
                Picker("Log Level", selection: $logLevel) {
                    Text("Debug").tag(0)
                    Text("Info").tag(1)
                    Text("Warning").tag(2)
                    Text("Error").tag(3)
                }
                .pickerStyle(.menu)
                .help("Set the minimum log level for file logging")

                HStack {
                    Button("Open Log File") {
                        NSWorkspace.shared.selectFile(
                            LoggingService.shared.getLogFileURL().path,
                            inFileViewerRootedAtPath: LoggingService.shared.getLogDirectoryURL().path
                        )
                    }

                    Button("Clear Logs") {
                        Task {
                            await LoggingService.shared.clearLogs()
                        }
                    }
                }
            }

            Section("Large Attachments") {
                let thresholdMB = Binding(
                    get: { backupManager.streamingThresholdBytes / (1024 * 1024) },
                    set: { backupManager.setStreamingThreshold($0 * 1024 * 1024) }
                )

                Stepper(
                    "Stream emails larger than \(thresholdMB.wrappedValue) MB",
                    value: thresholdMB,
                    in: 1...100,
                    step: 5
                )
                .help("Emails larger than this threshold are streamed directly to disk to reduce memory usage")

                Text("Large emails with attachments are streamed directly to disk instead of loading into memory. This reduces memory usage when backing up emails with large attachments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Attachment Extraction") {
                Toggle("Extract attachments to separate folders", isOn: Binding(
                    get: { AttachmentExtractionManager.shared.settings.isEnabled },
                    set: { AttachmentExtractionManager.shared.settings.isEnabled = $0 }
                ))
                .help("When enabled, attachments are extracted from emails and saved to separate folders")

                Text("When enabled, attachments (PDFs, images, documents, etc.) are extracted from .eml files and saved to a subfolder next to each email. The original .eml file is preserved with embedded attachments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            // Apply saved dock icon preference on app start
            setDockIconVisibility(hidden: hideDockIcon)
        }
    }

    private func setDockIconVisibility(hidden: Bool) {
        if hidden {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }
}
