import ImageIO
import UIKit

/// Logo/poster loader tuned for long lists and CarPlay: shared disk cache, in-flight de-duplication,
/// and downsampling so a 4000px poster never sits decoded in memory next to 200 others.
actor ImageLoader {
    static let shared = ImageLoader()

    private let session: URLSession
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 300 << 20)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 12
        cfg.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: cfg)
        cache.countLimit = 600
    }

    func image(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(url.absoluteString)@\(Int(maxPixel))"
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let t = inFlight[key] { return await t.value }
        let session = self.session
        let task = Task<UIImage?, Never> {
            guard let (data, resp) = try? await session.data(from: url),
                  (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
            else { return nil }
            return Self.downsample(data, maxPixel: maxPixel)
        }
        inFlight[key] = task
        let img = await task.value
        inFlight[key] = nil
        if let img { cache.setObject(img, forKey: key as NSString) }
        return img
    }

    nonisolated static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary) else { return nil }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
