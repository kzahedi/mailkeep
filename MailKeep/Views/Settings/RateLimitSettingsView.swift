import SwiftUI

struct RateLimitSettingsView: View {
    @EnvironmentObject var backupManager: BackupManager
    @StateObject private var rateLimitService = RateLimitService.shared
    @State private var selectedPreset: RateLimitPreset = .balanced

    var body: some View {
        Form {
            Section("Global Rate Limiting") {
                Toggle("Enable rate limiting", isOn: $rateLimitService.globalSettings.isEnabled)
                    .help("Add delays between requests to avoid server throttling")

                if rateLimitService.globalSettings.isEnabled {
                    Picker("Preset", selection: $selectedPreset) {
                        ForEach(RateLimitPreset.allCases, id: \.self) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedPreset) { _, newValue in
                        if newValue != .custom {
                            rateLimitService.globalSettings = newValue.settings
                        }
                    }

                    Text(selectedPreset.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if selectedPreset == .custom {
                        Stepper(
                            "Request delay: \(rateLimitService.globalSettings.requestDelayMs)ms",
                            value: $rateLimitService.globalSettings.requestDelayMs,
                            in: 0...5000,
                            step: 50
                        )

                        Stepper(
                            "Max throttle delay: \(rateLimitService.globalSettings.maxThrottleDelayMs / 1000)s",
                            value: Binding(
                                get: { rateLimitService.globalSettings.maxThrottleDelayMs / 1000 },
                                set: { rateLimitService.globalSettings.maxThrottleDelayMs = $0 * 1000 }
                            ),
                            in: 5...120,
                            step: 5
                        )
                    }
                }
            }

            Section("Throttle Detection") {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text("The app automatically detects when servers send throttle warnings and backs off accordingly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Backoff multiplier")
                    Spacer()
                    Text("\(rateLimitService.globalSettings.throttleBackoffMultiplier, specifier: "%.1f")x")
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: $rateLimitService.globalSettings.throttleBackoffMultiplier,
                    in: 1.5...4.0,
                    step: 0.5
                )
                .disabled(!rateLimitService.globalSettings.isEnabled)

                Button("Reset Throttle State") {
                    Task {
                        await rateLimitService.resetAllThrottles()
                    }
                }
                .help("Clear any accumulated throttle delays")
            }

            Section("Per-Account Settings") {
                if backupManager.accounts.isEmpty {
                    Text("No accounts configured")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(backupManager.accounts) { account in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(account.email)
                                    .font(.body)
                                if rateLimitService.hasCustomSettings(for: account.id) {
                                    let settings = rateLimitService.getSettings(for: account.id)
                                    Text("Custom: \(settings.requestDelayMs)ms delay")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                } else {
                                    Text("Using global settings")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            if rateLimitService.hasCustomSettings(for: account.id) {
                                Button("Reset") {
                                    rateLimitService.removeSettings(for: account.id)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Text("To customize per-account settings, click an account above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            // Detect current preset
            detectCurrentPreset()
        }
    }

    private func detectCurrentPreset() {
        let current = rateLimitService.globalSettings

        if current.requestDelayMs == RateLimitSettings.conservative.requestDelayMs &&
           current.throttleBackoffMultiplier == RateLimitSettings.conservative.throttleBackoffMultiplier {
            selectedPreset = .conservative
        } else if current.requestDelayMs == RateLimitSettings.aggressive.requestDelayMs &&
                  current.throttleBackoffMultiplier == RateLimitSettings.aggressive.throttleBackoffMultiplier {
            selectedPreset = .aggressive
        } else if current.requestDelayMs == RateLimitSettings.default.requestDelayMs &&
                  current.throttleBackoffMultiplier == RateLimitSettings.default.throttleBackoffMultiplier {
            selectedPreset = .balanced
        } else {
            selectedPreset = .custom
        }
    }
}
