package network.mysterium.vless_dart

import android.content.Intent
import android.net.VpnService
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * Holds the tunnel open while the app is backgrounded.
 *
 * The foreground notification is what keeps it alive; without it the system
 * reclaims the service and the tunnel dies with the app.
 */
class VlessVpnService : VpnService() {

    private companion object {
        const val TAG = "VlessVpnService"
        const val NOTIFICATION_INTERVAL_MS = 2_000L
    }

    // Not Main: the loop calls into Go every tick, and Xray holds one
    // package-wide mutex that a concurrent stop can own for hundreds of ms.
    private val scope = CoroutineScope(Job() + Dispatchers.IO)
    private lateinit var notifications: NotificationHelper
    private var updateJob: Job? = null
    private var startedInForeground = false

    override fun onCreate() {
        super.onCreate()
        // Before anything that can fail: every teardown path from here is
        // ownership-checked, and an unregistered service is indistinguishable
        // from a previous session whose destroy has not been delivered yet.
        VlessBackend.onServiceCreated(this)
        notifications = NotificationHelper(this)
        NotificationHelper.initNotificationChannel(this)

        // Android arms a ~10s deadline at startForegroundService() and crashes
        // the process with ForegroundServiceDidNotStartInTimeException if
        // startForeground() has not run by then. Doing it here rather than
        // only in onStartCommand beats the deadline even when the main thread
        // is busy.
        startedInForeground = notifications.startForegroundSafely(
            this,
            notifications.build(ConnectionStatus.connecting, 0, 0),
        )
        if (!startedInForeground) {
            // The contract can no longer be met; a destroying service makes
            // the system's timeout handler bail out instead of crashing.
            Log.e(TAG, "could not enter foreground, stopping")
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!startedInForeground) {
            startedInForeground = notifications.startForegroundSafely(
                this,
                notifications.build(VlessBackend.status, 0, 0),
            )
            if (!startedInForeground) {
                stopSelf()
                return START_NOT_STICKY
            }
        }

        // Asynchronous on purpose: this callback runs on the main thread
        // and the bring-up blocks for seconds.
        VlessBackend.startTunnelAsync(this) { started ->
            if (started) {
                startNotificationLoop()
            } else {
                stopSelf()
            }
        }
        return START_STICKY
    }

    private fun startNotificationLoop() {
        updateJob?.cancel()
        updateJob = scope.launch {
            var lastUp = -1L
            var lastDown = -1L
            var lastStatus: ConnectionStatus? = null
            while (isActive) {
                val status = VlessBackend.status
                if (status == ConnectionStatus.disconnected) {
                    break
                }
                val stats = VlessBackend.statisticsJson()
                var up = 0L
                var down = 0L
                if (stats.isNotEmpty()) {
                    val parsed = JSONObject(stats)
                    up = parsed.optLong("totalUpload")
                    down = parsed.optLong("totalDownload")
                }
                if (status != lastStatus || up != lastUp || down != lastDown) {
                    notifications.notifySafely(notifications.build(status, up, down))
                    lastStatus = status
                    lastUp = up
                    lastDown = down
                }
                delay(NOTIFICATION_INTERVAL_MS)
            }
        }
    }

    /** Called by the backend once the core is down. */
    fun shutdown() {
        updateJob?.cancel()
        updateJob = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /** The user revoked VPN permission, or another VPN app took over. */
    override fun onRevoke() {
        Log.i(TAG, "VPN permission revoked")
        VlessBackend.onRevoked(this)
        super.onRevoke()
    }

    override fun onDestroy() {
        updateJob?.cancel()
        scope.cancel()
        VlessBackend.onServiceDestroyed(this)
        super.onDestroy()
    }
}
