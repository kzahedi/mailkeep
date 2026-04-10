import SwiftUI

struct AddAccountView: View {
    @EnvironmentObject var backupManager: BackupManager
    @Environment(\.dismiss) private var dismiss

    @State private var accountType: AccountType = .gmailOAuth
    @State private var email = ""
    @State private var password = ""
    @State private var imapServer = "imap.gmail.com"  // Default for Gmail
    @State private var port = "993"
    @State private var useSSL = true

    @State private var isTesting = false
    @State private var isSigningIn = false
    @State private var testResult: TestResult?

    // OAuth state
    @State private var oauthTokens: GoogleOAuthTokens?

    enum AccountType: String, CaseIterable {
        case gmailOAuth = "Gmail"
        case ionos = "IONOS"
        case custom = "Custom IMAP"
    }

    enum TestResult {
        case success
        case failure(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add Email Account")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Form
            Form {
                // Account type picker
                Picker("Account Type", selection: $accountType) {
                    ForEach(AccountType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .onChange(of: accountType) { _, newValue in
                    // Reset OAuth state when changing account type
                    oauthTokens = nil
                    email = ""
                    testResult = nil

                    switch newValue {
                    case .gmailOAuth:
                        imapServer = "imap.gmail.com"
                        port = "993"
                        useSSL = true
                    case .ionos:
                        imapServer = "imap.ionos.de"
                        port = "993"
                        useSSL = true
                    case .custom:
                        imapServer = ""
                        port = "993"
                        useSSL = true
                    }
                }

                // Gmail OAuth flow
                if accountType == .gmailOAuth {
                    if oauthTokens != nil && !email.isEmpty {
                        // Successfully signed in
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Signed in as \(email)")
                                .foregroundStyle(.primary)
                            Spacer()
                            Button("Change Account") {
                                oauthTokens = nil
                                email = ""
                                testResult = nil
                            }
                            .buttonStyle(.link)
                        }
                    } else {
                        // Show sign in button
                        VStack(alignment: .leading, spacing: 12) {
                            Button(action: signInWithGoogle) {
                                HStack {
                                    Image(systemName: "g.circle.fill")
                                        .font(.title2)
                                    Text("Sign in with Google")
                                        .fontWeight(.medium)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                            .disabled(isSigningIn || !GoogleOAuthService.shared.isConfigured)

                            if isSigningIn {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Text("Signing in...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if !GoogleOAuthService.shared.isConfigured {
                                Text("OAuth not configured. Please set up Google Cloud credentials in Settings → Advanced.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            } else {
                                Text("Sign in securely with your Google account. No app password needed.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Email field for non-OAuth types
                if accountType != .gmailOAuth {
                    TextField("Email Address", text: $email)
                        .textContentType(.emailAddress)
                }

                // Password for non-OAuth types
                if accountType == .ionos || accountType == .custom {
                    SecureField("Password", text: $password)
                }

                // Server settings for custom
                if accountType == .custom {
                    TextField("IMAP Server", text: $imapServer)
                    TextField("Port", text: $port)
                    Toggle("Use SSL/TLS", isOn: $useSSL)
                }

            }
            .formStyle(.grouped)

            Divider()

            // Test result
            if let result = testResult {
                HStack {
                    switch result {
                    case .success:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Connection successful!")
                            .foregroundStyle(.green)
                    case .failure(let message):
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(message)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            // Actions
            HStack {
                if accountType != .gmailOAuth || oauthTokens != nil {
                    Button("Test Connection") {
                        testConnection()
                    }
                    .disabled(isTesting || !isFormValid)

                    if isTesting {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }

                Spacer()

                Button("Add Account") {
                    addAccount()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isFormValid)
            }
            .padding()
        }
        .frame(width: 450, height: accountType == .gmailOAuth ? 350 : 400)
    }

    var isFormValid: Bool {
        switch accountType {
        case .gmailOAuth:
            return oauthTokens != nil && !email.isEmpty
        case .ionos, .custom:
            return !email.isEmpty && !password.isEmpty && !imapServer.isEmpty && !port.isEmpty
        }
    }

    func signInWithGoogle() {
        isSigningIn = true
        testResult = nil

        Task {
            do {
                // Start OAuth flow
                let tokens = try await GoogleOAuthService.shared.authorize()

                // Get user email
                let userEmail = try await GoogleOAuthService.shared.getUserEmail(accessToken: tokens.accessToken)

                await MainActor.run {
                    self.oauthTokens = tokens
                    self.email = userEmail
                    self.isSigningIn = false
                    self.testResult = .success
                }
            } catch {
                await MainActor.run {
                    self.isSigningIn = false
                    if case GoogleOAuthError.userCancelled = error {
                        // User cancelled, don't show error
                    } else {
                        self.testResult = .failure(error.localizedDescription)
                    }
                }
            }
        }
    }

    func testConnection() {
        isTesting = true
        testResult = nil

        Task {
            do {
                let account = try await createAccount()
                let service = IMAPService(account: account)

                try await service.connect()
                try await service.login()
                try await service.logout()

                await MainActor.run {
                    testResult = .success
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = .failure(error.localizedDescription)
                    isTesting = false
                }
            }
        }
    }

    func addAccount() {
        Task {
            do {
                let account = try await createAccount()

                if accountType == .gmailOAuth, let tokens = oauthTokens {
                    // Save OAuth tokens
                    try await account.saveOAuthTokens(tokens)
                    await MainActor.run {
                        if backupManager.addAccount(account, password: nil) {
                            dismiss()
                        } else {
                            testResult = .failure("An account with this email already exists")
                        }
                    }
                } else {
                    await MainActor.run {
                        if backupManager.addAccount(account, password: password) {
                            dismiss()
                        } else {
                            testResult = .failure("An account with this email already exists")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    testResult = .failure("Failed to add account: \(error.localizedDescription)")
                }
            }
        }
    }

    func createAccount() async throws -> EmailAccount {
        switch accountType {
        case .gmailOAuth:
            return EmailAccount.gmailOAuth(email: email)
        case .ionos, .custom:
            return EmailAccount(
                email: email,
                imapServer: imapServer,
                port: Int(port) ?? 993,
                password: password,
                useSSL: useSSL,
                authType: .password
            )
        }
    }
}

#Preview {
    AddAccountView()
        .environmentObject(BackupManager())
}
