package app.lumina.core

import java.io.InputStream
import java.text.Normalizer

object NameNormalizer {
    /** Tags providers glue onto channel names that say nothing about *which* channel it is. */
    val noise: Set<String> = setOf(
        "hd", "fhd", "uhd", "4k", "sd", "hevc", "h265", "h264", "raw", "hq", "lq", "fullhd",
        "1080p", "1080i", "720p", "576p", "480p", "2160p", "50fps", "60fps", "backup", "vip",
    )
    private val marks = Regex("\\p{M}+")

    fun tokens(s: String): List<String> {
        val folded = marks.replace(Normalizer.normalize(s, Normalizer.Form.NFD), "").lowercase()
        val out = ArrayList<String>()
        val sb = StringBuilder()
        for (c in folded) {
            if (c.isLetterOrDigit()) sb.append(c) else if (sb.isNotEmpty()) { out += sb.toString(); sb.setLength(0) }
        }
        if (sb.isNotEmpty()) out += sb.toString()
        return out
    }

    /** Key used for search and for merging duplicate channels (quality tags removed). */
    fun key(name: String): String = tokens(name).filter { it !in noise }.joinToString(" ")
}

data class ParsedPlaylist(
    val channels: List<Channel>,
    val movies: List<VodItem>,
    val series: List<Series>,
    val episodes: List<Episode>,
    val epgUrls: List<String>,
    val skipped: Int,
)

/** Forgiving M3U/M3U8 (IPTV flavour) parser, streaming line by line. */
object M3UParser {
    fun parse(text: String, sourceId: String, defaultUserAgent: String? = null): ParsedPlaylist =
        parse(text.byteInputStream(Charsets.UTF_8), sourceId, defaultUserAgent)

    fun parse(input: InputStream, sourceId: String, defaultUserAgent: String? = null): ParsedPlaylist {
        val st = State(sourceId, defaultUserAgent)
        input.bufferedReader(Charsets.UTF_8).useLines { lines ->
            var first = true
            for (raw in lines) {
                var line = raw
                if (first) { line = line.removePrefix("﻿"); first = false }
                line = line.trimEnd('\r')
                if (line.isNotEmpty()) st.consume(line)
            }
        }
        return st.finish()
    }

    private class Pending(
        val attrs: Map<String, String>,
        val name: String,
        var group: String? = null,
        var userAgent: String? = null,
        var referer: String? = null,
    )

    private class State(val sourceId: String, val defaultUserAgent: String?) {
        val channels = ArrayList<Channel>()
        val movies = ArrayList<VodItem>()
        val episodes = ArrayList<Episode>()
        val epgUrls = ArrayList<String>()
        val seriesIndex = LinkedHashMap<String, Series>()
        val seenIds = HashMap<String, Int>()
        var skipped = 0
        var pending: Pending? = null

        fun consume(line: String) {
            if (line[0] == '#') {
                when {
                    line.startsWith("#EXTINF:") -> {
                        val (attrs, name) = parseExtInf(line)
                        pending = Pending(attrs, name)
                    }
                    line.startsWith("#EXTM3U") -> {
                        val attrs = scanAttributes(line, 7, stopAtComma = false).first
                        for (k in listOf("url-tvg", "x-tvg-url", "tvg-url")) attrs[k]?.split(',')?.forEach { part ->
                            val p = part.trim()
                            if (p.startsWith("http", ignoreCase = true)) epgUrls += p
                        }
                    }
                    line.startsWith("#EXTGRP:") -> pending?.group = line.substring(8).trim()
                    line.startsWith("#EXTVLCOPT:") -> {
                        val opt = line.substring(11)
                        val eq = opt.indexOf('=')
                        if (eq > 0) {
                            val v = opt.substring(eq + 1)
                            when (opt.substring(0, eq).lowercase()) {
                                "http-user-agent" -> pending?.userAgent = v
                                "http-referrer", "http-referer" -> pending?.referer = v
                            }
                        }
                    }
                }
                return
            }
            val p = pending ?: return
            pending = null
            val parsed = parseUrlLine(line.trim())
            if (parsed == null) { skipped++; return }
            emit(p, parsed.url, parsed.userAgent ?: p.userAgent, parsed.referer ?: p.referer)
        }

        fun emit(p: Pending, url: String, ua: String?, referer: String?) {
            val name = p.name.ifEmpty { p.attrs["tvg-name"] ?: "Channel" }
            val group = p.attrs["group-title"]?.takeIf { it.isNotEmpty() } ?: p.group ?: "Uncategorized"
            val ep = StreamEndpoint(url, ua ?: defaultUserAgent, referer, Quality.detect(name))
            val path = pathOf(url).lowercase()

            if ("/series/" in path) { emitEpisode(name, group, ep, p.attrs["tvg-logo"]); return }
            if ("/movie/" in path || isVodFile(path)) {
                movies += VodItem(
                    id = StableHash.hex("$sourceId|m|$name|${pathOf(url)}"), sourceId = sourceId, title = name,
                    category = group, poster = p.attrs["tvg-logo"]?.takeIf { it.isNotEmpty() }, stream = ep,
                )
                return
            }
            val tvgId = p.attrs["tvg-id"]?.takeIf { it.isNotEmpty() }
            var id = StableHash.hex("$sourceId|${tvgId ?: ""}|$name|$group")
            val n = seenIds[id]
            if (n != null) { seenIds[id] = n + 1; id += "#$n" } else seenIds[id] = 1
            channels += Channel(
                id = id, sourceId = sourceId, name = name,
                number = (p.attrs["tvg-chno"] ?: p.attrs["channel-number"])?.toIntOrNull(),
                group = group, logo = p.attrs["tvg-logo"]?.takeIf { it.isNotEmpty() },
                epgId = tvgId ?: p.attrs["tvg-name"]?.takeIf { it.isNotEmpty() },
                streams = listOf(ep), catchup = catchupFrom(p.attrs),
            )
        }

        fun emitEpisode(name: String, group: String, ep: StreamEndpoint, poster: String?) {
            val parsed = parseEpisodeName(name)
            val seriesId = StableHash.hex("$sourceId|s|${parsed.series.lowercase()}")
            if (seriesId !in seriesIndex) {
                seriesIndex[seriesId] = Series(seriesId, sourceId, parsed.series, group, poster?.takeIf { it.isNotEmpty() })
            }
            episodes += Episode(
                id = StableHash.hex("$seriesId|${parsed.season}|${parsed.episode}|${pathOf(ep.url)}"),
                seriesId = seriesId, season = parsed.season, number = parsed.episode, title = name, stream = ep,
            )
        }

        fun finish() = ParsedPlaylist(channels, movies, seriesIndex.values.toList(), episodes, epgUrls, skipped)
    }

    // MARK: helpers (internal for tests)

    private fun pathOf(url: String): String {
        val noQuery = url.substringBefore('?')
        val afterScheme = noQuery.substringAfter("://", noQuery)
        val slash = afterScheme.indexOf('/')
        return if (slash >= 0) afterScheme.substring(slash) else "/"
    }

    private fun isVodFile(path: String) = path.endsWith(".mp4") || path.endsWith(".mkv") || path.endsWith(".avi") || path.endsWith(".mov")

    private fun catchupFrom(a: Map<String, String>): Catchup? {
        val days = (a["catchup-days"] ?: a["tvg-rec"])?.toIntOrNull() ?: 0
        val type = (a["catchup"] ?: a["catchup-type"] ?: "").lowercase()
        val src = a["catchup-source"]?.takeIf { it.isNotEmpty() }
        if (type.isEmpty() && src == null && days == 0) return null
        val d = if (days > 0) days else 1
        return when (type) {
            "append" -> Catchup(CatchupMode.APPEND, d, src)
            "shift" -> Catchup(CatchupMode.SHIFT, d)
            "flussonic", "fs", "flussonic-hls", "flussonic-ts" -> Catchup(CatchupMode.FLUSSONIC, d)
            "xc", "xtream" -> Catchup(CatchupMode.XTREAM, d)
            "default" -> src?.let { Catchup(CatchupMode.TEMPLATE, d, it) }
            else -> when {
                src != null -> Catchup(CatchupMode.TEMPLATE, d, src)
                days > 0 -> Catchup(CatchupMode.XTREAM, d)
                else -> null
            }
        }
    }

    /** `#EXTINF:-1 key="v" key2="v2",Display Name` */
    fun parseExtInf(line: String): Pair<Map<String, String>, String> {
        var i = 8
        while (i < line.length && line[i] != ' ' && line[i] != ',') i++ // duration
        val (attrs, nameStart) = scanAttributes(line, i, stopAtComma = true)
        val name = if (nameStart < line.length) line.substring(nameStart).trim() else ""
        return attrs to name
    }

    fun scanAttributes(s: String, from: Int, stopAtComma: Boolean): Pair<Map<String, String>, Int> {
        var i = from
        val attrs = LinkedHashMap<String, String>()
        var nameStart = s.length
        while (i < s.length) {
            val c = s[i]
            if (c == ',' && stopAtComma) { nameStart = i + 1; break }
            if (c == ' ' || c == '\t' || c == ',') { i++; continue }
            val ks = i
            while (i < s.length && s[i] != '=' && s[i] != ',' && s[i] != ' ') i++
            if (i >= s.length || s[i] != '=') continue
            val key = s.substring(ks, i).lowercase()
            i++
            val value: String
            if (i < s.length && s[i] == '"') {
                i++
                val vs = i
                while (i < s.length && s[i] != '"') i++
                value = s.substring(vs, i)
                if (i < s.length) i++
            } else {
                val vs = i
                while (i < s.length && s[i] != ' ' && s[i] != ',') i++
                value = s.substring(vs, i)
            }
            if (key.isNotEmpty()) attrs[key] = value
        }
        return attrs to nameStart
    }

    class UrlLine(val url: String, val userAgent: String?, val referer: String?)

    /** Handles Kodi-style `url|User-Agent=x&Referer=y` suffixes; only http(s) is playable. */
    fun parseUrlLine(raw: String): UrlLine? {
        var url = raw
        var ua: String? = null
        var ref: String? = null
        val bar = raw.indexOf('|')
        if (bar >= 0 && raw.indexOf('=', bar) > 0) {
            url = raw.substring(0, bar)
            for (pair in raw.substring(bar + 1).split('&')) {
                val eq = pair.indexOf('=')
                if (eq <= 0) continue
                val v = runCatching { java.net.URLDecoder.decode(pair.substring(eq + 1), "UTF-8") }.getOrDefault(pair.substring(eq + 1))
                when (pair.substring(0, eq).lowercase()) {
                    "user-agent" -> ua = v
                    "referer", "referrer" -> ref = v
                }
            }
        }
        val scheme = url.substringBefore(':', "").lowercase()
        if (scheme != "http" && scheme != "https") return null
        return UrlLine(url.replace(" ", "%20"), ua, ref)
    }

    class EpisodeName(val series: String, val season: Int, val episode: Int)

    private val episodeRegexes = listOf(
        Regex("""^(.*?)[\s._-]*[Ss](\d{1,2})[\s._-]*[Ee](\d{1,4})"""),
        Regex("""^(.*?)[\s._-]+(\d{1,2})x(\d{1,3})\b"""),
    )

    /** "Show Name S02E05", "Show.Name.2x05", … */
    fun parseEpisodeName(name: String): EpisodeName {
        for (re in episodeRegexes) {
            val m = re.find(name) ?: continue
            val title = m.groupValues[1].replace('.', ' ').replace('_', ' ').trim(' ', '-', '|', ':')
            return EpisodeName(title.ifEmpty { name }, m.groupValues[2].toInt(), m.groupValues[3].toInt())
        }
        return EpisodeName(name, 1, 1)
    }
}
