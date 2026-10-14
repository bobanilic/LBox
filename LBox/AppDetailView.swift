import SwiftUI

struct AppDetailView: View {
    let app: AppItem
    @ObservedObject var viewModel: AppStoreViewModel
    @EnvironmentObject var downloadManager: DownloadManager
    @State private var showSetupNeeded = false
    
    @State private var loadedVersions: [AppItem] = []
    private var versionHistory: [AppItem] { loadedVersions.isEmpty ? [app] : loadedVersions }
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                heroSection
                
                if !app.screenshotURLs.isEmpty {
                    screenshotsSection
                }
                
                aboutSection
                versionsSection
                    .padding(.bottom, 36)
            }
            .padding(.top, 10)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(app.id)|\(viewModel.catalogRevision)") {
            let catalog = viewModel.allAppsByVariant.values.flatMap { $0 }
            let selected = app
            let history = await Task.detached(priority: .userInitiated) {
                CatalogSelection.history(for: selected, in: catalog)
            }.value
            guard !Task.isCancelled else { return }
            loadedVersions = history
        }
        .alert("Setup Required", isPresented: $showSetupNeeded) {
            Button("Open LiveContainer") {
                let name = downloadManager.getInstalledAppName(bundleID: app.bundleIdentifier) ?? "Unknown"
                if let url = URL(string: "livecontainer://livecontainer-launch?bundle-name=\(name)") {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This app has not been configured yet. Open it once in LiveContainer, then return to LBox.")
        }
    }
    
    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                CachedRemoteImage(
                    url: URL(string: app.iconURL ?? ""),
                    contentMode: .fill,
                    placeholderSystemImage: "app.fill"
                )
                .frame(width: 90, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                }
                
                VStack(alignment: .leading, spacing: 7) {
                    Text(app.name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    
                    Text("Version \(app.version)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    if let repo = app.sourceRepoName, !repo.isEmpty {
                        Text(repo)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    
                    if let size = app.size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                
                Spacer(minLength: 0)
            }
            
            HStack(spacing: 12) {
                DownloadButton(app: app)
                
                if downloadManager.isAppInstalled(bundleID: app.bundleIdentifier) {
                    Button {
                        launchApp(bundleID: app.bundleIdentifier)
                    } label: {
                        Text("OPEN")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .frame(minHeight: 44)
                            .background(Color.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Text(app.bundleIdentifier)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 18)
    }
    
    private var screenshotsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Preview")
            
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(app.screenshotURLs, id: \.self) { urlString in
                        CachedRemoteImage(
                            url: URL(string: urlString),
                            contentMode: .fit,
                            placeholderSystemImage: "photo"
                        )
                        .frame(width: 220, height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .padding(.horizontal, 18)
            }
        }
    }
    
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("About")
            Text(app.localizedDescription ?? "No description available.")
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 18)
        }
    }
    
    private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Versions & Sources")
            
            Text(versionHistory.count == 1 ? "One version is currently available in the loaded sources." : "Choose any published version below. Each entry shows its source.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
            VStack(spacing: 0) {
                ForEach(versionHistory.indices, id: \.self) { index in
                    VersionRow(app: versionHistory[index])
                    
                    if index < versionHistory.count - 1 {
                        Divider()
                            .padding(.leading, 18)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 18)
        }
    }
    
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .padding(.horizontal, 18)
    }
    
    private func launchApp(bundleID: String) {
        guard let installedApp = downloadManager.installedApps.first(where: { $0.bundleID == bundleID }) else {
            return
        }
        
        if downloadManager.hasLCAppInfo(bundleID: bundleID) {
            let folderName = installedApp.url.lastPathComponent
            if let url = URL(string: "livecontainer://livecontainer-launch?bundle-name=\(folderName)") {
                UIApplication.shared.open(url)
            }
        } else {
            showSetupNeeded = true
        }
    }
}

struct VersionRow: View {
    let app: AppItem
    @EnvironmentObject var downloadManager: DownloadManager
    
    private var isInstalledVersion: Bool {
        guard let current = downloadManager.getInstalledVersion(bundleID: app.bundleIdentifier) else {
            return false
        }
        return current == app.version
    }
    
    private var metadataText: String {
        var parts: [String] = []
        
        if let date = app.versionDate, !date.isEmpty {
            parts.append(date)
        }
        if let size = app.size {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let repo = app.sourceRepoName, !repo.isEmpty {
            parts.append(repo)
        }
        
        return parts.joined(separator: " • ")
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text("Version \(app.version)")
                        .font(.subheadline.weight(.semibold))
                    
                    if isInstalledVersion {
                        Text("CURRENT")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                }
                
                Text(app.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(metadataText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer(minLength: 8)
            DownloadButton(app: app, compact: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

struct FileShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct DownloadButton: View {
    let app: AppItem
    var compact: Bool = false
    var preferOpen: Bool = false
    @EnvironmentObject var downloadManager: DownloadManager
    @State private var showShareSheet = false
    @State private var showSetupNeeded = false

    private var updateAvailable: Bool {
        guard let version = downloadManager.getInstalledVersion(bundleID: app.bundleIdentifier) else { return false }
        return app.version.compare(version, options: .numeric) == .orderedDescending
    }

    var body: some View {
        Group {
            if let url = URL(string: app.downloadURL) {
                control(url: url)
            } else {
                Text("Unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = URL(string: app.downloadURL), let file = downloadManager.getLocalFile(for: url) {
                FileShareSheet(activityItems: [prepareFileForShare(file)])
            }
        }
        .alert("Finish App Setup", isPresented: $showSetupNeeded) {
            Button("Open LiveContainer", action: openInstalledApp)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Open this app once in LiveContainer, then return to LBox.")
        }
    }

    @ViewBuilder
    private func control(url: URL) -> some View {
        switch downloadManager.getStatus(for: url) {
        case .downloading(let progress, _, _):
            Button { downloadManager.pauseDownload(url: url) } label: {
                ZStack {
                    Circle().stroke(Color.accentColor.opacity(0.2), lineWidth: 3)
                    Circle().trim(from: 0, to: CGFloat(min(1, max(0.01, progress))))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "pause.fill").font(.caption)
                }
                .frame(width: 28, height: 28)
                .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pause download")
            .accessibilityValue("\(Int(progress * 100)) percent")
        case .paused:
            Button { downloadManager.resumeDownload(url: url) } label: { Image(systemName: "play.fill").frame(width: 44, height: 44) }
                .buttonStyle(.plain)
                .accessibilityLabel("Resume download")
        case .waitingForConnection:
            Button { downloadManager.pauseDownload(url: url) } label: { Image(systemName: "wifi.slash").frame(width: 44, height: 44) }
                .buttonStyle(.plain)
                .accessibilityLabel("Waiting for connection. Pause download")
        case .processing:
            ProgressView().frame(minWidth: 44, minHeight: 44).accessibilityLabel("Preparing app")
        case .failed:
            Button("Retry") { downloadManager.startDownload(url: url) }
                .buttonStyle(LBoxCapsuleButtonStyle())
        case .none:
            if preferOpen, downloadManager.isAppInstalled(bundleID: app.bundleIdentifier), !updateAvailable {
                Button("Open") {
                    if downloadManager.hasLCAppInfo(bundleID: app.bundleIdentifier) { openInstalledApp() }
                    else { showSetupNeeded = true }
                }
                .buttonStyle(LBoxCapsuleButtonStyle())
            } else if downloadManager.getLocalFile(for: url) != nil {
                Button { showShareSheet = true } label: {
                    Label("File", systemImage: "doc")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(LBoxCapsuleButtonStyle())
            } else {
                Button(updateAvailable ? "Update" : "Get") { downloadManager.startDownload(url: url) }
                    .buttonStyle(LBoxCapsuleButtonStyle())
            }
        }
    }

    private func openInstalledApp() {
        guard let name = downloadManager.getInstalledAppName(bundleID: app.bundleIdentifier) else { return }
        var components = URLComponents()
        components.scheme = "livecontainer"
        components.host = "livecontainer-launch"
        components.queryItems = [URLQueryItem(name: "bundle-name", value: name)]
        if let url = components.url { UIApplication.shared.open(url) }
    }

    func prepareFileForShare(_ url: URL) -> URL {
        let manager = FileManager.default
        let tempDir = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tempFile = tempDir.appendingPathComponent(url.lastPathComponent)
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            try manager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try manager.copyItem(at: url, to: tempFile)
            return tempFile
        } catch {
            downloadManager.sendNotification(title: "Unable to Share IPA", body: error.localizedDescription, type: .error)
            return url
        }
    }
}
