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
        try expect(manager.fileExists(atPath: dataRoot.appendingPathComponent("shared").path), "Containers referenced by the old app must survive")
        try expect(manager.fileExists(atPath: dataRoot.appendingPathComponent("retained").path), "Existing user data must survive")
        try expect(!manager.fileExists(atPath: dataRoot.appendingPathComponent("temporary").path), "Unused temporary container should be cleaned")
        try expect(UpdateRecovery.containerURL(named: "../outside", in: dataRoot) == nil, "Container paths must stay inside data storage")

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
