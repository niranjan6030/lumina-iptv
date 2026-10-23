import Foundation

// MARK: - Public types

public struct XtreamAccount: Codable, Hashable, Sendable {
    public var username: String
    public var status: String
    public var expiry: Date?
    public var isTrial: Bool
    public var maxConnections: Int?
    public var activeConnections: Int?
    public var allowedFormats: [String]
    public var serverTimezone: String?

    public var daysRemaining: Int? {
        guard let e = expiry else { return nil }
        return Int((e.timeIntervalSinceNow / 86400).rounded(.down))
    }
}

public struct VODDetail: Sendable {
    public var plot: String?
    public var cast: String?
    public var director: String?
    public var genre: String?
    public var year: String?
    public var rating: Double?
    public var duration: String?
    public var backdrop: URL?
    public var poster: URL?
    public var containerExtension: String?
}

// MARK: - Tolerant JSON

/// Xtream panels return numbers as strings, strings as numbers, `false` for "none"… accept all of it.
struct Flex: Decodable {
    let string: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { string = nil }
        else if let s = try? c.decode(String.self) { string = s }
        else if let i = try? c.decode(Int.self) { string = String(i) }
        else if let d = try? c.decode(Double.self) { string = d == d.rounded() ? String(Int(d)) : String(d) }
        else if let b = try? c.decode(Bool.self) { string = b ? "1" : "0" }
        else { string = nil }
    }
}

private extension Optional where Wrapped == Flex {
    var s: String? {
        guard let v = self?.string, !v.isEmpty else { return nil }
        return v
    }
    var i: Int? { s.flatMap { Int($0) } }
    var d: Double? { s.flatMap { Double($0) } }
}

struct AuthDTO: Decodable {
    struct UserInfo: Decodable {
        let username: Flex?, status: Flex?, auth: Flex?, exp_date: Flex?, is_trial: Flex?
        let max_connections: Flex?, active_cons: Flex?, allowed_output_formats: [Flex]?
    }
    struct ServerInfo: Decodable { let timezone: Flex? }
    let user_info: UserInfo?
    let server_info: ServerInfo?
}

struct CategoryDTO: Decodable { let category_id: Flex?, category_name: Flex? }

struct LiveDTO: Decodable {
    let num: Flex?, name: Flex?, stream_id: Flex?, stream_icon: Flex?, epg_channel_id: Flex?
    let category_id: Flex?, tv_archive: Flex?, tv_archive_duration: Flex?
}

struct VODDTO: Decodable {
    let name: Flex?, stream_id: Flex?, stream_icon: Flex?, rating: Flex?, category_id: Flex?
    let container_extension: Flex?, year: Flex?
}

struct SeriesDTO: Decodable {
    let series_id: Flex?, name: Flex?, cover: Flex?, plot: Flex?, rating: Flex?, category_id: Flex?
    let releaseDate: Flex?, release_date: Flex?
}

struct EPGListingsDTO: Decodable {
    struct Item: Decodable {
        let title: Flex?, description: Flex?, start_timestamp: Flex?, stop_timestamp: Flex?
    }
    let epg_listings: [Item]?
}

struct VODInfoDTO: Decodable {
    struct Info: Decodable {
        let plot: Flex?, cast: Flex?, director: Flex?, genre: Flex?, releasedate: Flex?, rating: Flex?
        let duration: Flex?, movie_image: Flex?
        let backdrop_path: [Flex]?
    }
    struct Data: Decodable { let container_extension: Flex? }
    let info: Info?
    let movie_data: Data?
}

struct SeriesInfoDTO: Decodable {
    struct EpInfo: Decodable { let movie_image: Flex?, plot: Flex?, duration_secs: Flex? }
    struct Ep: Decodable {
        let id: Flex?, episode_num: Flex?, title: Flex?, container_extension: Flex?, season: Flex?
        let info: EpInfo?
    }
    let episodes: [String: [Ep]]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let dict = try? c.decode([String: [Ep]].self, forKey: .episodes) {
            episodes = dict
        } else if let arr = try? c.decode([[Ep]].self, forKey: .episodes) {
            var d: [String: [Ep]] = [:]
            for (i, eps) in arr.enumerated() { d[String(i + 1)] = eps }
            episodes = d
        } else {
            episodes = nil
        }
    }
    enum CodingKeys: String, CodingKey { case episodes }
}

// MARK: - Client

public struct XtreamClient: Sendable {
    public let server: URL
    public let username: String
    public let password: String
    let session: URLSession

    public init(server: URL, username: String, password: String, session: URLSession = .shared) {
        self.server = server
        self.username = username
        self.password = password
        self.session = session
    }

    /// "host:8080", "http://host:8080/", "http://host/player_api.php?x=1" → "http://host:8080"
    public static func normalizeServer(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        guard var c = URLComponents(string: s), c.host != nil else { return nil }
        c.query = nil
        c.fragment = nil
        var path = c.path
        for tail in ["/player_api.php", "/get.php", "/xmltv.php", "/panel_api.php"] where path.hasSuffix(tail) {
            path = String(path.dropLast(tail.count))
        }
        while path.hasSuffix("/") { path.removeLast() }
        c.path = path
        return c.url
    }

    /// Recognises provider links like `http://h:80/get.php?username=u&password=p&type=m3u_plus`.
    public static func credentials(fromPlaylistURL url: URL) -> (server: URL, username: String, password: String)? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let u = c.queryItems?.first(where: { $0.name == "username" })?.value,
              let p = c.queryItems?.first(where: { $0.name == "password" })?.value,
              !u.isEmpty, !p.isEmpty,
              url.path.hasSuffix("get.php") || url.path.hasSuffix("player_api.php") || url.path.hasSuffix("xmltv.php"),
              let server = normalizeServer(url.absoluteString) else { return nil }
        return (server, u, p)
    }

    // MARK: URLs

    func api(_ action: String?, _ extra: [String: String] = [:]) throws -> URL {
        guard var c = URLComponents(url: server.appendingPathComponent("player_api.php"), resolvingAgainstBaseURL: false)
        else { throw LuminaError.invalidURL }
        var items = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        for (k, v) in extra.sorted(by: { $0.key < $1.key }) { items.append(URLQueryItem(name: k, value: v)) }
        c.queryItems = items
        guard let url = c.url else { throw LuminaError.invalidURL }
        return url
    }

    public var xmltvURL: URL? {
        guard var c = URLComponents(url: server.appendingPathComponent("xmltv.php"), resolvingAgainstBaseURL: false) else { return nil }
        c.queryItems = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]
        return c.url
    }

    public func liveURL(streamID: String, ext: String = "m3u8") -> URL {
        server.appendingPathComponent("live").appendingPathComponent(username)
            .appendingPathComponent(password).appendingPathComponent("\(streamID).\(ext)")
    }

    public func movieURL(streamID: String, ext: String) -> URL {
        server.appendingPathComponent("movie").appendingPathComponent(username)
            .appendingPathComponent(password).appendingPathComponent("\(streamID).\(ext)")
    }

    public func seriesURL(episodeID: String, ext: String) -> URL {
        server.appendingPathComponent("series").appendingPathComponent(username)
            .appendingPathComponent(password).appendingPathComponent("\(episodeID).\(ext)")
    }

    // MARK: Requests

    func fetch<T: Decodable>(_ type: T.Type, _ url: URL, timeout: TimeInterval = 60) async throws -> T {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("Lumina/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch let e as URLError { throw LuminaError.network(e.localizedDescription) }
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw LuminaError.http(h.statusCode) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw LuminaError.decoding }
    }

    /// Panels answer `[]`, `{}`, `false` or an error object when a section is empty; treat all as "no items".
    func list<T: Decodable>(_ type: T.Type, _ action: String, _ extra: [String: String] = [:]) async throws -> [T] {
        let url = try api(action, extra)
        do { return try await fetch([T].self, url) }
        catch LuminaError.decoding { return [] }
    }

    public func authenticate() async throws -> XtreamAccount {
        let dto = try await fetch(AuthDTO.self, try api(nil), timeout: 30)
        guard let u = dto.user_info, u.auth.i == 1 || u.auth.s == "true" else { throw LuminaError.authFailed }
        let status = u.status.s ?? "Active"
        if status.lowercased() != "active" { throw LuminaError.accountInactive(status) }
        return XtreamAccount(
            username: u.username.s ?? username, status: status,
            expiry: u.exp_date.d.map { Date(timeIntervalSince1970: $0) },
            isTrial: u.is_trial.s == "1", maxConnections: u.max_connections.i, activeConnections: u.active_cons.i,
            allowedFormats: (u.allowed_output_formats ?? []).compactMap { $0.string },
            serverTimezone: dto.server_info?.timezone.s
        )
    }

    // MARK: Library

    /// Pulls live + VOD + series lists concurrently. Only live is required; VOD/series failures are tolerated.
    public func loadSnapshot(sourceID: UUID, account: XtreamAccount, userAgent: String?) async throws -> SourceSnapshot {
        async let liveCats = list(CategoryDTO.self, "get_live_categories")
        async let live = list(LiveDTO.self, "get_live_streams")
        async let vodCats = (try? await list(CategoryDTO.self, "get_vod_categories")) ?? []
        async let vod = (try? await list(VODDTO.self, "get_vod_streams")) ?? []
        async let serCats = (try? await list(CategoryDTO.self, "get_series_categories")) ?? []
        async let ser = (try? await list(SeriesDTO.self, "get_series")) ?? []

        let (lc, l) = try await (liveCats, live)
        let (vc, v, sc, s) = await (vodCats, vod, serCats, ser)

        func names(_ c: [CategoryDTO]) -> [String: String] {
            var m: [String: String] = [:]
            for x in c { if let id = x.category_id.s { m[id] = x.category_name.s ?? "Other" } }
            return m
        }
        let liveNames = names(lc), vodNames = names(vc), serNames = names(sc)
        // Prefer HLS: AVPlayer cannot play raw MPEG-TS over HTTP.
        let ext = account.allowedFormats.isEmpty || account.allowedFormats.contains("m3u8") ? "m3u8" : (account.allowedFormats.first ?? "ts")

        var channels: [Channel] = []
        channels.reserveCapacity(l.count)
        for x in l {
            guard let sid = x.stream_id.s else { continue }
            let name = x.name.s ?? "Channel \(sid)"
            let archiveDays = x.tv_archive.s == "1" ? (x.tv_archive_duration.i ?? 1) : 0
            channels.append(Channel(
                id: "\(sourceID.uuidString.prefix(8)):x\(sid)", sourceID: sourceID, name: name, number: x.num.i,
                group: x.category_id.s.flatMap { liveNames[$0] } ?? "Uncategorized",
                logo: x.stream_icon.s.flatMap(URL.init(string:)), epgID: x.epg_channel_id.s,
                streams: [StreamEndpoint(url: liveURL(streamID: sid, ext: ext), userAgent: userAgent, quality: Quality.detect(in: name))],
                catchup: archiveDays > 0 ? Catchup(mode: .xtream, days: archiveDays) : nil
            ))
        }

        var movies: [VODItem] = []
        movies.reserveCapacity(v.count)
        for x in v {
            guard let sid = x.stream_id.s else { continue }
            movies.append(VODItem(
                id: "\(sourceID.uuidString.prefix(8)):m\(sid)", sourceID: sourceID, title: x.name.s ?? "Movie",
                category: x.category_id.s.flatMap { vodNames[$0] } ?? "Movies",
                poster: x.stream_icon.s.flatMap(URL.init(string:)),
                stream: StreamEndpoint(url: movieURL(streamID: sid, ext: x.container_extension.s ?? "mp4"), userAgent: userAgent),
                year: x.year.s, rating: x.rating.d, xtreamID: sid
            ))
        }

        let series: [Series] = s.compactMap { x in
            guard let sid = x.series_id.s else { return nil }
            return Series(
                id: "\(sourceID.uuidString.prefix(8)):s\(sid)", sourceID: sourceID, title: x.name.s ?? "Series",
                category: x.category_id.s.flatMap { serNames[$0] } ?? "Series",
                poster: x.cover.s.flatMap(URL.init(string:)), plot: x.plot.s, rating: x.rating.d,
                year: (x.releaseDate.s ?? x.release_date.s).map { String($0.prefix(4)) }, xtreamID: sid
            )
        }

        guard !channels.isEmpty || !movies.isEmpty || !series.isEmpty else { throw LuminaError.emptyPlaylist }
        return SourceSnapshot(
            sourceID: sourceID, channels: channels, movies: movies, series: series,
            epgURLs: xmltvURL.map { [$0] } ?? [], account: account
        )
    }

    // MARK: Details

    public func vodDetail(id: String) async throws -> VODDetail {
        let d = try await fetch(VODInfoDTO.self, try api("get_vod_info", ["vod_id": id]))
        let i = d.info
        return VODDetail(
            plot: i?.plot.s, cast: i?.cast.s, director: i?.director.s, genre: i?.genre.s,
            year: i?.releasedate.s.map { String($0.prefix(4)) }, rating: i?.rating.d, duration: i?.duration.s,
            backdrop: i?.backdrop_path?.first?.string.flatMap(URL.init(string:)),
            poster: i?.movie_image.s.flatMap(URL.init(string:)), containerExtension: d.movie_data?.container_extension.s
        )
    }

    public func episodes(seriesID: String, localSeriesID: String, userAgent: String?) async throws -> [Episode] {
        let d = try await fetch(SeriesInfoDTO.self, try api("get_series_info", ["series_id": seriesID]))
        var out: [Episode] = []
        for (seasonKey, eps) in d.episodes ?? [:] {
            for e in eps {
                guard let eid = e.id.s else { continue }
                let season = e.season.i ?? Int(seasonKey) ?? 1
                let n = e.episode_num.i ?? 0
                out.append(Episode(
                    id: "\(localSeriesID):e\(eid)", seriesID: localSeriesID, season: season, number: n,
                    title: e.title.s ?? "Episode \(n)",
                    stream: StreamEndpoint(url: seriesURL(episodeID: eid, ext: e.container_extension.s ?? "mp4"), userAgent: userAgent),
                    plot: e.info?.plot.s, duration: e.info?.duration_secs.d, thumbnail: e.info?.movie_image.s.flatMap(URL.init(string:))
                ))
            }
        }
        return out.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
    }

    // MARK: Guide fallbacks (when a panel has no xmltv.php)

    public func shortEPG(streamID: String, guideChannel: String, limit: Int = 6) async throws -> [Programme] {
        let d = try await fetch(EPGListingsDTO.self, try api("get_short_epg", ["stream_id": streamID, "limit": String(limit)]))
        return Self.programmes(from: d, channel: guideChannel)
    }

    public func fullDayEPG(streamID: String, guideChannel: String) async throws -> [Programme] {
        let d = try await fetch(EPGListingsDTO.self, try api("get_simple_data_table", ["stream_id": streamID]))
        return Self.programmes(from: d, channel: guideChannel)
    }

    static func programmes(from d: EPGListingsDTO, channel: String) -> [Programme] {
        (d.epg_listings ?? []).compactMap { x in
            guard let s = x.start_timestamp.d, let e = x.stop_timestamp.d, let t = x.title.s else { return nil }
            return Programme(
                channel: channel.lowercased(), start: Date(timeIntervalSince1970: s), stop: Date(timeIntervalSince1970: e),
                title: Self.b64(t), desc: x.description.s.map(Self.b64)
            )
        }
    }

    /// Xtream base64-encodes titles; some panels don't, so fall back to the raw text.
    static func b64(_ s: String) -> String {
        guard let d = Data(base64Encoded: s), let t = String(data: d, encoding: .utf8), !t.isEmpty else { return s }
        return t
    }
}
