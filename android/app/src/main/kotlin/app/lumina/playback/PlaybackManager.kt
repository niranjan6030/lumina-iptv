package app.lumina.playback

import android.app.Application
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.AudioAttributes
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import app.lumina.AppModel
import app.lumina.core.Channel
import app.lumina.core.GroupLabel
import app.lumina.core.StreamCandidates
import app.lumina.core.StreamEndpoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap

sealed interface PlayStatus {
    data object Idle : PlayStatus
    data object Loading : PlayStatus
    data object Playing : PlayStatus
    data object Paused : PlayStatus
    data class Failed(val message: String) : PlayStatus
}

data class PlayerUi(
    val status: PlayStatus = PlayStatus.Idle,
    val mediaId: String? = null,
    val title: String = "",
    val isLive: Boolean = false,
    val channelId: String? = null,
    val failoverNote: String? = null,
    val audioOnly: Boolean = false,
    val sleepEndsAt: Long? = null,
    val buffering: Boolean = false,
) {
    val hasMedia: Boolean get() = mediaId != null
}

/** Describes something playable that isn't a live channel (movie, episode, catch-up). */
class VodRequest(val id: String, val title: String, val endpoint: StreamEndpoint, val poster: String?)

/**
 * One ExoPlayer shared by the phone UI, the notification / lock screen and Android Auto.
 * Owns stream failover (backup sources), audio-only mode, sleep timer and VOD progress.
 */
@OptIn(UnstableApi::class)
class PlaybackManager(private val app: Application, private val model: AppModel) {
    private val scope: CoroutineScope get() = model.scope
    private val hostHeaders = ConcurrentHashMap<String, Map<String, String>>()
    private val attempt = HashMap<String, Int>()      // mediaId -> index into the channel's candidate list
    private var vodQueue: List<VodRequest> = emptyList()
    private var watchdog: Job? = null
    private var sleepJob: Job? = null
    private var progressJob: Job? = null
    private var generation = 0

    private val _ui = MutableStateFlow(PlayerUi())
    val ui: StateFlow<PlayerUi> = _ui.asStateFlow()

    val player: ExoPlayer

    init {
        val http = DefaultHttpDataSource.Factory()
            .setUserAgent("Lumina/1.0")
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(12_000)
            .setReadTimeoutMs(15_000)
        // Per-provider User-Agent / Referer, resolved per request by host (so HLS segments get them too).
        val resolving = ResolvingDataSource.Factory(http) { spec ->
            val h = spec.uri.host?.let { hostHeaders[it] }
            if (h.isNullOrEmpty()) spec else spec.withAdditionalHeaders(h)
        }
        player = ExoPlayer.Builder(app)
            .setMediaSourceFactory(DefaultMediaSourceFactory(DefaultDataSource.Factory(app, resolving)))
            .setLoadControl(
                // Small buffers: fast channel changes matter more than riding out long outages.
                DefaultLoadControl.Builder().setBufferDurationsMs(8_000, 30_000, 1_500, 3_000).build(),
            )
            .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), true)
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build()
        player.repeatMode = Player.REPEAT_MODE_ALL // channel zapping wraps around
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) = refresh()
            override fun onIsPlayingChanged(isPlaying: Boolean) = refresh()
            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) = refresh()
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) = onItemChanged(mediaItem)
            override fun onPlayerError(error: PlaybackException) = failover(error.errorCodeName)
        })
    }

    // MARK: Live

    private fun candidates(ch: Channel): List<StreamEndpoint> {
        val s = model.user.value.settings
        val c = ch.streams.flatMap { StreamCandidates.make(it, s.rewriteTsToHls) }
        return if (s.autoFailover) c else c.take(1)
    }

    private fun register(ep: StreamEndpoint) {
        val host = runCatching { Uri.parse(ep.url).host }.getOrNull() ?: return
        val h = HashMap<String, String>()
        ep.userAgent?.let { h["User-Agent"] = it }
        ep.referer?.let { h["Referer"] = it }
        if (h.isNotEmpty()) hostHeaders[host] = h
    }

    fun mediaItemFor(ch: Channel, idx: Int = 0): MediaItem? {
        val cands = candidates(ch)
        val ep = cands.getOrNull(idx) ?: return null
        register(ep)
        val now = model.nowNext(ch).now?.title
        return MediaItem.Builder()
            .setMediaId("ch:${ch.id}")
            .setUri(ep.url)
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(ch.name)
                    .setArtist(now ?: GroupLabel.parse(ch.group).title)
                    .setArtworkUri(ch.logo?.let { Uri.parse(it) })
                    .setIsPlayable(true).setIsBrowsable(false)
                    .build(),
            )
            .build()
    }

    /** Plays [channel] with [list] as the zapping context (capped around the selected channel). */
    fun play(channel: Channel, list: List<Channel>? = null) {
        val ctx = (list ?: model.library.value.visible).let { l -> if (l.any { it.id == channel.id }) l else listOf(channel) }
        val cap = model.user.value.settings.autoMaxItems.coerceIn(20, 200)
        val i = ctx.indexOfFirst { it.id == channel.id }
        val from = (i - cap / 2).coerceAtLeast(0)
        val window = ctx.subList(from, minOf(ctx.size, from + cap))
        val items = window.mapNotNull { mediaItemFor(it) }
        val start = window.indexOfFirst { it.id == channel.id }.coerceAtLeast(0)
        if (items.isEmpty()) return
        setItems(items, start)
        model.noteWatched(channel)
        scope.launch { model.ensureGuide(channel) }
    }

    /** Used by the Android Auto session: [items] already resolved by the browse tree. */
    fun setItems(items: List<MediaItem>, startIndex: Int) {
        ensureService()
        vodQueue = emptyList()
        attempt.clear()
        generation++
        player.setMediaItems(items, startIndex, C.TIME_UNSET)
        player.prepare()
        player.play()
        startWatchdog()
        progressJob?.cancel()
        refresh()
    }

    // MARK: VOD

    fun play(v: VodRequest, queue: List<VodRequest> = emptyList(), resumeMs: Long = 0) {
        ensureService()
        register(v.endpoint)
        vodQueue = queue
        attempt.clear()
        generation++
        val item = vodItem(v)
        player.setMediaItem(item, if (resumeMs > 0) resumeMs else C.TIME_UNSET)
        player.prepare()
        player.play()
        startWatchdog()
        startProgressSaver()
        refresh()
    }

    private fun vodItem(v: VodRequest) = MediaItem.Builder()
        .setMediaId("vod:${v.id}").setUri(v.endpoint.url)
        .setMediaMetadata(MediaMetadata.Builder().setTitle(v.title).setArtworkUri(v.poster?.let { Uri.parse(it) }).setIsPlayable(true).setIsBrowsable(false).build())
        .build()

    /** Called when the car (via the session) sets the queue itself. */
    fun onExternalItemsSet() { attempt.clear(); generation++ }

    private var controller: com.google.common.util.concurrent.ListenableFuture<androidx.media3.session.MediaController>? = null

    /** Binding a controller keeps the media service alive in the background and shows the playback notification. */
    private fun ensureService() {
        if (controller != null) return
        controller = androidx.media3.session.MediaController.Builder(
            app, androidx.media3.session.SessionToken(app, android.content.ComponentName(app, PlaybackService::class.java)),
        ).buildAsync()
    }

    // MARK: Transport

    fun togglePlayPause() { if (player.isPlaying || player.playWhenReady) player.pause() else resumePlayback() }

    fun resumePlayback() {
        if (_ui.value.status is PlayStatus.Failed) { attempt.clear(); player.prepare() }
        player.play()
    }

    fun zap(delta: Int) { if (delta > 0) player.seekToNextMediaItem() else player.seekToPreviousMediaItem(); startWatchdog() }
    fun seekBy(ms: Long) { player.seekTo((player.currentPosition + ms).coerceAtLeast(0)) }

    fun stop() {
        generation++
        watchdog?.cancel(); progressJob?.cancel()
        saveVodProgress()
        player.stop(); player.clearMediaItems()
        _ui.value = PlayerUi(audioOnly = _ui.value.audioOnly)
    }

    fun setAudioOnly(on: Boolean) {
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, on).build()
        _ui.value = _ui.value.copy(audioOnly = on)
    }

    fun setSleepTimer(minutes: Int?) {
        sleepJob?.cancel()
        if (minutes == null) { _ui.value = _ui.value.copy(sleepEndsAt = null); return }
        _ui.value = _ui.value.copy(sleepEndsAt = System.currentTimeMillis() + minutes * 60_000L)
        sleepJob = scope.launch {
            delay(minutes * 60_000L)
            for (step in 10 downTo 0) { player.volume = step / 10f; delay(500) } // fade out instead of cutting off
            player.pause(); player.volume = 1f
            _ui.value = _ui.value.copy(sleepEndsAt = null)
        }
    }

    // MARK: Failover

    private fun onItemChanged(item: MediaItem?) {
        generation++
        val id = item?.mediaId
        if (id != null && id.startsWith("ch:")) attempt.putIfAbsent(id, 0)
        refresh()
        startWatchdog()
    }

    private fun failover(reason: String) {
        val item = player.currentMediaItem ?: return
        val id = item.mediaId
        if (id.startsWith("ch:")) {
            val ch = model.channel(id.removePrefix("ch:"))
            if (ch != null) {
                val cands = candidates(ch)
                val next = (attempt[id] ?: 0) + 1
                if (next < cands.size) {
                    attempt[id] = next
                    val replacement = mediaItemFor(ch, next)
                    if (replacement != null) {
                        _ui.value = _ui.value.copy(failoverNote = "Switched to backup source ${next + 1} of ${cands.size}")
                        val idx = player.currentMediaItemIndex
                        player.replaceMediaItem(idx, replacement)
                        player.prepare(); player.play()
                        startWatchdog()
                        return
                    }
                }
            }
        }
        _ui.value = _ui.value.copy(
            status = PlayStatus.Failed("This channel isn't responding ($reason). It may be offline or need a different playlist URL."),
            buffering = false,
        )
    }

    /** A stream that neither plays nor errors (dead host, endless redirect) must not hang the UI. */
    private fun startWatchdog() {
        watchdog?.cancel()
        val gen = generation
        watchdog = scope.launch {
            delay(14_000)
            if (gen == generation && player.playbackState != Player.STATE_READY && player.playWhenReady) failover("timed out")
        }
    }

    // MARK: State + VOD progress

    private fun refresh() {
        val item = player.currentMediaItem
        val id = item?.mediaId
        val st: PlayStatus = when {
            id == null -> PlayStatus.Idle
            _ui.value.status is PlayStatus.Failed && player.playbackState == Player.STATE_IDLE -> _ui.value.status
            player.isPlaying -> PlayStatus.Playing
            player.playbackState == Player.STATE_BUFFERING || player.playbackState == Player.STATE_IDLE && player.playWhenReady -> PlayStatus.Loading
            player.playbackState == Player.STATE_ENDED -> PlayStatus.Paused
            else -> PlayStatus.Paused
        }
        if (st is PlayStatus.Playing) watchdog?.cancel()
        _ui.value = _ui.value.copy(
            status = st, mediaId = id, title = item?.mediaMetadata?.title?.toString() ?: "",
            isLive = id?.startsWith("ch:") == true, channelId = id?.takeIf { it.startsWith("ch:") }?.removePrefix("ch:"),
            buffering = player.playbackState == Player.STATE_BUFFERING,
            failoverNote = if (st is PlayStatus.Playing && (attempt[id] ?: 0) == 0) null else _ui.value.failoverNote,
        )
        if (player.playbackState == Player.STATE_ENDED && id?.startsWith("vod:") == true) onVodEnded()
    }

    private fun onVodEnded() {
        val cur = player.currentMediaItem ?: return
        val id = cur.mediaId.removePrefix("vod:")
        model.setProgress(id, 1, 1, cur.mediaMetadata.title?.toString() ?: "", cur.mediaMetadata.artworkUri?.toString(), cur.localConfiguration?.uri?.toString())
        vodQueue.firstOrNull()?.let { next -> play(next, vodQueue.drop(1)) }
    }

    private fun startProgressSaver() {
        progressJob?.cancel()
        progressJob = scope.launch { while (true) { delay(10_000); saveVodProgress() } }
    }

    private fun saveVodProgress() {
        val item = player.currentMediaItem ?: return
        if (!item.mediaId.startsWith("vod:")) return
        val d = player.duration
        if (d == C.TIME_UNSET || d <= 0) return
        model.setProgress(
            item.mediaId.removePrefix("vod:"), player.currentPosition, d,
            item.mediaMetadata.title?.toString() ?: "", item.mediaMetadata.artworkUri?.toString(), item.localConfiguration?.uri?.toString(),
        )
    }
}
