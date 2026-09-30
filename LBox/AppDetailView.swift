import SwiftUI

struct AppDetailView: View {
    let app: AppItem
    @ObservedObject var viewModel: AppStoreViewModel
    @EnvironmentObject var downloadManager: DownloadManager
    @State private var showSetupNeeded = false
    
    private var versionHistory: [AppItem] {
        viewModel.getVersions(for: app)
    }
    
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
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
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
                .frame(width: 116, height: 116)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
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
                            .frame(height: 38)
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
            sectionTitle("Version History")
            
            VStack(spacing: 0) {
                ForEach(versionHistory.indices, id: \.self) { index in
                    VersionRow(app: versionHistory[index])
                    
                    if index < versionHistory.count - 1 {
                        Divider()
                            .padding(.leading, 18)
                    }
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
    @EnvironmentObject var downloadManager: DownloadManager
    @State private var showShareSheet = false
    
    var body: some View {
        let downloadURL = URL(string: app.downloadURL)
        
        Group {
            if let url = downloadURL, let localURL = downloadManager.getLocalFile(for: url) {
                Button {
                    showShareSheet = true
                } label: {
                    if compact {
                        Image(systemName: "doc.fill")
                            .font(.body.bold())
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.gray.opacity(0.15))
                            .clipShape(Circle())
                    } else {
                        Label("File", systemImage: "doc.fill")
                            .font(.headline)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 20)
                            .background(Color.gray.opacity(0.15))
                            .foregroundColor(.primary)
                            .clipShape(Capsule())
                    }
                }
                .sheet(isPresented: $showShareSheet) {
                    FileShareSheet(activityItems: [prepareFileForShare(localURL)])
                }
            } else if let url = downloadURL, case .downloading(let progress, _, _) = downloadManager.getStatus(for: url) {
                Button {
                    downloadManager.pauseDownload(url: url)
                } label: {
                    ZStack {
                        Circle().stroke(lineWidth: 3).opacity(0.2).foregroundColor(.blue)
                        Circle().trim(from: 0.0, to: CGFloat(max(0.01, progress)))
                            .stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                            .foregroundColor(.blue).rotationEffect(Angle(degrees: 270.0)).animation(.linear, value: progress)
                        Image(systemName: "pause.fill").font(.system(size: compact ? 10 : 14)).foregroundColor(.blue)
                    }
                    .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
                }
            } else if let url = downloadURL, case .paused = downloadManager.getStatus(for: url) {
                Button {
                    downloadManager.resumeDownload(url: url)
                } label: {
                    ZStack {
                        Circle().stroke(lineWidth: 3).opacity(0.2).foregroundColor(.blue)
                        Image(systemName: "play.fill").font(.system(size: compact ? 10 : 14)).foregroundColor(.blue)
                    }
                    .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
                }
            } else if let url = downloadURL, case .waitingForConnection = downloadManager.getStatus(for: url) {
                Button {
                    downloadManager.pauseDownload(url: url)
                } label: {
                    ZStack {
                        Circle().stroke(lineWidth: 3).opacity(0.2).foregroundColor(.orange)
                        Image(systemName: "wifi.slash").font(.system(size: compact ? 10 : 14)).foregroundColor(.orange)
                    }
                    .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
                }
            } else {
                Button(action: {
                    if let url = downloadURL {
                        downloadManager.startDownload(url: url)
                    }
                }) {
                    Text("GET")
                        .font(compact ? .caption.bold() : .headline.bold())
                        .foregroundColor(.blue)
                        .padding(.horizontal, compact ? 16 : 24)
                        .padding(.vertical, compact ? 6 : 6)
                        .background(Color.blue.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
        }
    }
    
    func prepareFileForShare(_ url: URL) -> URL {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempFile = tempDir.appendingPathComponent(url.lastPathComponent)
        try? fileManager.removeItem(at: tempFile)
        try? fileManager.copyItem(at: url, to: tempFile)
        return tempFile
    }
}

