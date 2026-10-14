import Foundation
import SwiftUI
import Combine
import UserNotifications
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

// Make Equatable for UI comparisons
enum DownloadStatus: Equatable {
    case downloading(progress: Double, written: Int64, total: Int64)
    case paused
    case waitingForConnection
    case processing
    case failed(String)
    case none
}

enum InstallAction: Sendable {
    case installSeparate
    case updateExisting
    case cancel
}

struct PendingInstallation: Identifiable, Sendable {
    let id = UUID()
    let appName: String
    let bundleID: String
    let tempPayloadURL: URL 
    let extractedAppURL: URL 
    let sourceArchiveURL: URL 
    let existingApp: LocalApp? 
}

struct AppBackup: Codable, Identifiable, Sendable {
    var id: String { backupPath }
    let bundleID: String
    let appName: String
    let version: String?
    let backupPath: String 
    let originalInstallPath: String 
    let date: Date
    let hadLCAppInfo: Bool 
}

@MainActor
class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    @Published var activeDownloads: [URL: Double] = [:]
    @Published var pausedDownloads: Set<URL> = []
    
    // Files in the Download Folder
    @Published var fileList: [URL] = []
    
    // Installed Apps in the Apps Folder
    @Published var installedApps: [LocalApp] = []
    
    // Files currently being extracted
    @Published var extractingFiles: Set<URL> = []
    
    @Published var customDownloadFolder: URL? = nil
    @Published var customLiveContainerFolder: URL? = nil 
    
    // Pending Installation (Collision)
    @Published var pendingInstallation: PendingInstallation? = nil
    
    // Backups for Updates
    @Published var pendingBackups: [AppBackup] = []
    
    // Changed to Published for reactive UI updates
    @Published var isAutoUnzipEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoUnzipEnabled, forKey: "kAutoUnzipEnabled")
        }
    }
    
    @Published var downloadStates: [URL: DownloadStatus] = [:]
    
    private var urlSession: URLSession!
    private var tasks: [URL: URLSessionDownloadTask] = [:]
    private var resumeDataMap: [URL: Data] = [:]
    private var backgroundCompletionHandler: (() -> Void)?
    private var backgroundEventsFinished = false
    private var processingTasks = Set<Int>()
    private var pendingPauseTasks: [URL: Int] = [:]
    private var downloadFileIndex: [String: String] = [:]
    private let kDownloadFileIndex = "kDownloadFileIndexV2"
    private var installationQueue: [PendingInstallation] = []
    private var isFinalizingInstallation = false
    private var finalizingUpdates = Set<String>()
    @Published var recoveryFailure: UUID?

    
    private let kCustomDownloadFolderKey = "kCustomDownloadFolderBookmark"
    private let kCustomLiveContainerFolderKey = "kCustomLiveContainerFolderBookmark"
    private let kBackgroundSessionID = "com.lbox.downloadSession"
    private let kResumeDataMapKey = "kResumeDataMapKey"
    
    private let kPendingBackupsKey = "kPendingBackupsKey"
    
    // URL String -> Filename in Caches
    private var diskResumeDataPaths: [String: String] = [:]
    
    override convenience init() {
        self.init(configuration: nil)
    }

    init(configuration: URLSessionConfiguration?) {
        self.isAutoUnzipEnabled = UserDefaults.standard.bool(forKey: "kAutoUnzipEnabled")
        super.init()
        let config = configuration ?? URLSessionConfiguration.background(withIdentifier: kBackgroundSessionID)
        if configuration == nil {
            config.isDiscretionary = false
            config.sessionSendsLaunchEvents = true
            config.waitsForConnectivity = true
            config.timeoutIntervalForResource = 86400
            config.timeoutIntervalForRequest = 600
        }
        
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        
        downloadFileIndex = UserDefaults.standard.dictionary(forKey: kDownloadFileIndex) as? [String: String] ?? [:]
        restoreFolders()
        restoreResumeDataMapping()
        loadPendingBackups()
        reconnectExistingTasks()
        refreshFileList()
        refreshInstalledApps()
    }
    
    func getStatus(for url: URL) -> DownloadStatus {
        return downloadStates[url] ?? .none
    }
    
    func getInstalledVersion(bundleID: String) -> String? {
        return installedApps.first(where: { $0.bundleID == bundleID })?.version
    }
    
    func getInstalledAppName(bundleID: String) -> String? {
        return installedApps.first(where: { $0.bundleID == bundleID })?.url.lastPathComponent
    }
    
    // MARK: - Notifications
    func sendNotification(title: String, body: String, type: InAppNotification.NotificationType = .success) {
        NotificationManager.shared.show(title: title, message: body, type: type)
    }
    
    // MARK: - Directories
    
    var currentDownloadFolder: URL {
        if let custom = customDownloadFolder { return custom }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    var currentAppsFolder: URL {
        if let root = customLiveContainerFolder {
            let appsSub = root.appendingPathComponent("Applications")
            if FileManager.default.fileExists(atPath: appsSub.path) { return appsSub }
            return root
        }
        return currentDownloadFolder
    }
    
    var currentDataApplicationFolder: URL? {
        if let root = customLiveContainerFolder {
            return root.appendingPathComponent("Data").appendingPathComponent("Application")
        }
        return nil
    }
    
    var backupDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Backups")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    
    func getLocalFile(for url: URL) -> URL? {
        guard let filename = downloadFileIndex[url.absoluteString] else { return nil }
        let file = currentDownloadFolder.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    private func saveDownloadFileIndex() {
        UserDefaults.standard.set(downloadFileIndex, forKey: kDownloadFileIndex)
    }

    private func forgetFile(_ file: URL) {
        downloadFileIndex = downloadFileIndex.filter { $0.value != file.lastPathComponent }
        saveDownloadFileIndex()
    }

    
    func isAppInstalled(bundleID: String) -> Bool {
        return installedApps.contains { $0.bundleID == bundleID }
    }
    
    // MARK: - Backup Logic
    
    func loadPendingBackups() {
        if let data = UserDefaults.standard.data(forKey: kPendingBackupsKey),
           let list = try? JSONDecoder().decode([AppBackup].self, from: data) {
            self.pendingBackups = list
        }
    }
    
    func savePendingBackups() {
        if let data = try? JSONEncoder().encode(pendingBackups) {
            UserDefaults.standard.set(data, forKey: kPendingBackupsKey)
        }
    }
    
    func hasLCAppInfo(bundleID: String) -> Bool {
        guard let app = installedApps.first(where: { $0.bundleID == bundleID }) else { return false }
        let url = app.url.appendingPathComponent("LCAppInfo.plist")
        return FileManager.default.fileExists(atPath: url.path)
    }
    
    func checkUpdateStatus(for backup: AppBackup) -> Bool {
        if finalizingUpdates.contains(backup.id) { return true }
        refreshInstalledApps()
        
        let bundleID = backup.bundleID
        guard isAppInstalled(bundleID: bundleID) else {
            Logger.shared.log("CheckUpdate: App \(bundleID) not installed.")
            return false
        }
        
        if hasLCAppInfo(bundleID: bundleID) {
            // Verify if the plist is actually new (created after backup)
            // This prevents using a plist that might have come with the IPA or wasn't removed correctly
            if let app = installedApps.first(where: { $0.bundleID == bundleID }) {
                let plistURL = app.url.appendingPathComponent("LCAppInfo.plist")
                
                // 1. Check Creation Date
                if let attrs = try? FileManager.default.attributesOfItem(atPath: plistURL.path),
                   let date = attrs[.creationDate] as? Date {
                    // If plist is older than backup, it's not the new one generated by LiveContainer
                    // We add a small buffer (e.g. 1 second) to avoid precision issues
                    if date < backup.date {
                        Logger.shared.log("CheckUpdate: LCAppInfo.plist is older than backup. Plist: \(date), Backup: \(backup.date)")
                        return false
                    } else {
                        Logger.shared.log("CheckUpdate: New LCAppInfo found. Plist: \(date), Backup: \(backup.date)")
                    }
                } else {
                    // If we can't read attributes, assume it's invalid/old to be safe
                    Logger.shared.log("CheckUpdate: Could not read attributes of LCAppInfo.plist")
                    return false
                }
                
                // 2. Check Content (Must have at least one container)
                if let data = try? Data(contentsOf: plistURL),
                   let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    if plist["LBoxNeedsPreparation"] as? Bool == true {
                        Logger.shared.log("CheckUpdate: Waiting for LiveContainer to patch and sign the updated binary.")
                        return false
                    }
                    
                    if let containers = plist["LCContainers"] as? [[String: Any]] {
                        if containers.isEmpty {
                            Logger.shared.log("CheckUpdate: LCAppInfo.plist has empty LCContainers. Waiting for LiveContainer to populate it.")
                            return false
                        }
                    } else {
                        Logger.shared.log("CheckUpdate: LCAppInfo.plist missing LCContainers key. Waiting...")
                        return false
                    }
                } else {
                    Logger.shared.log("CheckUpdate: Could not read LCAppInfo.plist content.")
                    return false
                }
            }
            
            if backup.hadLCAppInfo {
                Logger.shared.log("CheckUpdate: Finalizing update for \(backup.appName)")
                finalizeUpdate(backup)
            } else {
                Logger.shared.log("CheckUpdate: Discarding backup for \(backup.appName) (No previous LCAppInfo)")
                discardBackup(backup)
            }
            return true
        }
        Logger.shared.log("CheckUpdate: No LCAppInfo.plist found for \(bundleID)")
        return false
    }
    
    func finalizeUpdate(_ backup: AppBackup) {
        guard !finalizingUpdates.contains(backup.id),
              let app = installedApps.first(where: { $0.bundleID == backup.bundleID }) else { return }
        finalizingUpdates.insert(backup.id)
        let newInfo = app.url.appendingPathComponent("LCAppInfo.plist")
        let oldInfo = backupDirectory.appendingPathComponent(backup.backupPath)
            .appendingPathComponent(backup.originalInstallPath).appendingPathComponent("LCAppInfo.plist")
        let dataRoot = currentDataApplicationFolder
        Task {
            defer { finalizingUpdates.remove(backup.id) }
            do {
                try await AppFileWorker.shared.finalizeUpdate(oldInfo: oldInfo, newInfo: newInfo, dataRoot: dataRoot)
                finalizingUpdates.remove(backup.id)
                discardBackup(backup)
                sendNotification(title: "Update Completed", body: "\(backup.appName) has been successfully updated.", type: .success)
            } catch {
                Logger.shared.log("FinalizeUpdate: \(error). Recovery backup retained.")
                recoveryFailure = UUID()
                sendNotification(title: "Update Needs Recovery", body: "\(error.localizedDescription) Your backup has been kept.", type: .error)
            }
        }
    }

    
    func restoreBackup(_ backup: AppBackup) {
        guard !finalizingUpdates.contains(backup.id) else { return }
        let backedUpApp = backupDirectory.appendingPathComponent(backup.backupPath)
            .appendingPathComponent(backup.originalInstallPath)
        let destination = currentAppsFolder.appendingPathComponent(backup.originalInstallPath)
        finalizingUpdates.insert(backup.id)
        Task {
            defer { finalizingUpdates.remove(backup.id) }
            do {
                try await AppFileWorker.shared.restore(backedUpApp, to: destination)
                finalizingUpdates.remove(backup.id)
                discardBackup(backup)
                refreshInstalledApps()
                sendNotification(title: "App Restored", body: backup.appName, type: .success)
            } catch {
                recoveryFailure = UUID()
                sendNotification(title: "Restore Failed", body: error.localizedDescription, type: .error)
            }
        }
    }

    
    func discardBackup(_ backup: AppBackup, deleteContainers: Bool = false) {
        guard !finalizingUpdates.contains(backup.id) else { return }
        let fileManager = FileManager.default
        let backupFolder = backupDirectory.appendingPathComponent(backup.backupPath)
        
        if deleteContainers {
            let backupAppURL = backupFolder.appendingPathComponent(backup.originalInstallPath)
            let lcInfoURL = backupAppURL.appendingPathComponent("LCAppInfo.plist")
            
            if fileManager.fileExists(atPath: lcInfoURL.path),
               let data = try? Data(contentsOf: lcInfoURL),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let containers = plist["LCContainers"] as? [[String: Any]],
               let dataAppFolder = currentDataApplicationFolder {
                
                for container in containers {
                    if let folderName = container["folderName"] as? String {
                        if let folderURL = UpdateRecovery.containerURL(named: folderName, in: dataAppFolder) {
                            try? fileManager.removeItem(at: folderURL)
                        }
                        print("Deleted backup container: \(folderName)")
                    }
                }
            }
        }
        
        try? fileManager.removeItem(at: backupFolder)
        
        if let index = pendingBackups.firstIndex(where: { $0.id == backup.id }) {
            pendingBackups.remove(at: index)
            savePendingBackups()
        }
    }
    
    private func restoreFolders() {
        restoreFolder(key: kCustomDownloadFolderKey) { self.customDownloadFolder = $0 }
        restoreFolder(key: kCustomLiveContainerFolderKey) { self.customLiveContainerFolder = $0 }
    }
    
    private func restoreFolder(key: String, assign: (URL) -> Void) {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
            if isStale {
               _ = url.startAccessingSecurityScopedResource()
               let newData = try url.bookmarkData()
               UserDefaults.standard.set(newData, forKey: key)
               url.stopAccessingSecurityScopedResource()
            }
            if url.startAccessingSecurityScopedResource() {
                assign(url)
            }
        } catch { }
    }
    
    private func reconnectExistingTasks() {
        urlSession.getAllTasks { tasks in
            Task { @MainActor in
                for task in tasks {
                    guard let downloadTask = task as? URLSessionDownloadTask,
                          let url = downloadTask.originalRequest?.url else { continue }

                    guard downloadTask.state == .running || downloadTask.state == .suspended else { continue }
                    if let current = self.tasks[url], current.taskIdentifier != downloadTask.taskIdentifier { continue }
                    
                    self.tasks[url] = downloadTask
                    
                    if downloadTask.state == .running {
                        let written = downloadTask.countOfBytesReceived
                        let expected = downloadTask.countOfBytesExpectedToReceive
                        let p = expected > 0 ? Double(written) / Double(expected) : 0.0
                        self.downloadStates[url] = .downloading(progress: p, written: written, total: expected)
                    } else if downloadTask.state == .suspended {
                        self.downloadStates[url] = .paused
                    }
                }
                
                for (urlStr, _) in self.diskResumeDataPaths {
                    if let url = URL(string: urlStr), self.tasks[url] == nil {
                        self.downloadStates[url] = .paused
                    }
                }
            }
        }
    }
    
    private func restoreResumeDataMapping() {
        if let map = UserDefaults.standard.dictionary(forKey: kResumeDataMapKey) as? [String: String] {
            self.diskResumeDataPaths = map
        }
    }
    
    private func saveResumeDataMapping() {
        UserDefaults.standard.set(diskResumeDataPaths, forKey: kResumeDataMapKey)
    }
    
    private func storeResumeData(_ data: Data, for url: URL) {
        clearResumeData(for: url)
        let filename = UUID().uuidString
        let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
        do {
            try data.write(to: fileURL)
            diskResumeDataPaths[url.absoluteString] = filename
            saveResumeDataMapping()
            resumeDataMap[url] = data
        } catch {
            print("Failed to save resume data: \(error)")
        }
    }
    
    private func retrieveResumeData(for url: URL) -> Data? {
        if let data = resumeDataMap[url] { return data }
        if let filename = diskResumeDataPaths[url.absoluteString] {
            let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
            if let data = try? Data(contentsOf: fileURL) { return data }
        }
        return nil
    }
    
    private func clearResumeData(for url: URL) {
        resumeDataMap[url] = nil
        if let filename = diskResumeDataPaths.removeValue(forKey: url.absoluteString) {
            let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: fileURL)
            saveResumeDataMapping()
        }
    }
    
    func setCustomFolder(_ url: URL, forApps: Bool) {
        do {
            guard url.startAccessingSecurityScopedResource() else { return }
            let bookmarkData = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            let key = forApps ? kCustomLiveContainerFolderKey : kCustomDownloadFolderKey
            UserDefaults.standard.set(bookmarkData, forKey: key)
            
            if forApps {
                self.customLiveContainerFolder?.stopAccessingSecurityScopedResource()
                self.customLiveContainerFolder = url
                self.isAutoUnzipEnabled = true // Auto-enable as requested
                refreshInstalledApps()
            } else {
                self.customDownloadFolder?.stopAccessingSecurityScopedResource()
                self.customDownloadFolder = url
                refreshFileList()
            }
        } catch {
            url.stopAccessingSecurityScopedResource()
            sendNotification(title: "Folder Access Failed", body: error.localizedDescription, type: .error)
        }
    }
    
    func clearCustomFolder(forApps: Bool) {
        let key = forApps ? kCustomLiveContainerFolderKey : kCustomDownloadFolderKey
        UserDefaults.standard.removeObject(forKey: key)
        if forApps {
            self.customLiveContainerFolder?.stopAccessingSecurityScopedResource()
            self.customLiveContainerFolder = nil
            refreshInstalledApps()
        } else {
            self.customDownloadFolder?.stopAccessingSecurityScopedResource()
            self.customDownloadFolder = nil
            refreshFileList()
        }
    }
    
    func startDownload(url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, getLocalFile(for: url) == nil else { return }
        if let task = tasks[url] {
            if task.state == .suspended {
                downloadStates[url] = .downloading(progress: 0, written: task.countOfBytesReceived, total: task.countOfBytesExpectedToReceive)
                task.resume()
            }
            return
        }
        pendingPauseTasks[url] = nil
        beginDownload(url: url)
    }

    private func beginDownload(url: URL) {
        let task: URLSessionDownloadTask
        if let data = retrieveResumeData(for: url) {
            task = urlSession.downloadTask(withResumeData: data)
        } else {
            task = urlSession.downloadTask(with: url)
        }
        tasks[url] = task
        downloadStates[url] = .downloading(progress: 0, written: 0, total: -1)
        task.resume()
    }

    func pauseDownload(url: URL) {
        guard let task = tasks[url], !processingTasks.contains(task.taskIdentifier) else { return }
        let identifier = task.taskIdentifier
        pendingPauseTasks[url] = identifier
        tasks[url] = nil
        downloadStates[url] = .paused
        task.cancel { [weak self] data in
            guard let self else { return }
            Task { @MainActor in
                guard self.pendingPauseTasks[url] == identifier else { return }
                self.pendingPauseTasks[url] = nil
                if let data { self.storeResumeData(data, for: url) }
                else { self.clearResumeData(for: url) }
            }
        }
    }

    func resumeDownload(url: URL) {
        // Missing/expired resume data starts a fresh task, without recursive calls.
        startDownload(url: url)
    }

    func cancelDownload(url: URL) {
        if let task = tasks[url], processingTasks.contains(task.taskIdentifier) { return }
        let task = tasks.removeValue(forKey: url)
        pendingPauseTasks[url] = nil
        clearResumeData(for: url)
        downloadStates[url] = nil
        task?.cancel()
    }

    
    func isDownloading(url: URL) -> Bool {
        if case .downloading = getStatus(for: url) { return true }
        return false
    }
    
    func isPaused(url: URL) -> Bool {
        if case .paused = getStatus(for: url) { return true }
        return false
    }
    
    func refreshFileList() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: currentDownloadFolder, includingPropertiesForKeys: nil)
            let filtered = files.filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension != "app" }
            self.fileList = filtered
        } catch { self.fileList = [] }
    }
    
    func refreshInstalledApps() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: currentAppsFolder, includingPropertiesForKeys: nil)
            var newApps: [LocalApp] = []
            for file in files where file.pathExtension == "app" {
                let plistURL = file.appendingPathComponent("Info.plist")
                var name = file.deletingPathExtension().lastPathComponent
                var bundleID = "unknown"
                var version: String? = nil
                var iconURL: URL? = nil
                
                if let plistData = try? Data(contentsOf: plistURL),
                   let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
                    if let bid = plist["CFBundleIdentifier"] as? String {
                        bundleID = bid.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if let displayName = plist["CFBundleDisplayName"] as? String {
                        name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if let bundleName = plist["CFBundleName"] as? String {
                        name = bundleName.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    
                    if let ver = plist["CFBundleShortVersionString"] as? String {
                        version = ver
                    } else if let ver = plist["CFBundleVersion"] as? String {
                        version = ver
                    }
                    
                    var iconFiles: [String] = []
                    if let iconsDict = plist["CFBundleIcons"] as? [String: Any],
                       let primaryIcon = iconsDict["CFBundlePrimaryIcon"] as? [String: Any],
                       let files = primaryIcon["CFBundleIconFiles"] as? [String] {
                        iconFiles.append(contentsOf: files)
                    }
                    if let ipadIconsDict = plist["CFBundleIcons~ipad"] as? [String: Any],
                       let primaryIcon = ipadIconsDict["CFBundlePrimaryIcon"] as? [String: Any],
                       let files = primaryIcon["CFBundleIconFiles"] as? [String] {
                        iconFiles.append(contentsOf: files)
                    }
                    if let legacyFiles = plist["CFBundleIconFiles"] as? [String] {
                        iconFiles.append(contentsOf: legacyFiles)
                    }
                    
                    for iconName in iconFiles.reversed() {
                        if let found = findIconFile(in: file, name: iconName) { iconURL = found; break }
                    }
                    
                    if iconURL == nil {
                        iconURL = findIconFile(in: file, name: "AppIcon60x60") ?? findIconFile(in: file, name: "AppIcon")
                    }
                }
                newApps.append(LocalApp(name: name, bundleID: bundleID, version: version, url: file, iconURL: iconURL))
            }
            self.installedApps = newApps
        } catch { self.installedApps = [] }
    }
    
    private func findIconFile(in folder: URL, name: String) -> URL? {
        let extensions = ["png", "jpg"]
        let candidates = [name, "\(name)@2x", "\(name)@3x", "\(name)60x60@2x"]
        for c in candidates {
            for e in extensions {
                let f = folder.appendingPathComponent("\(c).\(e)")
                if FileManager.default.fileExists(atPath: f.path) { return f }
            }
        }
        return nil
    }
    
    func renameFile(_ fileURL: URL, newName: String) {
        guard !newName.isEmpty, !newName.contains("/"), !newName.contains("\\"), newName != ".", newName != ".." else { return }
        let folder = fileURL.deletingLastPathComponent()
        let newURL = folder.appendingPathComponent(newName)
        do {
            let scoped = startAccessing(fileURL)
            defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
            if FileManager.default.fileExists(atPath: newURL.path) {
                print("Error: File already exists")
                return
            }
            try FileManager.default.moveItem(at: fileURL, to: newURL)
            for (source, filename) in downloadFileIndex where filename == fileURL.lastPathComponent {
                downloadFileIndex[source] = newURL.lastPathComponent
            }
            saveDownloadFileIndex()
            refreshFileList()
        } catch {
            print("Rename failed: \(error)")
        }
    }
    
    func deleteFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        forgetFile(url)
        refreshFileList()
    }
    
    func deleteApp(_ app: LocalApp) {
        let fileManager = FileManager.default
        let lcInfoURL = app.url.appendingPathComponent("LCAppInfo.plist")
        if fileManager.fileExists(atPath: lcInfoURL.path),
           let data = try? Data(contentsOf: lcInfoURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let containers = plist["LCContainers"] as? [[String: Any]],
           let dataAppFolder = currentDataApplicationFolder {
            for container in containers {
                if let folderName = container["folderName"] as? String {
                    if let container = UpdateRecovery.containerURL(named: folderName, in: dataAppFolder) {
                        try? fileManager.removeItem(at: container)
                    }
                }
            }
        }
        try? fileManager.removeItem(at: app.url)
        refreshInstalledApps()
    }
    
    func clearAllFiles() {
        // Only clear visible downloaded files, never installation staging directories.
        for file in fileList {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true { deleteFile(file) }
        }
        refreshFileList()
    }

    func convertToApp(file: URL) {
        guard !extractingFiles.contains(file) else { return }
        extractingFiles.insert(file)
        Task {
            let scoped = file.startAccessingSecurityScopedResource()
            defer {
                if scoped { file.stopAccessingSecurityScopedResource() }
                extractingFiles.remove(file)
                refreshFileList()
                refreshInstalledApps()
            }
            do { try await extractApp(from: file) }
            catch { sendNotification(title: "Installation Failed", body: error.localizedDescription, type: .error) }
        }
    }

    
    func importFile(at source: URL) {
        let dest = currentDownloadFolder.appendingPathComponent(source.lastPathComponent)
        do {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            guard source.standardizedFileURL.path != dest.standardizedFileURL.path else { return }
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: source, to: dest)
            refreshFileList()
        } catch {
            print("Import failed: \(error)")
        }
    }
    
    private func extractApp(from sourceURL: URL) async throws {
        let folder = currentAppsFolder
        let prepared = try await AppFileWorker.shared.prepare(sourceURL, in: folder)
        refreshInstalledApps()
        if let existing = installedApps.first(where: { $0.bundleID == prepared.bundleID }) {
            let pending = PendingInstallation(
                appName: existing.name, bundleID: prepared.bundleID,
                tempPayloadURL: prepared.payload, extractedAppURL: prepared.app,
                sourceArchiveURL: sourceURL, existingApp: existing
            )
            if pendingInstallation == nil { pendingInstallation = pending }
            else { installationQueue.append(pending) }
            return
        }
        do {
            try await AppFileWorker.shared.installSeparate(prepared.app, bundleID: prepared.bundleID, in: folder)
            try? FileManager.default.removeItem(at: prepared.root)
            removeSourceAfterInstall(sourceURL)
        } catch {
            try? FileManager.default.removeItem(at: prepared.root)
            throw error
        }
    }

    private func removeSourceAfterInstall(_ source: URL) {
        if source.deletingLastPathComponent().standardizedFileURL.path == currentDownloadFolder.standardizedFileURL.path {
            deleteFile(source)
        }
    }

    func finalizeInstallation(action: InstallAction) {
        guard let pending = pendingInstallation, !isFinalizingInstallation else { return }
        isFinalizingInstallation = true
        let folder = currentAppsFolder
        let backupRoot = backupDirectory
        Task {
            defer {
                try? FileManager.default.removeItem(at: pending.tempPayloadURL.deletingLastPathComponent())
                isFinalizingInstallation = false
                pendingInstallation = installationQueue.isEmpty ? nil : installationQueue.removeFirst()
                refreshFileList()
                refreshInstalledApps()
            }
            do {
                switch action {
                case .installSeparate:
                    try await AppFileWorker.shared.installSeparate(pending.extractedAppURL, bundleID: pending.bundleID, in: folder)
                case .updateExisting:
                    guard let existing = pending.existingApp else { throw LBoxFileError.invalidBundle }
                    guard !pendingBackups.contains(where: { $0.bundleID == existing.bundleID }) else {
                        throw LBoxFileError.invalidMetadata
                    }
                    let backupUUID = UUID().uuidString
                    let backupURL = backupRoot.appendingPathComponent(backupUUID).appendingPathComponent(existing.url.lastPathComponent)
                    let hadInfo = FileManager.default.fileExists(atPath: existing.url.appendingPathComponent("LCAppInfo.plist").path)
                    try await AppFileWorker.shared.createBackup(of: existing.url, at: backupURL)
                    let record = AppBackup(
                        bundleID: existing.bundleID, appName: existing.name, version: existing.version,
                        backupPath: backupUUID, originalInstallPath: existing.url.lastPathComponent,
                        date: Date(), hadLCAppInfo: hadInfo
                    )
                    pendingBackups.append(record)
                    savePendingBackups()
                    if hadInfo {
                        try await AppFileWorker.shared.prepareUpdateMetadata(backup: backupURL, prepared: pending.extractedAppURL)
                    }
                    try await AppFileWorker.shared.replace(existing.url, with: pending.extractedAppURL)
                case .cancel:
                    return
                }
                removeSourceAfterInstall(pending.sourceArchiveURL)
            } catch {
                // Keep both the source IPA and any recovery backup after a failure.
                sendNotification(title: "Installation Failed", body: error.localizedDescription, type: .error)
            }
        }
    }

    func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        guard identifier == kBackgroundSessionID else { completion(); return }
        backgroundCompletionHandler = completion
        finishBackgroundEventsIfReady()
    }

    private func finishBackgroundEventsIfReady() {
        guard backgroundEventsFinished, processingTasks.isEmpty,
              let completion = backgroundCompletionHandler else { return }
        backgroundEventsFinished = false
        backgroundCompletionHandler = nil
        completion()
    }

    
    private func startAccessing(_ url: URL) -> Bool {
        return url.startAccessingSecurityScopedResource()
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let source = downloadTask.originalRequest?.url else { return }
        let identifier = downloadTask.taskIdentifier
        // The delegate-provided URL disappears when this callback returns.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try DownloadFileIdentity.validate(downloadTask.response)
            try FileManager.default.moveItem(at: location, to: staged)
        } catch {
            Task { @MainActor in
                guard self.tasks[source]?.taskIdentifier == identifier else { return }
                self.tasks[source] = nil
                self.clearResumeData(for: source)
                self.downloadStates[source] = .failed(error.localizedDescription)
                self.sendNotification(title: "Download Failed", body: error.localizedDescription, type: .error)
            }
            return
        }
        Task { @MainActor in
            guard self.tasks[source]?.taskIdentifier == identifier else {
                try? FileManager.default.removeItem(at: staged)
                return
            }
            self.processingTasks.insert(identifier)
            self.downloadStates[source] = .processing
            var downloadedFile: URL?
            defer {
                try? FileManager.default.removeItem(at: staged)
                if let downloadedFile { self.extractingFiles.remove(downloadedFile) }
                self.processingTasks.remove(identifier)
                self.finishBackgroundEventsIfReady()
            }
            do {
                if source.pathExtension.isEmpty || source.pathExtension.lowercased() == "ipa" {
                    try await AppFileWorker.shared.validateIPA(at: staged)
                }
                guard self.tasks[source]?.taskIdentifier == identifier else { return }
                let folder = self.currentDownloadFolder
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let final = folder.appendingPathComponent(DownloadFileIdentity.filename(for: source))
                if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
                try FileManager.default.moveItem(at: staged, to: final)
                downloadedFile = final
                self.downloadFileIndex[source.absoluteString] = final.lastPathComponent
                self.saveDownloadFileIndex()
                if self.isAutoUnzipEnabled && final.pathExtension.lowercased() == "ipa" {
                    self.extractingFiles.insert(final)
                    try await self.extractApp(from: final)
                }
                if self.tasks[source]?.taskIdentifier == identifier {
                    self.tasks[source] = nil
                    self.downloadStates[source] = nil
                    self.clearResumeData(for: source)
                    self.sendNotification(title: "Download Complete", body: source.lastPathComponent, type: .success)
                }
            } catch {
                if self.tasks[source]?.taskIdentifier == identifier {
                    self.tasks[source] = nil
                    self.clearResumeData(for: source)
                    // A valid IPA remains available for manual installation if extraction failed.
                    self.downloadStates[source] = downloadedFile == nil ? .failed(error.localizedDescription) : nil
                    self.sendNotification(title: "Download or Installation Failed", body: error.localizedDescription, type: .error)
                }
            }
            self.refreshFileList()
            self.refreshInstalledApps()
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let source = downloadTask.originalRequest?.url else { return }
        let identifier = downloadTask.taskIdentifier
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        Task { @MainActor in
            guard self.tasks[source]?.taskIdentifier == identifier, !self.processingTasks.contains(identifier) else { return }
            self.downloadStates[source] = .downloading(progress: progress, written: totalBytesWritten, total: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let source = task.originalRequest?.url, let error = error as NSError? else { return }
        let identifier = task.taskIdentifier
        Task { @MainActor in
            guard self.tasks[source]?.taskIdentifier == identifier else { return }
            self.tasks[source] = nil
            if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                self.storeResumeData(data, for: source)
                self.downloadStates[source] = .paused
            } else {
                self.clearResumeData(for: source)
                self.downloadStates[source] = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        guard let source = task.originalRequest?.url else { return }
        let identifier = task.taskIdentifier
        Task { @MainActor in
            guard self.tasks[source]?.taskIdentifier == identifier else { return }
            self.downloadStates[source] = .waitingForConnection
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundEventsFinished = true
            self.finishBackgroundEventsIfReady()
        }
    }
}
