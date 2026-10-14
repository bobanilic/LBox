import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = AppStoreViewModel()
    @StateObject private var downloadManager = DownloadManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Int = 0
    @State private var showSetupAlert = false
    @State private var showSetupPicker = false
    @State private var showFilePickerHelp = false 
    @AppStorage("kHasAskedForLiveContainerSetup") private var hasAskedForSetup = false
    
    // Alert States
    @State private var verificationBackup: AppBackup? = nil
    @State private var showConflictAlert = false 
    
    var body: some View {
        ZStack {
            mainTabView
                .environmentObject(downloadManager)
            
            InAppNotificationView()
        }
        .task { await performInitialSetup() }
        .onChange(of: viewModel.catalogRevision) { _, _ in viewModel.checkForUpdates(installedApps: downloadManager.installedApps) }
        .onChange(of: downloadManager.installedApps) { _, newApps in viewModel.checkForUpdates(installedApps: newApps) }
        .onChange(of: showSetupPicker) { _, isPresented in checkForPickerFailure(isPresented: isPresented) }
        .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
            
            // Watch pendingInstallation to trigger local alert state
            .onChange(of: downloadManager.pendingInstallation?.id) { _, newID in
                if newID != nil {
                    showConflictAlert = true
                } else {
                    showConflictAlert = false
                    // Conflict resolution finished (or cancelled). 
                    // Check if we have an incomplete update (backup exists, app config missing).
                    // We add a small delay to ensure the previous alert effectively dismissed in the UI system
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if let backup = downloadManager.pendingBackups.last {
                            // If checkUpdateStatus returns false, it means the app is installed but lacks config (needs run).
                            if !downloadManager.checkUpdateStatus(for: backup) {
                                verificationBackup = backup
                            }
                        }
                    }
                }
            }
            
            // MARK: - Alerts
            .alert("Complete Update", isPresented: updateAlertBinding, presenting: verificationBackup) { backup in
                Button("Open LiveContainer") {
                    let folderName = backup.originalInstallPath
                    if let url = URL(string: "livecontainer://livecontainer-launch?bundle-name=\(folderName)") { 
                        UIApplication.shared.open(url) 
                    }
                }
                Button("Cancel Update (Restore)") { downloadManager.restoreBackup(backup) }
                // Modified to separate delete logic to optionally delete containers
                Button("Delete Backup", role: .destructive) { downloadManager.discardBackup(backup) }
            } message: { backup in
                Text("Please run '\(backup.appName)' in LiveContainer to finalize the update, and then return to LBox.\n\nIf you have already run it and the update is not detected, you can try again or restore the previous version.")
            }
            .alert("Setup LiveContainer", isPresented: $showSetupAlert) {
                Button("Select Folder") { hasAskedForSetup = true; showSetupPicker = true }
                Button("Trouble Selecting?", role: .none) { showFilePickerHelp = true }
                Button("Later", role: .cancel) { hasAskedForSetup = true }
            } message: {
                Text("To enable auto-installation and launching, please select your LiveContainer storage directory.")
            }
            .fileImporter(isPresented: $showSetupPicker, allowedContentTypes: [.folder]) { res in
                if case .success(let url) = res { downloadManager.setCustomFolder(url, forApps: true) }
            }
            .alert("Have trouble selecting?", isPresented: $showFilePickerHelp) {
                Button("Open LiveContainer") {
                    if let url = URL(string: "livecontainer://install") { UIApplication.shared.open(url) }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Solution: Open LiveContainer, find LBox in the \"My Apps\" list, press and hold the icon, tap Settings, and enable Fix File Picker. Then try selecting the directory again.")
            }
            // Use local state binding for Conflict Alert to prevent flickering
            .alert("App Conflict", isPresented: $showConflictAlert, presenting: downloadManager.pendingInstallation) { pending in
                Button("Update Existing") { 
                    downloadManager.finalizeInstallation(action: .updateExisting)
                    // We intentionally do NOT clear pendingInstallation here manually to allow background task to finish
                    // showConflictAlert becomes false automatically by SwiftUI on button press
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
    
    var mainTabView: some View {
        TabView(selection: $selectedTab) {
            StoreView(viewModel: viewModel)
                .tabItem { Label("Store", systemImage: "bag") }
                .tag(0)
            InstalledAppsView(selectedTab: $selectedTab, viewModel: viewModel)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                .tag(1)
            DirectDownloadView(viewModel: viewModel)
                .tabItem { Label("Download", systemImage: "arrow.down.circle") }
                .tag(2)
            SettingsView(viewModel: viewModel)
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(3)
        }
        .toolbarBackground(Color(.systemBackground), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
    
    var updateAlertBinding: Binding<Bool> {
        Binding(get: { verificationBackup != nil }, set: { if !$0 { verificationBackup = nil } })
    }
    // Removed conflictAlertBinding computed property in favor of local @State
    
    func performInitialSetup() async {
        // Render the persisted catalogue first. Network refresh is intentionally non-blocking.
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
    func checkForPickerFailure(isPresented: Bool) {
        if !isPresented {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if downloadManager.customLiveContainerFolder == nil && hasAskedForSetup {
                    showFilePickerHelp = true
                }
            }
        }
    }
    func handleScenePhase(_ phase: ScenePhase) {
        NotificationManager.shared.isAppInForeground = (phase == .active)
        
        if phase == .active {
            // Check the backup currently being verified, or fall back to the latest one
            let backupToCheck = verificationBackup ?? downloadManager.pendingBackups.last
            
            if let backup = backupToCheck {
                if downloadManager.checkUpdateStatus(for: backup) {
                    verificationBackup = nil
                } else {
                    verificationBackup = backup
                }
            }
        }
    }
}

// MARK: - Store View
struct StoreView: View {
    @ObservedObject var viewModel: AppStoreViewModel
    
    private let columns = [
        GridItem(.adaptive(minimum: 112, maximum: 140), spacing: 14, alignment: .top)
    ]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    storeControls
                        .padding(.horizontal, 18)
                        .padding(.top, 4)
                        .padding(.bottom, 18)
                    
                    if viewModel.filteredApps.isEmpty && !viewModel.isLoading {
                        ContentUnavailableView(
                            "No Apps",
                            systemImage: "square.grid.2x2",
                            description: Text(viewModel.searchText.isEmpty ? "No apps are available from the enabled sources." : "No apps match your search.")
                        )
                        .padding(.top, 72)
                    } else {
                        LazyVGrid(columns: columns, alignment: .center, spacing: 22) {
                            ForEach(viewModel.filteredApps) { app in
                                NavigationLink(destination: AppDetailView(app: app, viewModel: viewModel)) {
                                    StoreAppTile(app: app)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 28)
                    }
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle("Store")
            .searchable(text: $viewModel.searchText, prompt: "Search apps, bundles...")
            .refreshable { await viewModel.fetchAllRepos() }
        }
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
                    .frame(height: 34)
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
                    .frame(height: 34)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)
                
                Spacer(minLength: 2)
                
                Text("\(viewModel.filteredApps.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
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

}

private struct StoreAppTile: View {
    let app: AppItem
    
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                CachedRemoteImage(
                    url: URL(string: app.iconURL ?? ""),
                    contentMode: .fill,
                    placeholderSystemImage: "app.fill"
                )
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                }
                
                if updateAvailable {
                    statusBadge("UPDATE")
                } else if installed {
                    statusBadge("INSTALLED")
                }
            }
            
            Text(app.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(minHeight: 30, alignment: .topLeading)
            
            HStack(spacing: 4) {
                Text("v\(app.version)")
                if let repo = app.sourceRepoName, !repo.isEmpty {
                    Text("•")
                    Text(repo)
                        .lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
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

struct InstalledAppsView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @Binding var selectedTab: Int
    @ObservedObject var viewModel: AppStoreViewModel
    // Changed alignment to .top to prevent icons from shifting when "Update" button is present
    let columns = [GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 20, alignment: .top)]
    var body: some View {
        NavigationStack {
            ScrollView {
                if downloadManager.installedApps.isEmpty {
                    ContentUnavailableView("No Apps", systemImage: "square.dashed", description: Text("Apps extracted to the applications folder will appear here."))
                        .padding(.top, 50)
                } else {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(downloadManager.installedApps) { app in
                            InstalledAppItem(app: app, selectedTab: $selectedTab, viewModel: viewModel)
                        }
                    }.padding()
                }
            }
            .navigationTitle("Apps")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        viewModel.checkForUpdates(installedApps: downloadManager.installedApps)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Check Updates")
                }
            }
            .refreshable { downloadManager.refreshInstalledApps() }
        }
    }
}

struct InstalledAppItem: View {
    let app: LocalApp
    @Binding var selectedTab: Int
    @ObservedObject var viewModel: AppStoreViewModel
    @EnvironmentObject var downloadManager: DownloadManager
    @State private var showSetupNeeded = false
    var newVersion: String? {
        viewModel.availableUpdates[app.bundleID]
    }
    var body: some View {
        Button {
            if downloadManager.hasLCAppInfo(bundleID: app.bundleID) {
                let urlString = "livecontainer://livecontainer-launch?bundle-name=\(app.url.lastPathComponent)"
                if let url = URL(string: urlString) { UIApplication.shared.open(url) }
            } else {
                showSetupNeeded = true
            }
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    if let icon = app.iconURL, let data = try? Data(contentsOf: icon), let img = UIImage(data: data) {
                        Image(uiImage: img).resizable().frame(width: 70, height: 70).cornerRadius(14)
                    } else {
                        Image(systemName: "app.fill").resizable().frame(width: 70, height: 70).foregroundColor(.gray).cornerRadius(14)
                    }
                    if newVersion != nil {
                        Circle().fill(Color.red).frame(width: 12, height: 12).offset(x: 4, y: -4)
                    }
                }
                Text(app.name).font(.caption).lineLimit(2).frame(height: 35, alignment: .top)
                if newVersion != nil {
                    Button {
                        viewModel.searchText = app.bundleID
                        selectedTab = 0 
                    } label: {
                        Text("Update").font(.system(size: 10, weight: .bold)).foregroundColor(.white).padding(.horizontal, 8).padding(.vertical, 4).background(Color.blue).clipShape(Capsule())
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { downloadManager.deleteApp(app) } label: { Label("Delete App", systemImage: "trash") }
            Divider()
            Button { viewModel.searchText = app.name; selectedTab = 0 } label: { Label("Search Name", systemImage: "magnifyingglass") }
            Button { viewModel.searchText = app.bundleID; selectedTab = 0 } label: { Label("Search Bundle ID", systemImage: "barcode.viewfinder") }
            Divider()
            if let ver = app.version { Button("Version: \(ver)") {}.disabled(true) }
            Button("Bundle: \(app.bundleID)") {}.disabled(true)
            Button("File: \(app.url.lastPathComponent)") {}.disabled(true)
            #if DEBUG
            Button {
                let plistURL = app.url.appendingPathComponent("LCAppInfo.plist")
                if FileManager.default.fileExists(atPath: plistURL.path) {
                    let activityVC = UIActivityViewController(activityItems: [plistURL], applicationActivities: nil)
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let rootVC = windowScene.windows.first?.rootViewController {
                        rootVC.present(activityVC, animated: true)
                    }
                }
            } label: {
                Label("Share LCAppInfo.plist", systemImage: "square.and.arrow.up")
            }
            #endif
        }
        .alert("Setup Required", isPresented: $showSetupNeeded) {
            Button("Open LiveContainer") {
                let urlString = "livecontainer://livecontainer-launch?bundle-name=\(app.url.lastPathComponent)"
                if let url = URL(string: urlString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This app has not been configured yet. Please open LiveContainer, then find and run this app once to generate the configuration.")
        }
    }
}

struct DirectDownloadView: View {
    @ObservedObject var viewModel: AppStoreViewModel
    @EnvironmentObject var downloadManager: DownloadManager
    @State private var renamingFile: URL?
    @State private var newFileName = ""
    @State private var showFileImporter = false
    @State private var showDownloadLink = false
    @State private var confirmClearFiles = false

    private var activeURLs: [URL] {
        downloadManager.downloadStates.keys.filter {
            switch downloadManager.getStatus(for: $0) {
            case .none, .failed: return false
            default: return true
            }
        }.sorted { $0.absoluteString < $1.absoluteString }
    }

    private var failedURLs: [URL] {
        downloadManager.downloadStates.keys.filter {
            if case .failed = downloadManager.getStatus(for: $0) { return true }
            return false
        }.sorted { $0.absoluteString < $1.absoluteString }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("From download to installed, clearly.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    Button { showDownloadLink = true } label: {
                        Label("Add download link", systemImage: "link")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                }
                if !activeURLs.isEmpty {
                    Section("In progress") {
                        ForEach(activeURLs, id: \.self) { url in
                            DownloadRow(url: url, status: downloadManager.getStatus(for: url), viewModel: viewModel)
                        }
                    }
                }
                if !failedURLs.isEmpty {
                    Section("Needs attention") {
                        ForEach(failedURLs, id: \.self) { url in
                            DownloadRow(url: url, status: downloadManager.getStatus(for: url), viewModel: viewModel)
                        }
                    }
                }
                Section {
                    if downloadManager.fileList.isEmpty {
                        Text("Downloaded and imported files appear here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(downloadManager.fileList, id: \.self) { file in
                        FileRow(localURL: file, onRename: {
                            renamingFile = file
                            newFileName = file.lastPathComponent
                        })
                    }
                    .onDelete { offsets in
                        let files = downloadManager.fileList
                        offsets.compactMap { files.indices.contains($0) ? files[$0] : nil }
                            .forEach { downloadManager.deleteFile($0) }
                    }
                } header: {
                    HStack {
                        Text("Files")
                        Spacer()
                        if !downloadManager.fileList.isEmpty {
                            Button("Clear All") { confirmClearFiles = true }
                                .font(.caption)
                        }
                    }
                } footer: {
                    Text("Saved in \(downloadManager.customDownloadFolder?.lastPathComponent ?? "the default downloads folder").")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showDownloadLink = true } label: { Label("Download from URL", systemImage: "link") }
                        Button { showFileImporter = true } label: { Label("Import File", systemImage: "square.and.arrow.down") }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add download or import file")
                }
                ToolbarItem(placement: .topBarTrailing) { LBoxSettingsButton() }
            }
            .sheet(isPresented: $showDownloadLink) {
                DownloadLinkSheet().environmentObject(downloadManager)
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.data, .archive]) { result in
                if case .success(let url) = result { downloadManager.importFile(at: url) }
            }
            .refreshable { downloadManager.refreshFileList() }
            .confirmationDialog("Clear downloaded files?", isPresented: $confirmClearFiles, titleVisibility: .visible) {
                Button("Clear All Files", role: .destructive) { downloadManager.clearAllFiles() }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Rename File", isPresented: Binding(get: { renamingFile != nil }, set: { if !$0 { renamingFile = nil } })) {
                TextField("Filename.ipa", text: $newFileName)
                Button("Cancel", role: .cancel) { renamingFile = nil }
                Button("Save") {
                    if let file = renamingFile { downloadManager.renameFile(file, newName: newFileName) }
                    renamingFile = nil
                }
            }
        }
    }
}

private struct DownloadLinkSheet: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var validationError: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("IPA download URL") {
                    TextField("https://example.com/app.ipa", text: $text)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Paste from Clipboard") {
                        text = UIPasteboard.general.string ?? ""
                        validationError = nil
                    }
                    if let validationError { Text(validationError).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let value = trimmed.contains("://") ? trimmed : "https://" + trimmed
                        guard let url = URL(string: value),
                              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                              let host = url.host, !host.isEmpty else {
                            validationError = "Enter a valid HTTP or HTTPS download URL."
                            return
                        }
                        downloadManager.startDownload(url: url)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct DownloadRow: View {
    let url: URL
    let status: DownloadStatus
    var viewModel: AppStoreViewModel? = nil
    @EnvironmentObject var downloadManager: DownloadManager

    private var sourceApp: AppItem? {
        viewModel?.displayApps.first { $0.downloadURL == url.absoluteString }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CachedRemoteImage(url: URL(string: sourceApp?.iconURL ?? ""), contentMode: .fill, placeholderSystemImage: "arrow.down.doc")
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(sourceApp?.name ?? (url.lastPathComponent.isEmpty ? url.host ?? "Download" : url.lastPathComponent))
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Text(sourceApp?.sourceRepoName ?? url.host ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    switch status {
                    case .paused: downloadManager.resumeDownload(url: url)
                    case .failed: downloadManager.startDownload(url: url)
                    default: downloadManager.pauseDownload(url: url)
                    }
                } label: {
                    Image(systemName: actionIcon).frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(status == .processing)
                .accessibilityLabel(actionLabel)
                Button { downloadManager.cancelDownload(url: url) } label: {
                    Image(systemName: "xmark.circle").frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(status == .processing)
                .accessibilityLabel("Cancel download")
            }
            switch status {
            case .downloading(let progress, let written, let total):
                let expected = total > 0 ? total : sourceApp?.size ?? 0
                if expected > 0 {
                    ProgressView(value: min(1, max(0, total > 0 ? progress : Double(written) / Double(expected))))
                    HStack {
                        Text("\(format(written)) of \(format(expected))")
                        Spacer()
                        Text("\(Int(min(1, max(0, Double(written) / Double(expected))) * 100))%")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                } else {
                    HStack { ProgressView(); Text("\(format(written)) downloaded").font(.caption).foregroundStyle(.secondary) }
                }
            case .paused: Label("Paused", systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary)
            case .waitingForConnection: Label("Waiting for connection", systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary)
            case .processing: HStack { ProgressView(); Text("Preparing app…").font(.caption).foregroundStyle(.secondary) }
            case .failed(let message): Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            case .none: EmptyView()
            }
        }
        .padding(.vertical, 8)
    }

    private var actionIcon: String {
        switch status {
        case .paused: return "play.fill"
        case .failed: return "arrow.clockwise"
        default: return "pause.fill"
        }
    }
    private var actionLabel: String {
        switch status {
        case .paused: return "Resume download"
        case .failed: return "Retry download"
        default: return "Pause download"
        }
    }
    func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

struct FileRow: View {
    let localURL: URL
    @EnvironmentObject var manager: DownloadManager
    @State private var showShare = false
    @State private var tempURL: URL?
    var onRename: (() -> Void)? = nil
    var isExtracting: Bool { manager.extractingFiles.contains(localURL) }
    var body: some View {
        HStack {
            Image(systemName: isArchive ? "archivebox.fill" : "doc.fill").foregroundStyle(.blue)
            VStack(alignment: .leading) {
                Text(localURL.lastPathComponent).lineLimit(1)
                if isExtracting {
                    Text("Extracting...").font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            if isExtracting {
                ProgressView().scaleEffect(0.8).padding(.trailing, 8)
            } else {
                Menu {
                    if isArchive {
                        Button { manager.convertToApp(file: localURL) } label: { Label("Install App", systemImage: "app.badge") }
                    }
                    if let onRename {
                        Button(action: onRename) { Label("Rename", systemImage: "pencil") }
                    }
                    Button {
                        tempURL = prepareShare(localURL); showShare = true
                    } label: { Label("Share", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { manager.deleteFile(localURL) } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Options for \(localURL.lastPathComponent)")
            }
        }
        .contextMenu {
            if let onRename = onRename {
                Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
            }
            Button(role: .destructive) { manager.deleteFile(localURL) } label: { Label("Delete", systemImage: "trash") }
            if isArchive {
                Button { manager.convertToApp(file: localURL) } label: { Label("Convert to .app", systemImage: "cube") }
            }
            Button {
                tempURL = prepareShare(localURL); showShare = true
            } label: { Label("Share", systemImage: "square.and.arrow.up") }
        }
        .disabled(isExtracting)
        .sheet(isPresented: $showShare) { if let u = tempURL { ShareSheet(activityItems: [u]) } }
    }
    var isArchive: Bool {
        let ext = localURL.pathExtension.lowercased()
        return ext == "ipa" || ext == "zip"
    }
    func prepareShare(_ url: URL) -> URL? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = url.startAccessingSecurityScopedResource()
        try? FileManager.default.copyItem(at: url, to: tmp)
        url.stopAccessingSecurityScopedResource()
        return tmp
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: AppStoreViewModel
    var isPresentedAsSheet = false
    @EnvironmentObject var dm: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("kLBoxAppearance") private var appearanceRaw = LBoxAppearance.automatic.rawValue
    @AppStorage("kStoreLayoutMode") private var layoutRaw = EnhancedStoreLayout.list.rawValue
    @State private var showFolderImporter = false
    @State private var isPickingLiveContainer = false
    
    @State private var confirmReset = false
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var exportJSONString = ""
    @State private var showCopyAlert = false
    @State private var didSelectLiveContainer = false
    @State private var showSettingsHelp = false
    var body: some View {
        NavigationStack {
            List {
                Section("Appearance") {
                    Picker("Theme", selection: $appearanceRaw) {
                        ForEach(LBoxAppearance.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                }
                Section("Directories") {
                    HStack { 
                        Text("Downloads")
                        Spacer() 
                        if dm.customDownloadFolder != nil { 
                            Button("Default") { dm.clearCustomFolder(forApps: false) }.buttonStyle(.bordered) 
                        }
                        Button("Select") { 
                            isPickingLiveContainer = false
                            showFolderImporter = true 
                        } 
                    }
                    HStack { 
                        Text("LiveContainer")
                        Spacer() 
                        if dm.customLiveContainerFolder != nil { 
                            Button("Default") { dm.clearCustomFolder(forApps: true) }.buttonStyle(.bordered) 
                        }
                        Button("Select") { 
                            isPickingLiveContainer = true
                            showFolderImporter = true 
                        } 
                    }
                    Toggle("Auto .ipa to .app", isOn: $dm.isAutoUnzipEnabled)
                }
                Section("Browse") {
                   Picker("Catalog Layout", selection: $layoutRaw) {
                       ForEach(EnhancedStoreLayout.allCases) { option in
                           Text(option.title).tag(option.rawValue)
                       }
                   }
                   Picker("Sort Apps By", selection: $viewModel.appSortOrder) {
                       ForEach(AppSortOption.allCases) { option in Text(option.rawValue).tag(option) }
                   }
                   Toggle("Strict Grouping", isOn: $viewModel.strictGrouping)
                   if viewModel.strictGrouping {
                       Text("Apps with different sources, names, or descriptions will be listed separately.").font(.caption).foregroundColor(.secondary)
                   } else {
                       Text("Apps with the same Bundle ID will be grouped together regardless of source.").font(.caption).foregroundColor(.secondary)
                   }
                }
                Section("Repositories") {
                    NavigationLink("Manage Sources") { RepoManagementView(viewModel: viewModel, parentID: nil) }
                    Picker("Sort Repos By", selection: $viewModel.repoSortOrder) {
                        ForEach(RepoSortOption.allCases) { option in Text(option.rawValue).tag(option) }
                    }
                }
                Section("Backup/Restore") {
                    Menu("Export Repos...") {
                        Button("Copy as JSON") {
                            if viewModel.savedRepos.contains(where: { $0.hasDisabledContentRecursive }) { showCopyAlert = true } else { if let s = viewModel.exportReposJSON() { UIPasteboard.general.string = s } }
                        }
                        Button("Copy as URL List") { UIPasteboard.general.string = viewModel.exportReposURLList() }
                        if #available(iOS 16.0, *) {
                            ShareLink(item: viewModel.exportReposJSON() ?? "", subject: Text("LBox Repos"), preview: SharePreview("LBox Repos")) { Text("Share JSON File") }
                        } else {
                            Button("Share JSON File") { if let s = viewModel.exportReposJSON() { exportJSONString = s; showExporter = true } }
                        }
                    }
                    Button("Import Repos (JSON)") { showImporter = true }
                }
                Section("About") {
                    LabeledContent("LBox", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.4.0")
                    #if DEBUG
                    NavigationLink("Debug Logs") { DebugLogView() }
                    #endif
                    Button("Reset to Defaults") { confirmReset = true }.foregroundColor(.red)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                if isPresentedAsSheet {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .fileImporter(isPresented: $showFolderImporter, allowedContentTypes: [.folder]) { res in 
                if case .success(let url) = res { 
                    if isPickingLiveContainer {
                        dm.setCustomFolder(url, forApps: true) 
                        didSelectLiveContainer = true 
                    } else {
                        dm.setCustomFolder(url, forApps: false)
                    }
                } 
            }
            .onChange(of: showFolderImporter) { _, isPresented in
                // Only run Help logic if we were picking for LiveContainer
                if isPickingLiveContainer {
                    if !isPresented { 
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { 
                            if !didSelectLiveContainer { showSettingsHelp = true } 
                        } 
                    } else { 
                        didSelectLiveContainer = false 
                    } 
                }
            }
            .alert("Reset?", isPresented: $confirmReset) { Button("Cancel", role: .cancel) {}; Button("Reset", role: .destructive) { viewModel.resetReposToDefault() } }
            
            // Corrected Confirmation Dialog for SettingsView
            .confirmationDialog("Copy Options", isPresented: $showCopyAlert) { 
                Button("Copy All") { 
                    if let s = viewModel.exportReposJSON(onlyEnabled: false) { UIPasteboard.general.string = s } 
                }
                Button("Only Enabled") { 
                    if let s = viewModel.exportReposJSON(onlyEnabled: true) { UIPasteboard.general.string = s } 
                }
                Button("Cancel", role: .cancel) { } 
            } message: { Text("Some repositories are disabled. Which would you like to copy?") }
            
            .sheet(isPresented: $showExporter) { ShareSheet(activityItems: [exportJSONString]) }
            .sheet(isPresented: $showImporter) { ImportJSONView(viewModel: viewModel) }
            .alert("Have trouble selecting?", isPresented: $showSettingsHelp) { Button("Open LiveContainer") { if let url = URL(string: "livecontainer://install") { UIApplication.shared.open(url) } }; Button("Cancel", role: .cancel) { } } message: { Text("Solution: Open LiveContainer, find LBox in the \"My Apps\" list, press and hold the icon, tap Settings, and enable Fix File Picker. Then try selecting the directory again.") }
        }
    }
}

// MARK: - Repository Management
struct RepoManagementView: View {
    @ObservedObject var viewModel: AppStoreViewModel
    let parentID: String?
    
    @State private var showAdd = false
    @State private var showCopyAlert = false
    @State private var pendingCopyRepo: SavedRepo?
    @State private var copyMode: CopyMode = .json
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var pendingRenameRepo: SavedRepo?
    @State private var showMoveSheet = false
    @State private var pendingMoveRepo: SavedRepo?
    
    enum CopyMode {
        case json
        case url
    }
    
    private var displayedRepos: [SavedRepo] {
        viewModel.getRepos(in: parentID)
    }
    
    private var isReadOnly: Bool {
        guard let parentID, let parent = viewModel.getRepo(parentID) else {
            return false
        }
        return parent.isRemoteFolder
    }
    
    var body: some View {
        List {
            if parentID == nil {
                Section {
                    Text("Choose where your apps come from.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
            }
            if displayedRepos.isEmpty {
                ContentUnavailableView(
                    "No Sources",
                    systemImage: "tray",
                    description: Text(isReadOnly ? "This remote folder currently contains no sources." : "Add a repository or folder to get started.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(displayedRepos) { repo in
                    repositoryRow(repo)
                        .contextMenu {
                            repositoryContextMenu(repo)
                        }
                }
                .onDelete(perform: deleteRepos)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(parentID.flatMap { viewModel.getRepo($0)?.name } ?? "Sources")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if parentID == nil {
                    Button {
                        Task { await viewModel.fetchAllRepos() }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(viewModel.isLoading)
                    .accessibilityLabel("Refresh all sources")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { LBoxSettingsButton() }
            ToolbarItem(placement: .navigationBarTrailing) {
                if !isReadOnly {
                    HStack {
                        EditButton()
                        Button {
                            showAdd = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
        }
        .refreshable {
            if let parentID,
               let parent = viewModel.getRepo(parentID),
               parent.isRemoteFolder {
                await viewModel.fetchRemoteFolderList(folderID: parentID, fetchApps: true)
            } else {
                await viewModel.fetchAllRepos()
            }
        }
        .sheet(isPresented: $showAdd) {
            AddRepoSheet(viewModel: viewModel, parentID: parentID)
        }
        .sheet(isPresented: $showMoveSheet) {
            if let repo = pendingMoveRepo {
                MoveRepoSheet(itemToMove: repo, viewModel: viewModel)
            }
        }
        .alert("Rename Folder", isPresented: $showRenameAlert) {
            TextField("New Name", text: $renameText)
            Button("Cancel", role: .cancel) {
                pendingRenameRepo = nil
            }
            Button("Save") {
                if let repo = pendingRenameRepo {
                    viewModel.renameRepo(id: repo.id, newName: renameText)
                }
                pendingRenameRepo = nil
            }
        }
        .confirmationDialog("Copy Options", isPresented: $showCopyAlert, titleVisibility: .visible) {
            Button("Copy All") {
                performCopy(all: true)
            }
            Button("Only Enabled") {
                performCopy(all: false)
            }
            Button("Cancel", role: .cancel) {
                pendingCopyRepo = nil
            }
        } message: {
            Text("This item contains disabled content.")
        }
    }
    
    @ViewBuilder
    private func repositoryRow(_ repo: SavedRepo) -> some View {
        HStack(spacing: 12) {
            if repo.isFolder {
                NavigationLink(destination: RepoManagementView(viewModel: viewModel, parentID: repo.id)) {
                    repositoryIdentity(repo)
                }
            } else {
                repositoryIdentity(repo)
            }
            
            Spacer(minLength: 8)
            
            Toggle(
                repo.name,
                isOn: Binding(
                    get: { repo.isEnabled },
                    set: { viewModel.setRepoEnabled(id: repo.id, enabled: $0) }
                )
            )
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }
    
    private func repositoryIdentity(_ repo: SavedRepo) -> some View {
        HStack(spacing: 12) {
            repositoryIcon(repo)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(repo.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(repo.isEnabled ? .primary : .secondary)
                    .lineLimit(1)
                
                if repo.isFolder {
                    Text("\(repo.totalRepoCount) sources • \(repo.totalAppCount) apps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(repo.appCount) apps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    if let url = repo.url {
                        Text(url.host ?? url.absoluteString)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if !repo.isEnabled {
                        Text("Disabled").font(.caption).foregroundStyle(.secondary)
                    } else if repo.fetchStatus == .success {
                        Label("Up to date", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if case .error(let message) = repo.fetchStatus {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                        if repo.cachedApps != nil {
                            Text("Showing saved apps")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else if case .warning(let message) = repo.fetchStatus {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func repositoryIcon(_ repo: SavedRepo) -> some View {
        if repo.isFolder {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
                
                Image(systemName: repo.isRemoteFolder ? "folder.badge.gearshape" : "folder.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 42, height: 42)
        } else {
            switch repo.fetchStatus {
            case .loading:
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                    ProgressView()
                }
                .frame(width: 42, height: 42)
            case .waiting:
                statusIcon("clock", foreground: .secondary)
            case .error:
                statusIcon("exclamationmark.triangle.fill", foreground: .red)
            case .warning:
                statusIcon("exclamationmark.triangle.fill", foreground: .orange)
            default:
                CachedRemoteImage(
                    url: URL(string: repo.iconURL ?? ""),
                    contentMode: .fill,
                    placeholderSystemImage: "server.rack"
                )
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
    
    private func statusIcon(_ systemName: String, foreground: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemBackground))
            Image(systemName: systemName)
                .foregroundStyle(foreground)
        }
        .frame(width: 42, height: 42)
    }
    
    @ViewBuilder
    private func repositoryContextMenu(_ repo: SavedRepo) -> some View {
        if !repo.isFolder {
            Button {
                Task {
                    await viewModel.fetchRepo(id: repo.id)
                    await viewModel.refreshDisplayApps()
                }
            } label: {
                Label("Retry Source", systemImage: "arrow.clockwise")
            }
            if case .error(let message) = repo.fetchStatus {
                Button("Copy Error Details") {
                    UIPasteboard.general.string = "\(repo.name)\n\(repo.url?.host ?? "")\n\(message)"
                }
            }
        }
        if repo.isFolder {
            if repo.isRemoteFolder {
                Button {
                    Task {
                        await viewModel.fetchRemoteFolderList(folderID: repo.id, fetchApps: true)
                    }
                } label: {
                    Label("Update List", systemImage: "arrow.triangle.2.circlepath")
                }
                
                if let listURL = repo.repoListURL {
                    Button {
                        UIPasteboard.general.string = listURL.absoluteString
                    } label: {
                        Label("Copy Folder URL", systemImage: "link")
                    }
                }
            }
            
            Button {
                pendingRenameRepo = repo
                renameText = repo.name
                showRenameAlert = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        }
        
        Button {
            pendingMoveRepo = repo
            showMoveSheet = true
        } label: {
            Label("Move…", systemImage: "folder.badge.gearshape")
        }
        
        Button("Copy URLs") {
            if repo.hasDisabledContentRecursive {
                pendingCopyRepo = repo
                copyMode = .url
                showCopyAlert = true
            } else {
                UIPasteboard.general.string = repo.allURLs(onlyEnabled: false)
            }
        }
        
        Button("Copy JSON") {
            if repo.hasDisabledContentRecursive {
                pendingCopyRepo = repo
                copyMode = .json
                showCopyAlert = true
            } else if let json = viewModel.exportSingleRepoJSON(repo, onlyEnabled: false) {
                UIPasteboard.general.string = json
            }
        }
        
        if !isReadOnly {
            Button(role: .destructive) {
                viewModel.deleteRepo(id: repo.id)
            } label: {
                Label(repo.isFolder ? "Delete Folder" : "Delete", systemImage: "trash")
            }
        }
    }
    
    private func deleteRepos(at offsets: IndexSet) {
        guard !isReadOnly else { return }
        
        for index in offsets where displayedRepos.indices.contains(index) {
            viewModel.deleteRepo(id: displayedRepos[index].id)
        }
    }
    
    private func performCopy(all: Bool) {
        guard let repo = pendingCopyRepo else { return }
        
        if copyMode == .json {
            if let json = viewModel.exportSingleRepoJSON(repo, onlyEnabled: !all) {
                UIPasteboard.general.string = json
            }
        } else {
            UIPasteboard.general.string = repo.allURLs(onlyEnabled: !all)
        }
        
        pendingCopyRepo = nil
    }
}

struct MoveRepoSheet: View { let itemToMove: SavedRepo; @ObservedObject var viewModel: AppStoreViewModel; @Environment(\.dismiss) var dismiss; var body: some View { NavigationStack { List { Button { viewModel.moveRepo(id: itemToMove.id, toParentId: nil); dismiss() } label: { HStack { Image(systemName: "house.fill"); Text("Root") } }; Section("Folders") { ForEach(viewModel.getFolderTargets(excludingId: itemToMove.id)) { folder in Button { viewModel.moveRepo(id: itemToMove.id, toParentId: folder.id); dismiss() } label: { HStack { Image(systemName: "folder"); Text(folder.name) } } } } }.navigationTitle("Move to...").toolbar { Button("Cancel") { dismiss() } } } } }
struct AddRepoSheet: View { @ObservedObject var viewModel: AppStoreViewModel; let parentID: String?; @Environment(\.dismiss) var dismiss; @State private var mode = 0; @State private var textInput = ""; @State private var folderName = ""; @State private var folderLink = ""; var body: some View { NavigationStack { Form { Picker("Add", selection: $mode) { Text("Sources").tag(0); Text("Folder").tag(1) }.pickerStyle(.segmented); if mode == 0 { Section(header: Text("URLs (One per line)")) { TextEditor(text: $textInput).frame(height: 150).autocorrectionDisabled().textInputAutocapitalization(.never); Button("Paste from Clipboard") { if let s = UIPasteboard.general.string { textInput = s } } } } else { Section(header: Text("New Folder")) { TextField("Name", text: $folderName); TextField("Link URL (Optional)", text: $folderLink).autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL) }; Section(footer: Text("If a link is provided, this folder will automatically populate with repositories from that URL (one per line).")) { EmptyView() } } }.navigationTitle("Add").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { if mode == 0 { let lines = textInput.components(separatedBy: .newlines); for line in lines { let t = line.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { let fixed = (!t.lowercased().hasPrefix("http") ? "https://" + t : t); if let u = URL(string: fixed) { viewModel.addRepo(url: u, parentID: parentID) } } } } else { let link = folderLink.trimmingCharacters(in: .whitespacesAndNewlines); var finalName = folderName.trimmingCharacters(in: .whitespacesAndNewlines); if finalName.isEmpty && !link.isEmpty { finalName = link; if finalName.lowercased().hasPrefix("https://") { finalName = String(finalName.dropFirst(8)) } else if finalName.lowercased().hasPrefix("http://") { finalName = String(finalName.dropFirst(7)) } }; if !finalName.isEmpty { let url = link.isEmpty ? nil : URL(string: (!link.lowercased().hasPrefix("http") ? "https://" + link : link)); viewModel.addFolder(name: finalName, parentID: parentID, repoListURL: url) } }; dismiss() } } } } } }
struct ImportJSONView: View { @ObservedObject var viewModel: AppStoreViewModel; @Environment(\.dismiss) var dismiss; @State private var text = ""; var body: some View { NavigationStack { Form { TextEditor(text: $text).frame(height: 300); Button("Paste") { if let s = UIPasteboard.general.string { text = s } } }.navigationTitle("Import JSON").toolbar { Button("Import") { viewModel.importReposJSON(text); dismiss() } } } } }
struct ShareSheet: UIViewControllerRepresentable { let activityItems: [Any]; func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: activityItems, applicationActivities: nil) }; func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {} }


