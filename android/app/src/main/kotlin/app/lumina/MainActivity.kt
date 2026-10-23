package app.lumina

import android.Manifest
import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.util.Rational
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import app.lumina.playback.PlayStatus
import app.lumina.ui.AppRoot
import app.lumina.ui.AppTab
import app.lumina.ui.LuminaTheme
import app.lumina.ui.UiState
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { LuminaTheme { AppRoot() } }
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(i: Intent?) {
        val app = LuminaApp.instance
        // Debug builds only (used to screenshot the app): --ez demo true --es tab settings --ez play true
        if (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0 && i != null &&
            (i.hasExtra("demo") || i.hasExtra("tab") || i.hasExtra("play"))) {
            app.model.scope.launch {
                app.model.bootstrap()
                if (i.getBooleanExtra("demo", false)) app.model.addDemo()
                i.getStringExtra("tab")?.let { t -> runCatching { UiState.tab = AppTab.valueOf(t.uppercase()) } }
                if (i.getBooleanExtra("play", false)) app.model.library.value.visible.let { l -> l.firstOrNull()?.let { UiState.play(it, l) } }
            }
        }
        // Tapped a reminder: jump straight to the channel.
        i?.getStringExtra("channelId")?.let { id ->
            app.model.scope.launch {
                app.model.bootstrap()
                app.model.channel(id)?.let { UiState.play(it) }
            }
            i.removeExtra("channelId")
        }
        // "Open with Lumina" on a playlist file.
        if (i?.action == Intent.ACTION_VIEW) i.data?.let { uri ->
            val name = runCatching {
                contentResolver.query(uri, null, null, null, null)?.use { c -> if (c.moveToFirst()) c.getString(c.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME)) else null }
            }.getOrNull() ?: uri.lastPathSegment
            app.model.scope.launch { app.model.bootstrap(); app.model.handleOpen(uri, name) }
            i.data = null
        }
    }

    /** Leaving the app while a channel plays keeps it going in a floating window. */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        val ui = LuminaApp.instance.playback.ui.value
        if (UiState.showPlayer && ui.status == PlayStatus.Playing && !ui.audioOnly) enterPip()
    }

    fun enterPip() {
        if (Build.VERSION.SDK_INT < 26 || !packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) return
        runCatching { enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9)).build()) }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: android.content.res.Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        UiState.inPip = isInPictureInPictureMode
    }
}
