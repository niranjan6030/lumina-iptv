import Compression
import Foundation

// MARK: - Model

public struct Programme: Codable, Hashable, Sendable, Identifiable {
    public var channel: String   // lower-cased guide channel id
    public var start: Date
    public var stop: Date
    public var title: String
    public var subtitle: String?
    public var desc: String?
    public var category: String?
    public var icon: URL?

    public var id: String { "\(channel)|\(start.timeIntervalSince1970)" }
    public var duration: TimeInterval { stop.timeIntervalSince(start) }

    public init(
        channel: String, start: Date, stop: Date, title: String, subtitle: String? = nil,
        desc: String? = nil, category: String? = nil, icon: URL? = nil
    ) {
        self.channel = channel
        self.start = start
        self.stop = stop
        self.title = title
        self.subtitle = subtitle
        self.desc = desc
        self.category = category
        self.icon = icon
    }

    public func progress(at date: Date) -> Double {
        let d = duration
        guard d > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / d))
    }
}

// MARK: - Index

/// Read-optimised guide data. Value type, safe to hand between actors.
public struct EPGIndex: Sendable {
    private var byChannel: [String: [Programme]] = [:]
    private var nameToID: [String: String] = [:]
    public private(set) var channelIcons: [String: URL] = [:]

    public init() {}

    public init(programmes: [Programme], channelNames: [String: [String]] = [:], channelIcons: [String: URL] = [:]) {
        var grouped: [String: [Programme]] = [:]
        for p in programmes { grouped[p.channel, default: []].append(p) }
        for k in grouped.keys { grouped[k]!.sort { $0.start < $1.start } }
        byChannel = grouped
        for (id, names) in channelNames {
            for n in names { nameToID[NameNormalizer.key(n)] = id }
        }
        self.channelIcons = channelIcons
    }

    public var isEmpty: Bool { byChannel.isEmpty }
    public var programmeCount: Int { byChannel.values.reduce(0) { $0 + $1.count } }

    /// Merge another index in (used when several sources / guide URLs are loaded).
    public mutating func merge(_ other: EPGIndex) {
        for (k, v) in other.byChannel {
            if var existing = byChannel[k] {
                let starts = Set(existing.map(\.start))
                existing.append(contentsOf: v.filter { !starts.contains($0.start) })
                existing.sort { $0.start < $1.start }
                byChannel[k] = existing
            } else {
                byChannel[k] = v
            }
        }
        nameToID.merge(other.nameToID) { a, _ in a }
        channelIcons.merge(other.channelIcons) { a, _ in a }
    }

    public func guideKey(for channel: Channel) -> String? {
        if byChannel[channel.id.lowercased()] != nil { return channel.id.lowercased() }
        if let id = channel.epgID?.lowercased(), byChannel[id] != nil { return id }
        if let id = nameToID[NameNormalizer.key(channel.name)] { return id }
        if let e = channel.epgID, let id = nameToID[NameNormalizer.key(e)] { return id }
        return nil
    }

    public func programmes(for channel: Channel) -> [Programme] {
        guideKey(for: channel).flatMap { byChannel[$0] } ?? []
    }

    public func programmes(forKey key: String) -> [Programme] { byChannel[key] ?? [] }

    /// `offset` shifts the guide: positive means the guide runs late (programmes appear later than they really air).
    public func now(for channel: Channel, at date: Date = Date(), offset: TimeInterval = 0) -> Programme? {
        nowNext(for: channel, at: date, offset: offset).now
    }

    public func nowNext(for channel: Channel, at date: Date = Date(), offset: TimeInterval = 0)
        -> (now: Programme?, next: Programme?)
    {
        guard let key = guideKey(for: channel) else { return (nil, nil) }
        return nowNext(forKey: key, at: date, offset: offset)
    }

    /// Fast path for lists: resolve the key once with `guideKey(for:)`, then call this per row.
    public func nowNext(forKey key: String, at date: Date = Date(), offset: TimeInterval = 0)
        -> (now: Programme?, next: Programme?)
    {
        guard let list = byChannel[key], !list.isEmpty else { return (nil, nil) }
        let t = date.addingTimeInterval(-offset)
        // Last programme with start <= t.
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        let idx = lo - 1
        if idx >= 0, list[idx].stop > t {
            return (list[idx], idx + 1 < list.count ? list[idx + 1] : nil)
        }
        return (nil, lo < list.count ? list[lo] : nil)
    }

    public func timeline(for channel: Channel, from: Date, to: Date, offset: TimeInterval = 0) -> [Programme] {
        let a = from.addingTimeInterval(-offset), b = to.addingTimeInterval(-offset)
        return programmes(for: channel).filter { $0.stop > a && $0.start < b }
    }

    /// Programme title search over [from, to]. Returns (programme, guide key).
    public func search(_ query: String, from: Date, to: Date, limit: Int = 40) -> [Programme] {
        let tokens = NameNormalizer.tokens(query)
        guard !tokens.isEmpty else { return [] }
        var hits: [Programme] = []
        for list in byChannel.values {
            for p in list where p.stop > from && p.start < to {
                let t = NameNormalizer.tokens(p.title)
                if tokens.allSatisfy({ q in t.contains(where: { $0.hasPrefix(q) }) }) { hits.append(p) }
            }
        }
        hits.sort { $0.start < $1.start }
        return Array(hits.prefix(limit))
    }

    /// Every guide key set (used to restrict XMLTV parsing to channels we actually have).
    public var guideKeys: Set<String> { Set(byChannel.keys) }
}

// MARK: - XMLTV

public struct XMLTVResult: Sendable {
    public init() {}

    public var programmes: [Programme] = []
    public var channelNames: [String: [String]] = [:]
    public var channelIcons: [String: URL] = [:]

    public var index: EPGIndex {
        EPGIndex(programmes: programmes, channelNames: channelNames, channelIcons: channelIcons)
    }
}

public enum XMLTVParser {
    /// - Parameters:
    ///   - wantedIDs: lower-cased guide ids to keep (nil keeps everything).
    ///   - wantedNameKeys: `NameNormalizer.key` values; a guide channel is kept if one of its display names matches.
    ///   - window: only programmes overlapping this window are kept, which bounds memory for huge guides.
    public static func parse(
        fileURL: URL, wantedIDs: Set<String>? = nil, wantedNameKeys: Set<String> = [],
        window: ClosedRange<Date>
    ) throws -> XMLTVResult {
        guard let stream = InputStream(url: fileURL) else { throw LuminaError.notAGuide }
        return try run(XMLParser(stream: stream), wantedIDs: wantedIDs, wantedNameKeys: wantedNameKeys, window: window)
    }

    public static func parse(
        data: Data, wantedIDs: Set<String>? = nil, wantedNameKeys: Set<String> = [], window: ClosedRange<Date>
    ) throws -> XMLTVResult {
        try run(XMLParser(data: data), wantedIDs: wantedIDs, wantedNameKeys: wantedNameKeys, window: window)
    }

    private static func run(
        _ parser: XMLParser, wantedIDs: Set<String>?, wantedNameKeys: Set<String>, window: ClosedRange<Date>
    ) throws -> XMLTVResult {
        let d = Delegate(wantedIDs: wantedIDs, wantedNameKeys: wantedNameKeys, window: window)
        parser.delegate = d
        parser.shouldProcessNamespaces = false
        guard parser.parse() || !d.result.programmes.isEmpty else { throw LuminaError.notAGuide }
        return d.result
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let wantedIDs: Set<String>?
        let wantedNameKeys: Set<String>
        let window: ClosedRange<Date>
        var result = XMLTVResult()

        var wantedChannels: Set<String> = []
        var chID: String?
        var chNames: [String] = []

        var inProgramme = false
        var skip = false
        var p = Programme(channel: "", start: .distantPast, stop: .distantPast, title: "")
        var text = ""
        var collecting = false

        init(wantedIDs: Set<String>?, wantedNameKeys: Set<String>, window: ClosedRange<Date>) {
            self.wantedIDs = wantedIDs
            self.wantedNameKeys = wantedNameKeys
            self.window = window
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes a: [String: String] = [:]) {
            switch name {
            case "channel":
                chID = a["id"]?.lowercased()
                chNames = []
            case "programme":
                inProgramme = true
                skip = true
                guard let ch = a["channel"]?.lowercased(),
                      let s = XMLTVDate.parse(a["start"] ?? ""),
                      let e = XMLTVDate.parse(a["stop"] ?? "") ?? Optional(s.addingTimeInterval(1800)),
                      e >= window.lowerBound, s <= window.upperBound else { return }
                if wantedIDs != nil, !wantedChannels.contains(ch), !(wantedIDs?.contains(ch) ?? false) { return }
                skip = false
                p = Programme(channel: ch, start: s, stop: e, title: "")
            case "display-name", "title", "sub-title", "desc", "category":
                if chID != nil || (inProgramme && !skip) {
                    collecting = true
                    text = ""
                }
            case "icon":
                guard let src = a["src"], let url = URL(string: src) else { return }
                if inProgramme { if !skip { p.icon = url } } else if let id = chID { result.channelIcons[id] = url }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if collecting { text += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if collecting { text += String(decoding: CDATABlock, as: UTF8.self) }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            switch name {
            case "display-name":
                if collecting, chID != nil { chNames.append(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                collecting = false
            case "channel":
                if let id = chID {
                    result.channelNames[id] = chNames
                    if let w = wantedIDs {
                        if w.contains(id) || chNames.contains(where: { wantedNameKeys.contains(NameNormalizer.key($0)) }) {
                            wantedChannels.insert(id)
                        }
                    }
                }
                chID = nil
            case "title":
                if collecting, inProgramme, !skip { p.title = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                collecting = false
            case "sub-title":
                if collecting, inProgramme, !skip { p.subtitle = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                collecting = false
            case "desc":
                if collecting, inProgramme, !skip { p.desc = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                collecting = false
            case "category":
                if collecting, inProgramme, !skip, p.category == nil {
                    p.category = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                collecting = false
            case "programme":
                if !skip, !p.title.isEmpty { result.programmes.append(p) }
                inProgramme = false
                skip = false
            default: break
            }
        }
    }
}

enum XMLTVDate {
    /// `20240131183000 +0100`, `202401311830 -0500`, `20240131183000` (UTC assumed), `…Z`.
    static func parse(_ s: String) -> Date? {
        let u = Array(s.utf8)
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= u.count else { return nil }
            var v = 0
            for k in from..<(from + len) {
                let c = u[k]
                guard c >= 0x30, c <= 0x39 else { return nil }
                v = v * 10 + Int(c - 0x30)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(4, 2), let d = num(6, 2), let h = num(8, 2), let mi = num(10, 2),
              (1...12).contains(mo), (1...31).contains(d) else { return nil }
        var idx = 12
        var sec = 0
        if let sv = num(12, 2) { sec = sv; idx = 14 }
        while idx < u.count, u[idx] == 0x20 { idx += 1 }
        var offset = 0
        if idx < u.count, u[idx] == 0x2B || u[idx] == 0x2D, let hh = num(idx + 1, 2) {
            let mm = num(idx + 3, 2) ?? 0
            offset = (hh * 3600 + mm * 60) * (u[idx] == 0x2D ? -1 : 1)
        }
        let days = daysFromCivil(y, mo, d)
        let t = days * 86400 + h * 3600 + mi * 60 + sec - offset
        return Date(timeIntervalSince1970: TimeInterval(t))
    }

    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}

// MARK: - gzip

public enum Gzip {
    public static func isGzip(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let d = (try? h.read(upToCount: 2)) ?? Data()
        return d.count == 2 && d[d.startIndex] == 0x1F && d[d.startIndex + 1] == 0x8B
    }

    static func headerLength(_ data: Data) -> Int? {
        let b = [UInt8](data.prefix(4096))
        guard b.count >= 10, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 {
            guard i + 2 <= b.count else { return nil }
            i += 2 + Int(b[i]) + Int(b[i + 1]) << 8
        }
        if flags & 8 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 16 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 2 != 0 { i += 2 }
        return i <= b.count ? i : nil
    }

    /// Streams the inflated bytes to `dst` so a 400 MB guide never sits in memory.
    public static func decompress(_ src: URL, to dst: URL) throws {
        let data = try Data(contentsOf: src, options: .mappedIfSafe)
        guard let offset = headerLength(data), data.count > offset else { throw LuminaError.corruptArchive }
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let out = try FileHandle(forWritingTo: dst)
        defer { try? out.close() }

        let bufSize = 1 << 17
        let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { dstBuf.deallocate() }
        let sp = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { sp.deallocate() }
        guard compression_stream_init(sp, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw LuminaError.corruptArchive
        }
        defer { compression_stream_destroy(sp) }

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw LuminaError.corruptArchive }
            sp.pointee.src_ptr = base + offset
            sp.pointee.src_size = data.count - offset
            sp.pointee.dst_ptr = dstBuf
            sp.pointee.dst_size = bufSize
            let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            while true {
                let status = compression_stream_process(sp, flags)
                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                    throw LuminaError.corruptArchive
                }
                let produced = bufSize - sp.pointee.dst_size
                if produced > 0 { try out.write(contentsOf: Data(bytes: dstBuf, count: produced)) }
                if status == COMPRESSION_STATUS_END { return }
                if produced == 0, sp.pointee.src_size == 0 { throw LuminaError.corruptArchive }
                sp.pointee.dst_ptr = dstBuf
                sp.pointee.dst_size = bufSize
            }
        }
    }
}
