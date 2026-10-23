package app.lumina.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.io.File
import java.io.IOException

/** Turns a [Source] into a [SourceSnapshot] and loads guide data. */
class PlaylistLoader(private val http: OkHttpClient = Net.client, private val tempDir: File = File(System.getProperty("java.io.tmpdir"))) {

    suspend fun load(source: Source): SourceSnapshot = when (val k = source.kind) {
        SourceKind.Demo -> DemoContent.snapshot(source.id)
        is SourceKind.Xtream -> {
            val server = XtreamClient.normalizeServer(k.server) ?: throw LuminaException(LuminaException.Kind.INVALID_URL)
            val client = XtreamClient(server, k.username, k.password, http)
            val account = client.authenticate()
            val snap = client.loadSnapshot(source.id, account, source.userAgent)
            snap.copy(epgUrls = snap.epgUrls + source.extraEpg)
        }
        is SourceKind.M3u -> {
            val file = fetchFile(k.url, source.userAgent)
            try {
                val head = file.inputStream().use { s -> String(s.readNBytes(2048), Charsets.UTF_8) }
                if (!head.contains("#EXTM3U") && !head.contains("#EXTINF")) throw LuminaException(LuminaException.Kind.NOT_A_PLAYLIST)
                val p = withContext(Dispatchers.Default) { file.inputStream().buffered().use { M3UParser.parse(it, source.id, source.userAgent) } }
                if (p.channels.isEmpty() && p.movies.isEmpty() && p.episodes.isEmpty()) throw LuminaException(LuminaException.Kind.EMPTY_PLAYLIST)
                SourceSnapshot(source.id, p.channels, p.movies, p.series, p.episodes, p.epgUrls + source.extraEpg)
            } finally {
                if (!k.url.startsWith("file:") && !k.url.startsWith("/")) file.delete()
            }
        }
    }

    /** Downloads to a temp file (or returns the local file) so big playlists are never held twice in memory. */
    suspend fun fetchFile(url: String, userAgent: String? = null, timeoutSec: Long = 120): File = withContext(Dispatchers.IO) {
        if (url.startsWith("file:")) return@withContext File(java.net.URI(url))
        if (url.startsWith("/")) return@withContext File(url)
        if (url.toHttpUrlOrNull() == null) throw LuminaException(LuminaException.Kind.INVALID_URL)
        val client = http.newBuilder().callTimeout(timeoutSec, java.util.concurrent.TimeUnit.SECONDS).build()
        val req = Request.Builder().url(url).header("User-Agent", userAgent ?: "Lumina/1.0").build()
        val out = File.createTempFile("lumina-", ".tmp", tempDir)
        try {
            client.newCall(req).execute().use { r ->
                if (!r.isSuccessful) throw LuminaException(LuminaException.Kind.HTTP, r.code.toString())
                r.body.byteStream().use { input -> out.outputStream().use { input.copyTo(it) } }
            }
            out
        } catch (e: IOException) {
            out.delete()
            throw LuminaException(LuminaException.Kind.NETWORK, e.message ?: "unreachable")
        } catch (e: LuminaException) {
            out.delete(); throw e
        }
    }

    /** Download + (auto-gunzip) + parse one XMLTV guide. */
    suspend fun loadGuide(
        url: String, userAgent: String? = null, wantedIds: Set<String>?, wantedNameKeys: Set<String>, window: LongRange,
    ): XmlTvResult {
        val file = fetchFile(url, userAgent, 180)
        try {
            return withContext(Dispatchers.Default) { XmlTvParser.parse(file, wantedIds, wantedNameKeys, window) }
        } finally {
            if (!url.startsWith("file:") && !url.startsWith("/")) file.delete()
        }
    }
}

/** Public Apple / Mux test streams, so the app is usable before adding a provider. */
object DemoContent {
    const val M3U = """#EXTM3U
#EXTINF:-1 tvg-id="demo.bipbop" tvg-name="Lumina Test Card" group-title="Demo",Lumina Test Card HD
https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8
#EXTINF:-1 tvg-id="demo.bipbop16" tvg-name="Lumina Test Card 2" group-title="Demo",Lumina Test Card 2
https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8
#EXTINF:-1 tvg-id="demo.bbb" tvg-name="Big Buck Bunny" group-title="Demo Movies",Big Buck Bunny FHD
https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8
"""

    fun snapshot(sourceId: String): SourceSnapshot {
        val p = M3UParser.parse(M3U, sourceId)
        return SourceSnapshot(sourceId, channels = p.channels)
    }

    /** Synthetic guide so the now/next UI can be explored with the demo source. */
    fun guide(now: Long = System.currentTimeMillis()): EpgIndex {
        val titles = mapOf(
            "demo.bipbop" to listOf("Test Pattern Hour", "Colour Bars", "Signal Check", "Night Loop"),
            "demo.bipbop16" to listOf("Wide Screen Lab", "Aspect Ratio Show", "Calibration Live"),
            "demo.bbb" to listOf("Big Buck Bunny", "Behind the Rabbit", "Animation Shorts"),
        )
        val slot = 1_800_000L
        val base = (now / slot) * slot - 6 * 3_600_000L
        val out = ArrayList<Programme>()
        for ((id, names) in titles) for (n in 0 until 96) {
            val start = base + n * slot
            out += Programme(id, start, start + slot, names[n % names.size], desc = "Sample programme for the demo source.")
        }
        return EpgIndex.of(out)
    }
}
