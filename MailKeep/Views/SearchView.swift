import SwiftUI
import AppKit

struct SearchView: View {
    @EnvironmentObject var backupManager: BackupManager
    @State private var searchText = ""
    @State private var searchResults: [SearchResult] = []
    @State private var isSearching = false
    @State private var emailCount: Int = 0
    @State private var errorMessage: String?
    @State private var searchService: SearchService?

    // Filter state
    @State private var showFilters = false
    @State private var selectedScope: SearchScope = .all
    @State private var selectedAccounts: Set<String> = []
    @State private var selectedFolders: Set<String> = []
    @State private var startDate: Date?
    @State private var endDate: Date?
    @State private var useStartDate = false
    @State private var useEndDate = false

    // Available options for filters
    @State private var availableAccounts: [String] = []
    @State private var availableFolders: [String] = []

    @Environment(\.dismiss) private var dismiss

    private var activeFilter: SearchFilter {
        var filter = SearchFilter()
        filter.scope = selectedScope
        filter.accounts = selectedAccounts
        filter.folders = selectedFolders
        filter.startDate = useStartDate ? startDate : nil
        filter.endDate = useEndDate ? endDate : nil
        return filter
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with search field
            searchHeader

            // Filter panel (collapsible)
            if showFilters {
                filterPanel
            }

            Divider()

            // Content area
            if isSearching {
                ProgressView("Searching...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if searchResults.isEmpty {
                emptyStateView
            } else {
                resultsList
            }

            Divider()

            // Footer with stats
            footerView
        }
        .frame(minWidth: 700, minHeight: 500)
        .task {
            await initializeSearchService()
        }
    }

    // MARK: - Search Header

    var searchHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search emails...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.title3)
                .onSubmit {
                    Task { await performSearch() }
                }

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Filter toggle button
            Button(action: { withAnimation { showFilters.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: showFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    if activeFilter.hasActiveFilters {
                        Text("Filters")
                            .font(.caption)
                    }
                }
            }
            .buttonStyle(.bordered)
            .foregroundStyle(activeFilter.hasActiveFilters ? .blue : .secondary)

            Button("Search") {
                Task { await performSearch() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(searchText.isEmpty || isSearching)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Filter Panel

    var filterPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                // Search Scope
                VStack(alignment: .leading, spacing: 4) {
                    Text("Search In")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $selectedScope) {
                        ForEach(SearchScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }

                // Account Filter
                VStack(alignment: .leading, spacing: 4) {
                    Text("Account")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Menu {
                        Button("All Accounts") {
                            selectedAccounts.removeAll()
                        }
                        Divider()
                        ForEach(availableAccounts, id: \.self) { account in
                            Button(action: {
                                if selectedAccounts.contains(account) {
                                    selectedAccounts.remove(account)
                                } else {
                                    selectedAccounts.insert(account)
                                }
                            }) {
                                HStack {
                                    Text(account)
                                    Spacer()
                                    if selectedAccounts.contains(account) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(selectedAccounts.isEmpty ? "All Accounts" : "\(selectedAccounts.count) selected")
                            Image(systemName: "chevron.down")
                        }
                        .frame(minWidth: 120)
                    }
                }

                // Folder Filter
                VStack(alignment: .leading, spacing: 4) {
                    Text("Folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Menu {
                        Button("All Folders") {
                            selectedFolders.removeAll()
                        }
                        Divider()
                        ForEach(availableFolders, id: \.self) { folder in
                            Button(action: {
                                if selectedFolders.contains(folder) {
                                    selectedFolders.remove(folder)
                                } else {
                                    selectedFolders.insert(folder)
                                }
                            }) {
                                HStack {
                                    Text(folder)
                                    Spacer()
                                    if selectedFolders.contains(folder) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(selectedFolders.isEmpty ? "All Folders" : "\(selectedFolders.count) selected")
                            Image(systemName: "chevron.down")
                        }
                        .frame(minWidth: 120)
                    }
                }

                Spacer()

                // Clear filters button
                if activeFilter.hasActiveFilters {
                    Button("Clear Filters") {
                        selectedScope = .all
                        selectedAccounts.removeAll()
                        selectedFolders.removeAll()
                        useStartDate = false
                        useEndDate = false
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            }

            // Date Range
            HStack(spacing: 20) {
                HStack(spacing: 8) {
                    Toggle("From:", isOn: $useStartDate)
                        .toggleStyle(.checkbox)
                    DatePicker("", selection: Binding(
                        get: { startDate ?? Date() },
                        set: { startDate = $0 }
                    ), displayedComponents: .date)
                    .disabled(!useStartDate)
                    .frame(width: 120)
                }

                HStack(spacing: 8) {
                    Toggle("To:", isOn: $useEndDate)
                        .toggleStyle(.checkbox)
                    DatePicker("", selection: Binding(
                        get: { endDate ?? Date() },
                        set: { endDate = $0 }
                    ), displayedComponents: .date)
                    .disabled(!useEndDate)
                    .frame(width: 120)
                }

                Spacer()
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Empty State

    var emptyStateView: some View {
        VStack(spacing: 16) {
            if searchText.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Search Your Emails")
                    .font(.title2)
                Text("Search by sender, subject, or email content.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if emailCount == 0 {
                    Text("No emails backed up yet. Run a backup first.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                }
            } else {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No Results")
                    .font(.title2)
                Text("No emails found matching \"\(searchText)\"")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Results List

    var resultsList: some View {
        List {
            ForEach(searchResults) { result in
                SearchResultRow(result: result)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        openEmail(result)
                    }
                    .contextMenu {
                        Button("Open in Finder") {
                            revealInFinder(result)
                        }
                        Button("Open Email") {
                            openEmail(result)
                        }
                        Divider()
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(result.filePath, forType: .string)
                        }
                    }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Footer

    var footerView: some View {
        HStack {
            if !searchResults.isEmpty {
                Text("\(searchResults.count) results")
                    .foregroundStyle(.secondary)
            }

            if activeFilter.hasActiveFilters {
                Text("(filtered)")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

            Spacer()

            if selectedScope != .all {
                Text("Scope: \(selectedScope.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("\(emailCount) emails available")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: {
                Task { await refreshStats() }
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh email count")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Actions

    private func initializeSearchService() async {
        searchService = SearchService(backupLocation: backupManager.backupLocation)
        do {
            try await searchService?.open()
            await refreshStats()
            await loadFilterOptions()
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshStats() async {
        do {
            let stats = try await searchService?.getStats() ?? (0, 0)
            await MainActor.run {
                emailCount = stats.0
            }
        } catch {
            // Ignore stats errors
        }
    }

    private func loadFilterOptions() async {
        guard let service = searchService else { return }

        let accounts = await service.getAvailableAccounts()
        let folders = await service.getAvailableFolders()

        await MainActor.run {
            availableAccounts = accounts
            availableFolders = folders
        }
    }

    private func performSearch() async {
        guard !searchText.isEmpty, let service = searchService else { return }

        await MainActor.run {
            isSearching = true
            errorMessage = nil
        }

        do {
            let results = try await service.search(query: searchText, filter: activeFilter)
            await MainActor.run {
                searchResults = results
                isSearching = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isSearching = false
            }
        }
    }

    private func openEmail(_ result: SearchResult) {
        let url = URL(fileURLWithPath: result.filePath)
        NSWorkspace.shared.open(url)
    }

    private func revealInFinder(_ result: SearchResult) {
        let url = URL(fileURLWithPath: result.filePath)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
}

// MARK: - Search Result Row

struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Subject and date
            HStack {
                Text(result.subject)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Text(result.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Sender
            HStack(spacing: 4) {
                Image(systemName: "person.circle.fill")
                    .foregroundStyle(.secondary)
                Text(result.sender)
                    .font(.subheadline)
                if !result.senderEmail.isEmpty {
                    Text("<\(result.senderEmail)>")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Match type badge and snippet
            HStack(alignment: .top, spacing: 8) {
                Text(result.matchType.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(matchTypeColor.opacity(0.2))
                    .foregroundStyle(matchTypeColor)
                    .clipShape(Capsule())

                HighlightedText(text: result.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // Account and mailbox
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .foregroundStyle(.tertiary)
                Text("\(result.accountId) / \(result.mailbox)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
    }

    var matchTypeColor: Color {
        switch result.matchType {
        case .sender: return .blue
        case .subject: return .green
        case .body: return .orange
        case .attachment: return .purple
        case .attachmentContent: return .pink
        }
    }
}

// MARK: - Highlighted Text

struct HighlightedText: View {
    let text: String

    var body: some View {
        highlightedAttributedString
    }

    private var highlightedAttributedString: Text {
        var result = Text("")

        // Split by <mark> tags
        let parts = text.components(separatedBy: "<mark>")

        for (index, part) in parts.enumerated() {
            if index == 0 {
                // First part is never highlighted
                result = result + Text(part)
            } else {
                // Check for closing tag
                let subparts = part.components(separatedBy: "</mark>")
                if subparts.count > 1 {
                    // Highlighted part - use bold and different color
                    result = result + Text(subparts[0])
                        .foregroundColor(.orange)
                        .fontWeight(.bold)
                    // Rest after closing tag
                    result = result + Text(subparts.dropFirst().joined(separator: "</mark>"))
                } else {
                    result = result + Text(part)
                }
            }
        }

        return result
    }
}

// MARK: - Search Window

struct SearchWindow: View {
    @EnvironmentObject var backupManager: BackupManager

    var body: some View {
        SearchView()
            .environmentObject(backupManager)
    }
}

#Preview {
    SearchView()
        .environmentObject(BackupManager())
        .frame(width: 700, height: 500)
}
