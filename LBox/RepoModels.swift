import Foundation

// MARK: - Models

enum RepoFetchStatus: Equatable, Sendable, Hashable {
    case idle
    case waiting
    case loading
    case success
    case error(String)
    case warning(String)
}

// MARK: - Sorting Enums
enum AppSortOption: String, CaseIterable, Identifiable, Sendable {
    case name = "Name"
    case date = "Date"
    case size = "Size"

    var id: String { rawValue }
}

enum RepoSortOption: String, CaseIterable, Identifiable {
    case standard = "Default"
    case name = "Name"

    var id: String { rawValue }
}

struct AppItem: Codable, Identifiable, Hashable, Sendable {
    // Modified ID to include sourceRepoName for uniqueness
    var id: String {
        if let repo = sourceRepoName {
            return "\(repo)|\(bundleIdentifier)|\(version)|\(downloadURL)"
        }
        return "\(bundleIdentifier)|\(version)|\(downloadURL)"
    }
    let name: String
    let bundleIdentifier: String
    let version: String
    let versionDate: String?
    let size: Int64?
    let downloadURL: String
    let iconURL: String?
    let localizedDescription: String?
    let screenshotURLs: [String]

    var sourceRepoName: String? = nil

    enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, bundleID
        case version, versionDate, size, downloadURL
        case iconURL, icon
        case localizedDescription
        case screenshotURLs, screenshots
        case sourceRepoName
    }

    init(
        name: String,
        bundleIdentifier: String,
        version: String,
        versionDate: String?,
        size: Int64?,
        downloadURL: String,
        iconURL: String?,
        localizedDescription: String?,
        screenshotURLs: [String],
        sourceRepoName: String? = nil
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.versionDate = versionDate
        self.size = size
        self.downloadURL = downloadURL
        self.iconURL = iconURL
        self.localizedDescription = localizedDescription
        self.screenshotURLs = screenshotURLs
        self.sourceRepoName = sourceRepoName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)

        if let bid = try? container.decode(String.self, forKey: .bundleIdentifier) {
            bundleIdentifier = bid
        } else if let bid = try? container.decode(String.self, forKey: .bundleID) {
            bundleIdentifier = bid
        } else {
            bundleIdentifier = "unknown.bundle.id"
        }

        guard let parsedVersion = container.flexibleString(forKey: .version) else {
            throw DecodingError.keyNotFound(CodingKeys.version, .init(codingPath: decoder.codingPath, debugDescription: "Missing app version"))
        }
        version = parsedVersion
        versionDate = try? container.decodeIfPresent(String.self, forKey: .versionDate)
        size = container.flexibleSize(forKey: .size)
        downloadURL = try container.decode(String.self, forKey: .downloadURL)

        if let iUrl = try? container.decode(String.self, forKey: .iconURL) {
            iconURL = iUrl
        } else {
            iconURL = try? container.decodeIfPresent(String.self, forKey: .icon)
        }

        localizedDescription = try? container.decodeIfPresent(String.self, forKey: .localizedDescription)

        if let screens = try? container.decode([String].self, forKey: .screenshotURLs) {
            screenshotURLs = screens
        } else if let screens = try? container.decode([String].self, forKey: .screenshots) {
            screenshotURLs = screens
        } else {
            screenshotURLs = []
        }

        sourceRepoName = try container.decodeIfPresent(String.self, forKey: .sourceRepoName)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(version, forKey: .version)
        try container.encode(versionDate, forKey: .versionDate)
        try container.encode(size, forKey: .size)
        try container.encode(downloadURL, forKey: .downloadURL)
        try container.encode(iconURL, forKey: .iconURL)
        try container.encode(localizedDescription, forKey: .localizedDescription)
        try container.encode(screenshotURLs, forKey: .screenshotURLs)
        try container.encode(sourceRepoName, forKey: .sourceRepoName)
    }
}

// Represents an installed .app in the Applications folder
struct LocalApp: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let name: String
    let bundleID: String
    let version: String?
    let url: URL
    let iconURL: URL? // Local file URL to the icon if found
}

struct MetaData: Codable, Sendable {
    let repoName: String?
    let repoIcon: String?
}

private struct AltStoreVersionRecord: Decodable, Sendable {
    let version: String
    let date: String?
    let size: Int64?
    let downloadURL: String

    enum CodingKeys: String, CodingKey {
        case version, date, versionDate, size, downloadURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let parsedVersion = container.flexibleString(forKey: .version) else {
            throw DecodingError.keyNotFound(CodingKeys.version, .init(codingPath: decoder.codingPath, debugDescription: "Missing app version"))
        }
        version = parsedVersion

        if let primaryDate = try? container.decodeIfPresent(String.self, forKey: .date) {
            date = primaryDate
        } else {
            date = try? container.decodeIfPresent(String.self, forKey: .versionDate)
        }

        size = container.flexibleSize(forKey: .size)
        downloadURL = try container.decode(String.self, forKey: .downloadURL)
    }
}

private struct AltStoreAppRecord: Decodable, Sendable {
    let name: String
    let bundleIdentifier: String
    let iconURL: String?
    let localizedDescription: String?
    let subtitle: String?
    let screenshotURLs: [String]
    let versions: [AltStoreVersionRecord]

    enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, bundleID
        case iconURL, icon
        case localizedDescription, subtitle
        case screenshotURLs, screenshots
        case versions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)

        if let primaryBundleID = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier) {
            bundleIdentifier = primaryBundleID
        } else if let alternateBundleID = try container.decodeIfPresent(String.self, forKey: .bundleID) {
            bundleIdentifier = alternateBundleID
        } else {
            bundleIdentifier = "unknown.bundle.id"
        }

        if let primaryIcon = try? container.decodeIfPresent(String.self, forKey: .iconURL) {
            iconURL = primaryIcon
        } else {
            iconURL = try? container.decodeIfPresent(String.self, forKey: .icon)
        }

        localizedDescription = try? container.decodeIfPresent(String.self, forKey: .localizedDescription)
        subtitle = try? container.decodeIfPresent(String.self, forKey: .subtitle)

        if let primaryScreenshots = try? container.decodeIfPresent([String].self, forKey: .screenshotURLs) {
            screenshotURLs = primaryScreenshots
        } else {
            screenshotURLs = (try? container.decodeIfPresent([String].self, forKey: .screenshots)) ?? []
        }

        versions = try container.decodeIfPresent([AltStoreVersionRecord].self, forKey: .versions) ?? []
    }
}

private struct RepoAppRecord: Decodable {
    let releases: [AppItem]

    init(from decoder: Decoder) throws {
        let legacy = try? AppItem(from: decoder)
        let modern = try? AltStoreAppRecord(from: decoder)
        var items = legacy.map { [$0] } ?? []
        if let modern {
            items.append(contentsOf: modern.versions.map { release in
                AppItem(
                    name: modern.name, bundleIdentifier: modern.bundleIdentifier,
                    version: release.version, versionDate: release.date, size: release.size,
                    downloadURL: release.downloadURL, iconURL: modern.iconURL,
                    localizedDescription: modern.localizedDescription ?? modern.subtitle,
                    screenshotURLs: modern.screenshotURLs
                )
            })
        }
        if items.isEmpty { items = [try AppItem(from: decoder)] }
        var seen = Set<String>()
        releases = items.filter { seen.insert($0.id).inserted }

    }
}

struct RepoResponse: Decodable, Sendable {
    let name: String
    let identifier: String?
    let iconURL: String?
    let META: MetaData?
    let apps: [AppItem]
    let skippedRecords: Int

    enum CodingKeys: String, CodingKey {
        case name, identifier, iconURL, META, apps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? "Unknown Source"
        identifier = try? container.decodeIfPresent(String.self, forKey: .identifier)
        iconURL = try? container.decodeIfPresent(String.self, forKey: .iconURL)
        META = try? container.decodeIfPresent(MetaData.self, forKey: .META)

        // Decode each entry independently: a feed may mix legacy and versions[] records.
        var records = try container.nestedUnkeyedContainer(forKey: .apps)
        var releases: [AppItem] = []
        var skipped = 0
        let originalCount = records.count ?? 0
        while !records.isAtEnd {
            let recordDecoder = try records.superDecoder()
            do { releases.append(contentsOf: try RepoAppRecord(from: recordDecoder).releases) }
            catch { skipped += 1 }
        }
        guard !releases.isEmpty || originalCount == 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "No usable app records found in this source"))
        }
        apps = releases
        skippedRecords = skipped

    }

    var bestIconURL: String? {
        iconURL ?? META?.repoIcon
    }
}

struct ExportableRepo: Codable {
    let name: String
    let url: URL?
    let isEnabled: Bool?
    let children: [ExportableRepo]?
    let repoListURL: URL?

    init(_ repo: SavedRepo, onlyEnabled: Bool = false) {
        self.name = repo.name
        self.url = repo.url
        if onlyEnabled { self.isEnabled = nil } else { self.isEnabled = repo.isEnabled }
        self.repoListURL = repo.repoListURL

        // If this is a remote folder (has repoListURL), do not include children in export
        if repo.repoListURL != nil {
            self.children = nil
        } else if let kids = repo.children {
            let filtered = onlyEnabled ? kids.filter { $0.hasEnabledContent } : kids
            self.children = filtered.map { ExportableRepo($0, onlyEnabled: onlyEnabled) }
        } else {
            self.children = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, url, isEnabled, children
        case repoListURL = "childrenUrl"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.url = try container.decodeIfPresent(URL.self, forKey: .url)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.children = try container.decodeIfPresent([ExportableRepo].self, forKey: .children)
        self.repoListURL = try container.decodeIfPresent(URL.self, forKey: .repoListURL)
    }

    func toSavedRepo() -> SavedRepo {
        let enabled = isEnabled ?? true
        if repoListURL != nil || children != nil {
            // If it has children or is a remote folder
            let mappedChildren = children?.map { $0.toSavedRepo() } ?? []
            var folder = SavedRepo(folderName: name, children: mappedChildren, repoListURL: repoListURL)
            folder.isEnabled = enabled
            return folder
        } else {
            return SavedRepo(url: url ?? URL(string: "about:blank")!, name: name, isEnabled: enabled)
        }
    }
}

struct SavedRepo: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var url: URL?
    var iconURL: String?
    var isEnabled: Bool
    var children: [SavedRepo]?
    var appCount: Int = 0

    var repoListURL: URL? // URL for subscription folder source

    // Cache the apps to persist between launches
    var cachedApps: [AppItem]? = nil

    var fetchStatus: RepoFetchStatus = .idle

    var isFolder: Bool { children != nil }
    var isRemoteFolder: Bool { repoListURL != nil }

    var totalAppCount: Int {
        if let children = children {
            return children.reduce(0) { $0 + $1.totalAppCount }
        } else {
            return isEnabled ? appCount : 0
        }
    }

    // Counts the number of repos (leaves) inside recursively
    var totalRepoCount: Int {
        if let children = children {
            return children.reduce(0) { $0 + $1.totalRepoCount }
        } else {
            return 1
        }
    }

    var hasEnabledContent: Bool {
        if !isEnabled { return false }
        if let children = children { return children.contains { $0.hasEnabledContent } }
        return true
    }

    var hasDisabledContentRecursive: Bool {
        if !isEnabled { return true }
        if let children = children { return children.contains { $0.hasDisabledContentRecursive } }
        return false
    }

    func allURLs(onlyEnabled: Bool = false) -> String {
        if onlyEnabled && !isEnabled { return "" }
        if let children = children {
            return children.map { $0.allURLs(onlyEnabled: onlyEnabled) }.filter { !$0.isEmpty }.joined(separator: "\n")
        } else if let url = url {
            return url.absoluteString
        }
        return ""
    }

    enum CodingKeys: String, CodingKey {
        case id, name, url, iconURL, isEnabled, children, appCount, cachedApps
        case repoListURL = "childrenUrl"
    }

    init(url: URL, name: String? = nil, iconURL: String? = nil, isEnabled: Bool = true, appCount: Int = 0) {
        self.id = url.absoluteString; self.url = url; self.name = name ?? "Unknown"; self.iconURL = iconURL; self.isEnabled = isEnabled; self.children = nil; self.appCount = appCount
        self.repoListURL = nil
        self.cachedApps = nil
    }

    init(folderName: String, children: [SavedRepo] = [], repoListURL: URL? = nil) {
        self.id = UUID().uuidString; self.name = folderName; self.url = nil; self.iconURL = nil; self.isEnabled = true; self.children = children; self.appCount = 0
        self.repoListURL = repoListURL
        self.cachedApps = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let idVal = try? container.decode(String.self, forKey: .id) { self.id = idVal }
        else if let urlVal = try? container.decode(URL.self, forKey: .url) { self.id = urlVal.absoluteString }
        else { self.id = UUID().uuidString }

        self.url = try container.decodeIfPresent(URL.self, forKey: .url)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
        self.iconURL = try? container.decodeIfPresent(String.self, forKey: .iconURL)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.children = try container.decodeIfPresent([SavedRepo].self, forKey: .children)
        self.appCount = try container.decodeIfPresent(Int.self, forKey: .appCount) ?? 0
        self.cachedApps = try container.decodeIfPresent([AppItem].self, forKey: .cachedApps)
        self.repoListURL = try container.decodeIfPresent(URL.self, forKey: .repoListURL)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id); try container.encode(name, forKey: .name); try container.encode(url, forKey: .url)
        try container.encode(iconURL, forKey: .iconURL); try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(children, forKey: .children); try container.encode(appCount, forKey: .appCount)
        try container.encode(cachedApps, forKey: .cachedApps)
        try container.encode(repoListURL, forKey: .repoListURL)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(name); hasher.combine(url); hasher.combine(iconURL)
        hasher.combine(isEnabled); hasher.combine(children); hasher.combine(appCount); hasher.combine(fetchStatus)
        hasher.combine(repoListURL)
    }

    static func == (lhs: SavedRepo, rhs: SavedRepo) -> Bool {
        return lhs.id == rhs.id && lhs.name == rhs.name && lhs.url == rhs.url && lhs.iconURL == rhs.iconURL &&
               lhs.isEnabled == rhs.isEnabled && lhs.children == rhs.children && lhs.appCount == rhs.appCount && lhs.fetchStatus == rhs.fetchStatus &&
               lhs.repoListURL == rhs.repoListURL
    }
}

private extension KeyedDecodingContainer {
    func flexibleString(forKey key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int64.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key), value.isFinite { return String(value) }
        return nil
    }

    func flexibleSize(forKey key: Key) -> Int64? {
        if let value = try? decode(Int64.self, forKey: key) { return value >= 0 ? value : nil }
        if let value = try? decode(String.self, forKey: key), let parsed = Int64(value) { return parsed >= 0 ? parsed : nil }
        if let value = try? decode(Double.self, forKey: key), value.isFinite, value >= 0, value < Double(Int64.max) {
            return Int64(value)
        }
        return nil
    }
}
