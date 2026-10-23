package app.lumina.core

import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

// MARK: Duplicate merging (auto-failover backbone)

class MergeResult(val channels: List<Channel>, /** removed id -> surviving id */ val aliases: Map<String, String>)

object ChannelMerger {
    /**
     * Collapses "ESPN", "ESPN HD", "ESPN FHD" (even across providers) into one channel with several
     * streams, best quality first. The player falls through them automatically when one fails.
     */
    fun mergeDuplicates(channels: List<Channel>): MergeResult {
        val order = ArrayList<String>()
        val merged = HashMap<String, Channel>()
        val aliases = HashMap<String, String>()
        val unkeyed = ArrayList<Channel>()
        for (ch in channels) {
            val key = NameNormalizer.key(ch.name)
            if (key.isEmpty()) { unkeyed += ch; continue }
            val ex = merged[key]
            if (ex != null) {
                val extra = ch.streams.filter { s -> ex.streams.none { it.url == s.url } }
                merged[key] = ex.copy(
                    streams = ex.streams + extra, logo = ex.logo ?: ch.logo, epgId = ex.epgId ?: ch.epgId,
                    catchup = ex.catchup ?: ch.catchup, number = ex.number ?: ch.number,
                )
                aliases[ch.id] = ex.id
            } else {
                merged[key] = ch
                order += key
            }
        }
        val out = order.map { k ->
            val c = merged.getValue(k)
            // Stable sort: highest quality first, provider order otherwise preserved.
            c.copy(streams = c.streams.sortedByDescending { it.quality })
        } + unkeyed
        return MergeResult(out, aliases)
    }
}

// MARK: Search

data class SearchResults(
    val channels: List<Channel> = emptyList(),
    val movies: List<VodItem> = emptyList(),
    val series: List<Series> = emptyList(),
) {
    val isEmpty: Boolean get() = channels.isEmpty() && movies.isEmpty() && series.isEmpty()
}

/** Prebuilt index so every keystroke is a cheap linear scan over normalised tokens. */
class SearchIndex(
    private val channels: List<Channel>, private val movies: List<VodItem>, private val series: List<Series>,
) {
    private class Entry(val key: String, val tokens: List<String>)

    private fun entry(s: String): Entry { val t = NameNormalizer.tokens(s); return Entry(t.joinToString(" "), t) }
    private val channelEntries = channels.map { entry(it.name) }
    private val movieEntries = movies.map { entry(it.title) }
    private val seriesEntries = series.map { entry(it.title) }

    fun search(query: String, limit: Int = 30): SearchResults {
        val q = NameNormalizer.tokens(query)
        if (q.isEmpty()) return SearchResults()
        val joined = q.joinToString(" ")
        fun <T> top(items: List<T>, entries: List<Entry>): List<T> {
            val scored = ArrayList<Pair<Int, Int>>()
            for ((i, e) in entries.withIndex()) score(q, joined, e)?.let { scored += it to i }
            scored.sortWith(compareByDescending<Pair<Int, Int>> { it.first }.thenBy { it.second })
            return scored.take(limit).map { items[it.second] }
        }
        return SearchResults(top(channels, channelEntries), top(movies, movieEntries), top(series, seriesEntries))
    }

    private fun score(q: List<String>, joined: String, e: Entry): Int? {
        if (e.key == joined) return 10_000 - e.key.length
        if (e.key.startsWith(joined)) return 8_000 - e.key.length
        var total = 0
        for (t in q) {
            val pos = e.tokens.indexOfFirst { it.startsWith(t) }
            if (pos >= 0) total += 400 - pos * 20 else return if (e.key.contains(joined)) 1_000 - e.key.length else null
        }
        return total - e.key.length
    }
}

// MARK: Playable URL candidates

object StreamCandidates {
    /**
     * Xtream-style links (`.../user/pass/123` or `.../123.ts`) almost always answer as HLS too, which starts faster
     * and handles bitrate changes better than raw TS; try `.m3u8` first and keep the original as the fallback.
     * (ExoPlayer *can* play raw TS, so the original stays as a safety net.)
     */
    fun make(ep: StreamEndpoint, rewriteTs: Boolean = true): List<StreamEndpoint> {
        if (!rewriteTs) return listOf(ep)
        val url = ep.url.toHttpUrlOrNull() ?: return listOf(ep)
        val segs = url.pathSegments.filter { it.isNotEmpty() }
        val last = segs.lastOrNull() ?: return listOf(ep)
        val alt: String? = when {
            last.lowercase().endsWith(".ts") && segs.size >= 3 ->
                url.newBuilder().setPathSegment(url.pathSize - 1, last.dropLast(3) + ".m3u8").build().toString()
            !last.contains('.') && segs.size >= 3 && last.all { it.isDigit() } ->
                url.newBuilder().setPathSegment(url.pathSize - 1, "$last.m3u8").build().toString()
            else -> null
        }
        return if (alt == null) listOf(ep) else listOf(ep.copy(url = alt), ep)
    }
}

// MARK: Catch-up / timeshift

object CatchupBuilder {
    fun url(channel: Channel, programme: Programme, now: Long = System.currentTimeMillis()): String? {
        val c = channel.catchup ?: return null
        val base = channel.primary?.url ?: return null
        if (programme.start < now - c.days * 86_400_000L || programme.start >= now) return null
        val start = programme.start / 1000
        val end = programme.stop / 1000
        val duration = maxOf(60, end - start)
        val nowSec = now / 1000
        fun fill(t: String) = t
            .replace("\${start}", "$start").replace("{utc}", "$start").replace("\${utc}", "$start")
            .replace("\${end}", "$end").replace("{utcend}", "$end")
            .replace("\${timestamp}", "$nowSec").replace("{lutc}", "$nowSec")
            .replace("\${duration}", "$duration").replace("{duration}", "$duration")
            .replace("\${offset}", "${nowSec - start}")

        return when (c.mode) {
            CatchupMode.XTREAM -> {
                // .../live/<user>/<pass>/<id>.<ext> -> .../timeshift/<user>/<pass>/<minutes>/<yyyy-MM-dd:HH-mm>/<id>.<ext>
                val url = base.toHttpUrlOrNull() ?: return null
                val segs = url.pathSegments.toMutableList()
                val liveIdx = segs.lastIndexOf("live")
                if (liveIdx < 0 || segs.size < liveIdx + 4) return null
                val file = segs[liveIdx + 3]
                val f = SimpleDateFormat("yyyy-MM-dd:HH-mm", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
                segs[liveIdx] = "timeshift"
                val tail = listOf("${duration / 60}", f.format(java.util.Date(programme.start)), file)
                val head = segs.subList(0, liveIdx + 3)
                val b = url.newBuilder().encodedPath("/")
                (head + tail).forEach { b.addPathSegment(it) }
                b.build().toString()
            }
            CatchupMode.APPEND -> base + fill(c.template ?: "?utc=\${start}&lutc=\${timestamp}")
            CatchupMode.TEMPLATE -> c.template?.let { fill(it) }
            CatchupMode.SHIFT -> base + (if ('?' in base) "&" else "?") + "utc=$start&lutc=$nowSec"
            CatchupMode.FLUSSONIC -> when {
                "index.m3u8" in base -> base.replace("index.m3u8", "index-$start-$duration.m3u8")
                "mpegts" in base -> base.replace("mpegts", "index-$start-$duration.m3u8")
                else -> null
            }
        }
    }
}

// MARK: Stream health (dead-channel scan)

class HealthResult(val channelId: String, val alive: Boolean, val latencyMs: Long?)

object StreamHealth {
    fun probe(ep: StreamEndpoint, http: OkHttpClient = Net.client, timeoutSec: Long = 6): Pair<Boolean, Long?> {
        val url = ep.url.toHttpUrlOrNull() ?: return false to null
        val client = http.newBuilder().callTimeout(timeoutSec, java.util.concurrent.TimeUnit.SECONDS).build()
        val req = Request.Builder().url(url).header("Range", "bytes=0-2047").header("User-Agent", ep.userAgent ?: "Lumina/1.0")
            .apply { ep.referer?.let { header("Referer", it) } }.build()
        val t0 = System.nanoTime()
        return try {
            client.newCall(req).execute().use { r ->
                if (!r.isSuccessful) return false to null
                val head = r.body.source().let { s -> s.request(2048); s.buffer.snapshot().utf8() }
                if (url.encodedPath.lowercase().endsWith(".m3u8") && !head.contains("#EXTM3U")) return false to null
                (head.isNotEmpty()) to (System.nanoTime() - t0) / 1_000_000
            }
        } catch (e: Exception) { false to null }
    }

    /** Probes at most [concurrency] channels at once, emitting each result as it arrives. Cancelling the collector stops the scan. */
    fun scan(channels: List<Channel>, concurrency: Int = 8, http: OkHttpClient = Net.client): Flow<HealthResult> = channelFlow {
        val gate = Semaphore(maxOf(1, concurrency))
        coroutineScope {
            for (c in channels) {
                val ep = c.primary ?: continue
                launch(kotlinx.coroutines.Dispatchers.IO) {
                    gate.withPermit {
                        val (ok, ms) = probe(ep, http)
                        send(HealthResult(c.id, ok, ms))
                    }
                }
            }
        }
    }
}
