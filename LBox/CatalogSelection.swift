import Foundation

enum CatalogSelection {
    static func isNewer(_ left: AppItem, than right: AppItem) -> Bool {
        let version = left.version.compare(right.version, options: .numeric)
        if version != .orderedSame { return version == .orderedDescending }
        if left.versionDate != right.versionDate { return (left.versionDate ?? "") > (right.versionDate ?? "") }
        if left.sourceRepoName != right.sourceRepoName { return (left.sourceRepoName ?? "") < (right.sourceRepoName ?? "") }
        return left.downloadURL < right.downloadURL
    }

    static func latestPerSource(_ apps: [AppItem]) -> [AppItem] {
        var latest: [String: AppItem] = [:]
        for app in apps {
            let bundle = app.bundleIdentifier == "unknown.bundle.id" ? app.downloadURL : app.bundleIdentifier.lowercased()
            let key = bundle + "|" + app.name.lowercased() + "|" + (app.sourceRepoName ?? "")
            if let current = latest[key], !isNewer(app, than: current) { continue }
            latest[key] = app
        }
        return Array(latest.values)
    }

    static func history(for app: AppItem, in catalog: [AppItem]) -> [AppItem] {
        var seen = Set<String>()
        let validBundle = !app.bundleIdentifier.isEmpty && app.bundleIdentifier != "unknown" && app.bundleIdentifier != "unknown.bundle.id"
        let matches = catalog.filter {
            let matches = validBundle ? $0.bundleIdentifier.caseInsensitiveCompare(app.bundleIdentifier) == .orderedSame : $0.name == app.name
            return matches && seen.insert($0.id).inserted
        }
        return (matches.isEmpty ? [app] : matches).sorted { isNewer($0, than: $1) }
    }

    static func spotlight(in catalog: [AppItem]) -> AppItem? {
        for name in ["Delta", "LiveContainer"] {
            let matches = catalog.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if let app = matches.sorted(by: { isNewer($0, than: $1) }).first { return app }
        }
        return nil
    }
}
