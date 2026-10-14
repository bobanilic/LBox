import Foundation

@main enum SourceFetchChecks {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let sources = [
            URL(string: "https://community-apps.sidestore.io/sidecommunity.json")!,
            URL(string: "https://raw.githubusercontent.com/bebound/AltGallery/refs/heads/master/all-apps.json")!
        ]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for url in sources {
                group.addTask {
                    let payload = try await RepositoryTransport.load(url, session: session, bypassCache: true)
                    guard case .data(let data) = payload else { throw RepositoryLoadError.notModifiedWithoutCache }
                    let source = try JSONDecoder().decode(RepoResponse.self, from: data)
                    guard !source.apps.isEmpty else { throw RepositoryLoadError.emptyResponse }
                    print("Live source loaded: \(source.name), \(Set(source.apps.map { $0.name }).count) apps, \(source.skippedRecords) skipped entries")
                }
            }
            try await group.waitForAll()
        }
    }
}
