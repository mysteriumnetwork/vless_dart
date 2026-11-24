package network.mysterium.vless_dart

import android.content.Intent
import android.net.VpnService
import android.os.IBinder
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

    /** Whether this instance has already been given its one session. */
    private var sessionAccepted = false

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

        if (intent?.action == VlessIpc.ACTION_DISCONNECT) {
            VlessBackend.disconnect()
            return START_NOT_STICKY
        }

        val prepared = preparedFrom(intent) ?: run {
            // A system-redelivered start, with no config left to bring up.
            Log.w(TAG, "start with no prepared config, stopping")
            VlessBackend.disconnect()
            return START_NOT_STICKY
        }

        if (sessionAccepted) {
            // The plugin only connects when it believes nothing is up, so
            // this is one whose view of us is stale. Bringing it up would
            // fail against the running core, and the cleanup for that failure
            // would take the live tunnel down with it. Correct the view
            // instead, and keep the tunnel.
            Log.w(TAG, "connect while a session is live, ignoring")
            VlessBackend.announce()
            return START_STICKY
        }
        sessionAccepted = true

        // Asynchronous on purpose: this callback runs on the main thread
        // and the bring-up blocks for seconds.
        VlessBackend.startTunnelAsync(this, prepared) { started ->
            if (started) {
                startNotificationLoop()
            } else {
                stopSelf()
            }
        }
        return START_STICKY
    }

    /**
     * Rebuilds the prepared config from the start intent.
     *
     * It used to be handed over through a field on the backend; the plugin is
     * in another process now, so it travels with the command instead.
     */
    private fun preparedFrom(intent: Intent?): XrayConfigPreparer.Prepared? {
        if (intent?.action != VlessIpc.ACTION_CONNECT) {
            return null
        }
        val config = intent.getStringExtra(VlessIpc.EXTRA_CONFIG) ?: return null
        // On the main thread of the tunnel's process: unparseable is a start
        // with nothing to bring up, not a reason to take the process down.
        val json = runCatching { JSONObject(config) }.getOrNull() ?: return null
        return XrayConfigPreparer.Prepared(
            config = json,
            socksPort = intent.getIntExtra(VlessIpc.EXTRA_SOCKS_PORT, 0),
            username = intent.getStringExtra(VlessIpc.EXTRA_USERNAME).orEmpty(),
            password = intent.getStringExtra(VlessIpc.EXTRA_PASSWORD).orEmpty(),
            serverAddress = intent.getStringExtra(VlessIpc.EXTRA_SERVER).orEmpty(),
        )
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
                val (up, down) = VlessBackend.counters()
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

    /**
     * Hands the plugin its binder on the core. Every other bind is the
     * framework's, checking consent or tracking the tunnel it established.
     */
    override fun onBind(intent: Intent?): IBinder? =
        if (intent?.action == VlessIpc.ACTION_BIND) VlessBackend.binder else super.onBind(intent)

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
