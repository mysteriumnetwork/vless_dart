package network.mysterium.vless_dart

import XRay.Protector
import XRay.XRay
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import java.net.Inet4Address
import java.net.InetAddress
import java.util.concurrent.Executors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Owns the Xray core and the tun2socks bridge for the whole process.
 *
 * A singleton because both are process-wide globals in Go: starting a second
 * instance fails rather than running alongside the first. The service can also
 * be recreated by the system without the plugin ever attaching, so state
 * cannot live in either of them.
 */
object VlessBackend {
    private const val TAG = "VlessBackend"
    const val MTU = 1500

    /**
     * Where clients address DNS. Not a public resolver: Android's Private DNS,
     * opportunistic by default, probes the resolvers a network advertises for
     * DoT and then queries port 853, which no port-53 rule can intercept, so
     * AAAA reached the client. Nothing answers 853 here, so it falls back to
     * cleartext 53, which dns-out does intercept. `.2` because `.1` is the
     * tun's own address and would be answered locally instead of tunnelled.
     */
    private const val TUN_DNS = "198.18.0.2"

    /** Resolved through the proxy to prove the tunnel carries traffic. */
    private const val PROBE_DOMAIN = "cloudflare.com"

    /** Fits inside the app's 15s connect budget with the setup ahead of it. */
    private const val PROBE_TIMEOUT_MS = 8000L

    /**
     * Every start and stop runs here. Xray's instance handle is a package
     * global: a stop that lands before its start returns leaves the handle set
     * and every later connect fails with "xray is already running".
     */
    private val lifecycle = Executors.newSingleThreadExecutor { r ->
        Thread(r, "vless-lifecycle")
    }.asCoroutineDispatcher()

    private val scope = CoroutineScope(SupervisorJob() + lifecycle)

    private val _statusFlow = MutableStateFlow(ConnectionStatus.disconnected)
    val statusFlow: StateFlow<ConnectionStatus> = _statusFlow.asStateFlow()

    /** Set by [connect], consumed by the service once it is running. */
    @Volatile
    private var pending: XrayConfigPreparer.Prepared? = null

    @Volatile
    private var service: VlessVpnService? = null

    val status: ConnectionStatus
        get() = _statusFlow.value

    /**
     * Prepares the config and asks the service to start.
     *
     * Resolution happens here, before any tunnel exists, so the lookup cannot
     * route into it.
     */
    suspend fun connect(context: Context, rawConfig: String) = withContext(lifecycle) {
        check(VpnService.prepare(context) == null) { "VPN permission has not been granted" }
        // One session at a time. A second connect would otherwise overwrite
        // `pending` before the first service consumed it, so one start takes
        // the other's config and the other finds none and stops the service.
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

        pending = prepared
        _statusFlow.value = ConnectionStatus.connecting

        val intent = Intent(context, VlessVpnService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        } catch (e: Exception) {
            // The service never starts, so no teardown will ever run: without
            // this the status is stranded at `connecting` for good.
            pending = null
            _statusFlow.value = ConnectionStatus.disconnected
            throw e
        }
    }

    /**
     * Brings the tunnel up on [lifecycle] and reports the outcome on the main
     * thread.
     *
     * The service calls this from `onStartCommand`, which runs on the main
     * thread: establish(), Xray start and the readiness probe together block
     * for seconds, which is an ANR. Running here also puts start and stop on
     * the one thread, so a cancel mid-connect can no longer land between them.
     */
    fun startTunnelAsync(host: VlessVpnService, onResult: (Boolean) -> Unit) {
        scope.launch {
            val started = startTunnel(host)
            withContext(Dispatchers.Main) { onResult(started) }
        }
    }

    /**
     * Brings the tunnel up inside the service. Called once the service is in
     * the foreground, so a failure here can still report through the channel.
     */
    private fun startTunnel(host: VlessVpnService): Boolean {
        val prepared = pending ?: run {
            Log.w(TAG, "startTunnel with no prepared config")
            return false
        }
        pending = null

        var fd = -1
        try {
            // IPv6 is captured rather than left out. An address family with
            // no route does not get dropped, it falls through to the physical
            // interface, which leaks the real address while the UI says
            // connected. The exits are IPv4-only, so the core drops the frames
            // before its TCP stack can answer them -- see ipv4only.go.
            val builder = host.Builder()
                .setSession("Mysterium VLESS")
                .setMtu(MTU)
                .addAddress("198.18.0.1", 24)
                .addRoute("0.0.0.0", 0)
                .addAddress("fd00:2::1", 64)
                .addRoute("::", 0)
                .addDnsServer(TUN_DNS)

            val descriptor = builder.establish()
                ?: throw IllegalStateException("VpnService.establish returned null")
            // Handed to Go, which closes it on every path from here.
            fd = descriptor.detachFd()

            XRay.setProtector(Protector { socket -> host.protect(socket) })
            XRay.start(prepared.config.toString().toByteArray())

            // Ownership passes at the call, whether or not it succeeds, so the
            // descriptor is released here rather than after it returns.
            val handedOver = fd
            fd = -1
            try {
                XRay.startTun2Socks(
                    handedOver,
                    "127.0.0.1:${prepared.socksPort}",
                    prepared.username,
                    prepared.password,
                    MTU,
                )
            } catch (e: Exception) {
                // Xray is up but nothing is carrying packets to it.
                XRay.stop()
                throw e
            }

            try {
                XRay.probe(PROBE_DOMAIN, PROBE_TIMEOUT_MS)
            } catch (e: Exception) {
                // Established is not the same as working: a server that
                // refuses our credentials closes every connection, which would
                // otherwise be reported as a healthy tunnel.
                XRay.stopTun2Socks()
                XRay.stop()
                throw e
            }

            _statusFlow.value = ConnectionStatus.connected
            return true
        } catch (e: Exception) {
            Log.e(TAG, "failed to start tunnel", e)
            if (fd >= 0) {
                // Only reachable before the descriptor was handed to Go.
                runCatching { ParcelFileDescriptor.adoptFd(fd).close() }
            }
            _statusFlow.value = ConnectionStatus.disconnected
            return false
        }
    }

    /** Tears the tunnel down. Safe to call when nothing is running. */
    fun disconnect() {
        scope.launch { stopNow() }
    }

    /**
     * Bridge first, then Xray, matching the order the Apple provider uses:
     * stopping Xray first would strand in-flight packets against a proxy that
     * is already gone.
     */
    private fun stopNow() {
        if (_statusFlow.value != ConnectionStatus.disconnected) {
            _statusFlow.value = ConnectionStatus.disconnecting
        }
        runCatching { XRay.stopTun2Socks() }.onFailure { Log.w(TAG, "stopTun2Socks", it) }
        runCatching { XRay.stop() }.onFailure { Log.w(TAG, "XRay.stop", it) }
        runCatching { XRay.setProtector(null) }

        service?.let { host ->
            service = null
            // Reached from onDestroy as well, where the service is already on
            // its way out and the stop calls have nothing left to act on.
            runCatching { host.shutdown() }.onFailure { Log.w(TAG, "shutdown", it) }
        }
        pending = null
        _statusFlow.value = ConnectionStatus.disconnected
    }

    /**
     * Registers the service that owns the tunnel.
     *
     * At creation rather than once the tunnel is up: the window in between is
     * exactly when a previous session's teardown can still arrive, and only a
     * registered owner tells the two sessions apart.
     */
    fun onServiceCreated(host: VlessVpnService) {
        service = host
    }

    /** Called by the service when the system or the user stops it. */
    fun onServiceDestroyed(host: VlessVpnService) = stopIfOwner(host)

    /** The user revoked VPN permission, or another VPN app took over. */
    fun onRevoked(host: VlessVpnService) = stopIfOwner(host)

    /**
     * Tears the tunnel down, but only for the service that owns it.
     *
     * Android delivers onDestroy long after stopSelf, and the caller reconnects
     * as soon as the status reads `disconnected` — which stopNow sets before
     * the old service is gone. An unconditional teardown here therefore lands
     * on the session that replaced it and stops a tunnel it never owned.
     */
    private fun stopIfOwner(host: VlessVpnService) {
        scope.launch {
            if (service === host) {
                stopNow()
            }
        }
    }

    /**
     * Cumulative counters as the JSON string `tunnelStatistics` expects.
     *
     * Xray's own outbound counters are the source here, unlike Apple where the
     * hev bridge reports them. They measure the same flow; the difference is
     * the proxy framing.
     */
    fun statisticsJson(): String {
        if (!XRay.isRunning()) {
            return ""
        }
        var up = 0L
        var down = 0L
        XRay.queryStats("proxy").lineSequence().forEach { line ->
            val parts = line.split(">>>")
            if (parts.size == 2) {
                val value = parts[1].toLongOrNull() ?: 0L
                when (parts[0]) {
                    "uplink" -> up = value
                    "downlink" -> down = value
                }
            }
        }
        return JSONObject()
            .put("totalUpload", up)
            .put("totalDownload", down)
            .put("latestHandshake", 0)
            .toString()
    }
}
