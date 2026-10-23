package app.lumina

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.lumina.core.Source
import app.lumina.core.SourceKind
import app.lumina.playback.PlayStatus
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class FailoverTest {
    @Test
    fun deadPrimaryStreamFallsOverToBackupAutomatically() = runBlocking(Dispatchers.Main) {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val app = ctx.applicationContext as LuminaApp
        app.model.bootstrap()

        // Two providers list the same channel; the FHD one (preferred, so tried first) is dead.
        val f = File(ctx.cacheDir, "failover.m3u")
        f.writeText(
            """#EXTM3U
#EXTINF:-1 tvg-id="ft" group-title="Test",Failover Test FHD
http://127.0.0.1:9/dead.m3u8
#EXTINF:-1 tvg-id="ft" group-title="Test",Failover Test
https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8
""",
        )
        app.model.addSource(Source(name = "failover", kind = SourceKind.M3u(f.absolutePath)))
        val ch = app.model.library.value.visible.firstOrNull { it.name.startsWith("Failover Test") }
        assertNotNull("merged channel missing", ch)
        assertEquals("duplicates should merge into one channel with 2 streams", 2, ch!!.streams.size)
        assertTrue("best quality first", ch.streams[0].url.contains("127.0.0.1"))

        app.playback.play(ch, listOf(ch))
        var playing = false
        for (i in 0 until 60) {
            delay(500)
            if (app.playback.ui.value.status == PlayStatus.Playing) { playing = true; break }
        }
        val ui = app.playback.ui.value
        assertTrue("never recovered: ${ui.status} note=${ui.failoverNote}", playing)
        assertTrue("player should now be on the backup URL", app.playback.player.currentMediaItem?.localConfiguration?.uri.toString().contains("devstreaming"))
        app.playback.stop()
    }
}
