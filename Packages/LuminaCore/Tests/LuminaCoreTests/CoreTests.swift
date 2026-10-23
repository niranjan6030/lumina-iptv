import Foundation
import Testing
@testable import LuminaCore

private let sid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

// MARK: - M3U

@Suite struct M3UTests {
    @Test func parsesAttributesQuotesAndCommasInNames() {
        let text = """
        #EXTM3U url-tvg="http://epg.example/a.xml.gz,http://epg.example/b.xml"\r
        #EXTINF:-1 tvg-id="bbc.one" tvg-logo="http://l/x.png" group-title="UK, News" tvg-chno="101",BBC One, London HD\r
        http://h/live/u/p/1.m3u8\r
        #EXTINF:-1 group-title="Sports",ESPN
        #EXTVLCOPT:http-user-agent=Foo/1.0
        #EXTVLCOPT:http-referrer=http://ref/
        http://h/2.m3u8
        """
        let p = M3UParser.parse(text, sourceID: sid)
        #expect(p.epgURLs.count == 2)
        #expect(p.channels.count == 2)
        let bbc = p.channels[0]
        #expect(bbc.name == "BBC One, London HD")
        #expect(bbc.group == "UK, News")
        #expect(bbc.number == 101)
        #expect(bbc.epgID == "bbc.one")
        #expect(bbc.logo?.absoluteString == "http://l/x.png")
        #expect(bbc.streams[0].quality == .hd)
        let espn = p.channels[1]
        #expect(espn.streams[0].userAgent == "Foo/1.0")
        #expect(espn.streams[0].referer == "http://ref/")
    }

    @Test func kodiPipeHeadersAndSkipsUnsupportedSchemes() {
        let text = """
        #EXTM3U
        #EXTINF:-1,A
        http://h/a.m3u8|User-Agent=Bar&Referer=http://r/
        #EXTINF:-1,B
        rtmp://h/b
        """
        let p = M3UParser.parse(text, sourceID: sid)
        #expect(p.channels.count == 1)
        #expect(p.skipped == 1)
        #expect(p.channels[0].streams[0].url.absoluteString == "http://h/a.m3u8")
        #expect(p.channels[0].streams[0].userAgent == "Bar")
        #expect(p.channels[0].streams[0].referer == "http://r/")
    }

    @Test func classifiesMoviesAndGroupsEpisodesIntoSeries() {
        let text = """
        #EXTM3U
        #EXTINF:-1 group-title="Films",Some Film (2020)
        http://h/movie/u/p/10.mkv
        #EXTINF:-1 group-title="Shows",Great Show S01E02
        http://h/series/u/p/21.mp4
        #EXTINF:-1 group-title="Shows",Great Show S02E01
        http://h/series/u/p/22.mp4
        #EXTINF:-1 group-title="Shows",Other.Show.1x03
        http://h/series/u/p/23.mp4
        #EXTINF:-1,Live One
        http://h/live/u/p/5.m3u8
        """
        let p = M3UParser.parse(text, sourceID: sid)
        #expect(p.movies.count == 1)
        #expect(p.channels.count == 1)
        #expect(p.series.count == 2)
        #expect(p.episodes.count == 3)
        let great = p.series.first { $0.title == "Great Show" }!
        let eps = p.episodes.filter { $0.seriesID == great.id }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        #expect(eps.map(\.season) == [1, 2])
        #expect(eps.map(\.number) == [2, 1])
        #expect(p.series.contains { $0.title == "Other Show" })
    }

    @Test func idsAreStableAcrossParsesAndUniqueForDuplicates() {
        let text = """
        #EXTM3U
        #EXTINF:-1 tvg-id="x" group-title="G",Same
        http://h/1.m3u8
        #EXTINF:-1 tvg-id="x" group-title="G",Same
        http://h/2.m3u8
        """
        let a = M3UParser.parse(text, sourceID: sid).channels
        let b = M3UParser.parse(text, sourceID: sid).channels
        #expect(a.map(\.id) == b.map(\.id))
        #expect(Set(a.map(\.id)).count == 2)
    }

    @Test func catchupAttributes() {
        let text = """
        #EXTM3U
        #EXTINF:-1 catchup="append" catchup-days="3" catchup-source="?utc=${start}&end=${end}",A
        http://h/a.m3u8
        #EXTINF:-1,B
        http://h/b.m3u8
        """
        let p = M3UParser.parse(text, sourceID: sid)
        #expect(p.channels[0].catchup?.mode == .append)
        #expect(p.channels[0].catchup?.days == 3)
        #expect(p.channels[1].catchup == nil)
    }

    @Test func handlesBOMAndHugePlaylistQuickly() {
        var s = "\u{FEFF}#EXTM3U\n"
        for i in 0..<60_000 { s += "#EXTINF:-1 tvg-id=\"c\(i)\" group-title=\"G\(i % 50)\",Channel \(i)\nhttp://h/live/u/p/\(i).m3u8\n" }
        let t0 = Date()
        let p = M3UParser.parse(s, sourceID: sid)
        let dt = Date().timeIntervalSince(t0)
        #expect(p.channels.count == 60_000)
        #expect(dt < 5, "parsing 60k channels took \(dt)s")
    }
}

// MARK: - XMLTV / EPG

@Suite struct EPGTests {
    @Test func parsesDatesWithTimezones() {
        let a = XMLTVDate.parse("20240131183000 +0100")!
        let b = XMLTVDate.parse("20240131173000 +0000")!
        let c = XMLTVDate.parse("20240131123000 -0500")!
        #expect(a == b)
        #expect(b == c)
        #expect(XMLTVDate.parse("20240131173000")! == b)
        #expect(XMLTVDate.parse("202401311730")! == b)
        #expect(b.timeIntervalSince1970 == 1_706_722_200)
        #expect(XMLTVDate.parse("garbage") == nil)
    }

    static let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tv>
      <channel id="BBC.One"><display-name>BBC One HD</display-name><icon src="http://i/bbc.png"/></channel>
      <channel id="other"><display-name>Other</display-name></channel>
      <programme start="20240101100000 +0000" stop="20240101110000 +0000" channel="BBC.One">
        <title lang="en">Morning &amp; News</title><sub-title>Ep 1</sub-title><desc><![CDATA[Top stories]]></desc><category>News</category>
      </programme>
      <programme start="20240101110000 +0000" stop="20240101120000 +0000" channel="BBC.One"><title>Cooking</title></programme>
      <programme start="20240101100000 +0000" stop="20240101110000 +0000" channel="other"><title>Nope</title></programme>
      <programme start="20230101100000 +0000" stop="20230101110000 +0000" channel="BBC.One"><title>Too old</title></programme>
    </tv>
    """

    static var window: ClosedRange<Date> {
        Date(timeIntervalSince1970: 1_704_067_200 - 86_400)...Date(timeIntervalSince1970: 1_704_067_200 + 3 * 86_400)
    }

    @Test func parsesFiltersAndIndexes() throws {
        let r = try XMLTVParser.parse(data: Data(Self.xml.utf8), wantedIDs: ["bbc.one"], wantedNameKeys: [], window: Self.window)
        #expect(r.programmes.count == 2)
        #expect(r.programmes[0].title == "Morning & News")
        #expect(r.programmes[0].desc == "Top stories")
        #expect(r.programmes[0].category == "News")
        #expect(r.channelIcons["bbc.one"]?.absoluteString == "http://i/bbc.png")

        let idx = r.index
        let ch = Channel(id: "1", sourceID: sid, name: "BBC One", group: "g", epgID: "BBC.One", streams: [])
        let t = XMLTVDate.parse("20240101103000 +0000")!
        let nn = idx.nowNext(for: ch, at: t)
        #expect(nn.now?.title == "Morning & News")
        #expect(nn.next?.title == "Cooking")
        // Guide running 60 min late: at 11:30 real time we should still be in the 10:00 show.
        let shifted = idx.now(for: ch, at: XMLTVDate.parse("20240101113000 +0000")!, offset: 3600)
        #expect(shifted?.title == "Morning & News")
        #expect(idx.now(for: ch, at: XMLTVDate.parse("20240101130000 +0000")!) == nil)
    }

    @Test func matchesByNameWhenIDsDiffer() throws {
        let r = try XMLTVParser.parse(
            data: Data(Self.xml.utf8), wantedIDs: ["something-else"],
            wantedNameKeys: [NameNormalizer.key("BBC One")], window: Self.window
        )
        #expect(r.programmes.count == 2)
        let ch = Channel(id: "1", sourceID: sid, name: "UK: BBC One FHD", group: "g", epgID: nil, streams: [])
        // No id match; "uk bbc one" != "bbc one", so this one must NOT match by accident...
        #expect(r.index.now(for: ch, at: XMLTVDate.parse("20240101103000 +0000")!) == nil)
        // ...but a plain name does.
        let plain = Channel(id: "2", sourceID: sid, name: "BBC One HD", group: "g", streams: [])
        #expect(r.index.now(for: plain, at: XMLTVDate.parse("20240101103000 +0000")!)?.title == "Morning & News")
    }

    #if os(macOS)
    @Test func gunzipRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("g.xml")
        var big = Self.xml
        for i in 0..<5000 { big += "<!-- padding \(i) lorem ipsum dolor sit amet -->\n" }
        try big.write(to: plain, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-k", plain.path]
        try p.run(); p.waitUntilExit()
        let gz = dir.appendingPathComponent("g.xml.gz")
        #expect(Gzip.isGzip(gz))
        #expect(!Gzip.isGzip(plain))
        let out = dir.appendingPathComponent("out.xml")
        try Gzip.decompress(gz, to: out)
        #expect(try Data(contentsOf: out) == Data(contentsOf: plain))
    }
    #endif

    @Test func programmeSearch() throws {
        let r = try XMLTVParser.parse(data: Data(Self.xml.utf8), wantedIDs: nil, wantedNameKeys: [], window: Self.window)
        let from = XMLTVDate.parse("20240101090000 +0000")!
        let hits = r.index.search("cook", from: from, to: from.addingTimeInterval(86_400))
        #expect(hits.map(\.title) == ["Cooking"])
    }
}

// MARK: - Xtream

@Suite struct XtreamTests {
    @Test func normalizesServerAndRecognisesProviderLinks() {
        #expect(XtreamClient.normalizeServer("host.tv:8080")?.absoluteString == "http://host.tv:8080")
        #expect(XtreamClient.normalizeServer("https://host.tv/player_api.php?x=1")?.absoluteString == "https://host.tv")
        #expect(XtreamClient.normalizeServer("   ") == nil)
        let c = XtreamClient.credentials(fromPlaylistURL: URL(string: "http://h.tv:80/get.php?username=bob&password=pw&type=m3u_plus&output=ts")!)
        #expect(c?.username == "bob")
        #expect(c?.password == "pw")
        #expect(c?.server.absoluteString == "http://h.tv:80")
        #expect(XtreamClient.credentials(fromPlaylistURL: URL(string: "http://h.tv/list.m3u")!) == nil)
    }

    @Test func buildsURLs() throws {
        let c = XtreamClient(server: URL(string: "http://h.tv:80")!, username: "u", password: "p")
        #expect(c.liveURL(streamID: "7").absoluteString == "http://h.tv:80/live/u/p/7.m3u8")
        #expect(c.movieURL(streamID: "8", ext: "mkv").absoluteString == "http://h.tv:80/movie/u/p/8.mkv")
        #expect(try c.api("get_live_streams").absoluteString == "http://h.tv:80/player_api.php?username=u&password=p&action=get_live_streams")
    }

    @Test func toleratesLooseJSONTypes() throws {
        let json = """
        {"user_info":{"username":"bob","auth":1,"status":"Active","exp_date":"1900000000","is_trial":"0",
        "max_connections":"2","active_cons":0,"allowed_output_formats":["m3u8","ts"]},
        "server_info":{"timezone":"Europe/London"}}
        """
        let d = try JSONDecoder().decode(AuthDTO.self, from: Data(json.utf8))
        #expect(d.user_info?.max_connections?.string == "2")
        #expect(d.user_info?.active_cons?.string == "0")
        let live = try JSONDecoder().decode([LiveDTO].self, from: Data(#"[{"num":1,"name":"A","stream_id":"5","tv_archive":1,"tv_archive_duration":"3","category_id":2}]"#.utf8))
        #expect(live[0].stream_id?.string == "5")
        #expect(live[0].category_id?.string == "2")
        let eps = try JSONDecoder().decode(SeriesInfoDTO.self, from: Data(#"{"episodes":[]}"#.utf8))
        #expect(eps.episodes?.isEmpty ?? true)
    }

    @Test func decodesBase64EPGTitles() {
        #expect(XtreamClient.b64("TmV3cw==") == "News")
        #expect(XtreamClient.b64("Plain title") == "Plain title")
    }
}

// MARK: - Library logic

@Suite struct LibraryTests {
    func ch(_ id: String, _ name: String, _ url: String, group: String = "g") -> Channel {
        Channel(id: id, sourceID: sid, name: name, group: group,
                streams: [StreamEndpoint(url: URL(string: url)!, quality: Quality.detect(in: name))])
    }

    @Test func mergesQualityVariantsAndKeepsCountriesApart() {
        let r = ChannelMerger.mergeDuplicates([
            ch("1", "ESPN", "http://a/1.m3u8"),
            ch("2", "ESPN FHD", "http://b/2.m3u8"),
            ch("3", "US| ESPN", "http://c/3.m3u8"),
            ch("4", "ESPN HD", "http://d/4.m3u8"),
        ])
        #expect(r.channels.count == 2)
        let espn = r.channels.first { $0.id == "1" }!
        #expect(espn.streams.count == 3)
        #expect(espn.streams[0].url.absoluteString == "http://b/2.m3u8") // FHD first
        #expect(r.aliases["2"] == "1")
        #expect(r.aliases["4"] == "1")
    }

    @Test func searchRanksAndFindsByPrefixTokens() {
        let chans = [ch("1", "ESPN Sports", "http://a/1"), ch("2", "Sports Center", "http://a/2"), ch("3", "CNN", "http://a/3")]
        let idx = SearchIndex(channels: chans, movies: [], series: [])
        #expect(idx.search("espn").channels.map(\.id) == ["1"])
        #expect(idx.search("esp spo").channels.map(\.id) == ["1"])
        #expect(idx.search("sports").channels.map(\.id) == ["2", "1"]) // starts-with beats later token
        #expect(idx.search("zzz").isEmpty)
        #expect(idx.search("  ").isEmpty)
        // Diacritics fold.
        let idx2 = SearchIndex(channels: [ch("9", "Télévision Française", "http://a/9")], movies: [], series: [])
        #expect(idx2.search("television").channels.count == 1)
    }

    @Test func rewritesTSToHLSOnlyForXtreamStyleLinks() {
        func c(_ s: String) -> [String] { StreamCandidates.make(for: StreamEndpoint(url: URL(string: s)!)).map(\.url.absoluteString) }
        #expect(c("http://h/live/u/p/12.ts") == ["http://h/live/u/p/12.m3u8", "http://h/live/u/p/12.ts"])
        #expect(c("http://h/u/p/12") == ["http://h/u/p/12.m3u8", "http://h/u/p/12"])
        #expect(c("http://h/stream.m3u8") == ["http://h/stream.m3u8"])
        #expect(c("http://h/a.ts") == ["http://h/a.ts"])
    }

    @Test func xtreamCatchupURL() {
        let live = Channel(id: "1", sourceID: sid, name: "A", group: "g",
                           streams: [StreamEndpoint(url: URL(string: "http://h:80/live/u/p/77.m3u8")!)],
                           catchup: Catchup(mode: .xtream, days: 3))
        let now = XMLTVDate.parse("20240102120000 +0000")!
        let prog = Programme(channel: "a", start: XMLTVDate.parse("20240102100000 +0000")!,
                             stop: XMLTVDate.parse("20240102110000 +0000")!, title: "T")
        #expect(CatchupBuilder.url(for: live, programme: prog, now: now)?.absoluteString
                == "http://h:80/timeshift/u/p/60/2024-01-02:10-00/77.m3u8")
        // Outside the archive window.
        let old = Programme(channel: "a", start: now.addingTimeInterval(-10 * 86_400), stop: now.addingTimeInterval(-10 * 86_400 + 3600), title: "Old")
        #expect(CatchupBuilder.url(for: live, programme: old, now: now) == nil)
        // Future programmes aren't catch-up.
        let fut = Programme(channel: "a", start: now.addingTimeInterval(3600), stop: now.addingTimeInterval(7200), title: "Future")
        #expect(CatchupBuilder.url(for: live, programme: fut, now: now) == nil)
    }

    @Test func templateCatchup() {
        let c = Channel(id: "1", sourceID: sid, name: "A", group: "g",
                        streams: [StreamEndpoint(url: URL(string: "http://h/a.m3u8")!)],
                        catchup: Catchup(mode: .append, days: 1, template: "?utc=${start}&dur=${duration}"))
        let now = Date()
        let p = Programme(channel: "a", start: now.addingTimeInterval(-7200), stop: now.addingTimeInterval(-3600), title: "T")
        let u = CatchupBuilder.url(for: c, programme: p, now: now)!.absoluteString
        #expect(u.hasPrefix("http://h/a.m3u8?utc=\(Int(p.start.timeIntervalSince1970))&dur=3600"))
    }

    @Test func groupLabels() {
        #expect(GroupLabel.parse("US| NEWS").region == "US")
        #expect(GroupLabel.parse("US| NEWS").title == "News")
        #expect(GroupLabel.parse("UK - Sports").title == "Sports")
        #expect(GroupLabel.parse("Documentaries").region == nil)
    }
}

// MARK: - User data

@Suite struct UserDataTests {
    @Test func favoritesRecentsAndAliases() {
        var u = UserData()
        u.toggleFavorite("a"); u.toggleFavorite("b"); u.toggleFavorite("a")
        #expect(u.favorites == ["b"])
        for i in 0..<40 { u.pushRecent("c\(i)") }
        #expect(u.recents.count == 30)
        #expect(u.recents.first == "c39")
        u.favorites = ["x", "y", "z"]
        u.applyAliases(["y": "x"])
        #expect(u.favorites == ["x", "z"])
    }

    @Test func pinHashingAndBackwardsCompatibleDecoding() throws {
        var u = UserData()
        #expect(u.verifyPIN("anything")) // no PIN set
        u.setPIN("1234")
        #expect(u.hasPIN)
        #expect(u.verifyPIN("1234"))
        #expect(!u.verifyPIN("0000"))
        #expect(u.pinHash != "1234")
        #expect(u.pinHash?.count == 64) // salted SHA-256 hex, never the PIN itself
        // An old file missing most keys must still load with defaults.
        let old = try JSONDecoder().decode(UserData.self, from: Data(#"{"favorites":["a"]}"#.utf8))
        #expect(old.favorites == ["a"])
        #expect(old.settings.autoFailover)
        // Round trip.
        let again = try JSONDecoder().decode(UserData.self, from: JSONEncoder().encode(u))
        #expect(again == u)
    }

    @Test func parentalHeuristics() {
        #expect(ParentalHeuristics.looksAdult(group: "XXX Adults 18+"))
        #expect(!ParentalHeuristics.looksAdult(group: "Documentaries"))
    }
}

// MARK: - Demo + loader

@Suite struct DemoTests {
    @Test func demoSnapshotAndGuide() async throws {
        let snap = DemoContent.snapshot(sourceID: sid)
        #expect(snap.channels.count == 3)
        let g = DemoContent.guide()
        for c in snap.channels { #expect(g.now(for: c) != nil, "no programme now for \(c.name)") }
    }

    @Test func loadsLocalM3UFile() async throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).m3u")
        try DemoContent.m3u.write(to: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f) }
        let snap = try await PlaylistLoader().load(Source(id: sid, name: "t", kind: .m3u(f)))
        #expect(snap.channels.count == 3)
        // Not a playlist -> friendly error
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("b-\(UUID().uuidString).txt")
        try "hello world, this is not a playlist at all".write(to: bad, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bad) }
        await #expect(throws: LuminaError.notAPlaylist) {
            _ = try await PlaylistLoader().load(Source(id: sid, name: "b", kind: .m3u(bad)))
        }
    }

    @Test func sourceCodableIsForwardCompatible() throws {
        let s = Source(name: "x", kind: .xtream(server: URL(string: "http://h")!, username: "u", password: "p"))
        let back = try JSONDecoder().decode(Source.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}
