import Foundation

// MARK: - Stable hashing (Swift's Hasher is randomised per launch, ids must survive restarts)

public enum StableHash {
    public static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return h
    }

    public static func hex(_ s: String) -> String { String(fnv1a(s), radix: 16) }
}

// MARK: - Source

/// A playlist source the user added (M3U URL, Xtream login, or the built-in demo).
public struct Source: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case m3u(URL)
        case xtream(server: URL, username: String, password: String)
        case demo
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Extra XMLTV guide URLs in addition to the ones declared by the playlist itself.
    public var extraEPG: [URL]
    public var userAgent: String?
    /// Minutes to shift guide times (positive = guide is late).
    public var epgOffsetMinutes: Int
    public var enabled: Bool
    public var lastRefreshed: Date?

    public init(
        id: UUID = UUID(), name: String, kind: Kind, extraEPG: [URL] = [],
        userAgent: String? = nil, epgOffsetMinutes: Int = 0, enabled: Bool = true,
        lastRefreshed: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.extraEPG = extraEPG
        self.userAgent = userAgent
        self.epgOffsetMinutes = epgOffsetMinutes
        self.enabled = enabled
        self.lastRefreshed = lastRefreshed
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, extraEPG, userAgent, epgOffsetMinutes, enabled, lastRefreshed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        extraEPG = try c.decodeIfPresent([URL].self, forKey: .extraEPG) ?? []
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent)
        epgOffsetMinutes = try c.decodeIfPresent(Int.self, forKey: .epgOffsetMinutes) ?? 0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        lastRefreshed = try c.decodeIfPresent(Date.self, forKey: .lastRefreshed)
    }
}

// MARK: - Quality

public enum Quality: Int, Codable, Comparable, Sendable, CaseIterable {
    case unknown = 0, sd, hd, fhd, uhd

    public static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }

    public var label: String? {
        switch self {
        case .unknown: nil
        case .sd: "SD"
        case .hd: "HD"
        case .fhd: "FHD"
        case .uhd: "4K"
        }
    }

    public static func detect(in name: String) -> Quality {
        var best = Quality.unknown
        for t in NameNormalizer.tokens(name) {
            switch t {
            case "4k", "uhd", "2160p": best = max(best, .uhd)
            case "fhd", "fullhd", "1080p", "1080i": best = max(best, .fhd)
            case "hd", "720p": best = max(best, .hd)
            case "sd", "480p", "576p": best = max(best, .sd)
            default: break
            }
        }
        return best
    }
}

// MARK: - Channel

public struct StreamEndpoint: Codable, Hashable, Sendable {
    public var url: URL
    public var userAgent: String?
    public var referer: String?
    public var quality: Quality

    public init(url: URL, userAgent: String? = nil, referer: String? = nil, quality: Quality = .unknown) {
        self.url = url
        self.userAgent = userAgent
        self.referer = referer
        self.quality = quality
    }
}

public struct Catchup: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case xtream      // /timeshift/user/pass/<minutes>/<yyyy-MM-dd:HH-mm>/<id>.m3u8
        case append      // channel url + template
        case template    // template is a full url
        case shift       // ?utc=&lutc=
        case flussonic   // index-<start>-<duration>.m3u8
    }

    public var mode: Mode
    public var days: Int
    public var template: String?

    public init(mode: Mode, days: Int, template: String? = nil) {
        self.mode = mode
        self.days = days
        self.template = template
    }
}

public struct Channel: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var sourceID: UUID
    public var name: String
    public var number: Int?
    public var group: String
    public var logo: URL?
    public var epgID: String?
    /// Primary stream first; further entries are backups used for automatic failover.
    public var streams: [StreamEndpoint]
    public var catchup: Catchup?

    public init(
        id: String, sourceID: UUID, name: String, number: Int? = nil, group: String,
        logo: URL? = nil, epgID: String? = nil, streams: [StreamEndpoint], catchup: Catchup? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.name = name
        self.number = number
        self.group = group
        self.logo = logo
        self.epgID = epgID
        self.streams = streams
        self.catchup = catchup
    }

    public var primary: StreamEndpoint? { streams.first }
    public var hasCatchup: Bool { catchup != nil && (catchup?.days ?? 0) > 0 }
}

// MARK: - VOD

public struct VODItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var sourceID: UUID
    public var title: String
    public var category: String
    public var poster: URL?
    public var stream: StreamEndpoint
    public var year: String?
    public var rating: Double?
    public var plot: String?
    /// Xtream id used to lazily fetch details.
    public var xtreamID: String?

    public init(
        id: String, sourceID: UUID, title: String, category: String, poster: URL? = nil,
        stream: StreamEndpoint, year: String? = nil, rating: Double? = nil, plot: String? = nil,
        xtreamID: String? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.category = category
        self.poster = poster
        self.stream = stream
        self.year = year
        self.rating = rating
        self.plot = plot
        self.xtreamID = xtreamID
    }
}

public struct Series: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var sourceID: UUID
    public var title: String
    public var category: String
    public var poster: URL?
    public var plot: String?
    public var rating: Double?
    public var year: String?
    public var xtreamID: String?

    public init(
        id: String, sourceID: UUID, title: String, category: String, poster: URL? = nil,
        plot: String? = nil, rating: Double? = nil, year: String? = nil, xtreamID: String? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.category = category
        self.poster = poster
        self.plot = plot
        self.rating = rating
        self.year = year
        self.xtreamID = xtreamID
    }
}

public struct Episode: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var seriesID: String
    public var season: Int
    public var number: Int
    public var title: String
    public var stream: StreamEndpoint
    public var plot: String?
    public var duration: TimeInterval?
    public var thumbnail: URL?

    public init(
        id: String, seriesID: String, season: Int, number: Int, title: String,
        stream: StreamEndpoint, plot: String? = nil, duration: TimeInterval? = nil, thumbnail: URL? = nil
    ) {
        self.id = id
        self.seriesID = seriesID
        self.season = season
        self.number = number
        self.title = title
        self.stream = stream
        self.plot = plot
        self.duration = duration
        self.thumbnail = thumbnail
    }
}

// MARK: - Snapshot (everything loaded from one source)

public struct SourceSnapshot: Codable, Sendable {
    public var sourceID: UUID
    public var channels: [Channel]
    public var movies: [VODItem]
    public var series: [Series]
    /// Episodes known up-front (M3U sources). Xtream episodes are fetched on demand.
    public var episodes: [Episode]
    public var epgURLs: [URL]
    public var account: XtreamAccount?
    public var fetchedAt: Date

    public init(
        sourceID: UUID, channels: [Channel] = [], movies: [VODItem] = [], series: [Series] = [],
        episodes: [Episode] = [], epgURLs: [URL] = [], account: XtreamAccount? = nil, fetchedAt: Date = Date()
    ) {
        self.sourceID = sourceID
        self.channels = channels
        self.movies = movies
        self.series = series
        self.episodes = episodes
        self.epgURLs = epgURLs
        self.account = account
        self.fetchedAt = fetchedAt
    }
}

// MARK: - Group labels ("US| NEWS" -> region US, title News)

public struct GroupLabel: Hashable, Sendable {
    public var raw: String
    public var region: String?
    public var title: String

    public static func parse(_ raw: String) -> GroupLabel {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let m = Self.regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let r1 = Range(m.range(at: 1), in: trimmed), let r2 = Range(m.range(at: 2), in: trimmed) {
            return GroupLabel(raw: raw, region: String(trimmed[r1]), title: Self.tidy(String(trimmed[r2])))
        }
        return GroupLabel(raw: raw, region: nil, title: Self.tidy(trimmed))
    }

    private static let regex = try! NSRegularExpression(pattern: #"^([A-Z]{2})\s*[|:\-]\s*(.+)$"#)

    private static func tidy(_ s: String) -> String {
        // Shouting providers: "NEWS" -> "News". Leave mixed-case names alone.
        if s == s.uppercased(), s.count > 3, s.rangeOfCharacter(from: .lowercaseLetters) == nil {
            return s.capitalized
        }
        return s
    }
}
