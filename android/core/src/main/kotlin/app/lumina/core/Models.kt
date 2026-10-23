package app.lumina.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID

/** FNV-1a: stable across launches (unlike String.hashCode on some runtimes, and shorter than a UUID). */
object StableHash {
    fun fnv1a(s: String): ULong {
        var h = 0xcbf29ce484222325uL
        for (b in s.toByteArray(Charsets.UTF_8)) {
            h = h xor b.toUByte().toULong()
            h *= 0x100000001b3uL
        }
        return h
    }

    fun hex(s: String): String = fnv1a(s).toString(16)
}

// MARK: Source

@Serializable
sealed interface SourceKind {
    @Serializable @SerialName("m3u") data class M3u(val url: String) : SourceKind
    @Serializable @SerialName("xtream") data class Xtream(val server: String, val username: String, val password: String) : SourceKind
    @Serializable @SerialName("demo") data object Demo : SourceKind
}

@Serializable
data class Source(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val kind: SourceKind,
    val extraEpg: List<String> = emptyList(),
    val userAgent: String? = null,
    val epgOffsetMinutes: Int = 0,
    val enabled: Boolean = true,
    val lastRefreshed: Long? = null,
)

// MARK: Quality

enum class Quality(val label: String?) {
    UNKNOWN(null), SD("SD"), HD("HD"), FHD("FHD"), UHD("4K");

    companion object {
        fun detect(name: String): Quality {
            var best = UNKNOWN
            for (t in NameNormalizer.tokens(name)) {
                val q = when (t) {
                    "4k", "uhd", "2160p" -> UHD
                    "fhd", "fullhd", "1080p", "1080i" -> FHD
                    "hd", "720p" -> HD
                    "sd", "480p", "576p" -> SD
                    else -> UNKNOWN
                }
                if (q > best) best = q
            }
            return best
        }
    }
}

// MARK: Channel

@Serializable
data class StreamEndpoint(
    val url: String,
    val userAgent: String? = null,
    val referer: String? = null,
    val quality: Quality = Quality.UNKNOWN,
)

@Serializable
enum class CatchupMode { XTREAM, APPEND, TEMPLATE, SHIFT, FLUSSONIC }

@Serializable
data class Catchup(val mode: CatchupMode, val days: Int, val template: String? = null)

@Serializable
data class Channel(
    val id: String,
    val sourceId: String,
    val name: String,
    val number: Int? = null,
    val group: String,
    val logo: String? = null,
    val epgId: String? = null,
    /** Primary stream first; further entries are backups used for automatic failover. */
    val streams: List<StreamEndpoint>,
    val catchup: Catchup? = null,
) {
    val primary: StreamEndpoint? get() = streams.firstOrNull()
    val hasCatchup: Boolean get() = catchup != null && catchup.days > 0
}

// MARK: VOD

@Serializable
data class VodItem(
    val id: String,
    val sourceId: String,
    val title: String,
    val category: String,
    val poster: String? = null,
    val stream: StreamEndpoint,
    val year: String? = null,
    val rating: Double? = null,
    val plot: String? = null,
    val xtreamId: String? = null,
)

@Serializable
data class Series(
    val id: String,
    val sourceId: String,
    val title: String,
    val category: String,
    val poster: String? = null,
    val plot: String? = null,
    val rating: Double? = null,
    val year: String? = null,
    val xtreamId: String? = null,
)

@Serializable
data class Episode(
    val id: String,
    val seriesId: String,
    val season: Int,
    val number: Int,
    val title: String,
    val stream: StreamEndpoint,
    val plot: String? = null,
    val durationSec: Double? = null,
    val thumbnail: String? = null,
)

@Serializable
data class XtreamAccount(
    val username: String,
    val status: String,
    val expiry: Long? = null,
    val isTrial: Boolean = false,
    val maxConnections: Int? = null,
    val activeConnections: Int? = null,
    val allowedFormats: List<String> = emptyList(),
    val serverTimezone: String? = null,
) {
    fun daysRemaining(now: Long = System.currentTimeMillis()): Int? = expiry?.let { Math.floorDiv(it - now, 86_400_000L).toInt() }
}

@Serializable
data class SourceSnapshot(
    val sourceId: String,
    val channels: List<Channel> = emptyList(),
    val movies: List<VodItem> = emptyList(),
    val series: List<Series> = emptyList(),
    val episodes: List<Episode> = emptyList(),
    val epgUrls: List<String> = emptyList(),
    val account: XtreamAccount? = null,
    val fetchedAt: Long = System.currentTimeMillis(),
)

// MARK: Group labels ("US| NEWS" -> region US, title News)

data class GroupLabel(val raw: String, val region: String?, val title: String) {
    companion object {
        private val regex = Regex("""^([A-Z]{2})\s*[|:\-]\s*(.+)$""")

        fun parse(raw: String): GroupLabel {
            val t = raw.trim()
            regex.find(t)?.let { return GroupLabel(raw, it.groupValues[1], tidy(it.groupValues[2])) }
            return GroupLabel(raw, null, tidy(t))
        }

        private fun tidy(s: String): String =
            if (s.length > 3 && s == s.uppercase() && s.none { it.isLowerCase() }) {
                s.lowercase().split(' ').joinToString(" ") { w -> w.replaceFirstChar { it.uppercase() } }
            } else s
    }
}

// MARK: Errors (human wording, never raw status dumps)

class LuminaException(val kind: Kind, val detail: String = "") : Exception() {
    enum class Kind { INVALID_URL, HTTP, AUTH_FAILED, ACCOUNT_INACTIVE, NOT_A_PLAYLIST, NOT_A_GUIDE, CORRUPT_ARCHIVE, EMPTY_PLAYLIST, NETWORK, DECODING }

    override val message: String
        get() = when (kind) {
            Kind.INVALID_URL -> "That address doesn't look right. Check it starts with http:// or https://."
            Kind.HTTP -> when (detail) {
                "401", "403" -> "The server refused access ($detail). Check your username, password or subscription."
                "404" -> "The server couldn't find that playlist (404). The link may have expired."
                else -> "The server answered with an error ($detail)."
            }
            Kind.AUTH_FAILED -> "Login failed. Check the server address, username and password."
            Kind.ACCOUNT_INACTIVE -> "This account is not active ($detail). Contact your provider."
            Kind.NOT_A_PLAYLIST -> "That link didn't return a playlist. It must be an M3U/M3U8 file."
            Kind.NOT_A_GUIDE -> "The TV guide file couldn't be read."
            Kind.CORRUPT_ARCHIVE -> "The compressed file is damaged."
            Kind.EMPTY_PLAYLIST -> "The playlist loaded but contains no channels."
            Kind.NETWORK -> "Network problem: $detail"
            Kind.DECODING -> "The server replied in a format we couldn't understand."
        }
}
