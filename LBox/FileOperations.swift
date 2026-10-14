import Foundation
import CryptoKit

enum LBoxFileError: LocalizedError {
    case invalidArchive
    case invalidBundle
    case invalidMetadata
    case unsupportedArchive
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "The downloaded file is not a valid IPA archive."
        case .invalidBundle: return "The archive does not contain a valid application bundle."
        case .invalidMetadata: return "Update metadata could not be verified. The recovery backup has been kept."
        case .unsupportedArchive: return "Archive support is unavailable in this build."
        case .httpStatus(let status): return "The download server returned HTTP \(status)."
        }
    }
}

enum DownloadFileIdentity {
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
        let oldData = try Data(contentsOf: oldInfo)
        let newData = try Data(contentsOf: newInfo)
        guard let old = try PropertyListSerialization.propertyList(from: oldData, format: nil) as? [String: Any],
              var updated = try PropertyListSerialization.propertyList(from: newData, format: nil) as? [String: Any],
              let oldContainers = old["LCContainers"] as? [[String: Any]],
              let newContainers = updated["LCContainers"] as? [[String: Any]] else {
            throw LBoxFileError.invalidMetadata
        }
        let retained = Set(oldContainers.compactMap { $0["folderName"] as? String })
        for (key, value) in old { updated[key] = value }
        let patched = try PropertyListSerialization.data(fromPropertyList: updated, format: .xml, options: 0)
        try writer(patched, newInfo)
        guard let verified = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: newInfo), format: nil
        ) as? [String: Any], NSDictionary(dictionary: verified).isEqual(to: updated) else {
            throw LBoxFileError.invalidMetadata
        }
        if let dataRoot {
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
