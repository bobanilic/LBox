import Foundation

// Only UI notification/log collaborators are stubbed. Checks use the production
// repository decoder, file operations, and DownloadManager with an offline session.
struct InAppNotification {
    enum NotificationType { case success, info, error }
}
@MainActor final class NotificationManager {
    static let shared = NotificationManager()
    func show(title: String, message: String, type: InAppNotification.NotificationType) {}
}
@MainActor final class Logger {
    static let shared = Logger()
    func log(_ message: String) {}
}

final class OfflineProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {} // No network: remains pending until cancellation.
    override func stopLoading() {}
}

enum CheckError: Error { case failed(String), injectedWriteFailure }

@main enum QuickChecks {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckError.failed(message) }
    }

    static func writePlist(_ plist: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    @MainActor static func waitForInstallation(_ downloads: DownloadManager) async throws {
        let deadline = Date().addingTimeInterval(2)
        while downloads.pendingInstallation != nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(downloads.pendingInstallation == nil, "Installation must finish promptly")
    }

    @MainActor static func main() async throws {
        let started = Date()
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("lbox-checks-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let mixed = #"{"name":"Mixed","apps":[{"name":"Legacy","bundleIdentifier":"test.legacy","version":"1.0","downloadURL":"https://one.test/app.ipa"},{"name":"Modern","bundleIdentifier":"test.modern","versions":[{"version":"2.0","downloadURL":"https://two.test/app.ipa"},{"version":"1.0","downloadURL":"https://two.test/app.ipa"}]}]}"#
        let repo = try JSONDecoder().decode(RepoResponse.self, from: Data(mixed.utf8))
        try expect(repo.apps.count == 3, "Mixed feeds must keep legacy entries and modern history")
        try expect(Set(repo.apps.map { $0.id }).count == 3, "Versions sharing an endpoint need distinct UI identities")
        let hybrid = #"{"apps":[{"name":"Delta","bundleIdentifier":"test.delta","version":"2.0","downloadURL":"https://one.test/v2.ipa","versions":[{"version":"2.0","downloadURL":"https://one.test/v2.ipa"},{"version":"1.0","downloadURL":"https://one.test/v1.ipa"}]}]}"#
        let hybridFeed = try JSONDecoder().decode(RepoResponse.self, from: Data(hybrid.utf8))
        try expect(hybridFeed.apps.count == 2, "A legacy current-version field must not hide versions[] history or duplicate the current release")
        var releases = hybridFeed.apps.map { value in var copy = value; copy.sourceRepoName = "First"; return copy }
        var otherSource = releases[0]
        otherSource.sourceRepoName = "Second"
        releases.append(otherSource)
        try expect(CatalogSelection.latestPerSource(releases).count == 2, "Search keeps the latest release from each source")
        try expect(CatalogSelection.latestPerSource(releases).allSatisfy { $0.version == "2.0" }, "Old releases belong in details, not duplicate search listings")
        try expect(CatalogSelection.history(for: releases[0], in: releases).count == 3, "Details expose older releases and alternative sources")
        try expect(CatalogSelection.spotlight(in: releases) == CatalogSelection.spotlight(in: Array(releases.reversed())), "Spotlight must not follow catalog sorting")
        try expect(CatalogSelection.spotlight(in: repo.apps) == nil, "Do not invent spotlight entries absent from enabled sources")
        let restored = try JSONDecoder().decode([AppItem].self, from: JSONEncoder().encode(repo.apps))
        try expect(restored == repo.apps, "Cached app metadata must round-trip")

        for (fixture, expectedApps) in [("side", 23), ("alt", 43)] {
            let data = try Data(contentsOf: URL(fileURLWithPath: "tests/fixtures/\(fixture).json"))
            let decoded = try JSONDecoder().decode(RepoResponse.self, from: data)
            try expect(Set(decoded.apps.map { $0.name }).count == expectedApps, "Actual \(fixture) feed must load all app listings")
            try expect(decoded.skippedRecords == 0, "Actual \(fixture) feed must decode without skipped apps")
        }
        let optionalMetadata = #"{"apps":[{"name":"Valid","bundleIdentifier":"test.valid","version":2,"size":"1024","localizedDescription":7,"downloadURL":"https://one.test/valid.ipa"},{"name":"Broken"}]}"#
        let tolerant = try JSONDecoder().decode(RepoResponse.self, from: Data(optionalMetadata.utf8))
        try expect(tolerant.apps.count == 1 && tolerant.skippedRecords == 1, "One malformed listing must not reject the entire feed")
        try expect(tolerant.apps[0].size == 1024 && tolerant.apps[0].version == "2", "Numeric/string metadata variants must remain usable")

        let fixtureURL = URL(string: "https://one.test/source.json")!
        let ordinaryResponse = URLResponse(url: fixtureURL, mimeType: "application/json", expectedContentLength: mixed.utf8.count, textEncodingName: "utf-8")
        guard case .data = try RepositoryTransport.payload(data: Data(mixed.utf8), response: ordinaryResponse) else {
            throw CheckError.failed("A valid feed with a plain URLResponse must load as in the working version")
        }
        let notModified = HTTPURLResponse(url: fixtureURL, statusCode: 304, httpVersion: nil, headerFields: nil)!
        guard case .notModified = try RepositoryTransport.payload(data: Data(), response: notModified) else {
            throw CheckError.failed("HTTP 304 must use the saved catalog instead of becoming a failed source")
        }
        do {
            _ = try RepositoryTransport.payload(data: Data("<html>closed</html>".utf8), response: ordinaryResponse)
            throw CheckError.failed("Web pages must not be accepted as app repositories")
        } catch RepositoryLoadError.notJSON {}

        let first = URL(string: "https://one.test/app.ipa")!
        let second = URL(string: "https://two.test/app.ipa")!
        let next = URL(string: "https://one.test/app.ipa?v=2")!
        try expect(DownloadFileIdentity.filename(for: first) != DownloadFileIdentity.filename(for: second), "Different hosts must not share files")
        try expect(DownloadFileIdentity.filename(for: first) != DownloadFileIdentity.filename(for: next), "Query-based versions must not share files")
        try expect(DownloadFileIdentity.filename(for: URL(string: "https://one.test/get")!).hasSuffix(".ipa"), "Extensionless endpoints must remain installable")
        let badResponse = HTTPURLResponse(url: first, statusCode: 404, httpVersion: nil, headerFields: nil)!
        do {
            try DownloadFileIdentity.validate(badResponse)
            throw CheckError.failed("HTTP 404 must not be accepted as a download")
        } catch LBoxFileError.httpStatus(404) {}
        try DownloadFileIdentity.validate(HTTPURLResponse(url: first, statusCode: 200, httpVersion: nil, headerFields: nil)!)

        let oldInfo = root.appendingPathComponent("old.plist")
        let newInfo = root.appendingPathComponent("new.plist")
        let dataRoot = root.appendingPathComponent("Data")
        for name in ["retained", "shared", "temporary"] {
            try manager.createDirectory(at: dataRoot.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try writePlist(["LCContainers": [["folderName": "retained"], ["folderName": "shared"]], "setting": "old"], to: oldInfo)
        try writePlist(["LCContainers": [["folderName": "temporary"], ["folderName": "shared"]]], to: newInfo)
        let preparedInfo = root.appendingPathComponent("prepared.plist")
        var originalInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: oldInfo), format: nil) as! [String: Any]
        originalInfo["LCDataUUID"] = "retained"
        originalInfo["LCPatchRevision"] = 7
        originalInfo["LCJITLessSignID"] = "stale-signature"
        try writePlist(originalInfo, to: oldInfo)
        do {
            try UpdateRecovery.prepareMetadata(oldInfo: oldInfo, preparedInfo: preparedInfo) { _, _ in throw CheckError.injectedWriteFailure }
            throw CheckError.failed("Failed metadata carryover must stop replacement")
        } catch CheckError.injectedWriteFailure {}
        try expect(!manager.fileExists(atPath: preparedInfo.path), "A failed preparation must leave the existing bundle untouched")
        try UpdateRecovery.prepareMetadata(oldInfo: oldInfo, preparedInfo: preparedInfo)
        let prepared = try PropertyListSerialization.propertyList(from: Data(contentsOf: preparedInfo), format: nil) as! [String: Any]
        try expect(prepared["LCDataUUID"] as? String == "retained", "An updated app must use its existing data on the first launch")
        try expect(prepared["LBoxNeedsPreparation"] as? Bool == true && prepared["LCPatchRevision"] as? Int == -1, "Copied settings must not make an unpatched binary appear ready")
        try expect(prepared["LCJITLessSignID"] == nil, "Old signing state must not carry over to a new executable")
        try writePlist(["LCContainers": [["folderName": "temporary"], ["folderName": "shared"]], "LCPatchRevision": 8, "LCJITLessSignID": "new-signature"], to: newInfo)
        let originalNewData = try Data(contentsOf: newInfo)
        do {
            try UpdateRecovery.patchMetadata(oldInfo: oldInfo, newInfo: newInfo, dataRoot: dataRoot) { _, _ in
                throw CheckError.injectedWriteFailure
            }
            throw CheckError.failed("Injected update-write failure must propagate")
        } catch CheckError.injectedWriteFailure {}
        let afterFailure = try Data(contentsOf: newInfo)
        try expect(afterFailure == originalNewData, "Failed write must retain existing metadata")
        try expect(manager.fileExists(atPath: oldInfo.path), "Failed write must retain recovery metadata")
        try expect(manager.fileExists(atPath: dataRoot.appendingPathComponent("temporary").path), "Cleanup must wait for verified metadata")
        try UpdateRecovery.patchMetadata(oldInfo: oldInfo, newInfo: newInfo, dataRoot: dataRoot)
        let finalized = try PropertyListSerialization.propertyList(from: Data(contentsOf: newInfo), format: nil) as! [String: Any]
        try expect(finalized["LCPatchRevision"] as? Int == 8 && finalized["LCJITLessSignID"] as? String == "new-signature", "Finalizing recovery must preserve LiveContainer's freshly generated signing state")
        try expect(manager.fileExists(atPath: dataRoot.appendingPathComponent("shared").path), "Containers referenced by the old app must survive")
        try expect(manager.fileExists(atPath: dataRoot.appendingPathComponent("retained").path), "Existing user data must survive")
        try expect(!manager.fileExists(atPath: dataRoot.appendingPathComponent("temporary").path), "Unused temporary container should be cleaned")
        try expect(UpdateRecovery.containerURL(named: "../outside", in: dataRoot) == nil, "Container paths must stay inside data storage")

        try writePlist(["setting": "never launched"], to: oldInfo)
        try UpdateRecovery.prepareMetadata(oldInfo: oldInfo, preparedInfo: preparedInfo)
        try manager.createDirectory(at: dataRoot.appendingPathComponent("first-launch"), withIntermediateDirectories: true)
        try writePlist(["LCContainers": [["folderName": "first-launch"]], "LCDataUUID": "first-launch"], to: newInfo)
        try UpdateRecovery.patchMetadata(oldInfo: oldInfo, newInfo: newInfo, dataRoot: dataRoot)
        let firstLaunch = try PropertyListSerialization.propertyList(from: Data(contentsOf: newInfo), format: nil) as! [String: Any]
        try expect(firstLaunch["LCDataUUID"] as? String == "first-launch", "Never-launched apps must retain their newly created first container")
        try expect((firstLaunch["LCContainers"] as? [[String: Any]])?.count == 1, "Finalization must not erase a first container")
        try expect(manager.fileExists(atPath: dataRoot.appendingPathComponent("first-launch").path), "First-launch data must not be deleted")
        try writePlist(["LCDataUUID": "existing-data"], to: oldInfo)
        do {
            try UpdateRecovery.prepareMetadata(oldInfo: oldInfo, preparedInfo: preparedInfo)
            throw CheckError.failed("Missing container metadata with existing data must fail safely")
        } catch LBoxFileError.missingContainerMetadata {}

        let installed = root.appendingPathComponent("Installed.app")
        try manager.createDirectory(at: installed, withIntermediateDirectories: true)
        let marker = installed.appendingPathComponent("old-marker")
        try Data("old".utf8).write(to: marker)
        do {
            try UpdateRecovery.replaceBundle(at: installed, with: root.appendingPathComponent("missing.app"))
            throw CheckError.failed("Replacing with a missing bundle must fail")
        } catch CheckError.failed(let message) { throw CheckError.failed(message) }
        catch {}
        try expect(manager.fileExists(atPath: marker.path), "Failed replacement must restore the installed bundle")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineProtocol.self]
        let downloads = DownloadManager(configuration: config)
        downloads.customDownloadFolder = root
        downloads.customLiveContainerFolder = root
        let priorBackups = UserDefaults.standard.data(forKey: "kPendingBackupsKey")
        downloads.pendingBackups = []
        defer {
            for backup in downloads.pendingBackups {
                try? manager.removeItem(at: downloads.backupDirectory.appendingPathComponent(backup.backupPath))
            }
            UserDefaults.standard.set(priorBackups, forKey: "kPendingBackupsKey")
        }
        let appsFolder = root.appendingPathComponent("Applications")
        let retryApp = appsFolder.appendingPathComponent("Retry.app")
        try manager.createDirectory(at: retryApp, withIntermediateDirectories: true)
        let originalAppInfo: [String: Any] = ["CFBundleIdentifier": "test.retry", "CFBundleName": "Retry", "CFBundleShortVersionString": "1.0"]
        try writePlist(originalAppInfo, to: retryApp.appendingPathComponent("Info.plist"))
        try writePlist(originalInfo, to: retryApp.appendingPathComponent("LCAppInfo.plist"))
        try Data("original-binary".utf8).write(to: retryApp.appendingPathComponent("original-marker"))
        let archive = root.appendingPathComponent("retry.ipa")
        try Data("retained-archive".utf8).write(to: archive)
        downloads.refreshInstalledApps()
        let existing = downloads.installedApps.first { $0.bundleID == "test.retry" }!
        let failingPayload = root.appendingPathComponent("failing/Payload")
        try manager.createDirectory(at: failingPayload, withIntermediateDirectories: true)
        downloads.pendingInstallation = PendingInstallation(appName: "Retry", bundleID: "test.retry", tempPayloadURL: failingPayload, extractedAppURL: failingPayload.appendingPathComponent("missing.app"), sourceArchiveURL: archive, existingApp: existing)
        downloads.finalizeInstallation(action: .updateExisting)
        try await waitForInstallation(downloads)
        try expect(downloads.pendingBackups.count == 1, "A failed update must keep its original recovery backup")
        let savedID = downloads.pendingBackups[0].id
        try expect(downloads.pendingBackups[0].replacementCompleted == false, "A failed installation must not be presented as awaiting launch")
        try expect(!downloads.checkUpdateStatus(for: downloads.pendingBackups[0]), "Opening the original app must not finalize a failed replacement")
        try expect(manager.fileExists(atPath: archive.path) && manager.fileExists(atPath: retryApp.appendingPathComponent("original-marker").path), "Failure must preserve both the IPA and installed bundle")

        // Retry once with the new transaction state and again with an old-version
        // backup record lacking that state. Both must keep the same original backup.
        for version in ["2.0", "3.0"] {
            if version == "3.0" {
                downloads.pendingBackups[0].replacementCompleted = nil
                let legacyData = try JSONEncoder().encode(downloads.pendingBackups)
                let migrated = try JSONDecoder().decode([AppBackup].self, from: legacyData)
                try expect(migrated[0].replacementCompleted == nil, "Earlier recovery records must decode without transaction state")
                downloads.pendingBackups = migrated
            }
            let payload = root.appendingPathComponent("retry-\(version)/Payload")
            let preparedApp = payload.appendingPathComponent("Retry.app")
            try manager.createDirectory(at: preparedApp, withIntermediateDirectories: true)
            var newAppInfo = originalAppInfo
            newAppInfo["CFBundleShortVersionString"] = version
            try writePlist(newAppInfo, to: preparedApp.appendingPathComponent("Info.plist"))
            downloads.refreshInstalledApps()
            downloads.pendingInstallation = PendingInstallation(appName: "Retry", bundleID: "test.retry", tempPayloadURL: payload, extractedAppURL: preparedApp, sourceArchiveURL: archive, existingApp: downloads.installedApps.first { $0.bundleID == "test.retry" })
            downloads.finalizeInstallation(action: .updateExisting)
            try await waitForInstallation(downloads)
            try expect(downloads.getInstalledVersion(bundleID: "test.retry") == version, "Retry must replace the app despite a retained backup")
            try expect(downloads.pendingBackups.count == 1 && downloads.pendingBackups[0].id == savedID, "Retries must reuse, never overwrite or duplicate, the original recovery bundle")
            try expect(downloads.pendingBackups[0].replacementCompleted == true, "Only successful replacement may await LiveContainer preparation")
            let recovery = downloads.backupDirectory.appendingPathComponent(savedID).appendingPathComponent("Retry.app")
            try expect(manager.fileExists(atPath: recovery.appendingPathComponent("original-marker").path), "Retry must retain the original binary for restoration")
            let retryMetadata = try PropertyListSerialization.propertyList(from: Data(contentsOf: retryApp.appendingPathComponent("LCAppInfo.plist")), format: nil) as! [String: Any]
            try expect(retryMetadata["LCDataUUID"] as? String == "retained", "Retries must preserve the original data container")
        }
        var readyMetadata = originalInfo
        readyMetadata["LCPatchRevision"] = 7
        try writePlist(readyMetadata, to: retryApp.appendingPathComponent("LCAppInfo.plist"))
        let missingInstallation = AppBackup(bundleID: "test.retry", appName: "Sibling", version: "1.0", backupPath: "absent-backup", originalInstallPath: "Sibling.app", date: .distantPast, hadLCAppInfo: true, replacementCompleted: true)
        try expect(!downloads.checkUpdateStatus(for: missingInstallation), "A separate app with the same bundle ID must not finalize another installation's backup")
        downloads.downloadStates[first] = .paused
        downloads.resumeDownload(url: first)
        try expect(downloads.isDownloading(url: first), "A paused task without resume data must restart without recursion")
        downloads.pauseDownload(url: first)
        downloads.resumeDownload(url: first)
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(downloads.isDownloading(url: first), "Old cancellation callbacks must not pause the new task")
        downloads.cancelDownload(url: first)
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(downloads.getStatus(for: first) == .none, "Cancel must not resurrect a paused download")
        print("LBox quick regression checks passed in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
    }
}
