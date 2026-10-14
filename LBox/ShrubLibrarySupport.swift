import Foundation

@MainActor
final class ShrubLibraryAppStoreViewModel: AppStoreViewModel {
    private static let shrubHost = "shrublibrary.pages.dev"
    private static let shrubRootURL = URL(string: "https://shrublibrary.pages.dev/")!
    private static let shrubFolderMarker = "lbox-catalog:shrublibrary"

    override func addRepo(url: URL, parentID: String? = nil) {
        guard Self.isShrubLibraryURL(url) else {
            super.addRepo(url: url, parentID: parentID)
            return
        }

        Task {
            do {
                let urls = try await ShrubLibraryCatalogResolver.discoverRepositoryURLs(from: url)
                guard !urls.isEmpty else {
                    super.addRepo(url: url, parentID: parentID)
                    return
                }

                if let existingID = shrubFolderID(in: savedRepos) {
                    replaceShrubFolderChildren(folderID: existingID, with: urls)
                } else {
                    let children = urls
                        .filter { !repoExists($0.absoluteString) }
                        .map { SavedRepo(url: $0) }

                    guard !children.isEmpty else { return }

                    var folder = SavedRepo(folderName: "ShrubLibrary", children: children)
                    folder.iconURL = Self.shrubFolderMarker
                    guard insertFolder(folder, parentID: parentID) else {
                        super.addRepo(url: url, parentID: parentID)
                        return
                    }
                }

                saveRepos()
                await super.fetchAllRepos()
            } catch {
                print("ShrubLibrary import failed: \(error)")
                super.addRepo(url: url, parentID: parentID)
            }
        }
    }

    override func fetchAllRepos() async {
        await refreshShrubLibraryCatalogIfNeeded()
        await super.fetchAllRepos()
    }

    private static func isShrubLibraryURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == shrubHost || host.hasSuffix(".\(shrubHost)")
    }

    private func shrubFolderID(in nodes: [SavedRepo]) -> String? {
        for node in nodes {
            if node.isFolder && node.iconURL == Self.shrubFolderMarker {
                return node.id
            }
            if let children = node.children, let found = shrubFolderID(in: children) {
                return found
            }
        }
        return nil
    }

    private func insertFolder(_ folder: SavedRepo, parentID: String?) -> Bool {
        guard let parentID else {
            savedRepos.append(folder)
            return true
        }

        func insert(_ nodes: inout [SavedRepo]) -> Bool {
            for index in nodes.indices {
                if nodes[index].id == parentID {
                    guard nodes[index].repoListURL == nil else { return false }
                    if nodes[index].children == nil { nodes[index].children = [] }
                    nodes[index].children?.append(folder)
                    return true
                }
                if nodes[index].isFolder, insert(&nodes[index].children!) {
                    return true
                }
            }
            return false
        }

        return insert(&savedRepos)
    }

    private func replaceShrubFolderChildren(folderID: String, with urls: [URL]) {
        func replace(_ nodes: inout [SavedRepo]) -> Bool {
            for index in nodes.indices {
                if nodes[index].id == folderID {
                    let existing = nodes[index].children ?? []
                    let existingByURL = Dictionary(
                        uniqueKeysWithValues: existing.compactMap { child -> (String, SavedRepo)? in
                            guard let url = child.url else { return nil }
                            return (url.absoluteString, child)
                        }
                    )

                    nodes[index].children = urls.map { url in
                        existingByURL[url.absoluteString] ?? SavedRepo(url: url)
                    }
                    return true
                }
                if nodes[index].isFolder, replace(&nodes[index].children!) {
                    return true
                }
            }
            return false
        }

        _ = replace(&savedRepos)
    }

    private func refreshShrubLibraryCatalogIfNeeded() async {
        guard let folderID = shrubFolderID(in: savedRepos) else { return }

        do {
            let urls = try await ShrubLibraryCatalogResolver.discoverRepositoryURLs(from: Self.shrubRootURL)
            guard !urls.isEmpty else { return }
            replaceShrubFolderChildren(folderID: folderID, with: urls)
            saveRepos()
        } catch {
            // Keep the last known catalog if ShrubLibrary is temporarily unavailable.
            print("ShrubLibrary catalog refresh failed: \(error)")
        }
    }
}

private enum ShrubLibraryCatalogResolver {
    private static let shrubHost = "shrublibrary.pages.dev"
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 LBox/1.0"

    static func discoverRepositoryURLs(from rootURL: URL) async throws -> [URL] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadRevalidatingCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)

        let html = try await fetchText(rootURL, session: session)
        var payloads = [html]

        let scriptURLs = extractScriptURLs(from: html, relativeTo: rootURL)
        for scriptURL in scriptURLs.prefix(12) {
            if let text = try? await fetchText(scriptURL, session: session) {
                payloads.append(text)
            }
        }

        // If the bundle loads its catalog from a same-origin data/API endpoint,
        // inspect those responses as well. This keeps the importer independent
        // of ShrubLibrary's current framework or deployment layout.
        var endpointSet = Set<URL>()
        for payload in payloads {
            for endpoint in extractLikelyDataEndpoints(from: payload, relativeTo: rootURL) {
                endpointSet.insert(endpoint)
            }
        }

        for endpoint in endpointSet.prefix(24) {
            if let text = try? await fetchText(endpoint, session: session) {
                payloads.append(text)
            }
        }

        var candidates = Set<URL>()
        for payload in payloads {
            for candidate in extractAbsoluteURLs(from: payload) {
                if let sharedRepo = repositoryURLFromShrubShareLink(candidate) {
                    candidates.insert(canonicalize(sharedRepo))
                }
                if isLikelyRepositoryURL(candidate) {
                    candidates.insert(canonicalize(candidate))
                }
            }
        }

        return candidates.sorted {
            $0.absoluteString.localizedCaseInsensitiveCompare($1.absoluteString) == .orderedAscending
        }
    }

    private static func fetchText(_ url: URL, session: URLSession) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/json,text/javascript,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func extractScriptURLs(from html: String, relativeTo baseURL: URL) -> [URL] {
        let values = captures(
            pattern: #"<script[^>]+src\s*=\s*[\"']([^\"']+)[\"']"#,
            in: html,
            options: [.caseInsensitive]
        )

        var seen = Set<String>()
        return values.compactMap { value in
            guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            guard seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    private static func extractLikelyDataEndpoints(from rawText: String, relativeTo baseURL: URL) -> [URL] {
        let text = normalizeEscapes(rawText)
        let relativePaths = captures(
            pattern: #"[\"'](/[^\"'\s]{1,240})[\"']"#,
            in: text
        )

        var urls = Set<URL>()
        for path in relativePaths {
            let lower = path.lowercased()
            guard !lower.contains("/assets/"),
                  !lower.contains("favicon"),
                  ["api", "repo", "source", "catalog", "data", ".json", "list"].contains(where: lower.contains) else {
                continue
            }
            if let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
               url.host?.lowercased() == shrubHost {
                urls.insert(url)
            }
        }
        return Array(urls)
    }

    private static func extractAbsoluteURLs(from rawText: String) -> [URL] {
        let text = normalizeEscapes(rawText)
        let rawURLs = captures(
            pattern: #"(https?://[^\s\"'<>\\]+)"#,
            in: text,
            captureGroup: 1,
            options: [.caseInsensitive]
        )

        var result = Set<URL>()
        let trailing = CharacterSet(charactersIn: ",;:.)]}>")
        for raw in rawURLs {
            var value = raw.trimmingCharacters(in: trailing)
            if value.hasSuffix("\\") { value.removeLast() }
            if let url = URL(string: value) {
                result.insert(url)
            }
        }
        return Array(result)
    }

    private static func repositoryURLFromShrubShareLink(_ url: URL) -> URL? {
        guard url.host?.lowercased() == shrubHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        for item in components.queryItems ?? [] where ["repo", "source", "url"].contains(item.name.lowercased()) {
            guard let value = item.value else { continue }
            let decoded = value.removingPercentEncoding ?? value
            if let repoURL = URL(string: decoded), ["http", "https"].contains(repoURL.scheme?.lowercased() ?? "") {
                return repoURL
            }
        }
        return nil
    }

    private static func isLikelyRepositoryURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), host != shrubHost else { return false }

        let lower = url.absoluteString.lowercased()
        let path = url.path.lowercased()

        let blockedHosts = [
            "discord.com", "discord.gg", "youtube.com", "youtu.be",
            "x.com", "twitter.com", "reddit.com", "t.me"
        ]
        if blockedHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            return false
        }

        let blockedExtensions = [
            "js", "css", "png", "jpg", "jpeg", "gif", "webp", "svg", "ico",
            "woff", "woff2", "ttf", "otf", "mp4", "mov", "zip", "ipa", "dylib"
        ]
        if blockedExtensions.contains(url.pathExtension.lowercased()) {
            return false
        }

        if host == "github.com" {
            let isRawStyle = path.contains("/raw/") || path.hasSuffix(".json") || path.contains("altsource")
            if !isRawStyle { return false }
        }

        let hints = [
            ".json", "repo", "repository", "source", "altsource", "altstore",
            "sidestore", "esign", "feather", "/apps", "app-repo", "appstore"
        ]
        return hints.contains(where: lower.contains)
    }

    private static func canonicalize(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url ?? url
    }

    private static func normalizeEscapes(_ text: String) -> String {
        var value = text
        value = value.replacingOccurrences(of: "\\/", with: "/")
        value = value.replacingOccurrences(of: "\\u002F", with: "/", options: [.caseInsensitive])
        value = value.replacingOccurrences(of: "\\u003A", with: ":", options: [.caseInsensitive])
        value = value.replacingOccurrences(of: "\\u0026", with: "&", options: [.caseInsensitive])
        value = value.replacingOccurrences(of: "\\u003D", with: "=", options: [.caseInsensitive])
        value = value.replacingOccurrences(of: "&amp;", with: "&")
        return value
    }

    private static func captures(
        pattern: String,
        in text: String,
        captureGroup: Int = 1,
        options: NSRegularExpression.Options = []
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: fullRange).compactMap { match in
            guard captureGroup < match.numberOfRanges,
                  let range = Range(match.range(at: captureGroup), in: text) else { return nil }
            return String(text[range])
        }
    }
}
