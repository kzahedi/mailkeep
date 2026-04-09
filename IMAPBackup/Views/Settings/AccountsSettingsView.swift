import SwiftUI

struct AccountsSettingsView: View {
    @EnvironmentObject var backupManager: BackupManager
    @State private var showingAddAccount = false
    @State private var accountToEdit: EmailAccount?
    @State private var accountToDelete: EmailAccount?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack {
            List {
                ForEach(backupManager.accounts) { account in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(account.email)
                                if account.authType == .oauth2 {
                                    Text("OAuth")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.2))
                                        .foregroundStyle(.blue)
                                        .cornerRadius(4)
                                }
                            }
                            Text(account.imapServer)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        // Edit button
                        Button(action: { accountToEdit = account }) {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Edit account")

                        // Delete button
                        Button(action: {
                            accountToDelete = account
                            showingDeleteConfirmation = true
                        }) {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("Delete account")

                        Toggle("", isOn: Binding(
                            get: { account.isEnabled },
                            set: { newValue in
                                var updated = account
                                updated.isEnabled = newValue
                                backupManager.updateAccount(updated)
                            }
                        ))
                        .labelsHidden()
                        .help("Enable/disable backup")
                    }
                    .padding(.vertical, 4)
                }
            }

            HStack {
                Button(action: { showingAddAccount = true }) {
                    Label("Add Account", systemImage: "plus")
                }

                Spacer()
            }
            .padding()
        }
        .sheet(isPresented: $showingAddAccount) {
            AddAccountView()
        }
        .sheet(item: $accountToEdit) { account in
            EditAccountView(account: account)
        }
        .alert("Delete Account?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                accountToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let account = accountToDelete {
                    backupManager.removeAccount(account)
                }
                accountToDelete = nil
            }
        } message: {
            if let account = accountToDelete {
                Text("Are you sure you want to delete \(account.email)? This will remove the account from the app but will not delete any backed up emails.")
            }
        }
    }
}

struct EditAccountView: View {
    @EnvironmentObject var backupManager: BackupManager
    @Environment(\.dismiss) private var dismiss

    let account: EmailAccount

    @State private var email: String
    @State private var password = ""
    @State private var imapServer: String
    @State private var port: String
    @State private var useSSL: Bool

    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var isReauthorizing = false
    @State private var reauthorizeResult: ReauthorizeResult?

    enum ReauthorizeResult {
        case success
        case failure(String)
    }

    enum TestResult {
        case success
        case failure(String)
    }

    init(account: EmailAccount) {
        self.account = account
        _email = State(initialValue: account.email)
        _imapServer = State(initialValue: account.imapServer)
        _port = State(initialValue: String(account.port))
        _useSSL = State(initialValue: account.useSSL)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Edit Account")
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
                if account.authType == .oauth2 {
                    // OAuth account - limited editing
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Signed in with Google")
                            .foregroundStyle(.primary)
                    }

                    LabeledContent("Email") {
                        Text(email)
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Server") {
                        Text(imapServer)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            reauthorize()
                        } label: {
                            if isReauthorizing {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.7)
                                    Text("Signing in...")
                                }
                            } else {
                                Text("Re-authorize with Google")
                            }
                        }
                        .disabled(isReauthorizing)

                        if let result = reauthorizeResult {
                            switch result {
                            case .success:
                                Label("Re-authorized successfully", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            case .failure(let message):
                                Label(message, systemImage: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                        }

                        Text("To switch to a different Google account, delete this account and add a new one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // Password-based account - full editing
                    TextField("Email Address", text: $email)
                        .textContentType(.emailAddress)

                    SecureField("Password", text: $password)

                    Text("Enter password and test connection to save it. Leave blank to use saved password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                if account.authType != .oauth2 {
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

                Button("Save Changes") {
                    saveChanges()
                }
                .buttonStyle(.borderedProminent)
                .disabled(account.authType != .oauth2 && !isFormValid)
            }
            .padding()
        }
        .frame(width: 450, height: account.authType == .oauth2 ? 300 : 380)
    }

    var isFormValid: Bool {
        !email.isEmpty && !imapServer.isEmpty && !port.isEmpty
    }

    func testConnection() {
        isTesting = true
        testResult = nil

        Task {
            do {
                // Get password: use typed password if available, otherwise try Keychain
                let testPassword: String
                if !password.isEmpty {
                    testPassword = password
                } else if let keychainPassword = try? await KeychainService.shared.getPassword(for: account.id) {
                    testPassword = keychainPassword
                } else {
                    await MainActor.run {
                        testResult = .failure("No password provided. Please enter the password.")
                        isTesting = false
                    }
                    return
                }

                let testAccount = EmailAccount(
                    id: account.id,
                    email: email,
                    imapServer: imapServer,
                    port: Int(port) ?? 993,
                    password: testPassword,
                    useSSL: useSSL,
                    authType: .password
                )

                let service = IMAPService(account: testAccount)
                try await service.connect()
                try await service.login()
                try await service.logout()

                // Save password to Keychain on successful test
                if !password.isEmpty {
                    do {
                        try await KeychainService.shared.savePassword(password, for: account.id)
                    } catch {
                        logError("Failed to save password to Keychain: \(error.localizedDescription)")
                    }
                }

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

    func saveChanges() {
        var updatedAccount = account
        updatedAccount.email = email
        updatedAccount.username = email  // Username should match email for IMAP login
        updatedAccount.imapServer = imapServer
        updatedAccount.port = Int(port) ?? 993
        updatedAccount.useSSL = useSSL

        // Update password only if a new one was provided
        let newPassword = password.isEmpty ? nil : password

        backupManager.updateAccount(updatedAccount, password: newPassword)
        dismiss()
    }

    @MainActor
    func reauthorize() {
        isReauthorizing = true
        reauthorizeResult = nil

        Task {
            do {
                let tokens = try await GoogleOAuthService.shared.authorize()
                try await account.saveOAuthTokens(tokens)
                await MainActor.run {
                    reauthorizeResult = .success
                    isReauthorizing = false
                }
            } catch GoogleOAuthError.userCancelled {
                await MainActor.run {
                    isReauthorizing = false
                }
            } catch {
                await MainActor.run {
                    reauthorizeResult = .failure(error.localizedDescription)
                    isReauthorizing = false
                }
            }
        }
    }
}
