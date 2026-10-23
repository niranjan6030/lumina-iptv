package app.lumina.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.security.MessageDigest
import java.util.UUID

@Serializable
data class Reminder(val channelId: String, val channelName: String, val title: String, val start: Long) {
    val id: String get() = "$channelId|$start"
}

@Serializable
data class WatchProgress(
    val positionMs: Long, val durationMs: Long, val updated: Long = System.currentTimeMillis(),
    val title: String, val poster: String? = null, val streamUrl: String? = null,
) {
    val fraction: Double get() = if (durationMs > 0) (positionMs.toDouble() / durationMs).coerceIn(0.0, 1.0) else 0.0
    val isFinished: Boolean get() = fraction > 0.95
}

@Serializable
data class AppSettings(
    val mergeDuplicates: Boolean = true,
    val autoFailover: Boolean = true,
    val rewriteTsToHls: Boolean = true,
    val guideRefreshHours: Int = 12,
    val resumeLastChannel: Boolean = true,
    val showGroupRegions: Boolean = true,
    val gridLayout: Boolean = false,
    val autoAudioOnly: Boolean = true,      // audio-only when Android Auto is the controller
    val autoMaxItems: Int = 100,
    val hideAdultByDefault: Boolean = true,
)

/** Everything personal that should survive a playlist refresh. */
@Serializable
data class UserData(
    val favorites: List<String> = emptyList(),
    val recents: List<String> = emptyList(),
    val lastChannelId: String? = null,
    val hiddenChannels: Set<String> = emptySet(),
    val hiddenGroups: Set<String> = emptySet(),
    val lockedGroups: Set<String> = emptySet(),
    val progress: Map<String, WatchProgress> = emptyMap(),
    val reminders: List<Reminder> = emptyList(),
    val pinHash: String? = null,
    val pinSalt: String? = null,
    val settings: AppSettings = AppSettings(),
) {
    fun isFavorite(id: String) = id in favorites
    fun toggleFavorite(id: String) = copy(favorites = if (id in favorites) favorites - id else favorites + id)

    fun pushRecent(id: String, limit: Int = 30) = copy(recents = (listOf(id) + recents.filter { it != id }).take(limit), lastChannelId = id)

    fun withProgress(id: String, p: WatchProgress): UserData {
        var m = progress + (id to p)
        if (m.size > 500) m = m.entries.sortedByDescending { it.value.updated }.take(500).associate { it.key to it.value }
        return copy(progress = m)
    }

    fun applyAliases(aliases: Map<String, String>): UserData {
        if (aliases.isEmpty()) return this
        fun remap(ids: List<String>): List<String> = ids.map { aliases[it] ?: it }.distinct()
        return copy(favorites = remap(favorites), recents = remap(recents), lastChannelId = lastChannelId?.let { aliases[it] ?: it })
    }

    val hasPin: Boolean get() = pinHash != null

    fun withPin(pin: String?): UserData {
        if (pin.isNullOrEmpty()) return copy(pinHash = null, pinSalt = null)
        val salt = UUID.randomUUID().toString()
        return copy(pinSalt = salt, pinHash = hash(pin, salt))
    }

    fun verifyPin(pin: String): Boolean {
        val h = pinHash ?: return true
        val s = pinSalt ?: return true
        return hash(pin, s) == h
    }

    private fun hash(pin: String, salt: String): String =
        MessageDigest.getInstance("SHA-256").digest((salt + pin).toByteArray()).joinToString("") { "%02x".format(it) }
}

object ParentalHeuristics {
    private val words = setOf("adult", "xxx", "porn", "18", "erotic", "sex", "playboy", "hustler")

    /** Groups that look adult by name. Only a hint: the user's own locks always win. */
    fun looksAdult(group: String) = NameNormalizer.tokens(group).any { it in words }
}

/** Small JSON-on-disk persistence. */
object JsonFile {
    val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; isLenient = true }

    inline fun <reified T> read(file: File): T? = runCatching { json.decodeFromString<T>(file.readText()) }.getOrNull()

    inline fun <reified T> write(file: File, value: T) {
        file.parentFile?.mkdirs()
        val tmp = File(file.path + ".tmp")
        tmp.writeText(json.encodeToString(value))
        if (!tmp.renameTo(file)) { file.delete(); tmp.renameTo(file) }
    }
}
