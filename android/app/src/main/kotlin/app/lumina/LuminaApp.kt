package app.lumina

import android.app.Application
import app.lumina.playback.PlaybackManager
import kotlinx.coroutines.launch

class LuminaApp : Application() {
    lateinit var model: AppModel
        private set
    lateinit var playback: PlaybackManager
        private set

    override fun onCreate() {
        super.onCreate()
        instance = this
        model = AppModel(this)
        playback = PlaybackManager(this, model)
        model.scope.launch { model.bootstrap() }
    }

    companion object {
        lateinit var instance: LuminaApp
            private set
    }
}
