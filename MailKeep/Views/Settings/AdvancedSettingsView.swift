import SwiftUI

struct AdvancedSettingsView: View {
    @AppStorage("googleOAuthClientId") private var customClientId = ""
    @State private var showCustomClientId = false

    var body: some View {
        Form {
            Section("Google OAuth") {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Sign in with Google is ready to use")
                        .fontWeight(.medium)
                }

                Text("Gmail accounts use secure OAuth authentication. Just click 'Sign in with Google' when adding a Gmail account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Use Custom OAuth Client ID", isExpanded: $showCustomClientId) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("For developers who want to use their own Google Cloud credentials.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("Custom Client ID (optional)", text: $customClientId)
                            .textFieldStyle(.roundedBorder)

                        if !customClientId.isEmpty {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Using custom Client ID")
                                    .foregroundStyle(.green)
                                Spacer()
                                Button("Reset to Default") {
                                    customClientId = ""
                                }
                                .buttonStyle(.link)
                            }
                            .font(.caption)
                        }

                        Link("Google Cloud Console",
                             destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                            .font(.caption)
                    }
                    .padding(.top, 8)
                }
            }

            Section {
                HStack {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                    Text("OAuth tokens are stored securely in the macOS Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
