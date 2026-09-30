import SwiftUI
import UIKit

actor LBoxImagePipeline {
    static let shared = LBoxImagePipeline()
    
    private let memoryCache = NSCache<NSURL, NSData>()
    private let session: URLSession
    
    private init() {
        memoryCache.totalCostLimit = 64 * 1024 * 1024
        
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024,
            diskPath: "LBoxImages"
        )
        session = URLSession(configuration: configuration)
    }
    
    func data(for url: URL) async throws -> Data {
        if let cached = memoryCache.object(forKey: url as NSURL) {
            return cached as Data
        }
        
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 20
        
        let (data, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        
        memoryCache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        return data
    }
}

struct CachedRemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var placeholderSystemImage: String = "app.fill"
    
    @State private var image: UIImage?
    
    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Image(systemName: placeholderSystemImage)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            
            do {
                let data = try await LBoxImagePipeline.shared.data(for: url)
                guard !Task.isCancelled, let decoded = UIImage(data: data) else { return }
                image = decoded
            } catch {
                // Keep the lightweight placeholder for unavailable images.
            }
        }
    }
}
