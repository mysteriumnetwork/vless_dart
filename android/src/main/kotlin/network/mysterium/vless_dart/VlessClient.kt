package network.mysterium.vless_dart

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.util.Log
import java.net.Inet4Address
import java.net.InetAddress
import java.util.concurrent.Executors
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * The plugin's half of the tunnel, in the app's main process.
 *
 * Holds no Xray state: the core runs in `:vless` (see [VlessIpc]), so the
 * status and counters here are the last values that process broadcast.
 *
 * This file must never reference an `XRay.*` class, directly or through
 * [VlessBackend]. Touching one loads the core's Go runtime into the main
 * process, which is exactly the crash the split exists to prevent.
 */
object VlessClient {
    private const val TAG = "VlessClient"

    /**
     * One connect at a time, and never on the main thread: the check below is
     * read-then-write, and the resolution either side of it blocks. The
     * backend used to give this for free with its own single-thread
     * dispatcher, before connect() moved over here.
     */
    private val lifecycle = Executors.newSingleThreadExecutor { r ->
        Thread(r, "vless-client")
    }.asCoroutineDispatcher()

    private val _statusFlow = MutableStateFlow(ConnectionStatus.disconnected)
    val statusFlow: StateFlow<ConnectionStatus> = _statusFlow.asStateFlow()

    val status: ConnectionStatus
        get() = _statusFlow.value

    @Volatile
    private var upload = 0L

    @Volatile
    private var download = 0L

    private var registered = false

    private val stateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val name = intent?.getStringExtra(VlessIpc.EXTRA_STATUS) ?: return
            upload = intent.getLongExtra(VlessIpc.EXTRA_UPLOAD, 0L)
            download = intent.getLongExtra(VlessIpc.EXTRA_DOWNLOAD, 0L)
            _statusFlow.value = VlessIpc.statusOf(name)
        }
    }

    /**
     * Starts listening for state from `:vless`.
     *
     * The service outlives the engine, so a tunnel may already be up when the
     * plugin attaches. It republishes on every notification tick, so the
     * status here converges within a couple of seconds either way.
     */
    fun attach(context: Context) {
        if (registered) {
            return
        }
        VlessIpc.registerStateReceiver(context.applicationContext, stateReceiver)
        registered = true
    }

    fun detach(context: Context) {
        if (!registered) {
            return
        }
        runCatching { context.applicationContext.unregisterReceiver(stateReceiver) }
            .onFailure { Log.w(TAG, "unregisterReceiver", it) }
        registered = false
    }

    /**
     * Prepares the config and asks `:vless` to bring the tunnel up.
     *
     * Resolution happens here, before any tunnel exists, so the lookup cannot
     * route into it. [XrayConfigPreparer] is pure JSON and sockets, so none of
     * this reaches the core.
     */
    suspend fun connect(context: Context, rawConfig: String) = withContext(lifecycle) {
        check(VpnService.prepare(context) == null) { "VPN permission has not been granted" }
        // One session at a time, as before the split. The check is against the
        // last broadcast state, which the optimistic `connecting` below keeps
        // honest between a connect and the service's first republish.
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
     * Guarded by the cached status rather than sent unconditionally: starting
     * the service only to stop it would post a foreground notification and
     * arm Android's startForeground deadline for no reason.
     */
    fun disconnect(context: Context) {
        if (status == ConnectionStatus.disconnected) {
            return
        }
        runCatching { context.startService(VlessIpc.command(context, VlessIpc.ACTION_DISCONNECT)) }
            .onFailure { Log.w(TAG, "disconnect command", it) }
    }

    /**
     * Cumulative counters as the Dart `tunnelStatistics` expects.
     *
     * Served from the last broadcast instead of querying the core, which is
     * now a process away. The service republishes every two seconds, the same
     * cadence the caller polls at.
     */
    fun statisticsJson(): String {
        if (status != ConnectionStatus.connected) {
            return ""
        }
        return JSONObject()
            .put("totalUpload", upload)
            .put("totalDownload", download)
            .put("latestHandshake", 0)
            .toString()
    }
}
