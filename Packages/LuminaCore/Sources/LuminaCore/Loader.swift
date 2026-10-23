import Foundation

/// Turns a `Source` into a `SourceSnapshot` and loads guide data.
public struct PlaylistLoader: Sendable {
    let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func load(_ source: Source) async throws -> SourceSnapshot {
        switch source.kind {
        case .demo:
            return DemoContent.snapshot(sourceID: source.id)
        case .xtream(let server, let user, let pass):
            let client = XtreamClient(server: server, username: user, password: pass, session: session)
            let account = try await client.authenticate()
            var snap = try await client.loadSnapshot(sourceID: source.id, account: account, userAgent: source.userAgent)
            snap.epgURLs += source.extraEPG
            return snap
        case .m3u(let url):
            let file = try await fetchFile(url, userAgent: source.userAgent)
            defer { if !url.isFileURL { try? FileManager.default.removeItem(at: file) } }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            guard data.count > 7 else { throw LuminaError.notAPlaylist }
            let head = String(decoding: data.prefix(2048), as: UTF8.self)
            guard head.contains("#EXTM3U") || head.contains("#EXTINF") else { throw LuminaError.notAPlaylist }
            let p = M3UParser.parse(data, sourceID: source.id, defaultUserAgent: source.userAgent)
            guard !(p.channels.isEmpty && p.movies.isEmpty && p.episodes.isEmpty) else { throw LuminaError.emptyPlaylist }
            return SourceSnapshot(
                sourceID: source.id, channels: p.channels, movies: p.movies, series: p.series,
                episodes: p.episodes, epgURLs: p.epgURLs + source.extraEPG
            )
        }
    }

    /// Downloads to a temp file (or returns the local file) so large playlists are never held twice in memory.
    public func fetchFile(_ url: URL, userAgent: String? = nil, timeout: TimeInterval = 120) async throws -> URL {
        if url.isFileURL { return url }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { throw LuminaError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue(userAgent ?? "Lumina/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (tmp, resp) = try await session.download(for: req)
            if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                try? FileManager.default.removeItem(at: tmp)
                throw LuminaError.http(h.statusCode)
            }
            // The system deletes the download when this call returns, so move it somewhere we own.
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: tmp, to: dst)
            return dst
        } catch let e as URLError {
            throw LuminaError.network(e.localizedDescription)
        }
    }

    /// Download + (optionally gunzip) + parse one XMLTV guide. Runs off the main thread by virtue of being async.
    public func loadGuide(
        _ url: URL, userAgent: String? = nil, wantedIDs: Set<String>?, wantedNameKeys: Set<String>,
        window: ClosedRange<Date>
    ) async throws -> XMLTVResult {
        let file = try await fetchFile(url, userAgent: userAgent, timeout: 180)
        let isTemp = !url.isFileURL
        var toParse = file
        var inflated: URL?
        defer {
            if isTemp { try? FileManager.default.removeItem(at: file) }
            if let inflated { try? FileManager.default.removeItem(at: inflated) }
        }
        if Gzip.isGzip(file) {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-epg-\(UUID().uuidString).xml")
            try Gzip.decompress(file, to: out)
            inflated = out
            toParse = out
        }
        return try XMLTVParser.parse(fileURL: toParse, wantedIDs: wantedIDs, wantedNameKeys: wantedNameKeys, window: window)
    }
}

// MARK: - Demo content (public Apple / Mux test streams, so the app is usable before adding a provider)

public enum DemoContent {
    public static let m3u = """
    #EXTM3U
    #EXTINF:-1 tvg-id="demo.bipbop" tvg-name="Lumina Test Card" group-title="Demo",Lumina Test Card HD
    https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8
    #EXTINF:-1 tvg-id="demo.bipbop16" tvg-name="Lumina Test Card 2" group-title="Demo",Lumina Test Card 2
    https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8
    #EXTINF:-1 tvg-id="demo.bbb" tvg-name="Big Buck Bunny" group-title="Demo Movies",Big Buck Bunny FHD
    https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8
    """

    public static func snapshot(sourceID: UUID) -> SourceSnapshot {
        let p = M3UParser.parse(m3u, sourceID: sourceID)
        return SourceSnapshot(sourceID: sourceID, channels: p.channels)
    }

    /// Synthetic guide so the timeline and now/next UI can be explored with the demo source.
    public static func guide(now: Date = Date()) -> EPGIndex {
        let titles: [String: [String]] = [
            "demo.bipbop": ["Test Pattern Hour", "Colour Bars", "Signal Check", "Night Loop"],
            "demo.bipbop16": ["Wide Screen Lab", "Aspect Ratio Show", "Calibration Live"],
            "demo.bbb": ["Big Buck Bunny", "Behind the Rabbit", "Animation Shorts"],
        ]
        let slot: TimeInterval = 1800
        let base = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / slot).rounded(.down) * slot - 6 * 3600)
        var out: [Programme] = []
        for (id, names) in titles {
            for n in 0..<(48 * 2) {
                let start = base.addingTimeInterval(Double(n) * slot)
                out.append(Programme(
                    channel: id, start: start, stop: start.addingTimeInterval(slot),
                    title: names[n % names.count], desc: "Sample programme for the demo source."
                ))
            }
        }
        return EPGIndex(programmes: out)
    }
}
