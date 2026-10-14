import Foundation
import CryptoKit

enum LBoxFileError: LocalizedError {
    case invalidArchive
    case invalidBundle
    case invalidMetadata
    case missingContainerMetadata
    case ambiguousRecovery
    case updateBusy
    case missingRecoveryBundle
    case updateTargetMismatch
    case unsupportedArchive
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "The downloaded file is not a valid IPA archive."
        case .invalidBundle: return "The archive does not contain a valid application bundle."
        case .invalidMetadata: return "Update metadata could not be verified. The recovery backup has been kept."
        case .missingContainerMetadata: return "The saved app has incomplete LiveContainer metadata. Restore the previous version, open it once in LiveContainer, then retry. Your IPA and recovery backup have been kept."
        case .ambiguousRecovery: return "More than one recovery backup exists for this installation. Restore the previous version before retrying."
        case .updateBusy: return "This app's previous update is still being finalized. Return to LBox and retry when it finishes."
        case .missingRecoveryBundle: return "The recovery bundle is missing or does not match this app. Re-select the original LiveContainer folder or restore the app before retrying."
        case .updateTargetMismatch: return "The downloaded app or selected installation changed. Nothing was replaced. Select the app again and retry the update."
        case .unsupportedArchive: return "Archive support is unavailable in this build."
        case .httpStatus(let status): return "The download server returned HTTP \(status)."
        }
    }
}

enum DownloadFileIdentity {
    static func displayName(for filename: String) -> String {
        let prefix = filename.prefix(64)
        if filename.count > 65, filename.dropFirst(64).first == "-",
           prefix.allSatisfy({ "0123456789abcdef".contains($0) }) {
            return String(filename.dropFirst(65))
        }
        return filename
    }

    static func filename(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        var name = url.lastPathComponent
        if name.isEmpty { name = "download" }
        if url.pathExtension.isEmpty { name += ".ipa" }
        // Bound the component length, leaving room for the stable URL identity.
        let stem = String((name as NSString).deletingPathExtension.prefix(80))
        let ext = (name as NSString).pathExtension
        return "\(digest)-\(stem).\(ext)"
    }

    static func validate(_ response: URLResponse?) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else { throw LBoxFileError.httpStatus(http.statusCode) }
    }
}

enum UpdateRecovery {
    private static let generatedKeys: Set<String> = [
        "LCPatchRevision", "LCJITLessSignID", "LCExpirationDate", "LCTeamId",
        "LCTweakLoaderCantInject", "segCountMismatch", "LCClassicModeCache", "LBoxNeedsPreparation"
    ]

    /// Carry forward this device's trusted container/settings metadata before
    /// replacing an app. LiveContainer still must patch and sign the new binary.
    static func prepareMetadata(
        oldInfo: URL, preparedInfo: URL,
        writer: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) throws {
        var info = try trustedMetadata(at: oldInfo)
        for key in generatedKeys { info.removeValue(forKey: key) }
        info["LCPatchRevision"] = -1
        info["LBoxNeedsPreparation"] = true
        // LiveContainer stores fractional NSDate values. XML rounds those dates
        // to whole seconds, causing the subsequent equality check to fail.
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        try writer(data, preparedInfo)
        guard let verified = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: preparedInfo), format: nil
        ) as? [String: Any], NSDictionary(dictionary: verified).isEqual(to: info) else {
            throw LBoxFileError.invalidMetadata
        }
    }

    private static func trustedMetadata(at url: URL) throws -> [String: Any] {
        guard var info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil
        ) as? [String: Any] else { throw LBoxFileError.invalidMetadata }
        if info["LCContainers"] == nil && info["LCDataUUID"] == nil {
            // Installed but never launched: there is no existing user container.
            info["LCContainers"] = [[String: Any]]()
        }
        guard let containers = info["LCContainers"] as? [[String: Any]],
              !containers.isEmpty || info["LCDataUUID"] == nil else {
            throw LBoxFileError.missingContainerMetadata
        }
        return info
    }

    static func containerURL(named name: String, in root: URL) -> URL? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else { return nil }
        let parent = root.resolvingSymlinksInPath().standardizedFileURL
        let child = parent.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
        guard child.deletingLastPathComponent().path == parent.path else { return nil }
        return child
    }

    /// Commit verified metadata before removing any newly generated containers.
    /// Throwing leaves the old metadata and recovery bundle available to the caller.
    static func patchMetadata(
        oldInfo: URL, newInfo: URL, dataRoot: URL?,
        writer: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) throws {
        let old = try trustedMetadata(at: oldInfo)
        let newData = try Data(contentsOf: newInfo)
        guard var updated = try PropertyListSerialization.propertyList(from: newData, format: nil) as? [String: Any],
              let oldContainers = old["LCContainers"] as? [[String: Any]],
              let newContainers = updated["LCContainers"] as? [[String: Any]] else {
            throw LBoxFileError.invalidMetadata
        }
        let retained = Set(oldContainers.compactMap { $0["folderName"] as? String })
        for (key, value) in old where !generatedKeys.contains(key) {
            // A never-launched app has no user container to restore. Keep the
            // first container LiveContainer creates instead of erasing it.
            if oldContainers.isEmpty && (key == "LCContainers" || key == "LCDataUUID") { continue }
            updated[key] = value
        }
        let patched = try PropertyListSerialization.data(fromPropertyList: updated, format: .binary, options: 0)
        try writer(patched, newInfo)
        guard let verified = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: newInfo), format: nil
        ) as? [String: Any], NSDictionary(dictionary: verified).isEqual(to: updated) else {
            throw LBoxFileError.invalidMetadata
        }
        if let dataRoot, !oldContainers.isEmpty {
            for container in newContainers {
                guard let name = container["folderName"] as? String, !retained.contains(name),
                      let url = containerURL(named: name, in: dataRoot) else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Move the old bundle aside on the same volume and roll back if replacement fails.
    static func replaceBundle(at destination: URL, with prepared: URL) throws {
        let manager = FileManager.default
        let rollback = destination.deletingLastPathComponent().appendingPathComponent(".lbox-rollback-" + UUID().uuidString)
        try manager.moveItem(at: destination, to: rollback)
        do {
            try manager.moveItem(at: prepared, to: destination)
        } catch {
            // Leave the rollback bundle in place if restoration itself fails.
            if !manager.fileExists(atPath: destination.path) {
                try manager.moveItem(at: rollback, to: destination)
            }
            throw error
        }
        try? manager.removeItem(at: rollback)
    }
}
