package pl.mytify.mytify

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class TransferService : Service() {
    private val executor = Executors.newSingleThreadExecutor()
    private val started = AtomicBoolean(false)
    private lateinit var manager: TransferManager
    private var wake: PowerManager.WakeLock? = null
    private var last = 0L

    override fun onCreate() {
        super.onCreate()
        manager = TransferManager.get(this)
        getSystemService(NotificationManager::class.java)
            .createNotificationChannel(
                NotificationChannel(
                    "mytify-transfer",
                    Lang.t("Kopiowanie muzyki"),
                    NotificationManager.IMPORTANCE_LOW,
                )
            )
    }

    private fun notification(): Notification {
        val s = manager.status()
        val total = s.optLong("totalBytes")
        val done = s.optLong("doneBytes")
        val cancel =
            PendingIntent.getService(
                this,
                9,
                Intent(this, TransferService::class.java).setAction("pause"),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val open =
            PendingIntent.getActivity(
                this,
                9,
                Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        return Notification.Builder(this, "mytify-transfer")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(Lang.t("Mytify · Pobieranie na telefon"))
            .setContentText("${s.optInt("done")} / ${s.optInt("total")} · ${s.optString("name")}")
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(
                100,
                if (total > 0) (done * 100 / total).toInt().coerceIn(0, 100) else 0,
                total <= 0,
            )
            .addAction(
                Notification.Action.Builder(android.R.drawable.ic_media_pause, Lang.t("Wstrzymaj"), cancel)
                    .build()
            )
            .build()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "pause") {
            manager.pause()
            if (!started.get()) stopSelf()
            return START_NOT_STICKY
        }
        startForeground(209, notification())
        if (!started.compareAndSet(false, true)) return START_NOT_STICKY
        wake =
            (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Mytify:transfer")
                .apply { acquire(2 * 60 * 60 * 1000L) }
        manager.onProgress = {
            val now = SystemClock.elapsedRealtime()
            if (now - last > 500) {
                last = now
                getSystemService(NotificationManager::class.java).notify(209, notification())
            }
        }
        executor.execute {
            try {
                manager.runJob()
            } finally {
                manager.onProgress = null
                wake?.takeIf { it.isHeld }?.release()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        manager.pause()
        stopSelf()
    }

    override fun onDestroy() {
        manager.pause()
        manager.onProgress = null
        wake?.takeIf { it.isHeld }?.release()
        executor.shutdownNow()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        fun launch(context: Context) {
            context.startForegroundService(Intent(context, TransferService::class.java))
        }
    }
}
