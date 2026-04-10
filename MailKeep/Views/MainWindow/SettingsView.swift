import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ScheduleSettingsView()
                .tabItem {
                    Label("Schedule", systemImage: "calendar")
                }

            AccountsSettingsView()
                .tabItem {
                    Label("Accounts", systemImage: "person.2")
                }

            BackupHistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }

            RetentionSettingsView()
                .tabItem {
                    Label("Retention", systemImage: "trash.circle")
                }

            RateLimitSettingsView()
                .tabItem {
                    Label("Rate Limit", systemImage: "speedometer")
                }

            VerificationSettingsView()
                .tabItem {
                    Label("Verify", systemImage: "checkmark.shield")
                }

            AdvancedSettingsView()
                .tabItem {
                    Label("Advanced", systemImage: "gearshape.2")
                }
        }
        .frame(width: 650, height: 550)
    }
}

#Preview {
    SettingsView()
        .environmentObject(BackupManager())
}
