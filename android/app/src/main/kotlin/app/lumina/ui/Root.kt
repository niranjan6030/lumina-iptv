package app.lumina.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.lumina.LuminaApp
import app.lumina.core.GroupLabel
import app.lumina.playback.PlayStatus
import kotlinx.coroutines.launch
import androidx.compose.runtime.rememberCoroutineScope

val appModel get() = LuminaApp.instance.model
val playbackManager get() = LuminaApp.instance.playback

@Composable
fun AppRoot() {
    val booted by appModel.booted.collectAsStateWithLifecycle()
    val sources by appModel.sources.collectAsStateWithLifecycle()
    val page = UiState.pages.lastOrNull()
    val showWelcome = booted && sources.isEmpty() && page == null

    Box(Modifier.fillMaxSize()) {
        AppBackground {
            if (showWelcome) WelcomeScreen() else MainTabs()
            if (page != null) {
                BackHandler { UiState.pop() }
                AppBackground { PageHost(page) }
            }
            StatusBanner()
        }
        if (UiState.showPlayer) PlayerScreen()
        UiState.pinRequest?.let { PinPrompt(it) }
    }
}

@Composable
private fun PageHost(p: Page) {
    when (p) {
        is Page.Movie -> MovieDetailScreen(p.item)
        is Page.SeriesPage -> SeriesDetailScreen(p.series)
        is Page.Schedule -> ScheduleScreen(p.channel)
        is Page.AddSource -> AddSourceScreen(p.mode)
        is Page.SourceEdit -> SourceEditScreen(p.source)
        Page.Groups -> GroupPickerScreen()
        Page.LockedGroups -> LockedGroupsScreen()
    }
}

@Composable
private fun MainTabs() {
    Box(Modifier.fillMaxSize()) {
        when (UiState.tab) {
            AppTab.LIVE -> LiveScreen()
            AppTab.LIBRARY -> LibraryScreen()
            AppTab.SEARCH -> SearchScreen()
            AppTab.SETTINGS -> SettingsScreen()
        }
        Column(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 8.dp)) {
            MiniPlayerBar()
            Spacer(Modifier.height(8.dp))
            NavBar()
        }
    }
}

@Composable
private fun NavBar() {
    Row(
        Modifier.padding(horizontal = 16.dp).fillMaxWidth().glass(32.dp, backdrop = Color(0xF00B0D17)).padding(6.dp),
        horizontalArrangement = Arrangement.SpaceEvenly,
    ) {
        NavItem(AppTab.LIVE, "Live", Icons.Filled.PlayCircle)
        NavItem(AppTab.LIBRARY, "Library", Icons.Filled.VideoLibrary)
        NavItem(AppTab.SEARCH, "Search", Icons.Filled.Search)
        NavItem(AppTab.SETTINGS, "Settings", Icons.Filled.Tune)
    }
}

@Composable
private fun RowScopeNavItemPlaceholder() {}

@Composable
private fun androidx.compose.foundation.layout.RowScope.NavItem(tab: AppTab, label: String, icon: ImageVector) {
    val selected = UiState.tab == tab
    Column(
        Modifier.weight(1f).glassIf(selected).clickable { UiState.tab = tab }.padding(vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(icon, label, Modifier.size(24.dp), tint = if (selected) Pal.accent else Color.White.copy(alpha = 0.85f))
        Text(label, fontSize = 11.sp, color = if (selected) Pal.accent else Color.White.copy(alpha = 0.85f), fontWeight = FontWeight.Medium)
    }
}

private fun Modifier.glassIf(on: Boolean): Modifier = if (on) this.glass(24.dp) else this

/** Slim progress / error line. Errors never block the UI. */
@Composable
private fun StatusBanner() {
    val loading by appModel.loading.collectAsStateWithLifecycle()
    val error by appModel.error.collectAsStateWithLifecycle()
    Column(Modifier.fillMaxWidth().statusBarsPadding().padding(top = 4.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        AnimatedVisibility(loading != null) {
            Row(Modifier.glass(50.dp).padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = Pal.accent)
                Text(loading ?: "", fontSize = 13.sp)
            }
        }
        AnimatedVisibility(error != null) {
            Text(
                error ?: "", fontSize = 13.sp,
                modifier = Modifier.padding(horizontal = 16.dp).glass(16.dp, Pal.live.copy(alpha = 0.25f)).clickable { appModel.clearError() }.padding(12.dp),
            )
        }
    }
}

/** Floating "now playing" capsule above the nav bar. */
@Composable
private fun MiniPlayerBar() {
    val ui by playbackManager.ui.collectAsStateWithLifecycle()
    val guide by appModel.guideVersion.collectAsStateWithLifecycle()
    if (!ui.hasMedia) return
    val ch = ui.channelId?.let { appModel.channel(it) }
    val now = remember(guide, ui.channelId) { ch?.let { appModel.nowNext(it).now?.title } }
    Row(
        Modifier.padding(horizontal = 16.dp).fillMaxWidth().glass(26.dp, backdrop = Color(0xF00B0D17)).clickable { UiState.showPlayer = true }.padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        LogoImage(ch?.logo, 40.dp, 10.dp)
        Column(Modifier.weight(1f)) {
            Text(ui.title, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                when (ui.status) { PlayStatus.Loading -> "Connecting…"; is PlayStatus.Failed -> "Can't play this channel"; else -> now ?: if (ui.isLive) "Live" else "" },
                fontSize = 12.sp, color = Color.White.copy(alpha = 0.6f), maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        if (ui.isLive) Icon(Icons.Filled.SkipPrevious, "Previous", Modifier.size(26.dp).clickable { playbackManager.zap(-1) })
        Icon(if (ui.status == PlayStatus.Playing || ui.buffering) Icons.Filled.Pause else Icons.Filled.PlayArrow, "Play/pause", Modifier.size(32.dp).clickable { playbackManager.togglePlayPause() })
        if (ui.isLive) Icon(Icons.Filled.SkipNext, "Next", Modifier.size(26.dp).clickable { playbackManager.zap(1) })
    }
}

// MARK: First run

@Composable
private fun WelcomeScreen() {
    val scope = rememberCoroutineScope()
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.weight(1f))
        Box(Modifier.size(96.dp).glass(30.dp), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.PlayCircle, null, Modifier.size(56.dp), tint = Pal.accent)
        }
        Spacer(Modifier.height(20.dp))
        Text("Lumina", fontSize = 40.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text("Your live TV, movies and series.\nOne calm place, on your phone and in your car.", textAlign = TextAlign.Center, color = Color.White.copy(alpha = 0.65f))
        Spacer(Modifier.weight(1f))
        Button({ UiState.push(Page.AddSource(AddMode.XTREAM)) }, Modifier.fillMaxWidth()) { Text("Sign in with Xtream login") }
        Spacer(Modifier.height(10.dp))
        OutlinedButton({ UiState.push(Page.AddSource(AddMode.M3U)) }, Modifier.fillMaxWidth()) { Text("Add an M3U link") }
        Spacer(Modifier.height(10.dp))
        OutlinedButton({ UiState.push(Page.AddSource(AddMode.FILE)) }, Modifier.fillMaxWidth()) { Text("Import a playlist file") }
        TextButton({ scope.launch { appModel.addDemo() } }) { Text("Try the demo first") }
        Text(
            "Lumina doesn't include any channels. Add playlists from a provider you have the right to use.",
            fontSize = 11.sp, color = Color.White.copy(alpha = 0.4f), textAlign = TextAlign.Center,
        )
    }
}

// MARK: Parental PIN

@Composable
private fun PinPrompt(req: PinRequest) {
    var pin by remember { mutableStateOf("") }
    var wrong by remember { mutableStateOf(false) }
    fun attempt(): Boolean = appModel.unlock(req.group, pin)
    AlertDialog(
        onDismissRequest = { UiState.pinRequest = null },
        icon = { Icon(Icons.Filled.Lock, null, tint = Pal.accent) },
        title = { Text("Enter PIN") },
        text = {
            Column {
                Text(GroupLabel.parse(req.group).title, color = Color.White.copy(alpha = 0.6f))
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = pin,
                    onValueChange = {
                        pin = it.filter(Char::isDigit).take(8); wrong = false
                        // auto-unlock the moment it's right
                        if (pin.length >= 4 && appModel.user.value.verifyPin(pin)) { appModel.unlock(req.group, pin); UiState.pinRequest = null; req.onSuccess() }
                    },
                    singleLine = true, isError = wrong, visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword), modifier = Modifier.fillMaxWidth(),
                )
                if (wrong) Text("Wrong PIN", color = Color(0xFFFFD166), fontSize = 12.sp)
            }
        },
        confirmButton = {
            TextButton({ if (attempt()) { UiState.pinRequest = null; req.onSuccess() } else { wrong = true; pin = "" } }) { Text("Unlock") }
        },
        dismissButton = { TextButton({ UiState.pinRequest = null }) { Text("Cancel") } },
    )
}
