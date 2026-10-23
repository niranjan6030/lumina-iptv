import Foundation

// MARK: - Duplicate merging (auto-failover backbone)

public struct MergeResult: Sendable {
    public var channels: [Channel]
    /// removed channel id -> surviving channel id, so favourites made before merging keep working.
    public var aliases: [String: String]
}

public enum ChannelMerger {
    /// Collapses "ESPN", "ESPN HD", "ESPN FHD" (even across providers) into one channel with several
    /// streams, best quality first. The player falls through them automatically when one fails.
    public static func mergeDuplicates(_ channels: [Channel]) -> MergeResult {
        var order: [String] = []
        var merged: [String: Channel] = [:]
        var aliases: [String: String] = [:]
        var unkeyed: [Channel] = []

        for ch in channels {
            let key = NameNormalizer.key(ch.name)
            guard !key.isEmpty else { unkeyed.append(ch); continue }
            if var existing = merged[key] {
                for s in ch.streams where !existing.streams.contains(where: { $0.url == s.url }) {
                    existing.streams.append(s)
                }
                if existing.logo == nil { existing.logo = ch.logo }
                if existing.epgID == nil { existing.epgID = ch.epgID }
                if existing.catchup == nil { existing.catchup = ch.catchup }
                if existing.number == nil { existing.number = ch.number }
                merged[key] = existing
                aliases[ch.id] = existing.id
            } else {
                merged[key] = ch
                order.append(key)
            }
        }
        var out: [Channel] = order.compactMap { k in
            guard var c = merged[k] else { return nil }
            // Stable sort: highest quality first, provider order otherwise preserved.
            c.streams = c.streams.enumerated()
                .sorted { ($0.element.quality, -$0.offset) > ($1.element.quality, -$1.offset) }
                .map(\.element)
            return c
        }
        out.append(contentsOf: unkeyed)
        return MergeResult(channels: out, aliases: aliases)
    }
}

// MARK: - Search

public struct SearchResults: Sendable {
    public var channels: [Channel] = []
    public var movies: [VODItem] = []
    public var series: [Series] = []

    public init(channels: [Channel] = [], movies: [VODItem] = [], series: [Series] = []) {
        self.channels = channels
        self.movies = movies
        self.series = series
    }
    public var isEmpty: Bool { channels.isEmpty && movies.isEmpty && series.isEmpty }
}

/// Prebuilt index so every keystroke is a cheap linear scan over normalised tokens.
public struct SearchIndex: Sendable {
    private struct Entry: Sendable {
        let key: String
        let tokens: [String]
    }

    private let channels: [Channel]
    private let channelEntries: [Entry]
    private let movies: [VODItem]
    private let movieEntries: [Entry]
    private let series: [Series]
    private let seriesEntries: [Entry]

    public init(channels: [Channel], movies: [VODItem], series: [Series]) {
        func entry(_ s: String) -> Entry {
            let t = NameNormalizer.tokens(s)
            return Entry(key: t.joined(separator: " "), tokens: t)
        }
        self.channels = channels
        channelEntries = channels.map { entry($0.name) }
        self.movies = movies
        movieEntries = movies.map { entry($0.title) }
        self.series = series
        seriesEntries = series.map { entry($0.title) }
    }

    public func search(_ query: String, limit: Int = 30) -> SearchResults {
        let q = NameNormalizer.tokens(query)
        guard !q.isEmpty else { return SearchResults() }
        let joined = q.joined(separator: " ")

        func top<T>(_ items: [T], _ entries: [Entry]) -> [T] {
            var scored: [(Int, Int)] = []
            for (i, e) in entries.enumerated() {
                if let s = Self.score(q, joined, e) { scored.append((s, i)) }
            }
            scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
            return scored.prefix(limit).map { items[$0.1] }
        }
        return SearchResults(
            channels: top(channels, channelEntries), movies: top(movies, movieEntries), series: top(series, seriesEntries)
        )
    }

    private static func score(_ q: [String], _ joined: String, _ e: Entry) -> Int? {
        if e.key == joined { return 10_000 - e.key.count }
        if e.key.hasPrefix(joined) { return 8_000 - e.key.count }
        // Every query token must start some entry token (so "esp spo" finds "ESPN Sports").
        var total = 0
        for t in q {
            if let pos = e.tokens.firstIndex(where: { $0.hasPrefix(t) }) { total += 400 - pos * 20 }
            else { return e.key.contains(joined) ? 1_000 - e.key.count : nil }
        }
        return total - e.key.count
    }
}

// MARK: - Playable URL candidates

public enum StreamCandidates {
    /// AVPlayer cannot play raw MPEG-TS over HTTP. Xtream-style links (`.../user/pass/123` or `.../123.ts`)
    /// almost always also answer as HLS, so try `.m3u8` first and keep the original as the fallback.
    public static func make(for endpoint: StreamEndpoint, rewriteTS: Bool = true) -> [StreamEndpoint] {
        guard rewriteTS else { return [endpoint] }
        let url = endpoint.url
        let comps = url.pathComponents.filter { $0 != "/" }
        guard let last = comps.last else { return [endpoint] }
        let lower = last.lowercased()
        var alt: URL?
        if lower.hasSuffix(".ts"), comps.count >= 3 {
            alt = url.deletingPathExtension().appendingPathExtension("m3u8")
        } else if !last.contains("."), comps.count >= 3, last.allSatisfy(\.isNumber) {
            alt = url.appendingPathExtension("m3u8")
        }
        guard let alt else { return [endpoint] }
        var variant = endpoint
        variant.url = alt
        return [variant, endpoint]
    }
}

// MARK: - Catch-up / timeshift

public enum CatchupBuilder {
    public static func url(for channel: Channel, programme: Programme, now: Date = Date()) -> URL? {
        guard let c = channel.catchup, let base = channel.primary?.url else { return nil }
        guard programme.start >= now.addingTimeInterval(-Double(c.days) * 86_400), programme.start < now else { return nil }
        let start = Int(programme.start.timeIntervalSince1970)
        let end = Int(programme.stop.timeIntervalSince1970)
        let duration = max(60, end - start)

        func fill(_ t: String) -> String {
            t.replacingOccurrences(of: "${start}", with: String(start))
                .replacingOccurrences(of: "{utc}", with: String(start))
                .replacingOccurrences(of: "${utc}", with: String(start))
                .replacingOccurrences(of: "${end}", with: String(end))
                .replacingOccurrences(of: "{utcend}", with: String(end))
                .replacingOccurrences(of: "${timestamp}", with: String(Int(now.timeIntervalSince1970)))
                .replacingOccurrences(of: "{lutc}", with: String(Int(now.timeIntervalSince1970)))
                .replacingOccurrences(of: "${duration}", with: String(duration))
                .replacingOccurrences(of: "{duration}", with: String(duration))
                .replacingOccurrences(of: "${offset}", with: String(Int(now.timeIntervalSince1970) - start))
        }

        switch c.mode {
        case .xtream:
            // .../live/<user>/<pass>/<id>.<ext>  ->  .../timeshift/<user>/<pass>/<minutes>/<yyyy-MM-dd:HH-mm>/<id>.<ext>
            var comps = base.pathComponents.filter { $0 != "/" }
            guard let liveIdx = comps.lastIndex(of: "live"), comps.count >= liveIdx + 4 else { return nil }
            let file = comps[liveIdx + 3]
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = "yyyy-MM-dd:HH-mm"
            comps.replaceSubrange((liveIdx + 3)..<(liveIdx + 4), with: ["\(duration / 60)", f.string(from: programme.start), file])
            comps[liveIdx] = "timeshift"
            var u = URLComponents(url: base, resolvingAgainstBaseURL: false)
            u?.path = "/" + comps.joined(separator: "/")
            return u?.url
        case .append:
            return URL(string: base.absoluteString + fill(c.template ?? "?utc=${start}&lutc=${timestamp}"))
        case .template:
            return c.template.flatMap { URL(string: fill($0)) }
        case .shift:
            let sep = base.absoluteString.contains("?") ? "&" : "?"
            return URL(string: base.absoluteString + sep + "utc=\(start)&lutc=\(Int(now.timeIntervalSince1970))")
        case .flussonic:
            let s = base.absoluteString
            if let r = s.range(of: "index.m3u8") ?? s.range(of: "mpegts") {
                return URL(string: s.replacingCharacters(in: r, with: "index-\(start)-\(duration).m3u8"))
            }
            return nil
        }
    }
}

// MARK: - Stream health (dead-channel scan)

public struct HealthResult: Sendable {
    public var channelID: String
    public var alive: Bool
    public var latency: TimeInterval?
}

public enum StreamHealth {
    public static func probe(_ ep: StreamEndpoint, timeout: TimeInterval = 6, session: URLSession = .shared) async -> (alive: Bool, latency: TimeInterval?) {
        var req = URLRequest(url: ep.url, timeoutInterval: timeout)
        req.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        req.setValue(ep.userAgent ?? "Lumina/1.0", forHTTPHeaderField: "User-Agent")
        if let r = ep.referer { req.setValue(r, forHTTPHeaderField: "Referer") }
        let t0 = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            guard let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) else { return (false, nil) }
            if ep.url.pathExtension.lowercased() == "m3u8", !String(decoding: data.prefix(16), as: UTF8.self).contains("#EXTM3U") {
                return (false, nil)
            }
            return (!data.isEmpty, Date().timeIntervalSince(t0))
        } catch {
            return (false, nil)
        }
    }

    /// Probes at most `concurrency` channels at once, yielding each result as it arrives.
    /// Cancelling the consuming task stops the scan.
    public static func scan(_ channels: [Channel], concurrency: Int = 8, session: URLSession = .shared) -> AsyncStream<HealthResult> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: HealthResult?.self) { group in
                    var it = channels.makeIterator()
                    for _ in 0..<max(1, concurrency) {
                        guard let c = it.next() else { break }
                        group.addTask { await result(c, session) }
                    }
                    while let r = await group.next() {
                        if let r { continuation.yield(r) }
                        if Task.isCancelled { group.cancelAll(); break }
                        if let c = it.next() { group.addTask { await result(c, session) } }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func result(_ c: Channel, _ session: URLSession) async -> HealthResult? {
        guard let ep = c.primary else { return nil }
        let r = await probe(ep, session: session)
        return HealthResult(channelID: c.id, alive: r.alive, latency: r.latency)
    }
}
