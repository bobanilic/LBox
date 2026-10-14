import SwiftUI

struct EnhancedInstalledAppsView: View {
    @EnvironmentObject private var downloadManager: DownloadManager
    @Binding var selectedTab: Int
    @ObservedObject var viewModel: AppStoreViewModel

    @State private var sourceIndex: [String: [AppItem]] = [:]
    @State private var sourceGeneration = 0

    private var updateApps: [LocalApp] {
        downloadManager.installedApps.filter { viewModel.availableUpdates[$0.bundleID] != nil }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Your installed apps, together.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
                if !updateApps.isEmpty {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(updateApps.count) updates available")
                                    .font(.headline)
                                Text("Ready when you are.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Update All", action: updateAll)
                                .buttonStyle(LBoxCapsuleButtonStyle())
                                .disabled(sourceIndex.isEmpty)
                        }
                        .padding(.vertical, 4)
                    }
                }
                if downloadManager.installedApps.isEmpty {
                    ContentUnavailableView(
                        "No Apps",
                        systemImage: "square.dashed",
                        description: Text("Apps extracted to the applications folder will appear here.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section("Installed") {
                        ForEach(downloadManager.installedApps) { app in
                            EnhancedInstalledAppItem(
                                app: app,
                                selectedTab: $selectedTab,
                                viewModel: viewModel,
                                sourceMatches: sourceIndex[app.bundleID.lowercased()] ?? []
                            )
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
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
                ToolbarItem(placement: .topBarTrailing) { LBoxSettingsButton() }
            }
            .refreshable {
                downloadManager.refreshInstalledApps()
                viewModel.checkForUpdates(installedApps: downloadManager.installedApps)
            }
            .task(id: viewModel.catalogRevision) { await rebuildSourceIndex() }
            .onChange(of: downloadManager.installedApps) { _, _ in
                Task { await rebuildSourceIndex() }
            }
        }
    }

    private func rebuildSourceIndex() async {
        sourceGeneration += 1
        let generation = sourceGeneration
        let candidates = viewModel.allAppsByVariant.values.flatMap { $0 }
        let bundles = Set(downloadManager.installedApps.map { $0.bundleID.lowercased() })
        let index = await Task.detached(priority: .userInitiated) {
            var groups: [String: [AppItem]] = [:]
            var seen = Set<String>()
            for app in candidates {
                let bundle = app.bundleIdentifier.lowercased()
                guard bundles.contains(bundle), seen.insert(bundle + "|" + app.downloadURL).inserted else { continue }
                groups[bundle, default: []].append(app)
            }
            for bundle in Array(groups.keys) {
                groups[bundle]?.sort {
                    let version = $0.version.compare($1.version, options: .numeric)
                    if version != .orderedSame { return version == .orderedDescending }
                    if $0.versionDate != $1.versionDate { return ($0.versionDate ?? "") > ($1.versionDate ?? "") }
                    if $0.sourceRepoName != $1.sourceRepoName { return ($0.sourceRepoName ?? "") < ($1.sourceRepoName ?? "") }
                    return $0.downloadURL < $1.downloadURL
                }
            }
            return groups
        }.value
        guard !Task.isCancelled, generation == sourceGeneration else { return }
        sourceIndex = index
    }

    private func updateAll() {
        var urls = Set<URL>()
        for app in updateApps {
            guard let current = app.version,
                  let target = viewModel.availableUpdates[app.bundleID],
                  target.compare(current, options: .numeric) == .orderedDescending,
                  let match = sourceIndex[app.bundleID.lowercased()]?.first(where: {
                      $0.version.compare(target, options: .numeric) == .orderedSame
                  }),
                  let url = URL(string: match.downloadURL), urls.insert(url).inserted else { continue }
            downloadManager.updateApp(app, from: url, version: match.version)
        }
        if !urls.isEmpty { selectedTab = 2 }
    }
}

private struct EnhancedInstalledAppItem: View {
    let app: LocalApp
    @Binding var selectedTab: Int
    @ObservedObject var viewModel: AppStoreViewModel
    let sourceMatches: [AppItem]
    @EnvironmentObject private var downloadManager: DownloadManager

    @State private var showSetupNeeded = false
    @State private var storeApp: AppItem?
    @State private var showShareSheet = false
    @State private var shareURL: URL?

    private var newVersion: String? {
        viewModel.availableUpdates[app.bundleID]
    }

    private var exactSourceMatch: AppItem? {
        guard let installedVersion = app.version, !installedVersion.isEmpty else { return nil }
        return sourceMatches.first {
            $0.version.compare(installedVersion, options: .numeric) == .orderedSame
        }
    }

    private var latestSourceMatch: AppItem? {
        sourceMatches.first
    }

    private var updateSourceMatch: AppItem? {
        guard let target = newVersion, let installed = app.version,
              target.compare(installed, options: .numeric) == .orderedDescending else { return nil }
        return sourceMatches.first { $0.version.compare(target, options: .numeric) == .orderedSame }
    }

    private var preferredSourceMatch: AppItem? {
        exactSourceMatch ?? latestSourceMatch
    }

    private var localIPA: URL? {
        guard let match = preferredSourceMatch,
              let url = URL(string: match.downloadURL) else { return nil }
        return downloadManager.getLocalFile(for: url)
    }

    var body: some View {
        HStack(spacing: 12) {
            CachedRemoteImage(url: app.iconURL, contentMode: .fill, placeholderSystemImage: "app.fill")
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            Button {
                if let source = preferredSourceMatch { storeApp = source }
                else { launchApp() }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(newVersion.map { "Update available · v\($0)" } ?? "Installed · v\(app.version ?? "Unknown")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                if newVersion != nil, let source = updateSourceMatch,
                   let url = URL(string: source.downloadURL) {
                    downloadManager.updateApp(app, from: url, version: source.version)
                }
                else { launchApp() }
            } label: {
                Text(newVersion == nil ? "Open" : "Update")
            }
            .buttonStyle(LBoxCapsuleButtonStyle())
            .disabled(newVersion != nil && updateSourceMatch == nil)

            Menu { ipaActions } label: {
                Image(systemName: "ellipsis")
                    .frame(minWidth: 30, minHeight: 44)
            }
            .accessibilityLabel("Options for \(app.name)")
        }
        .padding(.vertical, 6)
        .contextMenu {
            ipaActions
        }
        .alert("Setup Required", isPresented: $showSetupNeeded) {
            Button("Open LiveContainer") {
                let urlString = "livecontainer://livecontainer-launch?bundle-name=\(app.url.lastPathComponent)"
                if let url = URL(string: urlString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This app has not been configured yet. Please open LiveContainer, then find and run this app once to generate the configuration.")
        }
        .sheet(item: $storeApp) { sourceApp in
            NavigationStack {
                AppDetailView(app: sourceApp, viewModel: viewModel)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                storeApp = nil
                            }
                        }
                    }
            }
            .environmentObject(downloadManager)
        }
        .sheet(isPresented: $showShareSheet) {
            if let shareURL {
                ShareSheet(activityItems: [shareURL])
            }
        }
    }

    @ViewBuilder
    private var ipaActions: some View {
        if let preferred = preferredSourceMatch {
            Button {
                storeApp = preferred
            } label: {
                Label("View in Browse", systemImage: "square.grid.2x2")
            }

            if let localIPA {
                Button {
                    selectedTab = 2
                } label: {
                    Label("Show Downloaded IPA", systemImage: "folder")
                }

                Button {
                    shareDownloadedIPA(localIPA)
                } label: {
                    Label("Share Downloaded IPA", systemImage: "square.and.arrow.up")
                }
            } else if let exact = exactSourceMatch {
                Button {
                    downloadIPA(exact)
                } label: {
                    Label("Download Installed Version IPA", systemImage: "arrow.down.circle")
                }
            } else if let latest = latestSourceMatch {
                Button {
                    downloadIPA(latest)
                } label: {
                    Label("Download Latest IPA (v\(latest.version))", systemImage: "arrow.down.circle")
                }
            }

            Button {
                UIPasteboard.general.string = preferred.downloadURL
            } label: {
                Label("Copy IPA URL", systemImage: "link")
            }

            Divider()
        } else {
            Button("No matching IPA in enabled sources") { }
                .disabled(true)

            Button {
                viewModel.searchText = app.bundleID
                selectedTab = 0
            } label: {
                Label("Search Browse", systemImage: "magnifyingglass")
            }

            Divider()
        }

        Button {
            viewModel.searchText = app.bundleID
            selectedTab = 0
        } label: {
            Label("Search Bundle ID", systemImage: "barcode.viewfinder")
        }

        if let version = app.version {
            Button("Installed: v\(version)") { }
                .disabled(true)
        }

        Button(role: .destructive) {
            downloadManager.deleteApp(app)
        } label: {
            Label("Delete App", systemImage: "trash")
        }
    }

    private func launchApp() {
        if downloadManager.hasLCAppInfo(bundleID: app.bundleID) {
            let urlString = "livecontainer://livecontainer-launch?bundle-name=\(app.url.lastPathComponent)"
            if let url = URL(string: urlString) {
                UIApplication.shared.open(url)
            }
        } else {
            showSetupNeeded = true
        }
    }

    private func downloadIPA(_ sourceApp: AppItem) {
        guard let url = URL(string: sourceApp.downloadURL) else { return }

        if downloadManager.getLocalFile(for: url) != nil {
            selectedTab = 2
            return
        }

        downloadManager.startDownload(url: url)
        downloadManager.sendNotification(
            title: "IPA Download Started",
            body: "\(sourceApp.name) v\(sourceApp.version)",
            type: .success
        )
        selectedTab = 2
    }

    private func shareDownloadedIPA(_ url: URL) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(url.lastPathComponent)

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            shareURL = destination
            showShareSheet = true
        } catch {
            downloadManager.sendNotification(
                title: "Unable to Share IPA",
                body: error.localizedDescription,
                type: .error
            )
        }
    }

    private func sourceSort(_ lhs: AppItem, _ rhs: AppItem) -> Bool {
        let versionComparison = lhs.version.compare(rhs.version, options: .numeric)
        if versionComparison != .orderedSame {
            return versionComparison == .orderedDescending
        }

        let lhsDate = lhs.versionDate ?? ""
        let rhsDate = rhs.versionDate ?? ""
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
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

