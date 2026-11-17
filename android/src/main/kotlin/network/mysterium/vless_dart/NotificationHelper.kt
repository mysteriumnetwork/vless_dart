package network.mysterium.vless_dart

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import network.mysterium.vless_dart.R
import java.util.Locale

/** Builds and posts the ongoing tunnel notification. */
class NotificationHelper(private val context: Context) {

    companion object {
        private const val TAG = "VlessNotification"
        const val CHANNEL_ID = "network_mysterium_vless_channel"
        const val NOTIFICATION_ID = 424243

        /**
         * Must run before the first startForeground call. Posting to a channel
         * that does not exist yet throws
         * CannotPostForegroundServiceNotificationException and kills the
         * process.
         */
        fun initNotificationChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "VPN",
                NotificationManager.IMPORTANCE_LOW,
            )
            ContextCompat.getSystemService(context, NotificationManager::class.java)
                ?.createNotificationChannel(channel)
        }
    }

    fun build(status: ConnectionStatus, upload: Long, download: Long): Notification {
        val text = when (status) {
            ConnectionStatus.connected ->
                "Connected • ↑ ${formatBytes(upload)} ↓ ${formatBytes(download)}"
            ConnectionStatus.connecting -> "Connecting…"
            ConnectionStatus.disconnecting -> "Disconnecting…"
            else -> "Disconnected"
        }

        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.apply { flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP }
        val pending = launch?.let {
            PendingIntent.getActivity(
                context,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle("Mysterium VPN")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_vless_tunnel)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .apply { pending?.let { setContentIntent(it) } }
            .build()
    }

    /**
     * Never lets a foreground-start failure escape as a crash. Covers
     * SecurityException and ForegroundServiceStartNotAllowedException.
     */
    fun startForegroundSafely(service: android.app.Service, notification: Notification): Boolean =
        try {
            ServiceCompat.startForeground(
                service,
                NOTIFICATION_ID,
                notification,
                declaredForegroundServiceType(service),
            )
            true
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed", e)
            false
        }

    /** Posts an update, or gives up quietly when notifications are denied. */
    fun notifySafely(notification: Notification): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                context,
                "android.permission.POST_NOTIFICATIONS",
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        val manager = ContextCompat.getSystemService(context, NotificationManager::class.java)
            ?: return false
        return try {
            manager.notify(NOTIFICATION_ID, notification)
            true
        } catch (e: SecurityException) {
            Log.w(TAG, "notify refused", e)
            false
        }
    }

    /**
     * Read back from the merged manifest so the bitmask always matches what
     * the host app declared, across API levels.
     */
    private fun declaredForegroundServiceType(service: android.app.Service): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return 0
        return try {
            service.packageManager.getServiceInfo(
                android.content.ComponentName(service, service.javaClass),
                0,
            ).foregroundServiceType
        } catch (e: PackageManager.NameNotFoundException) {
            Log.w(TAG, "service not in manifest", e)
            ServiceInfo.FOREGROUND_SERVICE_TYPE_NONE
        }
    }

    private fun formatBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val units = arrayOf("KB", "MB", "GB", "TB")
        var value = bytes.toDouble() / 1024
        var unit = 0
        while (value >= 1024 && unit < units.lastIndex) {
            value /= 1024
            unit++
        }
        return String.format(Locale.US, "%.1f %s", value, units[unit])
    }
}
