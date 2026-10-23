package app.lumina

import android.app.Application
import android.net.Uri
import app.lumina.core.*
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import java.io.File

data class GroupInfo(val id: String, val label: GroupLabel, val count: Int, val adultLooking: Boolean)

data class Library(
    val visible: List<Channel> = emptyList(),
    val byGroup: Map<String, List<Channel>> = emptyMap(),
    val browseGroups: List<GroupInfo> = emptyList(),
    val allGroups: List<GroupInfo> = emptyList(),
    val movies: List<VodItem> = emptyList(),
    val series: List<Series> = emptyList(),
    val version: Int = 0,
)

@Serializable
private class GuideCache(
    val programmes: List<Programme>, val channelNames: Map<String, List<String>>,
    val channelIcons: Map<String, String>, val fetchedAt: Long,
)

@Serializable
class Backup(val sources: List<Source>, val user: UserData, val version: Int = 1)

class ContinueItem(val id: String, val progress: WatchProgress)

/** Single source of truth shared by the phone UI and the Android Auto browse tree (same process). */
class AppModel(private val app: Application) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val loader = PlaylistLoader(Net.client, app.cacheDir)
    private val root = File(app.filesDir, "lumina").apply { mkdirs() }
    private val sourcesFile get() = File(root, "sources.json")
    private val userFile get() = File(root, "user.json")
    private val guideFile get() = File(root, "guide-cache.json")
    private fun snapFile(id: String) = File(File(root, "snapshots").apply { mkdirs() }, "$id.json")
    val importsDir get() = File(root, "imports").apply { mkdirs() }

    // ---- Observable state
    private val _sources = MutableStateFlow<List<Source>>(emptyList())
    val sources: StateFlow<List<Source>> = _sources.asStateFlow()
    private val _user = MutableStateFlow(UserData())
    val user: StateFlow<UserData> = _user.asStateFlow()
    private val _library = MutableStateFlow(Library())
    val library: StateFlow<Library> = _library.asStateFlow()
    private val _guideVersion = MutableStateFlow(0)
    val guideVersion: StateFlow<Int> = _guideVersion.asStateFlow()
    private val _loading = MutableStateFlow<String?>(null)
    val loading: StateFlow<String?> = _loading.asStateFlow()
    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()
    private val _accounts = MutableStateFlow<Map<String, XtreamAccount>>(emptyMap())
    val accounts: StateFlow<Map<String, XtreamAccount>> = _accounts.asStateFlow()
    private val _booted = MutableStateFlow(false)
    val booted: StateFlow<Boolean> = _booted.asStateFlow()
    private val _guideUpdatedAt = MutableStateFlow<Long?>(null)
    val guideUpdatedAt: StateFlow<Long?> = _guideUpdatedAt.asStateFlow()
    private val _dead = MutableStateFlow<Set<String>>(emptySet())
    val deadChannels: StateFlow<Set<String>> = _dead.asStateFlow()
    private val _scan = MutableStateFlow<Pair<Int, Int>?>(null)
    val scanProgress: StateFlow<Pair<Int, Int>?> = _scan.asStateFlow()
    private val _unlocked = MutableStateFlow<Set<String>>(emptySet())
    val unlocked: StateFlow<Set<String>> = _unlocked.asStateFlow()

    /** Completes once saved data is loaded; Android Auto waits on this before serving its tree. */
    val ready = CompletableDeferred<Unit>()

    // ---- Internals
    private val snapshots = HashMap<String, SourceSnapshot>()
    @Volatile private var allChannels: List<Channel> = emptyList()
    @Volatile private var channelById: Map<String, Channel> = emptyMap()
    @Volatile private var visibleIds: Set<String> = emptySet()
    @Volatile private var searchIndex = SearchIndex(emptyList(), emptyList(), emptyList())
    @Volatile private var episodesBySeries: Map<String, List<Episode>> = emptyMap()
    @Volatile private var epg = EpgIndex()
    @Volatile private var guideKeys: Map<String, String> = emptyMap()
    @Volatile private var keyToChannels: Map<String, List<Channel>> = emptyMap()
    @Volatile private var offsets: Map<String, Long> = emptyMap()
    private val fetchedEpisodes = HashMap<String, List<Episode>>()
    private val bootMutex = Mutex()
    private val guideMutex = Mutex()
    private var userSaveJob: Job? = null
    private var scanJob: Job? = null

    // MARK: Boot

    suspend fun bootstrap() {
        bootMutex.withLock { bootLocked() }
    }

    private suspend fun bootLocked() {
        if (_booted.value) return
        withContext(Dispatchers.IO) {
            _sources.value = JsonFile.read<List<Source>>(sourcesFile) ?: emptyList()
            _user.value = JsonFile.read<UserData>(userFile) ?: UserData()
            offsets = _sources.value.associate { it.id to it.epgOffsetMinutes * 60_000L }
            for (s in _sources.value.filter { it.enabled }) {
                JsonFile.read<SourceSnapshot>(snapFile(s.id))?.let { snapshots[s.id] = it; _accounts.update { a -> a + (s.id to (it.account ?: return@let)) } }
            }
        }
        rebuild()
        _booted.value = true
        ready.complete(Unit)
        scope.launch {
            refreshGuide(force = false)
            refreshStaleSources()
        }
    }

    // MARK: Sources

    suspend fun addSource(source: Source) {
        _loading.value = "Connecting to ${source.name}…"
        try {
            val snap = loader.load(source)
            val s = source.copy(lastRefreshed = System.currentTimeMillis())
            _sources.update { it + s }
            snapshots[s.id] = snap
            snap.account?.let { a -> _accounts.update { it + (s.id to a) } }
            offsets = offsets + (s.id to s.epgOffsetMinutes * 60_000L)
            saveSources(); persist(snap)
            rebuild()
            scope.launch { refreshGuide(force = true) }
        } finally { _loading.value = null }
    }

    fun updateSource(src: Source) {
        _sources.update { list -> list.map { if (it.id == src.id) src else it } }
        offsets = offsets + (src.id to src.epgOffsetMinutes * 60_000L)
        saveSources()
        scope.launch { rebuild(); bumpGuide() }
    }

    fun removeSource(id: String) {
        _sources.update { list -> list.filter { it.id != id } }
        snapshots.remove(id); _accounts.update { it - id }
        snapFile(id).delete()
        saveSources()
        scope.launch { rebuild() }
    }

    suspend fun refresh(id: String) {
        val src = _sources.value.firstOrNull { it.id == id } ?: return
        _loading.value = "Updating ${src.name}…"
        try {
            val snap = loader.load(src)
            _sources.update { l -> l.map { if (it.id == id) it.copy(lastRefreshed = System.currentTimeMillis()) else it } }
            snapshots[id] = snap
            snap.account?.let { a -> _accounts.update { it + (id to a) } }
            saveSources(); persist(snap)
            rebuild()
            _error.value = null
        } catch (e: Exception) {
            _error.value = "${src.name}: ${e.message}"
        } finally { _loading.value = null }
    }

    suspend fun refreshAll() {
        for (s in _sources.value.filter { it.enabled }) refresh(s.id)
        refreshGuide(force = true)
    }

    private suspend fun refreshStaleSources() {
        val maxAge = maxOf(1, _user.value.settings.guideRefreshHours) * 3_600_000L
        for (s in _sources.value.filter { it.enabled && it.needsNetwork() }) {
            val t = s.lastRefreshed
            if (t != null && System.currentTimeMillis() - t < maxAge) continue
            refresh(s.id)
        }
        refreshGuide(force = false)
    }

    private fun Source.needsNetwork() = when (val k = kind) {
        SourceKind.Demo -> false
        is SourceKind.M3u -> !(k.url.startsWith("file:") || k.url.startsWith("/"))
        is SourceKind.Xtream -> true
    }

    /** Copies a user-picked playlist into app storage so it survives the picker's permission. */
    suspend fun importPlaylist(uri: Uri, displayName: String?): Source = withContext(Dispatchers.IO) {
        val name = displayName?.takeIf { it.isNotBlank() } ?: "Playlist"
        val dst = File(importsDir, "${System.currentTimeMillis()}-${name.replace(Regex("[^A-Za-z0-9._-]"), "_")}")
        app.contentResolver.openInputStream(uri)?.use { i -> dst.outputStream().use { i.copyTo(it) } }
            ?: throw LuminaException(LuminaException.Kind.NOT_A_PLAYLIST)
        Source(name = name.substringBeforeLast('.'), kind = SourceKind.M3u(dst.absolutePath))
    }

    suspend fun handleOpen(uri: Uri, name: String?) {
        try { addSource(importPlaylist(uri, name)) } catch (e: Exception) { _error.value = e.message }
    }

    suspend fun addDemo() {
        if (_sources.value.any { it.kind == SourceKind.Demo }) return
        runCatching { addSource(Source(name = "Demo", kind = SourceKind.Demo)) }
    }

    fun clearError() { _error.value = null }

    private fun saveSources() { val s = _sources.value; scope.launch(Dispatchers.IO) { JsonFile.write(sourcesFile, s) } }
    private fun persist(snap: SourceSnapshot) { scope.launch(Dispatchers.IO) { JsonFile.write(snapFile(snap.sourceId), snap) } }

    // MARK: Derived library

    private class Derived(
        val channels: List<Channel>, val aliases: Map<String, String>, val groups: List<GroupInfo>,
        val movies: List<VodItem>, val series: List<Series>, val episodes: Map<String, List<Episode>>, val search: SearchIndex,
    )

    private fun derive(snaps: List<SourceSnapshot>, order: List<String>, merge: Boolean): Derived {
        val sorted = snaps.sortedBy { order.indexOf(it.sourceId).let { i -> if (i < 0) 0 else i } }
        var channels = sorted.flatMap { it.channels }
        var aliases = emptyMap<String, String>()
        if (merge) { val r = ChannelMerger.mergeDuplicates(channels); channels = r.channels; aliases = r.aliases }
        val counts = LinkedHashMap<String, Int>()
        for (c in channels) counts[c.group] = (counts[c.group] ?: 0) + 1
        val groups = counts.map { (g, n) -> GroupInfo(g, GroupLabel.parse(g), n, ParentalHeuristics.looksAdult(g)) }
        val movies = sorted.flatMap { it.movies }
        val series = sorted.flatMap { it.series }
        return Derived(channels, aliases, groups, movies, series, sorted.flatMap { it.episodes }.groupBy { it.seriesId }, SearchIndex(channels, movies, series))
    }

    suspend fun rebuild() {
        val enabled = _sources.value.filter { it.enabled }.map { it.id }.toSet()
        val snaps = snapshots.values.filter { it.sourceId in enabled }
        val order = _sources.value.map { it.id }
        val merge = _user.value.settings.mergeDuplicates
        val d = withContext(Dispatchers.Default) { derive(snaps, order, merge) }
        allChannels = d.channels
        channelById = d.channels.associateBy { it.id }
        episodesBySeries = d.episodes
        searchIndex = d.search
        if (d.aliases.isNotEmpty()) {
            val u = _user.value.applyAliases(d.aliases)
            if (u != _user.value) { _user.value = u; saveUserSoon() }
        }
        publishLibrary(d.groups, d.movies, d.series)
        computeGuideKeys()
    }

    private var cachedGroups: List<GroupInfo> = emptyList()
    private var cachedMovies: List<VodItem> = emptyList()
    private var cachedSeries: List<Series> = emptyList()

    private fun publishLibrary(groups: List<GroupInfo> = cachedGroups, movies: List<VodItem> = cachedMovies, series: List<Series> = cachedSeries) {
        cachedGroups = groups; cachedMovies = movies; cachedSeries = series
        val u = _user.value
        val adult = if (u.settings.hideAdultByDefault) groups.filter { it.adultLooking }.map { it.id }.toSet() else emptySet()
        val dead = _dead.value
        val visible = allChannels.filter {
            it.id !in u.hiddenChannels && it.group !in u.hiddenGroups && it.group !in adult && it.id !in dead
        }
        visibleIds = visible.mapTo(HashSet()) { it.id }
        val byGroup = visible.groupBy { it.group }
        val browse = groups.mapNotNull { g -> byGroup[g.id]?.let { g.copy(count = it.size) } }
        _library.value = Library(visible, byGroup, browse, groups, movies, series, _library.value.version + 1)
    }

    // MARK: Lookups

    fun channel(id: String): Channel? = channelById[id]
    fun favoriteChannels(): List<Channel> = _user.value.favorites.mapNotNull { channelById[it] }.filter { it.id in visibleIds }
    fun recentChannels(): List<Channel> = _user.value.recents.mapNotNull { channelById[it] }.filter { it.id in visibleIds }
    fun lastChannel(): Channel? = _user.value.lastChannelId?.let { channelById[it] }
    fun channelsIn(group: String): List<Channel> = _library.value.byGroup[group] ?: emptyList()
    val hasSources: Boolean get() = _sources.value.isNotEmpty()

    fun isLocked(group: String): Boolean {
        val u = _user.value
        return u.hasPin && group in u.lockedGroups && group !in _unlocked.value
    }

    fun unlock(group: String, pin: String): Boolean {
        if (!_user.value.verifyPin(pin)) return false
        _unlocked.update { it + group }
        return true
    }

    fun lockAll() { _unlocked.value = emptySet() }

    // MARK: Guide

    fun epgOffset(c: Channel): Long = offsets[c.sourceId] ?: 0L

    /** Programmes come back already shifted by the source's guide offset, so callers can compare with real time. */
    fun nowNext(c: Channel, at: Long = System.currentTimeMillis()): NowNext {
        val k = guideKeys[c.id] ?: return NowNext(null, null)
        val off = offsets[c.sourceId] ?: 0L
        val r = epg.nowNext(k, at, off)
        if (off == 0L) return r
        fun shift(p: Programme?) = p?.copy(start = p.start + off, stop = p.stop + off)
        return NowNext(shift(r.now), shift(r.next))
    }

    fun schedule(c: Channel, from: Long, to: Long): List<Programme> {
        val k = guideKeys[c.id] ?: return emptyList()
        val off = offsets[c.sourceId] ?: 0L
        return epg.programmes(k).filter { it.stop + off > from && it.start + off < to }.map { it.copy(start = it.start + off, stop = it.stop + off) }
    }

    private fun bumpGuide() { _guideVersion.update { it + 1 } }

    private suspend fun computeGuideKeys() {
        val chans = allChannels
        val idx = epg
        val (keys, rev) = withContext(Dispatchers.Default) {
            val m = HashMap<String, String>()
            val r = HashMap<String, MutableList<Channel>>()
            for (c in chans) idx.guideKey(c)?.let { k -> m[c.id] = k; r.getOrPut(k) { ArrayList() }.add(c) }
            m to r
        }
        guideKeys = keys; keyToChannels = rev
        bumpGuide()
    }

    suspend fun refreshGuide(force: Boolean) = guideMutex.withLock { loadGuide(force) }

    private suspend fun loadGuide(force: Boolean) {
        val maxAge = maxOf(1, _user.value.settings.guideRefreshHours) * 3_600_000L
        val srcs = _sources.value.filter { it.enabled }
        val urls = LinkedHashSet<String>()
        for (s in srcs) snapshots[s.id]?.epgUrls?.let { urls.addAll(it) }
        val ua = srcs.firstNotNullOfOrNull { it.userAgent }
        val hasDemo = srcs.any { it.kind == SourceKind.Demo }

        if (!force && epg.isEmpty) {
            val cache = withContext(Dispatchers.IO) { JsonFile.read<GuideCache>(guideFile) }
            if (cache != null) {
                var idx = withContext(Dispatchers.Default) { EpgIndex.of(cache.programmes, cache.channelNames, cache.channelIcons) }
                if (hasDemo) idx = idx.merge(DemoContent.guide())
                epg = idx; _guideUpdatedAt.value = cache.fetchedAt
                computeGuideKeys()
                if (System.currentTimeMillis() - cache.fetchedAt < maxAge) return
            } else if (hasDemo) { epg = DemoContent.guide(); computeGuideKeys() }
        } else if (hasDemo && epg.isEmpty) { epg = DemoContent.guide(); computeGuideKeys() }
        if (urls.isEmpty()) return
        _guideUpdatedAt.value?.let { if (!force && System.currentTimeMillis() - it < maxAge) return }

        val channels = allChannels
        val wantedIds = channels.mapNotNull { it.epgId?.lowercase() }.toSet()
        val nameKeys = HashSet<String>()
        for (c in channels) { nameKeys += NameNormalizer.key(c.name); c.epgId?.let { nameKeys += NameNormalizer.key(it) } }
        val now = System.currentTimeMillis()
        val maxCatchup = channels.mapNotNull { it.catchup?.days }.maxOrNull() ?: 0
        val window = (now - maxOf(1, minOf(maxCatchup, 3)) * 86_400_000L)..(now + 2 * 86_400_000L)

        val progs = ArrayList<Programme>(); val names = HashMap<String, List<String>>(); val icons = HashMap<String, String>()
        var failures = 0
        for (u in urls) {
            try {
                val r = loader.loadGuide(u, ua, wantedIds, nameKeys, window)
                progs += r.programmes; names.putAll(r.channelNames); icons.putAll(r.channelIcons)
            } catch (e: Exception) { failures++ }
        }
        if (progs.isEmpty()) {
            if (failures > 0 && epg.isEmpty) _error.value = "The TV guide couldn't be loaded. Channels still play; check the guide URL in Settings."
            return
        }
        var merged = withContext(Dispatchers.Default) { EpgIndex.of(progs, names, icons) }
        if (hasDemo) merged = merged.merge(DemoContent.guide())
        epg = merged
        _guideUpdatedAt.value = System.currentTimeMillis()
        computeGuideKeys()
        scope.launch(Dispatchers.IO) {
            JsonFile.write(guideFile, GuideCache(progs.map { p -> p.desc?.takeIf { it.length > 300 }?.let { p.copy(desc = it.take(300)) } ?: p }, names, icons, System.currentTimeMillis()))
        }
    }

    /** Panels without an XMLTV feed still answer per-channel guide requests. */
    suspend fun ensureGuide(c: Channel) {
        if (guideKeys.containsKey(c.id)) return
        val src = _sources.value.firstOrNull { it.id == c.sourceId } ?: return
        val k = src.kind as? SourceKind.Xtream ?: return
        val last = c.id.substringAfterLast(':')
        if (!last.startsWith("x")) return
        val server = XtreamClient.normalizeServer(k.server) ?: return
        val progs = runCatching { XtreamClient(server, k.username, k.password).fullDayEpg(last.drop(1), c.id.lowercase()) }.getOrNull() ?: return
        if (progs.isEmpty()) return
        epg = epg.merge(EpgIndex.of(progs))
        guideKeys = guideKeys + (c.id to c.id.lowercase())
        bumpGuide()
    }

    // MARK: Search

    fun search(q: String): SearchResults {
        val r = searchIndex.search(q, 40)
        return r.copy(channels = r.channels.filter { it.id in visibleIds })
    }

    fun programmeSearch(q: String): List<Pair<Programme, Channel>> {
        val now = System.currentTimeMillis()
        return epg.search(q, now, now + 36 * 3_600_000L, 30).mapNotNull { p ->
            keyToChannels[p.channel]?.firstOrNull { it.id in visibleIds }?.let { p to it }
        }
    }

    // MARK: User data

    fun updateUser(change: (UserData) -> UserData) {
        val old = _user.value
        val u = change(old)
        if (u == old) return
        _user.value = u
        saveUserSoon()
        if (u.settings.mergeDuplicates != old.settings.mergeDuplicates) scope.launch { rebuild() }
        else if (u.hiddenChannels != old.hiddenChannels || u.hiddenGroups != old.hiddenGroups || u.settings.hideAdultByDefault != old.settings.hideAdultByDefault) publishLibrary()
    }

    private fun saveUserSoon() {
        userSaveJob?.cancel()
        userSaveJob = scope.launch {
            delay(1000)
            val u = _user.value
            withContext(Dispatchers.IO) { JsonFile.write(userFile, u) }
        }
    }

    fun toggleFavorite(c: Channel) = updateUser { it.toggleFavorite(c.id) }
    fun isFavorite(c: Channel) = _user.value.isFavorite(c.id)
    fun noteWatched(c: Channel) = updateUser { it.pushRecent(c.id) }

    fun setProgress(id: String, positionMs: Long, durationMs: Long, title: String, poster: String?, url: String?) {
        if (durationMs <= 0) return
        updateUser { it.withProgress(id, WatchProgress(positionMs, durationMs, title = title, poster = poster, streamUrl = url)) }
    }

    fun continueWatching(): List<ContinueItem> = _user.value.progress.filter { !it.value.isFinished && it.value.positionMs > 20_000 }
        .entries.sortedByDescending { it.value.updated }.take(20).map { ContinueItem(it.key, it.value) }

    // MARK: Hide / dead-channel scan

    fun hide(c: Channel) = updateUser { it.copy(hiddenChannels = it.hiddenChannels + c.id) }
    fun unhideAll() { updateUser { it.copy(hiddenChannels = emptySet(), hiddenGroups = emptySet()) }; _dead.value = emptySet(); publishLibrary() }

    fun scanForDeadChannels() {
        scanJob?.cancel()
        val list = _library.value.visible
        _scan.value = 0 to list.size
        scanJob = scope.launch {
            var done = 0
            val dead = HashSet<String>()
            StreamHealth.scan(list, 6).collect { r ->
                done++
                if (!r.alive) dead += r.channelId
                _scan.value = done to list.size
            }
            _dead.value = dead
            _scan.value = null
        }
    }

    fun cancelScan() { scanJob?.cancel(); _scan.value = null }
    fun applyDeadChannelHiding() = publishLibrary()

    // MARK: VOD helpers

    suspend fun episodes(s: Series): List<Episode> {
        episodesBySeries[s.id]?.takeIf { it.isNotEmpty() }?.let { return it.sortedWith(compareBy({ e -> e.season }, { e -> e.number })) }
        fetchedEpisodes[s.id]?.let { return it }
        val xid = s.xtreamId ?: return emptyList()
        val src = _sources.value.firstOrNull { it.id == s.sourceId } ?: return emptyList()
        val k = src.kind as? SourceKind.Xtream ?: return emptyList()
        val server = XtreamClient.normalizeServer(k.server) ?: return emptyList()
        val eps = runCatching { XtreamClient(server, k.username, k.password).episodes(xid, s.id, src.userAgent) }.getOrDefault(emptyList())
        fetchedEpisodes[s.id] = eps
        return eps
    }

    suspend fun detail(m: VodItem): XtreamClient.VodDetail? {
        val xid = m.xtreamId ?: return null
        val src = _sources.value.firstOrNull { it.id == m.sourceId } ?: return null
        val k = src.kind as? SourceKind.Xtream ?: return null
        val server = XtreamClient.normalizeServer(k.server) ?: return null
        return runCatching { XtreamClient(server, k.username, k.password).vodDetail(xid) }.getOrNull()
    }

    // MARK: Backup

    fun exportBackup(): File {
        val f = File(app.cacheDir, "Lumina-Backup.json")
        JsonFile.write(f, Backup(_sources.value, _user.value))
        return f
    }

    suspend fun importBackup(uri: Uri) {
        val text = withContext(Dispatchers.IO) { app.contentResolver.openInputStream(uri)?.bufferedReader()?.readText() } ?: error("empty")
        val b = JsonFile.json.decodeFromString(Backup.serializer(), text)
        _user.value = b.user
        saveUserSoon()
        for (s in b.sources) if (_sources.value.none { it.id == s.id }) runCatching { addSource(s) }
        publishLibrary()
    }
}
