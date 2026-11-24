package network.mysterium.vless_dart

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.RemoteException
import android.util.Log
import androidx.core.content.ContextCompat
import java.net.Inet4Address
import java.net.InetAddress
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * The plugin's half of the tunnel, in the app's main process.
 *
 * Holds no Xray state: the core runs in `:vless` (see [VlessIpc]). The status
 * here is the last one that process broadcast, corrected by the one thing a
 * broadcast cannot report, which is the process dying.
 *
 * This file must never reference an `XRay` class, directly or through
 * [VlessBackend]. Touching one loads the core's Go runtime into the main
 * process, which is exactly the crash the split exists to prevent.
 */
object VlessClient {
    private const val TAG = "VlessClient"

    /**
     * One connect at a time, and never on the main thread: the status check
     * in it is read-then-write, and the resolution beside it blocks. Teardown
     * commands queue here too, so one can never overtake the start it is
     * meant to stop.
     */
    private val lifecycle = Executors.newSingleThreadExecutor { r ->
        Thread(r, "vless-client")
    }.asCoroutineDispatcher()

    private val scope = CoroutineScope(SupervisorJob() + lifecycle)
    private val main = Handler(Looper.getMainLooper())

    private val _statusFlow = MutableStateFlow(ConnectionStatus.disconnected)
    val statusFlow: StateFlow<ConnectionStatus> = _statusFlow.asStateFlow()

    val status: ConnectionStatus
        get() = _statusFlow.value

    /** Counted so a connect still resolving can tell a teardown overtook it. */
    private val teardowns = AtomicInteger()

    /** Main thread only, like everything about the binding. */
    private var appContext: Context? = null
    private var bound = false

    @Volatile
    private var link: Link? = null

    /** A bound core, and the watch on the process that hosts it. */
    private class Link(val core: IVlessCore, val binder: IBinder) : IBinder.DeathRecipient {
        // Delivered on a binder thread.
        override fun binderDied() {
            main.post { onCoreDied(this) }
        }
    }

    private val statusReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val name = intent?.getStringExtra(VlessIpc.EXTRA_STATUS) ?: return
            val next = VlessIpc.statusOf(name)
            _statusFlow.value = next
            if (next != ConnectionStatus.disconnected) {
                ensureLinked()
            }
        }
    }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            binder ?: return
            if (link?.binder !== binder) {
                val fresh = Link(IVlessCore.Stub.asInterface(binder), binder)
                try {
                    binder.linkToDeath(fresh, 0)
                } catch (e: RemoteException) {
                    lost("core died before it could be watched")
                    return
                }
                link = fresh
                Log.i(TAG, "core linked")
            }
            // A tunnel can outlive this process and be up before anything
            // here has heard of it. The core answers only if one is, so a
            // session still starting is never told it is disconnected.
            try {
                link?.core?.announce()
            } catch (e: RemoteException) {
                Log.w(TAG, "announce", e)
            }
        }

        /**
         * Nothing to do. An orderly stop reports itself by broadcast and the
         * death watch covers a killed process, while acting here as well
         * would declare `disconnected` ahead of a teardown still in progress.
         */
        override fun onServiceDisconnected(name: ComponentName?) = Unit

        override fun onBindingDied(name: ComponentName?) {
            // The service instance is gone and this binding with it: it will
            // never connect again, and the next session needs one that can.
            appContext?.let(::bind)
            if (link?.binder?.isBinderAlive != true) {
                // No process left to broadcast the end of whatever was
                // starting, as when the service dies before it ever binds.
                lost("service gone with no core to report it")
            }
        }
    }

    /**
     * Wires this process to the core's. Once per process, never undone.
     *
     * Not tied to the engine: the tunnel outlives it, and a status change
     * missed while detached would be believed until the next one. The
     * binding uses no BIND_AUTO_CREATE, so it neither creates the service nor
     * keeps it alive; it connects when one is running, and [ensureLinked]
     * covers the case where the system has stopped honouring it.
     */
    fun attach(context: Context) {
        if (appContext != null) {
            return
        }
        val app = context.applicationContext
        appContext = app
        ContextCompat.registerReceiver(
            app,
            statusReceiver,
            IntentFilter(VlessIpc.ACTION_STATUS),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        bind(app)
    }

    private fun bind(context: Context) {
        if (bound) {
            runCatching { context.unbindService(connection) }
        }
        bound = runCatching {
            context.bindService(VlessIpc.command(context, VlessIpc.ACTION_BIND), connection, 0)
        }.getOrDefault(false)
        if (!bound) {
            Log.w(TAG, "could not bind the core; its death will go unnoticed")
        }
    }

    /**
     * Binds again when a core is running and nothing here is linked to it.
     *
     * The standing binding is not enough on its own. When the core's process
     * dies under a running service, the system can drop the binding's record
     * and leave the connection registered, so the next process is never
     * handed over: no counters, and no death watch for that session. A status
     * means a core is up right now, and binding to a running service is the
     * one case that connects on the spot.
     */
    private fun ensureLinked() {
        if (link?.binder?.isBinderAlive == true) {
            return
        }
        appContext?.let(::bind)
    }

    private fun onCoreDied(dead: Link) {
        if (link !== dead) {
            return
        }
        link = null
        lost("core process died")
    }

    /**
     * The tunnel is gone and nothing is left to say so.
     *
     * Its descriptor died with the process, so traffic is already leaving
     * outside it. Reporting `connected` until some later resync would tell the
     * user they are protected when they are not.
     */
    private fun lost(reason: String) {
        if (status == ConnectionStatus.disconnected) {
            return
        }
        Log.w(TAG, "tunnel lost: $reason")
        _statusFlow.value = ConnectionStatus.disconnected
    }

    /**
     * Prepares the config and asks `:vless` to bring the tunnel up.
     *
     * Resolution happens here, before any tunnel exists, so the lookup cannot
     * route into it. [XrayConfigPreparer] is pure JSON and sockets, so none of
     * this reaches the core.
     */
    suspend fun connect(context: Context, rawConfig: String) = withContext(lifecycle) {
        val teardownsBefore = teardowns.get()
        check(VpnService.prepare(context) == null) { "VPN permission has not been granted" }
        // One session at a time. Checked against the last broadcast, which
        // the `connecting` below keeps honest until the core confirms it; the
        // service checks again, since only it can know for certain.
        check(status == ConnectionStatus.disconnected) {
            "a tunnel is already ${status.name}, disconnect first"
        }

        val prepared = XrayConfigPreparer.prepare(rawConfig)
        // IPv4 only: getByName returns whichever family the resolver sorts
        // first, so a dual-stack server would pin an AAAA the exits cannot use.
        val resolved = InetAddress.getAllByName(prepared.serverAddress)
            .filterIsInstance<Inet4Address>()
            .firstOrNull()
            ?.hostAddress
            ?: throw IllegalStateException("cannot resolve ${prepared.serverAddress} to IPv4")
        XrayConfigPreparer.pinServerAddress(prepared.config, resolved)

        // Resolution can take seconds, and a disconnect during it found
        // nothing to stop. It still has to win, or the tunnel comes up after
        // the caller was told it would not.
        check(teardowns.get() == teardownsBefore) { "connect cancelled by a disconnect" }

        _statusFlow.value = ConnectionStatus.connecting

        val intent = VlessIpc.command(context, VlessIpc.ACTION_CONNECT).apply {
            // The prepared config crosses a process boundary now, so it rides
            // the intent rather than a field the service used to read in place.
            putExtra(VlessIpc.EXTRA_CONFIG, prepared.config.toString())
            putExtra(VlessIpc.EXTRA_SOCKS_PORT, prepared.socksPort)
            putExtra(VlessIpc.EXTRA_USERNAME, prepared.username)
            putExtra(VlessIpc.EXTRA_PASSWORD, prepared.password)
            putExtra(VlessIpc.EXTRA_SERVER, prepared.serverAddress)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        } catch (e: Exception) {
            // The service never starts, so no teardown will ever run: without
            // this the status is stranded at `connecting` for good.
            _statusFlow.value = ConnectionStatus.disconnected
            throw e
        }
    }

    /**
     * Asks `:vless` to tear down. Safe to call when nothing is running.
     *
     * Counted at once, so a connect still resolving gives up, and sent from
     * the queue that connect runs on, so it lands after any start already
     * issued. Skipped when nothing is up: starting the service only to stop it
     * would post a notification and arm the startForeground deadline for
     * nothing.
     */
    fun disconnect(context: Context) {
        teardowns.incrementAndGet()
        val app = context.applicationContext
        scope.launch {
            if (status == ConnectionStatus.disconnected) {
                return@launch
            }
            runCatching { app.startService(VlessIpc.command(app, VlessIpc.ACTION_DISCONNECT)) }
                .onFailure { Log.w(TAG, "disconnect command", it) }
        }
    }

    /**
     * Cumulative counters as the Dart `tunnelStatistics` expects.
     *
     * A call into the core's process, which takes the mutex Xray holds for
     * the whole of a start or stop, so never from the main thread.
     */
    fun statisticsJson(): String {
        if (status != ConnectionStatus.connected) {
            return ""
        }
        val core = link?.core ?: return ""
        val counters = try {
            core.counters()
        } catch (e: RemoteException) {
            null
        }
        if (counters == null || counters.size < 2) {
            return ""
        }
        return JSONObject()
            .put("totalUpload", counters[0])
            .put("totalDownload", counters[1])
            .put("latestHandshake", 0)
            .toString()
    }
}
