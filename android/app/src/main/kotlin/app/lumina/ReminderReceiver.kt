package app.lumina

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import app.lumina.core.Reminder

/** Local "your programme starts soon" notifications. Tapping one opens the channel. */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val channelId = intent.getStringExtra("channelId") ?: return
        val title = intent.getStringExtra("title") ?: return
        val name = intent.getStringExtra("channelName") ?: ""
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Programme reminders", NotificationManager.IMPORTANCE_HIGH))
        val open = PendingIntent.getActivity(
            context, channelId.hashCode(),
            Intent(context, MainActivity::class.java).putExtra("channelId", channelId).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_agenda).setContentTitle(title).setContentText("Starts soon on $name")
            .setContentIntent(open).setAutoCancel(true).build()
        runCatching { NotificationManagerCompat.from(context).notify((channelId + title).hashCode(), n) } // may lack POST_NOTIFICATIONS
    }

    companion object {
        private const val CHANNEL = "reminders"

        fun schedule(context: Context, r: Reminder) {
            val am = context.getSystemService(AlarmManager::class.java)
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, maxOf(System.currentTimeMillis() + 1000, r.start - 120_000), pending(context, r))
        }

        fun cancel(context: Context, r: Reminder) { context.getSystemService(AlarmManager::class.java).cancel(pending(context, r)) }

        private fun pending(context: Context, r: Reminder) = PendingIntent.getBroadcast(
            context, r.id.hashCode(),
            Intent(context, ReminderReceiver::class.java).putExtra("channelId", r.channelId).putExtra("title", r.title).putExtra("channelName", r.channelName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}
