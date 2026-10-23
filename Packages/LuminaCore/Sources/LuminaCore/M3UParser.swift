import Foundation

public struct ParsedPlaylist: Sendable {
    public var channels: [Channel] = []
    public var movies: [VODItem] = []
    public var series: [Series] = []
    public var episodes: [Episode] = []
    public var epgURLs: [URL] = []
    public var skipped: Int = 0
}

/// Fast, forgiving M3U / M3U8 (IPTV flavour) parser. Works on raw bytes so 100k-entry
/// playlists parse in well under a second and never build one giant `[String]`.
public enum M3UParser {
    public static func parse(_ data: Data, sourceID: UUID, defaultUserAgent: String? = nil) -> ParsedPlaylist {
        var state = State(sourceID: sourceID, defaultUserAgent: defaultUserAgent)
        let bytes = [UInt8](data)
        var start = 0
        // Skip UTF-8 BOM.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { start = 3 }
        var i = start
        let n = bytes.count
        while i <= n {
            if i == n || bytes[i] == 0x0A {
                var end = i
                if end > start, bytes[end - 1] == 0x0D { end -= 1 }
                if end > start { state.consume(bytes[start..<end]) }
                start = i + 1
            }
            i += 1
        }
        return state.finish()
    }

    public static func parse(_ string: String, sourceID: UUID, defaultUserAgent: String? = nil) -> ParsedPlaylist {
        parse(Data(string.utf8), sourceID: sourceID, defaultUserAgent: defaultUserAgent)
    }

    // MARK: State machine

    private struct Pending {
        var attrs: [String: String]
        var name: String
        var group: String?
        var userAgent: String?
        var referer: String?
    }

    private struct State {
        let sourceID: UUID
        let defaultUserAgent: String?
        var out = ParsedPlaylist()
        var pending: Pending?
        var seenIDs: [String: Int] = [:]
        var seriesIndex: [String: Series] = [:]
        var seriesOrder: [String] = []

        init(sourceID: UUID, defaultUserAgent: String?) {
            self.sourceID = sourceID
            self.defaultUserAgent = defaultUserAgent
        }

        mutating func consume(_ line: ArraySlice<UInt8>) {
            guard let first = line.first else { return }
            if first == 0x23 { // '#'
                let s = String(decoding: line, as: UTF8.self)
                if s.hasPrefix("#EXTINF:") {
                    let (attrs, name) = M3UParser.parseExtInf(line)
                    pending = Pending(attrs: attrs, name: name)
                } else if s.hasPrefix("#EXTM3U") {
                    let attrs = M3UParser.parseAttributes(line, from: 7)
                    for key in ["url-tvg", "x-tvg-url", "tvg-url"] {
                        if let v = attrs[key] {
                            for part in v.split(separator: ",") {
                                if let u = URL(string: part.trimmingCharacters(in: .whitespaces)), u.scheme != nil {
                                    out.epgURLs.append(u)
                                }
                            }
                        }
                    }
                } else if s.hasPrefix("#EXTGRP:") {
                    pending?.group = String(s.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                } else if s.hasPrefix("#EXTVLCOPT:") {
                    let opt = s.dropFirst(11)
                    if let eq = opt.firstIndex(of: "=") {
                        let k = opt[..<eq].lowercased()
                        let v = String(opt[opt.index(after: eq)...])
                        if k == "http-user-agent" { pending?.userAgent = v }
                        if k == "http-referrer" || k == "http-referer" { pending?.referer = v }
                    }
                }
                return
            }
            guard var p = pending else { return }
            pending = nil
            let raw = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard let (url, ua, ref) = M3UParser.parseURLLine(raw) else {
                out.skipped += 1
                return
            }
            if let ua { p.userAgent = ua }
            if let ref { p.referer = ref }
            emit(p, url: url)
        }

        mutating func emit(_ p: Pending, url: URL) {
            let name = p.name.isEmpty ? (p.attrs["tvg-name"] ?? "Channel") : p.name
            let group = p.attrs["group-title"].flatMap { $0.isEmpty ? nil : $0 } ?? p.group ?? "Uncategorized"
            let endpoint = StreamEndpoint(
                url: url, userAgent: p.userAgent ?? defaultUserAgent, referer: p.referer,
                quality: Quality.detect(in: name)
            )
            let path = url.path.lowercased()

            if path.contains("/series/") {
                emitEpisode(name: name, group: group, endpoint: endpoint, poster: p.attrs["tvg-logo"])
                return
            }
            if path.contains("/movie/") || Self.isVODFile(path) {
                let base = StableHash.hex("\(sourceID)|m|\(name)|\(url.path)")
                out.movies.append(VODItem(
                    id: base, sourceID: sourceID, title: name, category: group,
                    poster: p.attrs["tvg-logo"].flatMap(URL.init(string:)), stream: endpoint
                ))
                return
            }

            let tvgID = p.attrs["tvg-id"].flatMap { $0.isEmpty ? nil : $0 }
            var id = StableHash.hex("\(sourceID)|\(tvgID ?? "")|\(name)|\(group)")
            if let n = seenIDs[id] {
                seenIDs[id] = n + 1
                id += "#\(n)"
            } else {
                seenIDs[id] = 1
            }
            out.channels.append(Channel(
                id: id, sourceID: sourceID, name: name,
                number: p.attrs["tvg-chno"].flatMap { Int($0) } ?? p.attrs["channel-number"].flatMap { Int($0) },
                group: group,
                logo: p.attrs["tvg-logo"].flatMap { $0.isEmpty ? nil : URL(string: $0) },
                epgID: tvgID ?? p.attrs["tvg-name"].flatMap { $0.isEmpty ? nil : $0 },
                streams: [endpoint],
                catchup: Self.catchup(from: p.attrs)
            ))
        }

        mutating func emitEpisode(name: String, group: String, endpoint: StreamEndpoint, poster: String?) {
            let parsed = M3UParser.parseEpisodeName(name)
            let seriesTitle = parsed.series
            let seriesID = StableHash.hex("\(sourceID)|s|\(seriesTitle.lowercased())")
            if seriesIndex[seriesID] == nil {
                seriesIndex[seriesID] = Series(
                    id: seriesID, sourceID: sourceID, title: seriesTitle, category: group,
                    poster: poster.flatMap { $0.isEmpty ? nil : URL(string: $0) }
                )
                seriesOrder.append(seriesID)
            }
            out.episodes.append(Episode(
                id: StableHash.hex("\(seriesID)|\(parsed.season)|\(parsed.episode)|\(endpoint.url.path)"),
                seriesID: seriesID, season: parsed.season, number: parsed.episode, title: name, stream: endpoint
            ))
        }

        static func isVODFile(_ path: String) -> Bool {
            path.hasSuffix(".mp4") || path.hasSuffix(".mkv") || path.hasSuffix(".avi") || path.hasSuffix(".mov")
        }

        static func catchup(from a: [String: String]) -> Catchup? {
            let days = Int(a["catchup-days"] ?? a["tvg-rec"] ?? "") ?? 0
            let type = (a["catchup"] ?? a["catchup-type"] ?? "").lowercased()
            let src = a["catchup-source"].flatMap { $0.isEmpty ? nil : $0 }
            if type.isEmpty, src == nil, days == 0 { return nil }
            let d = days > 0 ? days : 1
            switch type {
            case "append": return Catchup(mode: .append, days: d, template: src)
            case "shift": return Catchup(mode: .shift, days: d)
            case "flussonic", "fs", "flussonic-hls", "flussonic-ts": return Catchup(mode: .flussonic, days: d)
            case "xc", "xtream": return Catchup(mode: .xtream, days: d)
            case "default": return src.map { Catchup(mode: .template, days: d, template: $0) }
            default:
                if let src { return Catchup(mode: .template, days: d, template: src) }
                return days > 0 ? Catchup(mode: .xtream, days: d) : nil
            }
        }

        mutating func finish() -> ParsedPlaylist {
            out.series = seriesOrder.compactMap { seriesIndex[$0] }
            return out
        }
    }

    // MARK: Line-level helpers (internal for tests)

    /// `#EXTINF:-1 key="v" key2="v2",Display Name`
    static func parseExtInf(_ line: ArraySlice<UInt8>) -> (attrs: [String: String], name: String) {
        let bytes = Array(line)
        var i = 8 // after "#EXTINF:"
        while i < bytes.count, bytes[i] != 0x20, bytes[i] != 0x2C { i += 1 } // duration
        let (attrs, nameStart) = scanAttributes(bytes, from: i, stopAtComma: true)
        let name = nameStart < bytes.count
            ? String(decoding: bytes[nameStart...], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            : ""
        return (attrs, name)
    }

    static func parseAttributes(_ line: ArraySlice<UInt8>, from: Int) -> [String: String] {
        scanAttributes(Array(line), from: from, stopAtComma: false).0
    }

    private static func scanAttributes(_ bytes: [UInt8], from: Int, stopAtComma: Bool) -> ([String: String], Int) {
        var i = from
        var attrs: [String: String] = [:]
        var nameStart = bytes.count
        while i < bytes.count {
            let c = bytes[i]
            if c == 0x2C, stopAtComma { nameStart = i + 1; break }
            if c == 0x20 || c == 0x09 || c == 0x2C { i += 1; continue }
            let ks = i
            while i < bytes.count, bytes[i] != 0x3D, bytes[i] != 0x2C, bytes[i] != 0x20 { i += 1 }
            guard i < bytes.count, bytes[i] == 0x3D else { continue }
            let key = String(decoding: bytes[ks..<i], as: UTF8.self).lowercased()
            i += 1
            let value: String
            if i < bytes.count, bytes[i] == 0x22 { // quoted value, may contain commas
                i += 1
                let vs = i
                while i < bytes.count, bytes[i] != 0x22 { i += 1 }
                value = String(decoding: bytes[vs..<i], as: UTF8.self)
                if i < bytes.count { i += 1 }
            } else {
                let vs = i
                while i < bytes.count, bytes[i] != 0x20, bytes[i] != 0x2C { i += 1 }
                value = String(decoding: bytes[vs..<i], as: UTF8.self)
            }
            if !key.isEmpty { attrs[key] = value }
        }
        return (attrs, nameStart)
    }

    /// Handles Kodi-style `url|User-Agent=x&Referer=y` suffixes and un-escaped URLs.
    static func parseURLLine(_ raw: String) -> (URL, String?, String?)? {
        var urlPart = raw
        var ua: String?
        var ref: String?
        if let bar = raw.firstIndex(of: "|"), raw[raw.index(after: bar)...].contains("=") {
            urlPart = String(raw[..<bar])
            for pair in raw[raw.index(after: bar)...].split(separator: "&") {
                guard let eq = pair.firstIndex(of: "=") else { continue }
                let k = pair[..<eq].lowercased()
                let v = String(pair[pair.index(after: eq)...]).removingPercentEncoding ?? String(pair[pair.index(after: eq)...])
                if k == "user-agent" { ua = v }
                if k == "referer" || k == "referrer" { ref = v }
            }
        }
        guard let scheme = urlPart.split(separator: ":").first?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        if let u = URL(string: urlPart) { return (u, ua, ref) }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.formUnion(.urlPathAllowed)
        allowed.insert(charactersIn: "%")
        if let enc = urlPart.addingPercentEncoding(withAllowedCharacters: allowed), let u = URL(string: enc) {
            return (u, ua, ref)
        }
        return nil
    }

    /// "Show Name S02E05", "Show.Name.2x05", etc.
    static func parseEpisodeName(_ name: String) -> (series: String, season: Int, episode: Int) {
        let range = NSRange(name.startIndex..., in: name)
        for re in episodeRegexes {
            if let m = re.firstMatch(in: name, range: range),
               let r0 = Range(m.range(at: 1), in: name),
               let r1 = Range(m.range(at: 2), in: name),
               let r2 = Range(m.range(at: 3), in: name),
               let s = Int(name[r1]), let e = Int(name[r2]) {
                let title = name[r0]
                    .replacingOccurrences(of: ".", with: " ")
                    .replacingOccurrences(of: "_", with: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -|:"))
                return (title.isEmpty ? name : title, s, e)
            }
        }
        return (name, 1, 1)
    }

    private static let episodeRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"^(.*?)[\s._-]*[Ss](\d{1,2})[\s._-]*[Ee](\d{1,4})"#),
        try! NSRegularExpression(pattern: #"^(.*?)[\s._-]+(\d{1,2})x(\d{1,3})\b"#),
    ]
}
