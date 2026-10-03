import SwiftUI

struct EnhancedInstalledAppsView: View {
    @EnvironmentObject private var downloadManager: DownloadManager
    @Binding var selectedTab: Int
    @ObservedObject var viewModel: AppStoreViewModel

    private let columns = [
        GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 20, alignment: .top)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                if downloadManager.installedApps.isEmpty {
                    ContentUnavailableView(
                        "No Apps",
                        systemImage: "square.dashed",
                        description: Text("Apps extracted to the applications folder will appear here.")
                    )
                    .padding(.top, 50)
                } else {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(downloadManager.installedApps) { app in
                            EnhancedInstalledAppItem(
                                app: app,
                                selectedTab: $selectedTab,
                                viewModel: viewModel
                            )
                        }
                    }
                    .padding()
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
            .refreshable {
                downloadManager.refreshInstalledApps()
            }
        }
    }
}

private struct EnhancedInstalledAppItem: View {
    let app: LocalApp
    @Binding var selectedTab: Int
    @ObservedObject var viewModel: AppStoreViewModel
    @EnvironmentObject private var downloadManager: DownloadManager

    @State private var showSetupNeeded = false
    @State private var storeApp: AppItem?
    @State private var showShareSheet = false
    @State private var shareURL: URL?

    private var newVersion: String? {
        viewModel.availableUpdates[app.bundleID]
    }

    private var sourceMatches: [AppItem] {
        var seen = Set<String>()
        let matches = viewModel.allAppsByVariant.values
            .flatMap { $0 }
            .filter { $0.bundleIdentifier.caseInsensitiveCompare(app.bundleID) == .orderedSame }
            .filter { seen.insert($0.downloadURL).inserted }

        return matches.sorted(by: sourceSort)
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

    private var preferredSourceMatch: AppItem? {
        exactSourceMatch ?? latestSourceMatch
    }

    private var localIPA: URL? {
        guard let match = preferredSourceMatch,
              let url = URL(string: match.downloadURL) else { return nil }
        return downloadManager.getLocalFile(for: url)
    }

    var body: some View {
        VStack(spacing: 6) {
            Button(action: launchApp) {
                VStack(spacing: 6) {
                    ZStack(alignment: .topTrailing) {
                        if let icon = app.iconURL,
                           let data = try? Data(contentsOf: icon),
                           let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .frame(width: 70, height: 70)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
                                Image(systemName: "app.fill")
                                    .font(.system(size: 34))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 70, height: 70)
                        }

                        if newVersion != nil {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 12, height: 12)
                                .offset(x: 4, y: -4)
                        }
                    }

                    Text(app.name)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(height: 35, alignment: .top)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 5) {
                if newVersion != nil {
                    Button {
                        storeApp = latestSourceMatch
                    } label: {
                        Text("Update")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Color.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Menu {
                    ipaActions
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 30, height: 24)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("IPA options for \(app.name)")
            }
            .frame(minHeight: 24)
        }
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
                Label("View in Store", systemImage: "bag")
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
                Label("Search Store", systemImage: "magnifyingglass")
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
