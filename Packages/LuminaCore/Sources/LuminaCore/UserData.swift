import CryptoKit
import Foundation

public struct Reminder: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(channelID)|\(start.timeIntervalSince1970)" }
    public var channelID: String
    public var channelName: String
    public var title: String
    public var start: Date

    public init(channelID: String, channelName: String, title: String, start: Date) {
        self.channelID = channelID
        self.channelName = channelName
        self.title = title
        self.start = start
    }
}

public struct WatchProgress: Codable, Hashable, Sendable {
    public var position: TimeInterval
    public var duration: TimeInterval
    public var updated: Date
    public var title: String
    public var poster: URL?
    public var streamURL: URL?

    public var fraction: Double { duration > 0 ? min(1, position / duration) : 0 }
    public var isFinished: Bool { fraction > 0.95 }

    public init(position: TimeInterval, duration: TimeInterval, updated: Date = Date(), title: String, poster: URL? = nil, streamURL: URL? = nil) {
        self.streamURL = streamURL
        self.position = position
        self.duration = duration
        self.updated = updated
        self.title = title
        self.poster = poster
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var mergeDuplicates = true
    public var autoFailover = true
    public var rewriteTSToHLS = true
    public var forwardBufferSeconds: Double = 4
    public var guideRefreshHours = 12
    public var resumeLastChannel = true
    public var showGroupRegions = true
    public var gridLayout = false
    public var carPlayAudioOnly = true
    public var carPlayMaxItems = 100
    public var hideAdultByDefault = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case mergeDuplicates, autoFailover, rewriteTSToHLS, forwardBufferSeconds, guideRefreshHours
        case resumeLastChannel, showGroupRegions, gridLayout, carPlayAudioOnly, carPlayMaxItems
        case hideAdultByDefault
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        mergeDuplicates = try c.decodeIfPresent(Bool.self, forKey: .mergeDuplicates) ?? d.mergeDuplicates
        autoFailover = try c.decodeIfPresent(Bool.self, forKey: .autoFailover) ?? d.autoFailover
        rewriteTSToHLS = try c.decodeIfPresent(Bool.self, forKey: .rewriteTSToHLS) ?? d.rewriteTSToHLS
        forwardBufferSeconds = try c.decodeIfPresent(Double.self, forKey: .forwardBufferSeconds) ?? d.forwardBufferSeconds
        guideRefreshHours = try c.decodeIfPresent(Int.self, forKey: .guideRefreshHours) ?? d.guideRefreshHours
        resumeLastChannel = try c.decodeIfPresent(Bool.self, forKey: .resumeLastChannel) ?? d.resumeLastChannel
        showGroupRegions = try c.decodeIfPresent(Bool.self, forKey: .showGroupRegions) ?? d.showGroupRegions
        gridLayout = try c.decodeIfPresent(Bool.self, forKey: .gridLayout) ?? d.gridLayout
        carPlayAudioOnly = try c.decodeIfPresent(Bool.self, forKey: .carPlayAudioOnly) ?? d.carPlayAudioOnly
        carPlayMaxItems = try c.decodeIfPresent(Int.self, forKey: .carPlayMaxItems) ?? d.carPlayMaxItems
        hideAdultByDefault = try c.decodeIfPresent(Bool.self, forKey: .hideAdultByDefault) ?? d.hideAdultByDefault
    }
}

/// Everything personal that should survive a playlist refresh (and, optionally, sync via iCloud).
public struct UserData: Codable, Equatable, Sendable {
    public var favorites: [String] = []          // channel ids, user-ordered
    public var recents: [String] = []            // newest first
    public var lastChannelID: String?
    public var hiddenChannels: Set<String> = []
    public var hiddenGroups: Set<String> = []
    public var lockedGroups: Set<String> = []
    public var progress: [String: WatchProgress] = [:]
    public var reminders: [Reminder] = []
    public var pinHash: String?
    public var pinSalt: String?
    public var settings = AppSettings()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case favorites, recents, lastChannelID, hiddenChannels, hiddenGroups, lockedGroups
        case progress, reminders, pinHash, pinSalt, settings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        favorites = try c.decodeIfPresent([String].self, forKey: .favorites) ?? []
        recents = try c.decodeIfPresent([String].self, forKey: .recents) ?? []
        lastChannelID = try c.decodeIfPresent(String.self, forKey: .lastChannelID)
        hiddenChannels = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenChannels) ?? []
        hiddenGroups = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenGroups) ?? []
        lockedGroups = try c.decodeIfPresent(Set<String>.self, forKey: .lockedGroups) ?? []
        progress = try c.decodeIfPresent([String: WatchProgress].self, forKey: .progress) ?? [:]
        reminders = try c.decodeIfPresent([Reminder].self, forKey: .reminders) ?? []
        pinHash = try c.decodeIfPresent(String.self, forKey: .pinHash)
        pinSalt = try c.decodeIfPresent(String.self, forKey: .pinSalt)
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
    }

    // MARK: Mutations

    public func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    public mutating func toggleFavorite(_ id: String) {
        if let i = favorites.firstIndex(of: id) { favorites.remove(at: i) } else { favorites.append(id) }
    }

    public mutating func pushRecent(_ id: String, limit: Int = 30) {
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        if recents.count > limit { recents.removeLast(recents.count - limit) }
        lastChannelID = id
    }

    public mutating func setProgress(_ id: String, _ p: WatchProgress) {
        progress[id] = p
        // Bound growth: keep the 500 most recent entries.
        if progress.count > 500 {
            for k in progress.sorted(by: { $0.value.updated < $1.value.updated }).prefix(progress.count - 500).map(\.key) {
                progress[k] = nil
            }
        }
    }

    public mutating func applyAliases(_ aliases: [String: String]) {
        guard !aliases.isEmpty else { return }
        func remap(_ ids: [String]) -> [String] {
            var seen = Set<String>()
            return ids.map { aliases[$0] ?? $0 }.filter { seen.insert($0).inserted }
        }
        favorites = remap(favorites)
        recents = remap(recents)
        if let l = lastChannelID { lastChannelID = aliases[l] ?? l }
    }

    // MARK: Parental PIN

    public var hasPIN: Bool { pinHash != nil }

    public mutating func setPIN(_ pin: String?) {
        guard let pin, !pin.isEmpty else { pinHash = nil; pinSalt = nil; return }
        let salt = UUID().uuidString
        pinSalt = salt
        pinHash = Self.hash(pin, salt: salt)
    }

    public func verifyPIN(_ pin: String) -> Bool {
        guard let h = pinHash, let s = pinSalt else { return true }
        return Self.hash(pin, salt: s) == h
    }

    static func hash(_ pin: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + pin).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ParentalHeuristics {
    private static let words: Set<String> = ["adult", "xxx", "porn", "18", "erotic", "sex", "playboy", "hustler"]

    /// Groups that look adult by name. Only a hint: the user's own locks always win.
    public static func looksAdult(group: String) -> Bool {
        NameNormalizer.tokens(group).contains(where: words.contains)
    }
}

// MARK: - JSON persistence

public enum JSONFile {
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }
}
