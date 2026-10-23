package app.lumina

import android.content.ComponentName
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.session.MediaBrowser
import androidx.media3.session.SessionToken
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.lumina.playback.PlaybackService
import kotlinx.coroutines.delay
import kotlinx.coroutines.guava.await
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Talks to PlaybackService exactly like Android Auto does (as a MediaBrowser) and checks the browse tree,
 * favorites, search and playback.
 */
@RunWith(AndroidJUnit4::class)
class AutoBrowseTest {
    @Test
    fun browseTreeSearchAndPlayback() = runBlocking(kotlinx.coroutines.Dispatchers.Main) {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val app = ctx.applicationContext as LuminaApp
        app.model.bootstrap()
        app.model.addDemo()
        val channels = app.model.library.value.visible
        assertEquals(3, channels.size)
        app.model.toggleFavorite(channels[0])

        val token = SessionToken(ctx, ComponentName(ctx, PlaybackService::class.java))
        val browser = MediaBrowser.Builder(ctx, token).buildAsync().await()
        try {
            val root = browser.getLibraryRoot(null).await().value!!
            assertEquals("root", root.mediaId)

            val top = browser.getChildren(root.mediaId, 0, 50, null).await().value!!
            assertEquals(listOf("Favorites", "Recent", "Groups"), top.map { it.mediaMetadata.title.toString() })
            assertTrue(top.all { it.mediaMetadata.isBrowsable == true })

            val favs = browser.getChildren("fav", 0, 50, null).await().value!!
            assertEquals(listOf(channels[0].name), favs.map { it.mediaMetadata.title.toString() })
            assertTrue("channel items must be playable", favs.all { it.mediaMetadata.isPlayable == true })

            val groups = browser.getChildren("groups", 0, 50, null).await().value!!
            assertTrue(groups.isNotEmpty())
            val inGroup = browser.getChildren(groups.first().mediaId, 0, 50, null).await().value!!
            assertTrue(inGroup.isNotEmpty())

            // Search ("play Big Buck Bunny")
            browser.search("buck", null).await()
            val found = browser.getSearchResult("buck", 0, 20, null).await().value!!
            assertEquals(1, found.size)
            assertTrue(found[0].mediaMetadata.title.toString().contains("Big Buck Bunny"))

            // Playing an id-only item (what the car sends) must resolve to a stream and actually start.
            val pick = inGroup.first()
            browser.setMediaItem(MediaItem.Builder().setMediaId(pick.mediaId).build())
            browser.prepare()
            browser.play()
            var ready = false
            for (i in 0 until 40) {
                delay(500)
                if (browser.playbackState == Player.STATE_READY && browser.isPlaying) { ready = true; break }
            }
            assertTrue("playback never started: state=${browser.playbackState}", ready)
            assertEquals(pick.mediaId, browser.currentMediaItem?.mediaId)
            // The browsed list becomes the queue, so next/previous zap between channels.
            assertTrue("queue should hold the browsed channels", browser.mediaItemCount >= 2)
        } finally {
            browser.release()
        }
    }
}
