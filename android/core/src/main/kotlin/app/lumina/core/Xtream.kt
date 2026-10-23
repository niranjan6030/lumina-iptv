package app.lumina.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.Base64

/** Xtream panels return numbers as strings, strings as numbers, `false` for "none"… accept all of it. */
internal fun JsonElement?.flex(): String? {
    val p = this as? JsonPrimitive ?: return null
    if (p is JsonNull) return null
    val c = p.content
    if (c.isEmpty()) return null
    if (!p.isString) when (c) { "true" -> return "1"; "false" -> return "0" }
    // 12.0 -> 12
    c.toDoubleOrNull()?.let { d -> if (!p.isString && d == Math.rint(d) && c.contains('.')) return d.toLong().toString() }
    return c
}

internal fun JsonObject.s(k: String) = this[k].flex()
internal fun JsonObject.i(k: String) = s(k)?.toIntOrNull()
internal fun JsonObject.d(k: String) = s(k)?.toDoubleOrNull()

class XtreamClient(
    val server: String,
    val username: String,
    val password: String,
    private val http: OkHttpClient = Net.client,
) {
    companion object {
        private val json = Json { ignoreUnknownKeys = true; isLenient = true }

        /** "host:8080", "http://host:8080/", "http://host/player_api.php?x=1" -> "http://host:8080" */
        fun normalizeServer(input: String): String? {
            var s = input.trim()
            if (s.isEmpty()) return null
            if (!s.startsWith("http://", true) && !s.startsWith("https://", true)) s = "http://$s"
            val url = s.toHttpUrlOrNull() ?: return null
            var path = url.encodedPath
            for (tail in listOf("/player_api.php", "/get.php", "/xmltv.php", "/panel_api.php")) if (path.endsWith(tail)) path = path.dropLast(tail.length)
            path = path.trimEnd('/')
            val b = url.newBuilder().query(null).fragment(null).encodedPath(if (path.isEmpty()) "/" else path).build().toString()
            return b.trimEnd('/')
        }

        /** Recognises provider links like `http://h:80/get.php?username=u&password=p&type=m3u_plus`. */
        fun credentials(playlistUrl: String): Triple<String, String, String>? {
            val url = playlistUrl.toHttpUrlOrNull() ?: return null
            val u = url.queryParameter("username") ?: return null
            val p = url.queryParameter("password") ?: return null
            val path = url.encodedPath
            if (u.isEmpty() || p.isEmpty()) return null
            if (!(path.endsWith("get.php") || path.endsWith("player_api.php") || path.endsWith("xmltv.php"))) return null
            return Triple(normalizeServer(playlistUrl) ?: return null, u, p)
        }

        /** Xtream base64-encodes titles; some panels don't, so fall back to the raw text. */
        fun b64(s: String): String = runCatching {
            val t = String(Base64.getDecoder().decode(s), Charsets.UTF_8)
            if (t.isNotEmpty() && t.none { it == '�' }) t else s
        }.getOrDefault(s)
    }

    // MARK: URLs

    internal fun api(action: String?, extra: Map<String, String> = emptyMap()): HttpUrl {
        val b = (server.toHttpUrlOrNull() ?: throw LuminaException(LuminaException.Kind.INVALID_URL))
            .newBuilder().addPathSegment("player_api.php")
            .addQueryParameter("username", username).addQueryParameter("password", password)
        if (action != null) b.addQueryParameter("action", action)
        for ((k, v) in extra.toSortedMap()) b.addQueryParameter(k, v)
        return b.build()
    }

    val xmltvUrl: String
        get() = (server.toHttpUrlOrNull() ?: return "").newBuilder().addPathSegment("xmltv.php")
            .addQueryParameter("username", username).addQueryParameter("password", password).build().toString()

    private fun media(kind: String, file: String) = "$server/$kind/$username/$password/$file"
    fun liveUrl(streamId: String, ext: String = "m3u8") = media("live", "$streamId.$ext")
    fun movieUrl(streamId: String, ext: String) = media("movie", "$streamId.$ext")
    fun seriesUrl(episodeId: String, ext: String) = media("series", "$episodeId.$ext")

    // MARK: Requests

    private suspend fun fetch(url: HttpUrl, timeoutSec: Long = 60): JsonElement = withContext(Dispatchers.IO) {
        val client = http.newBuilder().callTimeout(timeoutSec, java.util.concurrent.TimeUnit.SECONDS).build()
        val req = Request.Builder().url(url).header("User-Agent", "Lumina/1.0").build()
        val body = try {
            client.newCall(req).execute().use { r ->
                if (!r.isSuccessful) throw LuminaException(LuminaException.Kind.HTTP, r.code.toString())
                r.body.string()
            }
        } catch (e: LuminaException) { throw e } catch (e: java.io.IOException) {
            throw LuminaException(LuminaException.Kind.NETWORK, e.message ?: "unreachable")
        }
        try { json.parseToJsonElement(body) } catch (e: Exception) { throw LuminaException(LuminaException.Kind.DECODING) }
    }

    /** Panels answer `[]`, `{}`, `false` or an error object when a section is empty; treat all as "no items". */
    private suspend fun list(action: String, extra: Map<String, String> = emptyMap()): List<JsonObject> =
        (fetch(api(action, extra)) as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()

    suspend fun authenticate(): XtreamAccount {
        val root = fetch(api(null), 30) as? JsonObject ?: throw LuminaException(LuminaException.Kind.AUTH_FAILED)
        val u = root["user_info"] as? JsonObject ?: throw LuminaException(LuminaException.Kind.AUTH_FAILED)
        val auth = u.s("auth")
        if (auth != "1" && auth != "true") throw LuminaException(LuminaException.Kind.AUTH_FAILED)
        val status = u.s("status") ?: "Active"
        if (!status.equals("active", true)) throw LuminaException(LuminaException.Kind.ACCOUNT_INACTIVE, status)
        return XtreamAccount(
            username = u.s("username") ?: username, status = status,
            expiry = u.d("exp_date")?.let { (it * 1000).toLong() },
            isTrial = u.s("is_trial") == "1", maxConnections = u.i("max_connections"), activeConnections = u.i("active_cons"),
            allowedFormats = (u["allowed_output_formats"] as? JsonArray)?.mapNotNull { it.flex() } ?: emptyList(),
            serverTimezone = (root["server_info"] as? JsonObject)?.s("timezone"),
        )
    }

    /** Pulls live + VOD + series lists concurrently. Only live is required; VOD/series failures are tolerated. */
    suspend fun loadSnapshot(sourceId: String, account: XtreamAccount, userAgent: String?): SourceSnapshot = coroutineScope {
        val liveCats = async { list("get_live_categories") }
        val live = async { list("get_live_streams") }
        val vodCats = async { runCatching { list("get_vod_categories") }.getOrDefault(emptyList()) }
        val vod = async { runCatching { list("get_vod_streams") }.getOrDefault(emptyList()) }
        val serCats = async { runCatching { list("get_series_categories") }.getOrDefault(emptyList()) }
        val ser = async { runCatching { list("get_series") }.getOrDefault(emptyList()) }

        val lc = liveCats.await(); val l = live.await()
        val vc = vodCats.await(); val v = vod.await(); val sc = serCats.await(); val s = ser.await()

        fun names(c: List<JsonObject>) = c.mapNotNull { o -> o.s("category_id")?.let { it to (o.s("category_name") ?: "Other") } }.toMap()
        val liveNames = names(lc); val vodNames = names(vc); val serNames = names(sc)
        // Prefer HLS, but ExoPlayer plays raw TS too, so fall back to whatever the panel offers.
        val ext = if (account.allowedFormats.isEmpty() || "m3u8" in account.allowedFormats) "m3u8" else account.allowedFormats.first()
        val prefix = sourceId.take(8)

        val channels = l.mapNotNull { x ->
            val sid = x.s("stream_id") ?: return@mapNotNull null
            val name = x.s("name") ?: "Channel $sid"
            val days = if (x.s("tv_archive") == "1") x.i("tv_archive_duration") ?: 1 else 0
            Channel(
                id = "$prefix:x$sid", sourceId = sourceId, name = name, number = x.i("num"),
                group = x.s("category_id")?.let { liveNames[it] } ?: "Uncategorized",
                logo = x.s("stream_icon"), epgId = x.s("epg_channel_id"),
                streams = listOf(StreamEndpoint(liveUrl(sid, ext), userAgent, null, Quality.detect(name))),
                catchup = if (days > 0) Catchup(CatchupMode.XTREAM, days) else null,
            )
        }
        val movies = v.mapNotNull { x ->
            val sid = x.s("stream_id") ?: return@mapNotNull null
            VodItem(
                id = "$prefix:m$sid", sourceId = sourceId, title = x.s("name") ?: "Movie",
                category = x.s("category_id")?.let { vodNames[it] } ?: "Movies", poster = x.s("stream_icon"),
                stream = StreamEndpoint(movieUrl(sid, x.s("container_extension") ?: "mp4"), userAgent),
                year = x.s("year"), rating = x.d("rating"), xtreamId = sid,
            )
        }
        val series = s.mapNotNull { x ->
            val sid = x.s("series_id") ?: return@mapNotNull null
            Series(
                id = "$prefix:s$sid", sourceId = sourceId, title = x.s("name") ?: "Series",
                category = x.s("category_id")?.let { serNames[it] } ?: "Series", poster = x.s("cover"), plot = x.s("plot"),
                rating = x.d("rating"), year = (x.s("releaseDate") ?: x.s("release_date"))?.take(4), xtreamId = sid,
            )
        }
        if (channels.isEmpty() && movies.isEmpty() && series.isEmpty()) throw LuminaException(LuminaException.Kind.EMPTY_PLAYLIST)
        SourceSnapshot(sourceId, channels, movies, series, epgUrls = listOf(xmltvUrl), account = account)
    }

    // MARK: Details

    class VodDetail(
        val plot: String?, val cast: String?, val director: String?, val genre: String?, val year: String?,
        val rating: Double?, val duration: String?, val backdrop: String?, val poster: String?, val containerExtension: String?,
    )

    suspend fun vodDetail(id: String): VodDetail {
        val root = fetch(api("get_vod_info", mapOf("vod_id" to id))) as? JsonObject ?: throw LuminaException(LuminaException.Kind.DECODING)
        val i = root["info"] as? JsonObject
        return VodDetail(
            plot = i?.s("plot"), cast = i?.s("cast"), director = i?.s("director"), genre = i?.s("genre"),
            year = i?.s("releasedate")?.take(4), rating = i?.d("rating"), duration = i?.s("duration"),
            backdrop = (i?.get("backdrop_path") as? JsonArray)?.firstOrNull().flex(), poster = i?.s("movie_image"),
            containerExtension = (root["movie_data"] as? JsonObject)?.s("container_extension"),
        )
    }

    suspend fun episodes(seriesId: String, localSeriesId: String, userAgent: String?): List<Episode> {
        val root = fetch(api("get_series_info", mapOf("series_id" to seriesId))) as? JsonObject ?: return emptyList()
        val eps = root["episodes"]
        val groups: List<Pair<String, JsonArray>> = when (eps) {
            is JsonObject -> eps.entries.mapNotNull { (k, v) -> (v as? JsonArray)?.let { k to it } }
            is JsonArray -> eps.mapIndexedNotNull { idx, v -> (v as? JsonArray)?.let { (idx + 1).toString() to it } }
            else -> emptyList()
        }
        val out = ArrayList<Episode>()
        for ((seasonKey, arr) in groups) for (e in arr.mapNotNull { it as? JsonObject }) {
            val eid = e.s("id") ?: continue
            val info = e["info"] as? JsonObject
            val n = e.i("episode_num") ?: 0
            out += Episode(
                id = "$localSeriesId:e$eid", seriesId = localSeriesId, season = e.i("season") ?: seasonKey.toIntOrNull() ?: 1,
                number = n, title = e.s("title") ?: "Episode $n",
                stream = StreamEndpoint(seriesUrl(eid, e.s("container_extension") ?: "mp4"), userAgent),
                plot = info?.s("plot"), durationSec = info?.d("duration_secs"), thumbnail = info?.s("movie_image"),
            )
        }
        return out.sortedWith(compareBy({ it.season }, { it.number }))
    }

    // MARK: Guide fallbacks (panels without xmltv.php)

    suspend fun fullDayEpg(streamId: String, guideChannel: String): List<Programme> =
        programmes(fetch(api("get_simple_data_table", mapOf("stream_id" to streamId))), guideChannel)

    private fun programmes(root: JsonElement, channel: String): List<Programme> {
        val items = (root as? JsonObject)?.get("epg_listings") as? JsonArray ?: return emptyList()
        return items.mapNotNull { it as? JsonObject }.mapNotNull { x ->
            val s = x.d("start_timestamp") ?: return@mapNotNull null
            val e = x.d("stop_timestamp") ?: return@mapNotNull null
            val t = x.s("title") ?: return@mapNotNull null
            Programme(channel.lowercase(), (s * 1000).toLong(), (e * 1000).toLong(), b64(t), desc = x.s("description")?.let(::b64))
        }
    }
}

object Net {
    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, java.util.concurrent.TimeUnit.SECONDS)
        .readTimeout(30, java.util.concurrent.TimeUnit.SECONDS)
        .followRedirects(true).followSslRedirects(true)
        .build()
}
