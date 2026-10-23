package app.lumina.playback

import android.app.PendingIntent
import android.content.Intent
import android.os.Bundle
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSession.MediaItemsWithStartPosition
import androidx.media3.session.SessionError
import app.lumina.LuminaApp
import app.lumina.MainActivity
import app.lumina.core.Channel
import app.lumina.core.GroupLabel
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.guava.future
import java.util.concurrent.ConcurrentHashMap

/**
 * Hosts the MediaLibrarySession. Android Auto (and the notification / lock screen / Bluetooth buttons)
 * talk to this; it drives the same ExoPlayer the phone UI uses.
 */
@OptIn(UnstableApi::class)
class PlaybackService : MediaLibraryService() {
    private var session: MediaLibrarySession? = null

    override fun onCreate() {
        super.onCreate()
        val app = application as LuminaApp
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        session = MediaLibrarySession.Builder(this, app.playback.player, AutoCallback(app))
            .setSessionActivity(open)
            .build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession? = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        val p = session?.player
        if (p == null || !p.playWhenReady) stopSelf()
    }

    override fun onDestroy() {
        session?.release() // the ExoPlayer itself is app-scoped and outlives the service
        session = null
        super.onDestroy()
    }
}

@OptIn(UnstableApi::class)
private class AutoCallback(private val app: LuminaApp) : MediaLibraryService.MediaLibrarySession.Callback {
    private val model get() = app.model
    private val playback get() = app.playback
    private val served = ConcurrentHashMap<String, List<Channel>>() // parentId -> last list served (zapping context)
    private val searchResults = ConcurrentHashMap<String, List<Channel>>()
    private val limit get() = model.user.value.settings.autoMaxItems.coerceIn(20, 200)

    private fun isCar(c: MediaSession.ControllerInfo) = c.packageName.contains("projection.gearhead") || c.packageName.startsWith("com.google.android.carassistant") || c.packageName.contains("android.car")

    override fun onConnect(session: MediaSession, controller: MediaSession.ControllerInfo): MediaSession.ConnectionResult {
        if (isCar(controller)) playback.setAudioOnly(model.user.value.settings.autoAudioOnly)
        return super.onConnect(session, controller)
    }

    override fun onDisconnected(session: MediaSession, controller: MediaSession.ControllerInfo) {
        if (isCar(controller)) playback.setAudioOnly(false)
    }

    // MARK: Browse tree: root -> Favorites | Recent | Groups -> channels

    private fun folder(id: String, title: String, subtitle: String? = null) = MediaItem.Builder()
        .setMediaId(id)
        .setMediaMetadata(
            MediaMetadata.Builder().setTitle(title).setSubtitle(subtitle).setIsBrowsable(true).setIsPlayable(false)
                .setMediaType(MediaMetadata.MEDIA_TYPE_FOLDER_MIXED).build(),
        ).build()

    override fun onGetLibraryRoot(
        session: MediaLibraryService.MediaLibrarySession, browser: MediaSession.ControllerInfo, params: MediaLibraryService.LibraryParams?,
    ): ListenableFuture<LibraryResult<MediaItem>> =
        Futures.immediateFuture(LibraryResult.ofItem(folder("root", "Lumina"), params))

    override fun onGetItem(session: MediaLibraryService.MediaLibrarySession, browser: MediaSession.ControllerInfo, mediaId: String): ListenableFuture<LibraryResult<MediaItem>> =
        model.scope.future {
            model.ready.await()
            val item = when {
                mediaId.startsWith("ch:") -> model.channel(mediaId.removePrefix("ch:"))?.let { playback.mediaItemFor(it) }
                mediaId == "root" -> folder("root", "Lumina")
                else -> null
            }
            if (item != null) LibraryResult.ofItem(item, null) else LibraryResult.ofError(SessionError.ERROR_BAD_VALUE)
        }

    override fun onGetChildren(
        session: MediaLibraryService.MediaLibrarySession, browser: MediaSession.ControllerInfo, parentId: String,
        page: Int, pageSize: Int, params: MediaLibraryService.LibraryParams?,
    ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> = model.scope.future {
        model.ready.await()
        val items: List<MediaItem> = when {
            parentId == "root" -> listOf(
                folder("fav", "Favorites", "${model.favoriteChannels().size} channels"),
                folder("recent", "Recent"),
                folder("groups", "Groups", "${model.library.value.browseGroups.size} groups"),
            )
            parentId == "groups" -> model.library.value.browseGroups.take(limit).map {
                folder("grp:${it.id}", it.label.title, "${it.count} channels")
            }
            else -> {
                val chans = when {
                    parentId == "fav" -> model.favoriteChannels()
                    parentId == "recent" -> model.recentChannels()
                    parentId.startsWith("grp:") -> parentId.removePrefix("grp:").let { g -> if (model.isLocked(g)) emptyList() else model.channelsIn(g) }
                    else -> emptyList()
                }.take(limit)
                served[parentId] = chans
                chans.mapNotNull { playback.mediaItemFor(it) }
            }
        }
        val from = (page * pageSize).coerceAtMost(items.size)
        val to = if (pageSize <= 0) items.size else (from + pageSize).coerceAtMost(items.size)
        LibraryResult.ofItemList(ImmutableList.copyOf(items.subList(from, to)), params)
    }

    // MARK: Search ("Play BBC One" by voice, or the search box in the car)

    override fun onSearch(
        session: MediaLibraryService.MediaLibrarySession, browser: MediaSession.ControllerInfo, query: String, params: MediaLibraryService.LibraryParams?,
    ): ListenableFuture<LibraryResult<Void>> = model.scope.future {
        model.ready.await()
        val found = model.search(query).channels.take(20)
        searchResults[query] = found
        session.notifySearchResultChanged(browser, query, found.size, params)
        LibraryResult.ofVoid()
    }

    override fun onGetSearchResult(
        session: MediaLibraryService.MediaLibrarySession, browser: MediaSession.ControllerInfo, query: String,
        page: Int, pageSize: Int, params: MediaLibraryService.LibraryParams?,
    ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> = model.scope.future {
        model.ready.await()
        val found = searchResults[query] ?: model.search(query).channels.take(20)
        served["search:$query"] = found
        LibraryResult.ofItemList(ImmutableList.copyOf(found.mapNotNull { playback.mediaItemFor(it) }), params)
    }

    // MARK: Playback requests

    /** Resolves id-only items (what a car sends) into playable ones, with the browsed list as the zapping queue. */
    override fun onSetMediaItems(
        mediaSession: MediaSession, controller: MediaSession.ControllerInfo, mediaItems: MutableList<MediaItem>, startIndex: Int, startPositionMs: Long,
    ): ListenableFuture<MediaItemsWithStartPosition> = model.scope.future {
        model.ready.await()
        val first = mediaItems.firstOrNull()
        val query = first?.requestMetadata?.searchQuery
        val channelId = when {
            first != null && first.mediaId.startsWith("ch:") -> first.mediaId.removePrefix("ch:")
            !query.isNullOrBlank() -> model.search(query).channels.firstOrNull()?.id
            else -> null
        }
        if (mediaItems.size <= 1 && channelId != null) {
            val ctx = served.values.firstOrNull { l -> l.any { it.id == channelId } } ?: listOfNotNull(model.channel(channelId))
            val items = ctx.mapNotNull { playback.mediaItemFor(it) }
            val idx = ctx.indexOfFirst { it.id == channelId }.coerceAtLeast(0)
            model.channel(channelId)?.let { model.noteWatched(it) }
            playback.onExternalItemsSet()
            MediaItemsWithStartPosition(items, idx, C.TIME_UNSET)
        } else {
            MediaItemsWithStartPosition(mediaItems.map { resolve(it) }, startIndex, startPositionMs)
        }
    }

    override fun onAddMediaItems(
        mediaSession: MediaSession, controller: MediaSession.ControllerInfo, mediaItems: MutableList<MediaItem>,
    ): ListenableFuture<MutableList<MediaItem>> = model.scope.future {
        model.ready.await()
        mediaItems.map { resolve(it) }.toMutableList()
    }

    private fun resolve(item: MediaItem): MediaItem {
        if (item.localConfiguration != null) return item
        if (item.mediaId.startsWith("ch:")) model.channel(item.mediaId.removePrefix("ch:"))?.let { c -> playback.mediaItemFor(c)?.let { return it } }
        return item
    }
}
