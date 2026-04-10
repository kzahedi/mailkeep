import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var backupManager: BackupManager
    @Environment(\.openWindow) private var openWindow
    @State private var selectedAccount: EmailAccount?
    @State private var showingAddAccount = false
    @State private var showingMissingPasswords = false

    var body: some View {
        NavigationSplitView {
            // Sidebar - Account List
            List(selection: $selectedAccount) {
                Section("Accounts") {
                    ForEach(backupManager.accounts) { account in
                        AccountRowView(account: account)
                            .tag(account)
                    }
                    .onDelete(perform: deleteAccounts)
                    .onMove(perform: moveAccounts)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 220)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showingAddAccount = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
        } detail: {
            // Main Content
            if let account = selectedAccount {
                AccountDetailView(account: account)
            } else {
                ContentUnavailableView {
                    Label("No Account Selected", systemImage: "envelope")
                } description: {
                    Text("Select an account from the sidebar or add a new one.")
                } actions: {
                    Button("Add Account") {
                        showingAddAccount = true
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddAccount) {
            AddAccountView()
        }
        .sheet(isPresented: $showingMissingPasswords) {
            MissingPasswordsView()
        }
        .onAppear {
            // Show missing passwords prompt if needed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !backupManager.accountsWithMissingPasswords.isEmpty {
                    showingMissingPasswords = true
                }
            }
        }
        .onChange(of: backupManager.accountsWithMissingPasswords) { _, newValue in
            // Auto-show when missing passwords detected
            if !newValue.isEmpty && !showingMissingPasswords {
                showingMissingPasswords = true
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: {
                    openWindow(id: "browser")
                }) {
                    Label("Browse", systemImage: "tray.full")
                }

                Button(action: {
                    openWindow(id: "search")
                }) {
                    Label("Search", systemImage: "magnifyingglass")
                }

                Button(action: {
                    backupManager.startBackupAll()
                }) {
                    Label("Backup All", systemImage: "arrow.clockwise")
                }
                .disabled(backupManager.accounts.isEmpty || backupManager.isBackingUp)

                if backupManager.isBackingUp {
                    Button(action: {
                        backupManager.cancelAllBackups()
                    }) {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                }
            }
        }
    }

    private func deleteAccounts(at offsets: IndexSet) {
        for index in offsets {
            backupManager.removeAccount(backupManager.accounts[index])
        }
    }

    private func moveAccounts(from source: IndexSet, to destination: Int) {
        backupManager.moveAccounts(from: source, to: destination)
    }
}

struct AccountDetailView: View {
    @EnvironmentObject var backupManager: BackupManager
    let account: EmailAccount

    var progress: BackupProgress? {
        backupManager.progress[account.id]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading) {
                        Text(account.email)
                            .font(.title)
                        Text(account.imapServer)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    statusBadge
                }

                Divider()

                // Progress Section
                if let progress = progress, progress.status.isActive {
                    ProgressSection(progress: progress)
                }

                // Stats Section
                StatsSection(account: account)

                // Actions
                HStack {
                    Button(action: {
                        backupManager.startBackup(for: account)
                    }) {
                        Label("Start Backup", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(progress?.status.isActive == true)

                    if progress?.status.isActive == true {
                        Button(action: {
                            backupManager.cancelBackup(for: account.id)
                        }) {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    Button(action: {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: backupManager.backupLocation.appendingPathComponent(account.email.sanitizedForFilename()).path)
                    }) {
                        Label("Open in Finder", systemImage: "folder")
                    }
                }

                // Errors
                if let errors = progress?.errors, !errors.isEmpty {
                    ErrorsSection(errors: errors)
                }

                Spacer()
            }
            .padding()
        }
    }

    @ViewBuilder
    var statusBadge: some View {
        if let status = progress?.status {
            HStack {
                if status.isActive {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                Text(status.rawValue)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(statusColor(status).opacity(0.2))
            .foregroundStyle(statusColor(status))
            .clipShape(Capsule())
        } else if let lastBackup = account.lastBackupDate {
            Text("Last backup: \(lastBackup, style: .relative) ago")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    func statusColor(_ status: BackupStatus) -> Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        default: return .blue
        }
    }
}

struct ProgressSection: View {
    let progress: BackupProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backup Progress")
                .font(.headline)

            // Overall progress bar
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Emails")
                    Spacer()
                    Text("\(progress.downloadedEmails) / \(progress.totalEmails)")
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress.progress)
                    .progressViewStyle(.linear)
            }

            // Current folder
            if !progress.currentFolder.isEmpty {
                HStack {
                    Text("Current folder:")
                        .foregroundStyle(.secondary)
                    Text(progress.currentFolder)
                }
            }

            // Current email
            if !progress.currentEmailSubject.isEmpty {
                HStack {
                    Text("Current email:")
                        .foregroundStyle(.secondary)
                    Text(progress.currentEmailSubject)
                        .lineLimit(1)
                }
            }

            // Stats
            HStack {
                StatBox(title: "Downloaded", value: formatBytes(progress.bytesDownloaded))
                StatBox(title: "Speed", value: formatSpeed(progress.downloadSpeed))
                if let eta = progress.estimatedTimeRemaining {
                    StatBox(title: "ETA", value: formatDuration(eta))
                }
            }
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    func formatSpeed(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
    }

    func formatDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "--"
    }
}

struct StatBox: View {
    let title: String
    let value: String

    var body: some View {
        VStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct StatsSection: View {
    @EnvironmentObject var backupManager: BackupManager
    let account: EmailAccount

    @State private var stats: BackupManager.AccountStats = BackupManager.AccountStats()
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Backup Statistics
            Text("Backup Statistics")
                .font(.headline)

            HStack(spacing: 16) {
                StatCard(
                    icon: "envelope.fill",
                    title: "Emails",
                    value: isLoading ? "..." : "\(stats.totalEmails)",
                    color: .blue
                )
                StatCard(
                    icon: "internaldrive.fill",
                    title: "Size",
                    value: isLoading ? "..." : formatBytes(stats.totalSize),
                    color: .green
                )
                StatCard(
                    icon: "folder.fill",
                    title: "Folders",
                    value: isLoading ? "..." : "\(stats.folderCount)",
                    color: .orange
                )
            }

            // Date range
            if !isLoading, let oldest = stats.oldestEmail, let newest = stats.newestEmail {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)
                    Text("Emails from \(oldest, style: .date) to \(newest, style: .date)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Account Info
            Text("Account Info")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Server:").foregroundStyle(.secondary)
                    Text("\(account.imapServer):\(account.port)")
                }
                GridRow {
                    Text("SSL:").foregroundStyle(.secondary)
                    Text(account.useSSL ? "Enabled" : "Disabled")
                }
                GridRow {
                    Text("Status:").foregroundStyle(.secondary)
                    Text(account.isEnabled ? "Enabled" : "Disabled")
                        .foregroundStyle(account.isEnabled ? .green : .red)
                }
                if let lastBackup = account.lastBackupDate {
                    GridRow {
                        Text("Last backup:").foregroundStyle(.secondary)
                        Text(lastBackup, style: .relative) + Text(" ago")
                    }
                }
            }
        }
        .task(id: account.id) {
            // Load stats asynchronously to avoid blocking UI
            isLoading = true
            stats = await backupManager.getStats(for: account)
            isLoading = false
        }
    }

    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct StatCard: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct ErrorsSection: View {
    let errors: [BackupError]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Errors (\(errors.count))")
                .font(.headline)
                .foregroundStyle(.red)

            ForEach(errors) { error in
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading) {
                        Text(error.message)
                        if let folder = error.folder {
                            Text("Folder: \(folder)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    MainWindowView()
        .environmentObject(BackupManager())
}
