package app.lumina.ui

import android.app.Activity
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Forward30
import androidx.compose.material.icons.filled.Headphones
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Nightlight
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PictureInPictureAlt
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay10
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Subtitles
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.media3.common.C
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import app.lumina.core.GroupLabel
import app.lumina.MainActivity
import app.lumina.playback.PlayStatus
import kotlinx.coroutines.delay

@kotlin.OptIn(UnstableApi::class)
@Composable
fun PlayerScreen() {
    val pm = playbackManager
    val ui by pm.ui.collectAsStateWithLifecycle()
    val guide by appModel.guideVersion.collectAsStateWithLifecycle()
    var overlay by remember { mutableStateOf(true) }
    var fill by remember { mutableStateOf(false) }
    var drag by remember { mutableFloatStateOf(0f) }
    val view = LocalView.current

    BackHandler { UiState.showPlayer = false }

    // Immersive while the player is up.
    DisposableEffect(Unit) {
        val window = (view.context as? Activity)?.window
        val ctl = window?.let { WindowCompat.getInsetsController(it, view) }
        ctl?.hide(WindowInsetsCompat.Type.systemBars())
        ctl?.systemBarsBehavior = androidx.core.view.WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        onDispose { ctl?.show(WindowInsetsCompat.Type.systemBars()) }
    }
    LaunchedEffect(overlay, ui.status, UiState.inPip) {
        if (overlay && ui.status == PlayStatus.Playing) { delay(4_500); overlay = false }
    }

    Box(
        Modifier.fillMaxSize().background(Color.Black)
            .pointerInput(Unit) { detectTapGestures { overlay = !overlay } }
            .pointerInput(ui.isLive) {
                if (!ui.isLive) return@pointerInput
                detectVerticalDragGestures(
                    onDragStart = { drag = 0f },
                    onDragEnd = {
                        if (drag < -150f) { pm.zap(1); overlay = true } else if (drag > 150f) { pm.zap(-1); overlay = true }
                    },
                ) { _, dy -> drag += dy }
            },
    ) {
        AndroidView(
            factory = { ctx ->
                PlayerView(ctx).apply {
                    useController = false
                    setShutterBackgroundColor(android.graphics.Color.BLACK)
                    player = pm.player
                }
            },
            update = { it.resizeMode = if (fill) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT; it.player = pm.player },
            modifier = Modifier.fillMaxSize(),
        )

        if (ui.audioOnly) {
            AppBackground {
                Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                    LogoImage(ui.channelId?.let { appModel.channel(it)?.logo }, 140.dp, 32.dp, Icons.Filled.Headphones)
                    Spacer(Modifier.height(12.dp))
                    Text("Audio only", fontSize = 13.sp, color = Color.White.copy(alpha = 0.6f))
                }
            }
        }

        StatusLayer(ui.status, ui.failoverNote, ui.buffering, ui.isLive)

        if (overlay && !UiState.inPip) {
            Column(Modifier.fillMaxSize()) {
                TopBar(ui.title, ui.isLive, ui.channelId, fill, { fill = it })
                Spacer(Modifier.weight(1f))
                if (ui.isLive) LiveInfo(ui.channelId, guide, ui.status == PlayStatus.Playing || ui.buffering) { overlay = true }
                else VodControls(ui.status == PlayStatus.Playing || ui.buffering)
            }
        }
    }
}

@Composable
private fun StatusLayer(status: PlayStatus, note: String?, buffering: Boolean, live: Boolean) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        when {
            status is PlayStatus.Failed -> Column(
                Modifier.padding(32.dp).glass(26.dp).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text("⚠", fontSize = 32.sp)
                Text(status.message, textAlign = TextAlign.Center, fontSize = 15.sp)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button({ playbackManager.resumePlayback() }) { Text("Try again") }
                    if (live) OutlinedButton({ playbackManager.zap(1) }) { Text("Next channel") }
                }
            }
            status == PlayStatus.Loading || buffering -> Column(Modifier.glass(22.dp).padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator(color = Color.White)
                if (note != null) Text(note, fontSize = 12.sp, color = Color.White.copy(alpha = 0.7f), modifier = Modifier.padding(top = 8.dp))
            }
        }
        if (note != null && status == PlayStatus.Playing) {
            Text(note, fontSize = 13.sp, fontWeight = FontWeight.Medium, modifier = Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(top = 64.dp).glass(50.dp).padding(horizontal = 14.dp, vertical = 8.dp))
        }
    }
}

@kotlin.OptIn(UnstableApi::class)
@Composable
private fun TopBar(title: String, live: Boolean, channelId: String?, fill: Boolean, setFill: (Boolean) -> Unit) {
    val ctx = LocalContext.current
    val pm = playbackManager
    val ui by pm.ui.collectAsStateWithLifecycle()
    var menu by remember { mutableStateOf(false) }
    var sleepMenu by remember { mutableStateOf(false) }
    val ch = channelId?.let { appModel.channel(it) }
    val user by appModel.user.collectAsStateWithLifecycle()

    Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        GlassIconButton(Icons.Filled.KeyboardArrowDown, "Close") { UiState.showPlayer = false }
        Column(Modifier.weight(1f).glass(26.dp).padding(horizontal = 16.dp, vertical = 6.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(title, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (live) LiveDot()
        }
        GlassIconButton(Icons.Filled.PictureInPictureAlt, "Picture in picture") { (ctx as? MainActivity)?.enterPip() }
        Box {
            GlassIconButton(Icons.Filled.MoreVert, "More") { menu = true }
            DropdownMenu(menu, { menu = false }) {
                if (ch != null) {
                    DropdownMenuItem(
                        text = { Text(if (appModel.isFavorite(ch)) "Remove favorite" else "Add to favorites") }, leadingIcon = { Icon(Icons.Filled.Star, null) },
                        onClick = { appModel.toggleFavorite(ch); menu = false },
                    )
                    DropdownMenuItem(text = { Text("Schedule & replay") }, leadingIcon = { Icon(Icons.Filled.CalendarMonth, null) }, onClick = { menu = false; UiState.showPlayer = false; UiState.push(Page.Schedule(ch)) })
                }
                DropdownMenuItem(
                    text = { Text("Audio only (saves data)") }, leadingIcon = { Icon(Icons.Filled.Headphones, null) },
                    trailingIcon = { if (ui.audioOnly) Icon(Icons.Filled.Check, null) }, onClick = { pm.setAudioOnly(!ui.audioOnly); menu = false },
                )
                DropdownMenuItem(text = { Text(if (fill) "Fit to screen" else "Fill screen") }, leadingIcon = { Icon(Icons.Filled.AspectRatio, null) }, onClick = { setFill(!fill); menu = false })
                DropdownMenuItem(
                    text = { Text(if (ui.sleepEndsAt == null) "Sleep timer" else "Sleep timer on") }, leadingIcon = { Icon(Icons.Filled.Nightlight, null) },
                    onClick = { sleepMenu = true },
                )
                TrackItems(pm.player) { menu = false }
            }
            DropdownMenu(sleepMenu, { sleepMenu = false }) {
                listOf(15, 30, 45, 60, 90).forEach { m -> DropdownMenuItem(text = { Text("$m minutes") }, onClick = { pm.setSleepTimer(m); sleepMenu = false; menu = false }) }
                if (ui.sleepEndsAt != null) DropdownMenuItem(text = { Text("Turn off") }, onClick = { pm.setSleepTimer(null); sleepMenu = false; menu = false })
            }
        }
    }
}

/** Audio-language and subtitle choices read from the current stream's tracks. */
@kotlin.OptIn(UnstableApi::class)
@Composable
private fun TrackItems(player: androidx.media3.common.Player, close: () -> Unit) {
    val groups = player.currentTracks.groups
    val audio = groups.filter { it.type == C.TRACK_TYPE_AUDIO && it.length > 0 }
    val text = groups.filter { it.type == C.TRACK_TYPE_TEXT && it.length > 0 }
    fun label(g: androidx.media3.common.Tracks.Group, i: Int): String {
        val f = g.getTrackFormat(i)
        return f.label ?: f.language?.let { java.util.Locale.forLanguageTag(it).displayLanguage } ?: "Track ${i + 1}"
    }
    if (audio.size + audio.sumOf { it.length - 1 } > 1) {
        for (g in audio) for (i in 0 until g.length) DropdownMenuItem(
            text = { Text("Audio · ${label(g, i)}") }, leadingIcon = { Icon(Icons.AutoMirrored.Filled.VolumeUp, null) },
            trailingIcon = { if (g.isTrackSelected(i)) Icon(Icons.Filled.Check, null) },
            onClick = {
                player.trackSelectionParameters = player.trackSelectionParameters.buildUpon().setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, i)).build(); close()
            },
        )
    }
    if (text.isNotEmpty()) {
        DropdownMenuItem(text = { Text("Subtitles · Off") }, leadingIcon = { Icon(Icons.Filled.Subtitles, null) }, onClick = {
            player.trackSelectionParameters = player.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true).build(); close()
        })
        for (g in text) for (i in 0 until g.length) DropdownMenuItem(
            text = { Text("Subtitles · ${label(g, i)}") }, leadingIcon = { Icon(Icons.Filled.Subtitles, null) },
            trailingIcon = { if (g.isTrackSelected(i)) Icon(Icons.Filled.Check, null) },
            onClick = {
                player.trackSelectionParameters = player.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                    .setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, i)).build(); close()
            },
        )
    }
}

@Composable
private fun LiveInfo(channelId: String?, guide: Int, playing: Boolean, touched: () -> Unit) {
    @Suppress("UNUSED_VARIABLE") val g = guide
    val ch = channelId?.let { appModel.channel(it) }
    val nn = ch?.let { appModel.nowNext(it) }
    val pm = playbackManager
    Column(
        Modifier.navigationBarsPadding().padding(horizontal = 16.dp, vertical = 12.dp).fillMaxWidth().glass(28.dp).padding(18.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        val p = nn?.now
        if (p != null) {
            Row(verticalAlignment = Alignment.Top) {
                Text(p.title, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(Fmt.range(p.start, p.stop), fontSize = 12.sp, color = Color.White.copy(alpha = 0.6f))
            }
            LinearProgressIndicator(progress = { p.progress(System.currentTimeMillis()).toFloat() }, Modifier.fillMaxWidth().height(3.dp), color = Pal.accent, trackColor = Color.White.copy(alpha = 0.15f))
            nn.next?.let { Text("Next · ${it.title} · ${Fmt.time(it.start)}", fontSize = 12.sp, color = Color.White.copy(alpha = 0.6f), maxLines = 1, overflow = TextOverflow.Ellipsis) }
        } else if (ch != null) {
            Text(GroupLabel.parse(ch.group).title, fontSize = 14.sp, color = Color.White.copy(alpha = 0.6f))
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
            GlassIconButton(Icons.Filled.SkipPrevious, "Previous", 52.dp) { pm.zap(-1); touched() }
            GlassIconButton(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, "Play/pause", 64.dp, Pal.accent.copy(alpha = 0.35f)) { pm.togglePlayPause() }
            GlassIconButton(Icons.Filled.SkipNext, "Next", 52.dp) { pm.zap(1); touched() }
        }
    }
}

@Composable
private fun VodControls(playing: Boolean) {
    val pm = playbackManager
    var position by remember { mutableLongStateOf(0L) }
    var duration by remember { mutableLongStateOf(1L) }
    var scrubbing by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        while (true) {
            if (!scrubbing) {
                val d = pm.player.duration
                if (d != C.TIME_UNSET && d > 0) duration = d
                position = pm.player.currentPosition
            }
            delay(500)
        }
    }
    Column(
        Modifier.navigationBarsPadding().padding(horizontal = 16.dp, vertical = 12.dp).fillMaxWidth().glass(28.dp).padding(18.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Slider(
            value = position.toFloat(), onValueChange = { scrubbing = true; position = it.toLong() },
            onValueChangeFinished = { pm.player.seekTo(position); scrubbing = false }, valueRange = 0f..maxOf(duration, 1L).toFloat(),
            colors = SliderDefaults.colors(thumbColor = Pal.accent, activeTrackColor = Pal.accent),
        )
        Row(Modifier.fillMaxWidth()) {
            Text(Fmt.duration(position), fontSize = 12.sp, color = Color.White.copy(alpha = 0.6f))
            Spacer(Modifier.weight(1f))
            Text("-" + Fmt.duration(maxOf(0, duration - position)), fontSize = 12.sp, color = Color.White.copy(alpha = 0.6f))
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
            GlassIconButton(Icons.Filled.Replay10, "Back 15 seconds", 52.dp) { pm.seekBy(-15_000) }
            GlassIconButton(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, "Play/pause", 64.dp, Pal.accent.copy(alpha = 0.35f)) { pm.togglePlayPause() }
            GlassIconButton(Icons.Filled.Forward30, "Forward 30 seconds", 52.dp) { pm.seekBy(30_000) }
        }
    }
}
