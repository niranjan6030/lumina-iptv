package app.lumina.core

import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.GZIPOutputStream

private const val SID = "11111111-2222-3333-4444-555555555555"

private fun gzip(s: String): ByteArray {
    val bos = ByteArrayOutputStream()
    GZIPOutputStream(bos).use { it.write(s.toByteArray()) }
    return bos.toByteArray()
}

class M3UTests {
    @Test fun parsesAttributesQuotesAndCommasInNames() {
        val text = "#EXTM3U url-tvg=\"http://epg.example/a.xml.gz,http://epg.example/b.xml\"\r\n" +
            "#EXTINF:-1 tvg-id=\"bbc.one\" tvg-logo=\"http://l/x.png\" group-title=\"UK, News\" tvg-chno=\"101\",BBC One, London HD\r\n" +
            "http://h/live/u/p/1.m3u8\r\n" +
            "#EXTINF:-1 group-title=\"Sports\",ESPN\n#EXTVLCOPT:http-user-agent=Foo/1.0\n#EXTVLCOPT:http-referrer=http://ref/\nhttp://h/2.m3u8\n"
        val p = M3UParser.parse(text, SID)
        assertEquals(2, p.epgUrls.size)
        assertEquals(2, p.channels.size)
        val bbc = p.channels[0]
        assertEquals("BBC One, London HD", bbc.name)
        assertEquals("UK, News", bbc.group)
        assertEquals(101, bbc.number)
        assertEquals("bbc.one", bbc.epgId)
        assertEquals("http://l/x.png", bbc.logo)
        assertEquals(Quality.HD, bbc.streams[0].quality)
        assertEquals("Foo/1.0", p.channels[1].streams[0].userAgent)
        assertEquals("http://ref/", p.channels[1].streams[0].referer)
    }

    @Test fun kodiPipeHeadersAndSkipsUnsupportedSchemes() {
        val p = M3UParser.parse("#EXTM3U\n#EXTINF:-1,A\nhttp://h/a.m3u8|User-Agent=Bar&Referer=http://r/\n#EXTINF:-1,B\nrtmp://h/b\n", SID)
        assertEquals(1, p.channels.size)
        assertEquals(1, p.skipped)
        assertEquals("http://h/a.m3u8", p.channels[0].streams[0].url)
        assertEquals("Bar", p.channels[0].streams[0].userAgent)
        assertEquals("http://r/", p.channels[0].streams[0].referer)
    }

    @Test fun classifiesMoviesAndGroupsEpisodesIntoSeries() {
        val text = """#EXTM3U
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
        val p = M3UParser.parse(text, SID)
        assertEquals(1, p.movies.size)
        assertEquals(1, p.channels.size)
        assertEquals(2, p.series.size)
        assertEquals(3, p.episodes.size)
        val great = p.series.first { it.title == "Great Show" }
        val eps = p.episodes.filter { it.seriesId == great.id }.sortedWith(compareBy({ it.season }, { it.number }))
        assertEquals(listOf(1, 2), eps.map { it.season })
        assertEquals(listOf(2, 1), eps.map { it.number })
        assertTrue(p.series.any { it.title == "Other Show" })
    }

    @Test fun idsAreStableAndUniqueForDuplicates() {
        val text = "#EXTM3U\n#EXTINF:-1 tvg-id=\"x\" group-title=\"G\",Same\nhttp://h/1.m3u8\n#EXTINF:-1 tvg-id=\"x\" group-title=\"G\",Same\nhttp://h/2.m3u8\n"
        val a = M3UParser.parse(text, SID).channels
        val b = M3UParser.parse(text, SID).channels
        assertEquals(a.map { it.id }, b.map { it.id })
        assertEquals(2, a.map { it.id }.toSet().size)
    }

    @Test fun catchupAttributes() {
        val p = M3UParser.parse(
            "#EXTM3U\n#EXTINF:-1 catchup=\"append\" catchup-days=\"3\" catchup-source=\"?utc=\${start}&end=\${end}\",A\nhttp://h/a.m3u8\n#EXTINF:-1,B\nhttp://h/b.m3u8\n", SID,
        )
        assertEquals(CatchupMode.APPEND, p.channels[0].catchup?.mode)
        assertEquals(3, p.channels[0].catchup?.days)
        assertNull(p.channels[1].catchup)
    }

    @Test fun handlesBomAndHugePlaylistQuickly() {
        val sb = StringBuilder("﻿#EXTM3U\n")
        for (i in 0 until 60_000) sb.append("#EXTINF:-1 tvg-id=\"c$i\" group-title=\"G${i % 50}\",Channel $i\nhttp://h/live/u/p/$i.m3u8\n")
        val t0 = System.nanoTime()
        val p = M3UParser.parse(sb.toString(), SID)
        val sec = (System.nanoTime() - t0) / 1e9
        assertEquals(60_000, p.channels.size)
        assertTrue(sec < 5, "parsing 60k channels took ${sec}s")
    }
}

class EpgTests {
    private val xml = """<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="BBC.One"><display-name>BBC One HD</display-name><icon src="http://i/bbc.png"/></channel>
  <channel id="other"><display-name>Other</display-name></channel>
  <programme start="20240101100000 +0000" stop="20240101110000 +0000" channel="BBC.One">
    <title lang="en">Morning &amp; News</title><sub-title>Ep 1</sub-title><desc><![CDATA[Top stories]]></desc><category>News</category>
  </programme>
  <programme start="20240101110000 +0000" stop="20240101120000 +0000" channel="BBC.One"><title>Cooking</title></programme>
  <programme start="20240101100000 +0000" stop="20240101110000 +0000" channel="other"><title>Nope</title></programme>
  <programme start="20230101100000 +0000" stop="20230101110000 +0000" channel="BBC.One"><title>Too old</title></programme>
</tv>"""
    private val day = 86_400_000L
    private val base = 1_704_067_200_000L
    private val window = (base - day)..(base + 3 * day)
    private fun t(s: String) = XmlTvDate.parse(s)!!
    private fun chan(id: String, name: String, epg: String? = null) = Channel(id, SID, name, group = "g", epgId = epg, streams = emptyList())

    @Test fun parsesDatesWithTimezones() {
        val a = t("20240131183000 +0100"); val b = t("20240131173000 +0000"); val c = t("20240131123000 -0500")
        assertEquals(a, b); assertEquals(b, c)
        assertEquals(b, t("20240131173000")); assertEquals(b, t("202401311730"))
        assertEquals(1_706_722_200_000L, b)
        assertNull(XmlTvDate.parse("garbage"))
    }

    @Test fun parsesFiltersAndIndexes() {
        val r = XmlTvParser.parse(xml, setOf("bbc.one"), emptySet(), window)
        assertEquals(2, r.programmes.size)
        assertEquals("Morning & News", r.programmes[0].title)
        assertEquals("Top stories", r.programmes[0].desc)
        assertEquals("News", r.programmes[0].category)
        assertEquals("http://i/bbc.png", r.channelIcons["bbc.one"])
        val idx = r.index
        val ch = chan("1", "BBC One", "BBC.One")
        val nn = idx.nowNext(ch, t("20240101103000 +0000"))
        assertEquals("Morning & News", nn.now?.title)
        assertEquals("Cooking", nn.next?.title)
        // Guide running 60 min late: at 11:30 real time we should still be in the 10:00 show.
        assertEquals("Morning & News", idx.nowNext(ch, t("20240101113000 +0000"), 3_600_000).now?.title)
        assertNull(idx.nowNext(ch, t("20240101130000 +0000")).now)
    }

    @Test fun matchesByNameWhenIdsDiffer() {
        val r = XmlTvParser.parse(xml, setOf("something-else"), setOf(NameNormalizer.key("BBC One")), window)
        assertEquals(2, r.programmes.size)
        val prefixed = chan("1", "UK: BBC One FHD")
        assertNull(r.index.nowNext(prefixed, t("20240101103000 +0000")).now) // "uk bbc one" must not match by accident
        val plain = chan("2", "BBC One HD")
        assertEquals("Morning & News", r.index.nowNext(plain, t("20240101103000 +0000")).now?.title)
    }

    @Test fun gunzipAndProgrammeSearch() {
        val f = File.createTempFile("guide", ".xml.gz")
        try {
            f.writeBytes(gzip(xml))
            val r = XmlTvParser.parse(f, null, emptySet(), window)
            assertEquals(3, r.programmes.size) // unfiltered: two BBC + one "other"; the 2023 programme is outside the window
            val from = t("20240101090000 +0000")
            assertEquals(listOf("Cooking"), r.index.search("cook", from, from + day).map { it.title })
        } finally { f.delete() }
    }
}

class XtreamTests {
    @Test fun normalizesServerAndRecognisesProviderLinks() {
        assertEquals("http://host.tv:8080", XtreamClient.normalizeServer("host.tv:8080"))
        assertEquals("https://host.tv", XtreamClient.normalizeServer("https://host.tv/player_api.php?x=1"))
        assertNull(XtreamClient.normalizeServer("   "))
        val c = XtreamClient.credentials("http://h.tv:80/get.php?username=bob&password=pw&type=m3u_plus&output=ts")
        assertEquals("bob", c?.second); assertEquals("pw", c?.third); assertEquals("http://h.tv", c?.first) // default port :80 is implied
        assertNull(XtreamClient.credentials("http://h.tv/list.m3u"))
    }

    @Test fun buildsUrls() {
        val c = XtreamClient("http://h.tv:80", "u", "p")
        assertEquals("http://h.tv:80/live/u/p/7.m3u8", c.liveUrl("7"))
        assertEquals("http://h.tv:80/movie/u/p/8.mkv", c.movieUrl("8", "mkv"))
        assertEquals("http://h.tv/player_api.php?username=u&password=p&action=get_live_streams", c.api("get_live_streams").toString())
    }

    @Test fun decodesBase64EpgTitles() {
        assertEquals("News", XtreamClient.b64("TmV3cw=="))
        assertEquals("Plain title", XtreamClient.b64("Plain title"))
    }

    @Test fun fullFlowAgainstMockPanelWithLooseJsonTypes() = runBlocking {
        MockWebServer().use { server ->
            server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val action = request.requestUrl?.queryParameter("action")
                    val body = when (action) {
                        null -> """{"user_info":{"username":"bob","auth":1,"status":"Active","exp_date":"1900000000","is_trial":"0","max_connections":"2","active_cons":0,"allowed_output_formats":["m3u8","ts"]},"server_info":{"timezone":"Europe/London"}}"""
                        "get_live_categories" -> """[{"category_id":2,"category_name":"News"}]"""
                        "get_live_streams" -> """[{"num":1,"name":"BBC One HD","stream_id":"5","stream_icon":"http://l/x.png","epg_channel_id":"bbc.one","category_id":2,"tv_archive":1,"tv_archive_duration":"3"},{"num":2,"name":"No Id","category_id":2}]"""
                        "get_vod_streams" -> """[{"name":"Film","stream_id":9,"container_extension":"mkv","rating":"7.5","category_id":"1"}]"""
                        "get_vod_categories" -> """[{"category_id":"1","category_name":"Action"}]"""
                        "get_series_categories" -> "false"
                        "get_series" -> "[]"
                        "get_series_info" -> """{"episodes":{"1":[{"id":"101","episode_num":2,"title":"Two","container_extension":"mp4"},{"id":"100","episode_num":1,"title":"One"}]}}"""
                        else -> "[]"
                    }
                    return MockResponse().setBody(body).setHeader("Content-Type", "application/json")
                }
            }
            server.start()
            val c = XtreamClient(server.url("/").toString().trimEnd('/'), "bob", "pw")
            val acc = c.authenticate()
            assertEquals(2, acc.maxConnections); assertEquals(0, acc.activeConnections)
            assertEquals(listOf("m3u8", "ts"), acc.allowedFormats)
            val snap = c.loadSnapshot(SID, acc, null)
            assertEquals(1, snap.channels.size) // the entry without stream_id is dropped
            assertEquals("News", snap.channels[0].group)
            assertEquals(3, snap.channels[0].catchup?.days)
            assertEquals(1, snap.movies.size)
            assertTrue(snap.movies[0].stream.url.endsWith("/movie/bob/pw/9.mkv"))
            assertEquals(7.5, snap.movies[0].rating)
            assertTrue(snap.series.isEmpty())
            val eps = c.episodes("77", "local", null)
            assertEquals(listOf(1, 2), eps.map { it.number })
        }
    }

    @Test fun authFailureAndInactiveAccount() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("""{"user_info":{"auth":0}}"""))
            server.enqueue(MockResponse().setBody("""{"user_info":{"auth":1,"status":"Expired"}}"""))
            server.start()
            val c = XtreamClient(server.url("/").toString().trimEnd('/'), "u", "p")
            assertEquals(LuminaException.Kind.AUTH_FAILED, assertThrows<LuminaException> { runBlocking { c.authenticate() } }.kind)
            assertEquals(LuminaException.Kind.ACCOUNT_INACTIVE, assertThrows<LuminaException> { runBlocking { c.authenticate() } }.kind)
        }
    }
}

class LibraryTests {
    private fun ch(id: String, name: String, url: String) =
        Channel(id, SID, name, group = "g", streams = listOf(StreamEndpoint(url, quality = Quality.detect(name))))

    @Test fun mergesQualityVariantsAndKeepsCountriesApart() {
        val r = ChannelMerger.mergeDuplicates(listOf(
            ch("1", "ESPN", "http://a/1.m3u8"), ch("2", "ESPN FHD", "http://b/2.m3u8"),
            ch("3", "US| ESPN", "http://c/3.m3u8"), ch("4", "ESPN HD", "http://d/4.m3u8"),
        ))
        assertEquals(2, r.channels.size)
        val espn = r.channels.first { it.id == "1" }
        assertEquals(3, espn.streams.size)
        assertEquals("http://b/2.m3u8", espn.streams[0].url) // FHD first
        assertEquals("1", r.aliases["2"]); assertEquals("1", r.aliases["4"])
    }

    @Test fun searchRanksAndFindsByPrefixTokens() {
        val chans = listOf(ch("1", "ESPN Sports", "http://a/1"), ch("2", "Sports Center", "http://a/2"), ch("3", "CNN", "http://a/3"))
        val idx = SearchIndex(chans, emptyList(), emptyList())
        assertEquals(listOf("1"), idx.search("espn").channels.map { it.id })
        assertEquals(listOf("1"), idx.search("esp spo").channels.map { it.id })
        assertEquals(listOf("2", "1"), idx.search("sports").channels.map { it.id })
        assertTrue(idx.search("zzz").isEmpty); assertTrue(idx.search("  ").isEmpty)
        assertEquals(1, SearchIndex(listOf(ch("9", "Télévision Française", "http://a/9")), emptyList(), emptyList()).search("television").channels.size)
    }

    @Test fun rewritesTsToHlsOnlyForXtreamStyleLinks() {
        fun c(s: String) = StreamCandidates.make(StreamEndpoint(s)).map { it.url }
        assertEquals(listOf("http://h/live/u/p/12.m3u8", "http://h/live/u/p/12.ts"), c("http://h/live/u/p/12.ts"))
        assertEquals(listOf("http://h/u/p/12.m3u8", "http://h/u/p/12"), c("http://h/u/p/12"))
        assertEquals(listOf("http://h/stream.m3u8"), c("http://h/stream.m3u8"))
        assertEquals(listOf("http://h/a.ts"), c("http://h/a.ts"))
    }

    @Test fun catchupUrls() {
        val now = XmlTvDate.parse("20240102120000 +0000")!!
        val live = Channel("1", SID, "A", group = "g", streams = listOf(StreamEndpoint("http://h:80/live/u/p/77.m3u8")), catchup = Catchup(CatchupMode.XTREAM, 3))
        val prog = Programme("a", XmlTvDate.parse("20240102100000 +0000")!!, XmlTvDate.parse("20240102110000 +0000")!!, "T")
        assertEquals("http://h/timeshift/u/p/60/2024-01-02:10-00/77.m3u8", CatchupBuilder.url(live, prog, now)) // :80 is the implied default
        val old = Programme("a", now - 10 * 86_400_000L, now - 10 * 86_400_000L + 3_600_000, "Old")
        assertNull(CatchupBuilder.url(live, old, now))
        val fut = Programme("a", now + 3_600_000, now + 7_200_000, "Future")
        assertNull(CatchupBuilder.url(live, fut, now))
        val app = Channel("2", SID, "A", group = "g", streams = listOf(StreamEndpoint("http://h/a.m3u8")), catchup = Catchup(CatchupMode.APPEND, 1, "?utc=\${start}&dur=\${duration}"))
        val p2 = Programme("a", now - 7_200_000, now - 3_600_000, "T")
        assertEquals("http://h/a.m3u8?utc=${p2.start / 1000}&dur=3600", CatchupBuilder.url(app, p2, now))
    }

    @Test fun groupLabels() {
        assertEquals("US", GroupLabel.parse("US| NEWS").region)
        assertEquals("News", GroupLabel.parse("US| NEWS").title)
        assertEquals("Sports", GroupLabel.parse("UK - Sports").title)
        assertNull(GroupLabel.parse("Documentaries").region)
    }
}

class UserDataTests {
    @Test fun favoritesRecentsAndAliases() {
        var u = UserData().toggleFavorite("a").toggleFavorite("b").toggleFavorite("a")
        assertEquals(listOf("b"), u.favorites)
        for (i in 0 until 40) u = u.pushRecent("c$i")
        assertEquals(30, u.recents.size); assertEquals("c39", u.recents.first())
        u = u.copy(favorites = listOf("x", "y", "z")).applyAliases(mapOf("y" to "x"))
        assertEquals(listOf("x", "z"), u.favorites)
    }

    @Test fun pinHashingAndBackwardsCompatibleDecoding() {
        var u = UserData()
        assertTrue(u.verifyPin("anything"))
        u = u.withPin("1234")
        assertTrue(u.hasPin); assertTrue(u.verifyPin("1234")); assertFalse(u.verifyPin("0000"))
        assertNotEquals("1234", u.pinHash)
        assertEquals(64, u.pinHash?.length)
        val old = JsonFile.json.decodeFromString<UserData>("""{"favorites":["a"],"somethingNew":1}""")
        assertEquals(listOf("a"), old.favorites); assertTrue(old.settings.autoFailover)
        assertEquals(u, JsonFile.json.decodeFromString<UserData>(JsonFile.json.encodeToString(UserData.serializer(), u)))
    }

    @Test fun parentalHeuristicsAndSourceRoundTrip() {
        assertTrue(ParentalHeuristics.looksAdult("XXX Adults 18+")); assertFalse(ParentalHeuristics.looksAdult("Documentaries"))
        val s = Source(name = "x", kind = SourceKind.Xtream("http://h", "u", "p"))
        assertEquals(s, JsonFile.json.decodeFromString<Source>(JsonFile.json.encodeToString(Source.serializer(), s)))
        val d = Source(name = "d", kind = SourceKind.Demo)
        assertEquals(d, JsonFile.json.decodeFromString<Source>(JsonFile.json.encodeToString(Source.serializer(), d)))
    }
}

class NetworkTests {
    @Test fun playlistAndGzippedGuideOverHttp() = runBlocking {
        val now = System.currentTimeMillis()
        val fmt = java.text.SimpleDateFormat("yyyyMMddHHmmss", java.util.Locale.US).apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }
        fun t(off: Long) = fmt.format(java.util.Date(now + off)) + " +0000"
        val guide = """<?xml version="1.0"?><tv><channel id="one.tv"><display-name>One</display-name></channel>
<programme start="${t(-1_800_000)}" stop="${t(1_800_000)}" channel="one.tv"><title>Right Now</title></programme>
<programme start="${t(1_800_000)}" stop="${t(5_400_000)}" channel="one.tv"><title>Coming Up</title></programme></tv>"""
        MockWebServer().use { server ->
            server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = when (request.path) {
                    "/list.m3u" -> MockResponse().setBody("#EXTM3U\n#EXTINF:-1 tvg-id=\"one.tv\" group-title=\"News\",One HD\nhttp://127.0.0.1/one.m3u8\n")
                    "/guide.xml.gz" -> MockResponse().setBody(Buffer().write(gzip(guide)))
                    "/notplaylist" -> MockResponse().setBody("hello world, this is not a playlist at all")
                    else -> MockResponse().setResponseCode(404)
                }
            }
            server.start()
            val loader = PlaylistLoader()
            val base = server.url("/").toString().trimEnd('/')
            val snap = loader.load(Source(id = SID, name = "t", kind = SourceKind.M3u("$base/list.m3u")))
            assertEquals(1, snap.channels.size); assertEquals("one.tv", snap.channels[0].epgId)
            val r = loader.loadGuide("$base/guide.xml.gz", null, setOf("one.tv"), emptySet(), (now - 86_400_000)..(now + 86_400_000))
            val nn = r.index.nowNext(snap.channels[0], now)
            assertEquals("Right Now", nn.now?.title); assertEquals("Coming Up", nn.next?.title)
            assertEquals("404", assertThrows<LuminaException> { runBlocking { loader.load(Source(name = "x", kind = SourceKind.M3u("$base/missing.m3u"))) } }.detail)
            assertEquals(LuminaException.Kind.NOT_A_PLAYLIST, assertThrows<LuminaException> { runBlocking { loader.load(Source(name = "x", kind = SourceKind.M3u("$base/notplaylist"))) } }.kind)
        }
    }

    @Test fun healthProbeAndScan() = runBlocking {
        MockWebServer().use { server ->
            server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = when (request.path) {
                    "/ok.m3u8" -> MockResponse().setBody("#EXTM3U\n#EXT-X-VERSION:3\n")
                    "/bad.m3u8" -> MockResponse().setBody("<html>nope</html>")
                    else -> MockResponse().setResponseCode(404)
                }
            }
            server.start()
            val base = server.url("/").toString().trimEnd('/')
            fun ch(id: String, path: String) = Channel(id, SID, id, group = "g", streams = listOf(StreamEndpoint("$base/$path")))
            val chans = listOf(ch("ok", "ok.m3u8"), ch("bad", "bad.m3u8"), ch("missing", "nope.m3u8"),
                Channel("refused", SID, "r", group = "g", streams = listOf(StreamEndpoint("http://127.0.0.1:1/x.m3u8"))))
            val results = StreamHealth.scan(chans, 2).toList().associate { it.channelId to it.alive }
            assertEquals(mapOf("ok" to true, "bad" to false, "missing" to false, "refused" to false), results)
        }
    }

    @Test fun demoSnapshotAndGuide() {
        val snap = DemoContent.snapshot(SID)
        assertEquals(3, snap.channels.size)
        val g = DemoContent.guide()
        for (c in snap.channels) assertNotNull(g.nowNext(c).now, "no programme now for ${c.name}")
    }
}
