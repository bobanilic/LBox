import SwiftUI
import UniformTypeIdentifiers

enum EnhancedStoreLayout: String, CaseIterable, Identifiable {
    case list
    case three
    case four
    case five

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "List"
        case .three: return "3 Columns"
        case .four: return "4 Columns"
        case .five: return "5 Columns"
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .three: return "square.grid.3x3"
        case .four: return "square.grid.3x3.fill"
        case .five: return "circle.grid.3x3.fill"
        }
    }

    var columnCount: Int? {
        switch self {
        case .list: return nil
        case .three: return 3
        case .four: return 4
        case .five: return 5
        }
    }
}

struct EnhancedContentView: View {
    @StateObject private var viewModel = ShrubLibraryAppStoreViewModel()
    @StateObject private var downloadManager = DownloadManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Int = 0
    @State private var showSettings = false
    @AppStorage("kLBoxAppearance") private var appearanceRaw = LBoxAppearance.automatic.rawValue
    @State private var showSetupAlert = false
    @State private var showSetupPicker = false
    @State private var showFilePickerHelp = false
    @AppStorage("kHasAskedForLiveContainerSetup") private var hasAskedForSetup = false

    @State private var verificationBackup: AppBackup?
    @State private var showConflictAlert = false

    var body: some View {
        ZStack {
            mainTabView
                .environmentObject(downloadManager)

            InAppNotificationView()
        }
        .environment(\.openLBoxSettings, { showSettings = true })
        .preferredColorScheme(LBoxAppearance(rawValue: appearanceRaw)?.colorScheme)
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel, isPresentedAsSheet: true)
                .environmentObject(downloadManager)
                .preferredColorScheme(LBoxAppearance(rawValue: appearanceRaw)?.colorScheme)
        }
        .task { await performInitialSetup() }
        .onChange(of: viewModel.catalogRevision) { _, _ in
            viewModel.checkForUpdates(installedApps: downloadManager.installedApps)
        }
        .onChange(of: downloadManager.installedApps) { _, newApps in
            viewModel.checkForUpdates(installedApps: newApps)
        }
        .onChange(of: downloadManager.recoveryFailure) { _, _ in
            verificationBackup = downloadManager.pendingBackups.last
        }
        .onChange(of: showSetupPicker) { _, isPresented in
            checkForPickerFailure(isPresented: isPresented)
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhase(phase)
        }
        .onChange(of: downloadManager.pendingInstallation?.id) { _, newID in
            if newID != nil {
                showConflictAlert = true
            } else {
                showConflictAlert = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let backup = downloadManager.pendingBackups.last,
                       !downloadManager.checkUpdateStatus(for: backup) {
                        verificationBackup = backup
                    }
                }
            }
        }
        .alert("Complete Update", isPresented: updateAlertBinding, presenting: verificationBackup) { backup in
            Button("Open LiveContainer") {
                let folderName = backup.originalInstallPath
                if let url = URL(string: "livecontainer://livecontainer-launch?bundle-name=\(folderName)") {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel Update (Restore)") {
                downloadManager.restoreBackup(backup)
            }
            Button("Delete Backup", role: .destructive) {
                downloadManager.discardBackup(backup)
            }
        } message: { backup in
            Text("Please run '\(backup.appName)' in LiveContainer to finalize the update, and then return to LBox.\n\nIf you have already run it and the update is not detected, you can try again or restore the previous version.")
        }
        .alert("Setup LiveContainer", isPresented: $showSetupAlert) {
            Button("Select Folder") {
                hasAskedForSetup = true
                showSetupPicker = true
            }
            Button("Trouble Selecting?", role: .none) {
                showFilePickerHelp = true
            }
            Button("Later", role: .cancel) {
                hasAskedForSetup = true
            }
        } message: {
            Text("To enable auto-installation and launching, please select your LiveContainer storage directory.")
        }
        .fileImporter(isPresented: $showSetupPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                downloadManager.setCustomFolder(url, forApps: true)
            }
        }
        .alert("Have trouble selecting?", isPresented: $showFilePickerHelp) {
            Button("Open LiveContainer") {
                if let url = URL(string: "livecontainer://install") {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Solution: Open LiveContainer, find LBox in the \"My Apps\" list, press and hold the icon, tap Settings, and enable Fix File Picker. Then try selecting the directory again.")
        }
        .alert("App Conflict", isPresented: $showConflictAlert, presenting: downloadManager.pendingInstallation) { _ in
            Button("Update Existing") {
                downloadManager.finalizeInstallation(action: .updateExisting)
            }
            Button("Install as Separate App") {
                downloadManager.finalizeInstallation(action: .installSeparate)
            }
            Button("Cancel", role: .cancel) {
                downloadManager.finalizeInstallation(action: .cancel)
            }
        } message: { pending in
            Text("An app with the Bundle ID '\(pending.bundleID)' is already installed (\(pending.appName)). Would you like to update it (preserving data) or install it separately?")
        }
    }

    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            EnhancedStoreView(viewModel: viewModel)
                .tabItem { Label("Browse", systemImage: "square.grid.2x2") }
                .tag(0)

            EnhancedInstalledAppsView(selectedTab: $selectedTab, viewModel: viewModel)
                .tabItem { Label("Apps", systemImage: "square.stack.3d.up") }
                .badge(viewModel.availableUpdates.count)
                .tag(1)

            DirectDownloadView(viewModel: viewModel)
                .tabItem { Label("Downloads", systemImage: "arrow.down.to.line") }
                .badge(downloadManager.downloadStates.values.filter { status in
                    switch status {
                    case .downloading, .paused, .waitingForConnection, .processing: return true
                    case .none, .failed: return false
                    }
                }.count)
                .tag(2)

            NavigationStack {
                RepoManagementView(viewModel: viewModel, parentID: nil)
            }
                .tabItem { Label("Sources", systemImage: "folder") }
                .tag(3)
        }
    }

    private var updateAlertBinding: Binding<Bool> {
        Binding(
            get: { verificationBackup != nil },
            set: { if !$0 { verificationBackup = nil } }
        )
    }

    private func performInitialSetup() async {
        await viewModel.refreshDisplayApps()

        Task(priority: .utility) {
            await viewModel.fetchAllRepos()
        }

        downloadManager.refreshFileList()
        downloadManager.refreshInstalledApps()
        viewModel.checkForUpdates(installedApps: downloadManager.installedApps)

        if !hasAskedForSetup && downloadManager.customLiveContainerFolder == nil {
            showSetupAlert = true
        }
    }

    private func checkForPickerFailure(isPresented: Bool) {
        if !isPresented {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if downloadManager.customLiveContainerFolder == nil && hasAskedForSetup {
                    showFilePickerHelp = true
                }
            }
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        NotificationManager.shared.isAppInForeground = (phase == .active)

        if phase == .active {
            let backupToCheck = verificationBackup ?? downloadManager.pendingBackups.last
            if let backup = backupToCheck {
                verificationBackup = downloadManager.checkUpdateStatus(for: backup) ? nil : backup
            }
        }
    }
}

private struct EnhancedStoreView: View {
    @ObservedObject var viewModel: AppStoreViewModel
    @AppStorage("kStoreLayoutMode") private var layoutRawValue = EnhancedStoreLayout.list.rawValue

    @State private var orderedApps: [AppItem] = []
    @State private var spotlightApp: AppItem?
    @State private var sortGeneration = 0

    private var layout: EnhancedStoreLayout {
        EnhancedStoreLayout(rawValue: layoutRawValue) ?? .list
    }

    private var gridColumns: [GridItem] {
        let count = layout.columnCount ?? 3
        let spacing: CGFloat = count >= 5 ? 9 : (count == 4 ? 11 : 14)
        return Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: count)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    Text("Good apps. From sources you choose.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)
                    storeControls
                        .padding(.horizontal, 18)
                        .padding(.top, 4)
                        .padding(.bottom, 16)

                    if viewModel.searchText.isEmpty, viewModel.selectedRepoID == nil,
                       let app = spotlightApp {
                        spotlight(app)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 22)
                    }

                    if !orderedApps.isEmpty {
                        HStack {
                            Text("Your catalog").font(.title3.weight(.bold))
                            Spacer()
                            Text("\(orderedApps.count) apps")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                    }

                    if orderedApps.isEmpty && !viewModel.isLoading {
                        ContentUnavailableView(
                            "No Apps",
                            systemImage: "square.grid.2x2",
                            description: Text(viewModel.searchText.isEmpty ? "No apps are available from the enabled sources." : "No apps match your search.")
                        )
                        .padding(.top, 72)
                    } else if layout == .list {
                        LazyVStack(spacing: 0) {
                            ForEach(orderedApps) { app in
                                EnhancedStoreListRow(app: app, viewModel: viewModel)

                                if app.id != orderedApps.last?.id {
                                    Divider()
                                        .padding(.leading, 76)
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 28)
                    } else {
                        LazyVGrid(columns: gridColumns, alignment: .center, spacing: layout.columnCount == 5 ? 18 : 22) {
                            ForEach(orderedApps) { app in
                                NavigationLink(destination: AppDetailView(app: app, viewModel: viewModel)) {
                                    EnhancedStoreGridTile(app: app, columnCount: layout.columnCount ?? 3)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, layout.columnCount == 5 ? 14 : 18)
                        .padding(.bottom, 28)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Browse")
            .searchable(text: $viewModel.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search apps or bundle IDs")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { LBoxSettingsButton() }
            }
            .refreshable { await viewModel.fetchAllRepos() }
            .onReceive(viewModel.$filteredApps) { apps in
                scheduleSort(apps)
            }
            .onChange(of: viewModel.appSortOrder) { _, _ in
                scheduleSort(viewModel.filteredApps)
            }
        }
    }

    private func spotlight(_ app: AppItem) -> some View {
        NavigationLink(destination: AppDetailView(app: app, viewModel: viewModel)) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("APP SPOTLIGHT")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    Text(app.name.caseInsensitiveCompare("Delta") == .orderedSame ? "A little nostalgia.\nA lot of play." : "Your apps.\nMore possibilities.")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text("\(app.name) · \(app.sourceRepoName ?? "Version " + app.version)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Label("View app", systemImage: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
                CachedRemoteImage(url: URL(string: app.iconURL ?? ""), contentMode: .fill, placeholderSystemImage: "app.fill")
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var storeControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Menu {
                    Button("All Sources") {
                        viewModel.selectedRepoID = nil
                    }

                    Divider()

                    ForEach(viewModel.getEnabledLeafRepos()) { repo in
                        Button {
                            viewModel.selectedRepoID = repo.name
                        } label: {
                            if viewModel.selectedRepoID == repo.name {
                                Label(repo.name, systemImage: "checkmark")
                            } else {
                                Text(repo.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease")
                        Text(viewModel.selectedRepoID ?? "All Sources")
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 11)
                    .frame(minHeight: 44)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)
                .layoutPriority(1)

                Menu {
                    Picker("Sort By", selection: $viewModel.appSortOrder) {
                        Label("Name", systemImage: "textformat").tag(AppSortOption.name)
                        Label("Newest", systemImage: "calendar").tag(AppSortOption.date)
                        Label("Largest", systemImage: "internaldrive").tag(AppSortOption.size)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(sortLabel)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)

                Menu {
                    ForEach(EnhancedStoreLayout.allCases) { option in
                        Button {
                            layoutRawValue = option.rawValue
                        } label: {
                            if option == layout {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Label(option.title, systemImage: option.systemImage)
                            }
                        }
                    }
                } label: {
                    Image(systemName: layout.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Catalog layout")


            }

            if viewModel.isLoading && viewModel.fetchTotal > 0 {
                VStack(spacing: 5) {
                    ProgressView(
                        value: Double(viewModel.fetchProgress),
                        total: Double(max(viewModel.fetchTotal, 1))
                    )
                    .progressViewStyle(.linear)

                    HStack {
                        Text("Refreshing sources")
                        Spacer()
                        Text("\(viewModel.fetchProgress)/\(viewModel.fetchTotal)")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
    }

    private var sortLabel: String {
        switch viewModel.appSortOrder {
        case .name: return "Name"
        case .date: return "Newest"
        case .size: return "Largest"
        }
    }

    private func scheduleSort(_ apps: [AppItem]) {
        sortGeneration += 1
        let generation = sortGeneration
        let order = viewModel.appSortOrder
        let query = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let source = viewModel.selectedRepoID
        let candidates = query.isEmpty ? apps : viewModel.allAppsByVariant.values.flatMap { $0 }
        let spotlightCatalog = viewModel.displayApps

        Task {
            let sorted = await Task.detached(priority: .userInitiated) {
                let matches = query.isEmpty ? candidates : candidates.filter {
                    (source == nil || $0.sourceRepoName == source) &&
                    ($0.name.lowercased().contains(query) || $0.bundleIdentifier.lowercased().contains(query))
                }
                let listings = query.isEmpty ? matches : CatalogSelection.latestPerSource(matches)
                return (Self.stableSort(listings, by: order), CatalogSelection.spotlight(in: spotlightCatalog))
            }.value

            guard generation == sortGeneration else { return }
            orderedApps = sorted.0
            spotlightApp = sorted.1
        }
    }

    nonisolated private static func stableSort(_ apps: [AppItem], by order: AppSortOption) -> [AppItem] {
        apps.sorted { lhs, rhs in
            switch order {
            case .name:
                let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameComparison != .orderedSame {
                    return nameComparison == .orderedAscending
                }

            case .date:
                let lhsDate = dateOrdinal(lhs.versionDate)
                let rhsDate = dateOrdinal(rhs.versionDate)
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }

                let lhsRawDate = lhs.versionDate ?? ""
                let rhsRawDate = rhs.versionDate ?? ""
                if lhsRawDate != rhsRawDate {
                    return lhsRawDate > rhsRawDate
                }

            case .size:
                let lhsSize = lhs.size ?? -1
                let rhsSize = rhs.size ?? -1
                if lhsSize != rhsSize {
                    return lhsSize > rhsSize
                }
            }

            let versionComparison = lhs.version.compare(rhs.version, options: .numeric)
            if versionComparison != .orderedSame {
                return versionComparison == .orderedDescending
            }

            let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }

            let bundleComparison = lhs.bundleIdentifier.localizedCaseInsensitiveCompare(rhs.bundleIdentifier)
            if bundleComparison != .orderedSame {
                return bundleComparison == .orderedAscending
            }

            let lhsSource = lhs.sourceRepoName ?? ""
            let rhsSource = rhs.sourceRepoName ?? ""
            let sourceComparison = lhsSource.localizedCaseInsensitiveCompare(rhsSource)
            if sourceComparison != .orderedSame {
                return sourceComparison == .orderedAscending
            }

            return lhs.downloadURL < rhs.downloadURL
        }
    }

    nonisolated private static func dateOrdinal(_ rawValue: String?) -> Int64 {
        guard let rawValue else { return 0 }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return 0 }

        if let numeric = Double(value), numeric > 100_000_000 {
            return Int64(numeric > 10_000_000_000 ? numeric : numeric * 1000)
        }

        let digits = value.filter(\.isNumber)
        guard digits.count >= 8 else { return 0 }

        let yearString = String(digits.prefix(4))
        if let year = Int(yearString), (1900...2200).contains(year) {
            let compact = String(digits.prefix(14))
            let padded = compact.padding(toLength: 14, withPad: "0", startingAt: 0)
            return Int64(padded) ?? 0
        }

        return 0
    }
}

private struct EnhancedStoreGridTile: View {
    let app: AppItem
    let columnCount: Int

    @EnvironmentObject private var downloadManager: DownloadManager

    private var updateAvailable: Bool {
        guard let installed = downloadManager.getInstalledVersion(bundleID: app.bundleIdentifier) else {
            return false
        }
        return app.version.compare(installed, options: .numeric) == .orderedDescending
    }

    private var installed: Bool {
        downloadManager.isAppInstalled(bundleID: app.bundleIdentifier)
    }

    private var cornerRadius: CGFloat {
        switch columnCount {
        case 5...: return 13
        case 4: return 16
        default: return 20
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: columnCount >= 5 ? 5 : 7) {
            ZStack(alignment: .topTrailing) {
                CachedRemoteImage(
                    url: URL(string: app.iconURL ?? ""),
                    contentMode: .fill,
                    placeholderSystemImage: "app.fill"
                )
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                }

                if columnCount >= 5 {
                    if updateAvailable {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 9, height: 9)
                            .padding(6)
                    } else if installed {
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 8, height: 8)
                            .padding(6)
                    }
                } else if updateAvailable {
                    statusBadge("UPDATE")
                } else if installed {
                    statusBadge("INSTALLED")
                }
            }

            Text(app.name)
                .font(columnCount >= 5 ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(columnCount >= 5 ? 1 : 2)
                .frame(minHeight: columnCount >= 5 ? 14 : 30, alignment: .topLeading)

            if columnCount <= 4 {
                HStack(spacing: 4) {
                    Text("v\(app.version)")
                    if columnCount <= 3, let repo = app.sourceRepoName, !repo.isEmpty {
                        Text("•")
                        Text(repo)
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.name), version \(app.version)")
    }

    private func statusBadge(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .frame(height: 21)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(8)
    }
}

private struct EnhancedStoreListRow: View {
    let app: AppItem
    @ObservedObject var viewModel: AppStoreViewModel

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(destination: AppDetailView(app: app, viewModel: viewModel)) {
                HStack(spacing: 12) {
                    CachedRemoteImage(url: URL(string: app.iconURL ?? ""), contentMode: .fill, placeholderSystemImage: "app.fill")
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text("v\(app.version) · \(app.sourceRepoName ?? "Source")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let size = app.size {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            DownloadButton(app: app, compact: true, preferOpen: true)
        }
        .padding(.vertical, 12)
    }
}
