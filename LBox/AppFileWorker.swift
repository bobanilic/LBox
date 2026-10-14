import Foundation
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

struct PreparedAppArchive: Sendable {
    let root: URL
    let payload: URL
    let app: URL
    let bundleID: String
}

/// Serializes expensive archive and bundle operations away from the main actor.
actor AppFileWorker {
    static let shared = AppFileWorker()

    func validateIPA(at url: URL) throws {
        #if canImport(ZIPFoundation)
        let archive = try Archive(url: url, accessMode: .read)
        let metadata = archive.filter { entry in
            let parts = entry.path.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }
        guard metadata.count == 1, let entry = metadata.first else { throw LBoxFileError.invalidArchive }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            guard data.count + chunk.count <= 1024 * 1024 else { throw LBoxFileError.invalidBundle }
            data.append(chunk)
        }
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String,
              !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LBoxFileError.invalidBundle }
        #else
        throw LBoxFileError.unsupportedArchive
        #endif
    }

    func prepare(_ source: URL, in folder: URL) throws -> PreparedAppArchive {
        #if canImport(ZIPFoundation)
        try validateIPA(at: source)
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = folder.appendingPathComponent(".lbox-extract-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try manager.unzipItem(at: source, to: root)
            let payload = root.appendingPathComponent("Payload")
            let apps = try manager.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "app" }
            guard apps.count == 1, let app = apps.first,
                  let plist = try PropertyListSerialization.propertyList(
                    from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil
                  ) as? [String: Any],
                  let rawID = plist["CFBundleIdentifier"] as? String else { throw LBoxFileError.invalidBundle }
            let bundleID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty, !bundleID.contains("/"), !bundleID.contains("\\"),
                  bundleID != ".", bundleID != ".." else { throw LBoxFileError.invalidBundle }
            // LiveContainer must generate metadata for this installation itself.
            let info = app.appendingPathComponent("LCAppInfo.plist")
            if manager.fileExists(atPath: info.path) { try manager.removeItem(at: info) }
            return PreparedAppArchive(root: root, payload: payload, app: app, bundleID: bundleID)
        } catch {
            try? manager.removeItem(at: root)
            throw error
        }
        #else
        throw LBoxFileError.unsupportedArchive
        #endif
    }

    func installSeparate(_ prepared: URL, bundleID: String, in folder: URL) throws {
        let manager = FileManager.default
        var destination = folder.appendingPathComponent(bundleID + ".app")
        var suffix = 1
        while manager.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(bundleID)_\(suffix).app")
            suffix += 1
        }
        try manager.moveItem(at: prepared, to: destination)
    }

    func createBackup(of existing: URL, at destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: existing, to: destination)
    }

    func replace(_ existing: URL, with prepared: URL) throws {
        try UpdateRecovery.replaceBundle(at: existing, with: prepared)
    }

    func prepareUpdateMetadata(backup: URL, prepared: URL) throws {
        try UpdateRecovery.prepareMetadata(
            oldInfo: backup.appendingPathComponent("LCAppInfo.plist"),
            preparedInfo: prepared.appendingPathComponent("LCAppInfo.plist")
        )
    }

    func restore(_ backup: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try UpdateRecovery.replaceBundle(at: destination, with: backup)
        } else {
            try FileManager.default.moveItem(at: backup, to: destination)
        }
    }

    func finalizeUpdate(oldInfo: URL, newInfo: URL, dataRoot: URL?) throws {
        try UpdateRecovery.patchMetadata(oldInfo: oldInfo, newInfo: newInfo, dataRoot: dataRoot)
    }
}
