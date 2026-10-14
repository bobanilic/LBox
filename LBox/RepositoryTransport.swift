import Foundation

enum RepositoryLoadError: LocalizedError {
    case httpStatus(Int)
    case emptyResponse
    case notJSON
    case notModifiedWithoutCache

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "HTTP \(code): the source server refused or failed the request."
        case .emptyResponse: return "The source returned an empty response."
        case .notJSON: return "The source returned a web page or invalid JSON instead of an app feed."
        case .notModifiedWithoutCache: return "The server returned HTTP 304, but no saved catalog is available."
        }
    }
}

enum RepositoryPayload: Sendable {
    case data(Data)
    case notModified
}

enum RepositoryTransport {
    /// Catalogs are validated by their JSON contents. Keep binary download
    /// validation separate: some hosted/cached responses are plain URLResponse.
    static func payload(data: Data, response: URLResponse) throws -> RepositoryPayload {
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 304 { return .notModified }
            guard (200...299).contains(http.statusCode) else { throw RepositoryLoadError.httpStatus(http.statusCode) }
        }
        guard !data.isEmpty else { throw RepositoryLoadError.emptyResponse }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw RepositoryLoadError.notJSON }
        return .data(data)
    }

    static func load(_ url: URL, session: URLSession = .shared, bypassCache: Bool = false) async throws -> RepositoryPayload {
        var request = URLRequest(url: url)
        // Preserve the working version's normal URLSession cache behavior.
        request.cachePolicy = bypassCache ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        return try payload(data: data, response: response)
    }

    static func errorDescription(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "Feed format: missing \((context.codingPath.map { $0.stringValue } + [key.stringValue]).joined(separator: "."))."
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context), DecodingError.dataCorrupted(let context):
            return "Feed format at \(context.codingPath.map { $0.stringValue }.joined(separator: ".")): \(context.debugDescription)"
        default: return error.localizedDescription
        }
    }
}
