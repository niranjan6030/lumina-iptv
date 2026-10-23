package app.lumina.ui

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.automirrored.filled.ViewList
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.lumina.ReminderReceiver
import app.lumina.core.CatchupBuilder
import app.lumina.core.Channel
import app.lumina.core.GroupLabel
import app.lumina.core.Programme
import app.lumina.core.Reminder
import app.lumina.playback.VodRequest
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.Calendar

@Composable
fun LargeTitle(text: String, modifier: Modifier = Modifier, trailing: @Composable () -> Unit = {}) {
    Row(modifier.fillMaxWidth().statusBarsPadding().padding(start = 20.dp, end = 16.dp, top = 28.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(text, fontSize = 34.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
        trailing()
    }
}

@Composable
fun PageHeader(title: String, trailing: @Composable () -> Unit = {}) {
    Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        GlassIconButton(Icons.AutoMirrored.Filled.ArrowBack, "Back") { UiState.pop() }
        Text(title, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
        trailing()
    }
}

private val bottomInset = 168.dp // clears the floating mini player + nav bar

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LiveScreen() {
    val model = appModel
    val lib by model.library.collectAsStateWithLifecycle()
    val user by model.user.collectAsStateWithLifecycle()
    val guide by model.guideVersion.collectAsStateWithLifecycle()
    val loading by model.loading.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val now by produceState(System.currentTimeMillis()) { while (true) { delay(30_000); value = System.currentTimeMillis() } }

    val favs = remember(lib, user.favorites) { model.favoriteChannels() }
    val recents = remember(lib, user.recents) { model.recentChannels() }
    val group = UiState.liveGroup
    val filter = UiState.liveFilter ?: if (favs.isEmpty()) "all" else "fav"
    val channels = when {
        group != null -> lib.byGroup[group] ?: emptyList()
        filter == "fav" -> favs
        filter == "recent" -> recents
        else -> lib.visible
    }
    val title = when {
        group != null -> GroupLabel.parse(group).title
        filter == "fav" -> "Favorites"
        filter == "recent" -> "Recent"
        else -> "All Channels"
    }
    val grid = user.settings.gridLayout
    var refreshing by remember { mutableStateOf(false) }

    PullToRefreshBox(refreshing, onRefresh = { scope.launch { refreshing = true; model.refreshAll(); refreshing = false } }) {
        Column(Modifier.fillMaxSize()) {
            LargeTitle(title) {
                GlassIconButton(if (grid) Icons.AutoMirrored.Filled.ViewList else Icons.Filled.GridView, "Layout") { model.updateUser { it.copy(settings = it.settings.copy(gridLayout = !grid)) } }
            }
            Box(Modifier.weight(1f)) {
                if (channels.isEmpty()) {
                    Column(Modifier.fillMaxSize().padding(top = 60.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        FilterRow(favs.isNotEmpty(), recents.isNotEmpty(), filter, group, model.lastChannel(), user.settings.resumeLastChannel, channels)
                        Spacer(Modifier.height(48.dp))
                        Text(if (loading != null) "Loading…" else if (filter == "fav" && group == null) "No favorites yet" else "Nothing here", fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                        Text(if (filter == "fav" && group == null) "Long-press a channel and choose Favorite." else "Pull down to refresh your playlist.", color = Color.White.copy(alpha = 0.55f))
                    }
                } else if (grid) {
                    LazyVerticalGrid(
                        GridCells.Adaptive(150.dp), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = bottomInset),
                        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        item(span = { GridItemSpan(maxLineSpan) }) { FilterRow(favs.isNotEmpty(), recents.isNotEmpty(), filter, group, model.lastChannel(), user.settings.resumeLastChannel, channels) }
                        gridItems(channels, key = { it.id }) { ch -> ChannelCard(ch, now, guide, channels) }
                    }
                } else {
                    LazyColumn(contentPadding = PaddingValues(bottom = bottomInset), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        item { FilterRow(favs.isNotEmpty(), recents.isNotEmpty(), filter, group, model.lastChannel(), user.settings.resumeLastChannel, channels) }
                        items(channels, key = { it.id }) { ch -> ChannelRow(ch, now, guide, channels) }
                    }
                }
            }
        }
    }
}

@Composable
private fun FilterRow(hasFav: Boolean, hasRecent: Boolean, filter: String, group: String?, last: Channel?, showResume: Boolean, ctx: List<Channel>) {
    Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (hasFav) Chip("Favorites", group == null && filter == "fav", Icons.Filled.Star) { UiState.liveGroup = null; UiState.liveFilter = "fav" }
        if (hasRecent) Chip("Recent", group == null && filter == "recent", Icons.Filled.History) { UiState.liveGroup = null; UiState.liveFilter = "recent" }
        Chip("All", group == null && filter == "all", Icons.Filled.Bookmark) { UiState.liveGroup = null; UiState.liveFilter = "all" }
        Chip(if (group != null) GroupLabel.parse(group).title else "Groups", group != null, Icons.Filled.FilterList) { UiState.push(Page.Groups) }
        if (last != null && showResume) Chip("Resume ${last.name}", false, Icons.Filled.PlayArrow) { UiState.play(last, ctx) }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ChannelRow(ch: Channel, now: Long, guide: Int, list: List<Channel>) {
    val model = appModel
    @Suppress("UNUSED_VARIABLE") val g = guide // re-render when guide data arrives
    val nn = model.nowNext(ch, now)
    val locked = model.isLocked(ch.group)
    var menu by remember { mutableStateOf(false) }
    Box(Modifier.padding(horizontal = 16.dp)) {
        Row(
            Modifier.fillMaxWidth().rowCard().combinedClickable(onClick = { UiState.play(ch, list) }, onLongClick = { menu = true }).padding(10.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            LogoImage(ch.logo, 54.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    ch.number?.let { Text("$it", fontSize = 12.sp, color = Color.White.copy(alpha = 0.4f)) }
                    Text(ch.name, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    ch.primary?.quality?.label?.let { QualityBadge(it) }
                    if (ch.hasCatchup) Icon(Icons.Filled.History, null, Modifier.size(12.dp), tint = Color.White.copy(alpha = 0.4f))
                }
                val p = nn.now
                if (p != null) {
                    Text(p.title, fontSize = 14.sp, color = Color.White.copy(alpha = 0.65f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    LinearProgressIndicator(progress = { p.progress(now).toFloat() }, Modifier.fillMaxWidth().height(3.dp), color = Pal.accent, trackColor = Color.White.copy(alpha = 0.15f))
                } else {
                    Text(GroupLabel.parse(ch.group).title, fontSize = 14.sp, color = Color.White.copy(alpha = 0.4f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            if (locked) Icon(Icons.Filled.Lock, null, Modifier.size(18.dp), tint = Color.White.copy(alpha = 0.6f))
            else if (model.isFavorite(ch)) Icon(Icons.Filled.Star, null, Modifier.size(16.dp), tint = Color(0xFFFFD166))
        }
        ChannelMenu(menu, { menu = false }, ch)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ChannelCard(ch: Channel, now: Long, guide: Int, list: List<Channel>) {
    val model = appModel
    @Suppress("UNUSED_VARIABLE") val g = guide
    val nn = model.nowNext(ch, now)
    var menu by remember { mutableStateOf(false) }
    Box {
        Column(
            Modifier.fillMaxWidth().rowCard(18.dp).combinedClickable(onClick = { UiState.play(ch, list) }, onLongClick = { menu = true }).padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                LogoImage(ch.logo, 44.dp, 10.dp)
                Spacer(Modifier.weight(1f))
                if (model.isFavorite(ch)) Icon(Icons.Filled.Star, null, Modifier.size(14.dp), tint = Color(0xFFFFD166))
            }
            Text(ch.name, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(nn.now?.title ?: GroupLabel.parse(ch.group).title, fontSize = 12.sp, color = Color.White.copy(alpha = 0.6f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            nn.now?.let { LinearProgressIndicator(progress = { it.progress(now).toFloat() }, Modifier.fillMaxWidth().height(3.dp), color = Pal.accent, trackColor = Color.White.copy(alpha = 0.15f)) }
        }
        ChannelMenu(menu, { menu = false }, ch)
    }
}

@Composable
private fun ChannelMenu(expanded: Boolean, dismiss: () -> Unit, ch: Channel) {
    val model = appModel
    DropdownMenu(expanded, dismiss) {
        DropdownMenuItem(
            text = { Text(if (model.isFavorite(ch)) "Remove favorite" else "Add to favorites") },
            leadingIcon = { Icon(Icons.Filled.Star, null) }, onClick = { model.toggleFavorite(ch); dismiss() },
        )
        DropdownMenuItem(text = { Text("Show schedule") }, leadingIcon = { Icon(Icons.Filled.CalendarMonth, null) }, onClick = { dismiss(); UiState.push(Page.Schedule(ch)) })
        DropdownMenuItem(text = { Text("Hide channel") }, leadingIcon = { Icon(Icons.Filled.VisibilityOff, null) }, onClick = { model.hide(ch); dismiss() })
    }
}

// MARK: Group picker

@Composable
fun GroupPickerScreen() {
    val lib by appModel.library.collectAsStateWithLifecycle()
    val user by appModel.user.collectAsStateWithLifecycle()
    var query by remember { mutableStateOf("") }
    var region by remember { mutableStateOf<String?>(null) }
    val regions = remember(lib) { lib.browseGroups.mapNotNull { it.label.region }.distinct().sorted() }
    val groups = remember(lib, query, region) {
        lib.browseGroups.filter { g -> (region == null || g.label.region == region) && (query.isEmpty() || g.label.title.contains(query, true) || g.id.contains(query, true)) }
    }
    Column(Modifier.fillMaxSize()) {
        PageHeader("Groups")
        OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp), singleLine = true, placeholder = { Text("Search groups") })
        if (regions.isNotEmpty() && user.settings.showGroupRegions) {
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(16.dp, 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Chip("All", region == null) { region = null }
                regions.forEach { r -> Chip(r, region == r) { region = r } }
            }
        }
        LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
            items(groups, key = { it.id }) { g ->
                Row(
                    Modifier.fillMaxWidth().clickable { UiState.liveGroup = g.id; UiState.liveFilter = null; UiState.tab = AppTab.LIVE; UiState.pop() }.padding(horizontal = 20.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(g.label.title, fontSize = 16.sp)
                        g.label.region?.let { Text(it, fontSize = 12.sp, color = Color.White.copy(alpha = 0.5f)) }
                    }
                    if (g.id in user.lockedGroups) Icon(Icons.Filled.Lock, null, Modifier.size(16.dp), tint = Color.White.copy(alpha = 0.6f))
                    Spacer(Modifier.width(10.dp))
                    Text("${g.count}", color = Color.White.copy(alpha = 0.5f))
                }
            }
        }
    }
}

// MARK: Schedule / catch-up / reminders

@Composable
fun ScheduleScreen(channel: Channel) {
    val model = appModel
    val guide by model.guideVersion.collectAsStateWithLifecycle()
    val user by model.user.collectAsStateWithLifecycle()
    val ctx = LocalContext.current
    var day by remember { mutableIntStateOf(0) }
    val minDay = if (channel.hasCatchup) -minOf(channel.catchup?.days ?: 0, 3) else 0
    val notifPerm = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    LaunchedEffect(channel.id) { model.ensureGuide(channel) }

    val dayStart = remember(day) {
        Calendar.getInstance().apply { set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0); add(Calendar.DAY_OF_YEAR, day) }.timeInMillis
    }
    val programmes = remember(guide, day) { model.schedule(channel, dayStart, dayStart + 86_400_000L) }
    val now = System.currentTimeMillis()

    Column(Modifier.fillMaxSize()) {
        PageHeader(channel.name)
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (d in minDay..2) Chip(dayLabel(d), day == d) { day = d }
        }
        if (programmes.isEmpty()) {
            Text("No guide data for this day.", Modifier.padding(24.dp), color = Color.White.copy(alpha = 0.55f))
        }
        LazyColumn(contentPadding = PaddingValues(16.dp, 12.dp, 16.dp, 32.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(programmes, key = { it.id }) { p ->
                val isNow = p.start <= now && p.stop > now
                val isPast = p.stop <= now
                Column(Modifier.fillMaxWidth().rowCard().padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(Fmt.range(p.start, p.stop), fontSize = 12.sp, color = Color.White.copy(alpha = 0.6f))
                        if (isNow) LiveDot()
                        Spacer(Modifier.weight(1f))
                        when {
                            isNow -> Button({ UiState.pop(); UiState.play(channel) }, contentPadding = PaddingValues(horizontal = 14.dp)) { Text("Watch") }
                            isPast -> {
                                val off = model.epgOffset(channel)
                                val url = CatchupBuilder.url(channel, p.copy(start = p.start - off, stop = p.stop - off))
                                if (url != null) Chip("Replay", false, Icons.Filled.History) {
                                    val ep = channel.primary?.copy(url = url) ?: return@Chip
                                    UiState.pop()
                                    UiState.play(VodRequest("cu:${channel.id}:${p.start}", "${channel.name} · ${p.title}", ep, channel.logo))
                                }
                            }
                            else -> {
                                val r = Reminder(channel.id, channel.name, p.title, p.start)
                                val on = user.reminders.any { it.id == r.id }
                                Icon(
                                    if (on) Icons.Filled.NotificationsActive else Icons.Filled.Notifications, "Reminder",
                                    Modifier.size(24.dp).clickable {
                                        if (on) { ReminderReceiver.cancel(ctx, r); model.updateUser { u -> u.copy(reminders = u.reminders.filter { it.id != r.id }) } }
                                        else {
                                            if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) notifPerm.launch(Manifest.permission.POST_NOTIFICATIONS)
                                            ReminderReceiver.schedule(ctx, r)
                                            model.updateUser { u -> u.copy(reminders = u.reminders + r) }
                                        }
                                    },
                                    tint = if (on) Pal.accent else Color.White,
                                )
                            }
                        }
                    }
                    Text(p.title, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                    p.desc?.takeIf { it.isNotEmpty() }?.let { Text(it, fontSize = 13.sp, color = Color.White.copy(alpha = 0.6f), maxLines = 3, overflow = TextOverflow.Ellipsis) }
                    if (isNow) LinearProgressIndicator(progress = { p.progress(now).toFloat() }, Modifier.fillMaxWidth().height(3.dp), color = Pal.accent, trackColor = Color.White.copy(alpha = 0.15f))
                }
            }
        }
    }
}

private fun dayLabel(d: Int): String = when (d) {
    0 -> "Today"; 1 -> "Tomorrow"; -1 -> "Yesterday"
    else -> java.text.SimpleDateFormat("EEE", java.util.Locale.getDefault()).format(java.util.Date(System.currentTimeMillis() + d * 86_400_000L))
}
