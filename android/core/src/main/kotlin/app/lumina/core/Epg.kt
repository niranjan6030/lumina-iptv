package app.lumina.core

import kotlinx.serialization.Serializable
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.helpers.DefaultHandler
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.io.StringReader
import java.util.zip.GZIPInputStream
import javax.xml.parsers.SAXParserFactory

@Serializable
data class Programme(
    val channel: String,          // lower-cased guide channel id
    val start: Long,              // epoch millis
    val stop: Long,
    val title: String,
    val subtitle: String? = null,
    val desc: String? = null,
    val category: String? = null,
    val icon: String? = null,
) {
    val id: String get() = "$channel|$start"
    val durationMs: Long get() = stop - start

    fun progress(at: Long): Double {
        val d = durationMs
        return if (d <= 0) 0.0 else ((at - start).toDouble() / d).coerceIn(0.0, 1.0)
    }
}

data class NowNext(val now: Programme?, val next: Programme?)

/** Read-optimised guide data. Immutable: merging returns a new index. */
class EpgIndex private constructor(
    private val byChannel: Map<String, List<Programme>>,
    private val nameToId: Map<String, String>,
    val channelIcons: Map<String, String>,
) {
    constructor() : this(emptyMap(), emptyMap(), emptyMap())

    val isEmpty: Boolean get() = byChannel.isEmpty()
    val programmeCount: Int get() = byChannel.values.sumOf { it.size }

    fun guideKey(channel: Channel): String? {
        val idKey = channel.id.lowercase()
        if (byChannel.containsKey(idKey)) return idKey
        channel.epgId?.lowercase()?.let { if (byChannel.containsKey(it)) return it }
        nameToId[NameNormalizer.key(channel.name)]?.let { return it }
        channel.epgId?.let { e -> nameToId[NameNormalizer.key(e)]?.let { return it } }
        return null
    }

    fun programmes(channel: Channel): List<Programme> = guideKey(channel)?.let { byChannel[it] } ?: emptyList()
    fun programmes(key: String): List<Programme> = byChannel[key] ?: emptyList()

    fun nowNext(channel: Channel, at: Long = System.currentTimeMillis(), offsetMs: Long = 0): NowNext =
        guideKey(channel)?.let { nowNext(it, at, offsetMs) } ?: NowNext(null, null)

    /** `offsetMs` > 0 means the guide runs late (programmes appear later than they really air). */
    fun nowNext(key: String, at: Long = System.currentTimeMillis(), offsetMs: Long = 0): NowNext {
        val list = byChannel[key]
        if (list.isNullOrEmpty()) return NowNext(null, null)
        val t = at - offsetMs
        var lo = 0
        var hi = list.size
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            if (list[mid].start <= t) lo = mid + 1 else hi = mid
        }
        val idx = lo - 1
        if (idx >= 0 && list[idx].stop > t) return NowNext(list[idx], list.getOrNull(idx + 1))
        return NowNext(null, list.getOrNull(lo))
    }

    fun search(query: String, from: Long, to: Long, limit: Int = 40): List<Programme> {
        val q = NameNormalizer.tokens(query)
        if (q.isEmpty()) return emptyList()
        val hits = ArrayList<Programme>()
        for (list in byChannel.values) for (p in list) {
            if (p.stop <= from || p.start >= to) continue
            val t = NameNormalizer.tokens(p.title)
            if (q.all { qq -> t.any { it.startsWith(qq) } }) hits += p
        }
        hits.sortBy { it.start }
        return hits.take(limit)
    }

    fun merge(other: EpgIndex): EpgIndex {
        val m = HashMap<String, List<Programme>>(byChannel)
        for ((k, v) in other.byChannel) {
            val existing = m[k]
            m[k] = if (existing == null) v else {
                val starts = existing.mapTo(HashSet()) { it.start }
                (existing + v.filter { it.start !in starts }).sortedBy { it.start }
            }
        }
        return EpgIndex(m, other.nameToId + nameToId, other.channelIcons + channelIcons)
    }

    companion object {
        fun of(
            programmes: List<Programme>,
            channelNames: Map<String, List<String>> = emptyMap(),
            channelIcons: Map<String, String> = emptyMap(),
        ): EpgIndex {
            val grouped = programmes.groupBy { it.channel }.mapValues { (_, v) -> v.sortedBy { it.start } }
            val n = HashMap<String, String>()
            for ((id, names) in channelNames) for (name in names) n[NameNormalizer.key(name)] = id
            return EpgIndex(grouped, n, channelIcons)
        }
    }
}

// MARK: XMLTV

class XmlTvResult(
    val programmes: List<Programme>,
    val channelNames: Map<String, List<String>>,
    val channelIcons: Map<String, String>,
) {
    val index: EpgIndex get() = EpgIndex.of(programmes, channelNames, channelIcons)
}

object XmlTvParser {
    /**
     * @param wantedIds lower-cased guide ids to keep (null keeps everything)
     * @param wantedNameKeys [NameNormalizer.key] values; a guide channel is kept if one of its display names matches
     * @param window only programmes overlapping this window are kept, bounding memory for huge guides
     */
    fun parse(
        input: InputStream, wantedIds: Set<String>?, wantedNameKeys: Set<String>, window: LongRange,
    ): XmlTvResult {
        val handler = Handler(wantedIds, wantedNameKeys, window)
        try {
            val f = SAXParserFactory.newInstance()
            f.isNamespaceAware = false
            val src = InputSource(input)
            f.newSAXParser().parse(src, handler)
        } catch (e: Exception) {
            if (handler.programmes.isEmpty()) throw LuminaException(LuminaException.Kind.NOT_A_GUIDE)
        }
        return XmlTvResult(handler.programmes, handler.channelNames, handler.channelIcons)
    }

    fun parse(xml: String, wantedIds: Set<String>?, wantedNameKeys: Set<String>, window: LongRange): XmlTvResult =
        parse(xml.byteInputStream(Charsets.UTF_8), wantedIds, wantedNameKeys, window)

    fun parse(file: File, wantedIds: Set<String>?, wantedNameKeys: Set<String>, window: LongRange): XmlTvResult {
        val raw = FileInputStream(file).buffered()
        raw.mark(2)
        val b0 = raw.read(); val b1 = raw.read()
        raw.reset()
        val stream: InputStream = if (b0 == 0x1F && b1 == 0x8B) GZIPInputStream(raw, 64 * 1024) else raw
        return stream.use { parse(it, wantedIds, wantedNameKeys, window) }
    }

    private class Handler(
        val wantedIds: Set<String>?, val wantedNameKeys: Set<String>, val window: LongRange,
    ) : DefaultHandler() {
        val programmes = ArrayList<Programme>()
        val channelNames = HashMap<String, List<String>>()
        val channelIcons = HashMap<String, String>()
        val wantedChannels = HashSet<String>()

        var chId: String? = null
        var chNames = ArrayList<String>()
        var inProgramme = false
        var skip = true
        var pChannel = ""; var pStart = 0L; var pStop = 0L
        var title = ""; var sub: String? = null; var desc: String? = null; var cat: String? = null; var icon: String? = null
        val text = StringBuilder()
        var collecting = false

        override fun startElement(uri: String?, localName: String?, qName: String, a: Attributes) {
            when (qName) {
                "channel" -> { chId = a.getValue("id")?.lowercase(); chNames = ArrayList() }
                "programme" -> {
                    inProgramme = true
                    skip = true
                    val ch = a.getValue("channel")?.lowercase() ?: return
                    val s = XmlTvDate.parse(a.getValue("start") ?: "") ?: return
                    val e = XmlTvDate.parse(a.getValue("stop") ?: "") ?: (s + 1_800_000)
                    if (e < window.first || s > window.last) return
                    if (wantedIds != null && ch !in wantedChannels && ch !in wantedIds) return
                    skip = false
                    pChannel = ch; pStart = s; pStop = e
                    title = ""; sub = null; desc = null; cat = null; icon = null
                }
                "display-name", "title", "sub-title", "desc", "category" ->
                    if (chId != null || (inProgramme && !skip)) { collecting = true; text.setLength(0) }
                "icon" -> {
                    val src = a.getValue("src") ?: return
                    if (inProgramme) { if (!skip) icon = src } else chId?.let { channelIcons[it] = src }
                }
            }
        }

        override fun characters(ch: CharArray, start: Int, length: Int) {
            if (collecting) text.append(ch, start, length)
        }

        override fun endElement(uri: String?, localName: String?, qName: String) {
            val t = text.toString().trim()
            when (qName) {
                "display-name" -> { if (collecting && chId != null) chNames += t; collecting = false }
                "channel" -> {
                    chId?.let { id ->
                        channelNames[id] = chNames
                        if (wantedIds != null && (id in wantedIds || chNames.any { NameNormalizer.key(it) in wantedNameKeys })) wantedChannels += id
                    }
                    chId = null
                }
                "title" -> { if (collecting && inProgramme && !skip) title = t; collecting = false }
                "sub-title" -> { if (collecting && inProgramme && !skip) sub = t; collecting = false }
                "desc" -> { if (collecting && inProgramme && !skip) desc = t; collecting = false }
                "category" -> { if (collecting && inProgramme && !skip && cat == null) cat = t; collecting = false }
                "programme" -> {
                    if (!skip && title.isNotEmpty()) programmes += Programme(pChannel, pStart, pStop, title, sub, desc, cat, icon)
                    inProgramme = false
                    skip = false
                }
            }
        }
    }
}

object XmlTvDate {
    /** `20240131183000 +0100`, `202401311830 -0500`, `20240131183000` (UTC assumed). Returns epoch millis. */
    fun parse(s: String): Long? {
        fun num(from: Int, len: Int): Int? {
            if (from + len > s.length) return null
            var v = 0
            for (k in from until from + len) {
                val c = s[k]
                if (c !in '0'..'9') return null
                v = v * 10 + (c - '0')
            }
            return v
        }
        val y = num(0, 4) ?: return null
        val mo = num(4, 2) ?: return null
        val d = num(6, 2) ?: return null
        val h = num(8, 2) ?: return null
        val mi = num(10, 2) ?: return null
        if (mo !in 1..12 || d !in 1..31) return null
        var idx = 12
        var sec = 0
        num(12, 2)?.let { sec = it; idx = 14 }
        while (idx < s.length && s[idx] == ' ') idx++
        var offset = 0
        if (idx < s.length && (s[idx] == '+' || s[idx] == '-')) {
            num(idx + 1, 2)?.let { hh ->
                val mm = num(idx + 3, 2) ?: 0
                offset = (hh * 3600 + mm * 60) * (if (s[idx] == '-') -1 else 1)
            }
        }
        val days = java.time.LocalDate.of(y, mo, d.coerceAtMost(java.time.YearMonth.of(y, mo).lengthOfMonth())).toEpochDay()
        return (days * 86_400 + h * 3600 + mi * 60 + sec - offset) * 1000
    }
}
