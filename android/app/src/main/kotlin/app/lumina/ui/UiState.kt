package app.lumina.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.lumina.LuminaApp
import app.lumina.core.Channel
import app.lumina.core.Series
import app.lumina.core.Source
import app.lumina.core.VodItem
import app.lumina.playback.VodRequest

enum class AppTab { LIVE, LIBRARY, SEARCH, SETTINGS }
enum class AddMode(val label: String) { XTREAM("Xtream login"), M3U("M3U link"), FILE("File") }

/** Full-screen pages pushed above the tabs. */
sealed interface Page {
    data class Movie(val item: VodItem) : Page
    data class SeriesPage(val series: Series) : Page
    data class Schedule(val channel: Channel) : Page
    data class AddSource(val mode: AddMode) : Page
    data class SourceEdit(val source: Source) : Page
    data object Groups : Page
    data object LockedGroups : Page
}

class PinRequest(val group: String, val onSuccess: () -> Unit)

/** Phone-UI-only state (the Android Auto browse tree never touches this). */
object UiState {
    var tab by mutableStateOf(AppTab.LIVE)
    var showPlayer by mutableStateOf(false)
    var inPip by mutableStateOf(false)
    var pinRequest by mutableStateOf<PinRequest?>(null)
    val pages = mutableStateListOf<Page>()
    /** Group the Live tab should show (set by the group picker). */
    var liveGroup by mutableStateOf<String?>(null)
    var liveFilter by mutableStateOf<String?>(null) // "fav", "recent", "all", or null = automatic

    private val app get() = LuminaApp.instance

    fun push(p: Page) { pages += p }
    fun pop(): Boolean = if (pages.isNotEmpty()) { pages.removeAt(pages.lastIndex); true } else false

    fun play(channel: Channel, list: List<Channel>? = null) {
        if (app.model.isLocked(channel.group)) {
            pinRequest = PinRequest(channel.group) { play(channel, list) }
            return
        }
        app.playback.setAudioOnly(false)
        app.playback.play(channel, list)
        showPlayer = true
    }

    fun play(v: VodRequest, queue: List<VodRequest> = emptyList(), resumeMs: Long = 0) {
        app.playback.setAudioOnly(false)
        app.playback.play(v, queue, resumeMs)
        showPlayer = true
    }
}
