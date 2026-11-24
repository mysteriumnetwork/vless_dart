package network.mysterium.vless_dart

import XRay.Protector
import XRay.XRay
import android.content.Context
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.util.Log
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

/**
 * Owns the Xray core and the tun2socks bridge, inside the `:vless` process.
 *
 * A singleton because both are process-wide globals in Go: starting a second
 * instance fails rather than running alongside the first. The service can also
 * be recreated by the system without the plugin ever attaching, so state
 * cannot live in either of them.
 *
 * Unreachable from the app's main process, and nothing there may make it
 * reachable -- see [VlessIpc]. The plugin's half is [VlessClient].
 */
object VlessBackend {
    private const val TAG = "VlessBackend"
    const val MTU = 1500

    init {
        // Everything that touches the core goes through this object, so this
        // is where a caller in the wrong process is stopped: here, loudly and
        // by name, instead of by a SIGSEGV with no tombstone at some later
        // WireGuard connect. See [VlessIpc].
        check(VlessIpc.inCoreProcess()) {
            "VlessBackend reached from process '${VlessIpc.processName()}'. The Xray core may " +
                "only load in '${VlessIpc.CORE_PROCESS_SUFFIX}'; the plugin's side is VlessClient."
        }
    }

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

    @Volatile
    private var service: VlessVpnService? = null

    /** Set by the service, which is the only way into this process. */
    @Volatile
    private var appContext: Context? = null

    /**
     * Held across a status write and its broadcast.
     *
     * Transitions come from the lifecycle thread and announcements from a
     * binder thread. Unordered, the later broadcast can carry the older
     * status, and the plugin keeps whichever arrives last: a teardown that
     * ends on `disconnecting` there never ends at all.
     */
    private val publishLock = Any()

    val status: ConnectionStatus
        get() = _statusFlow.value

    /**
     * Assigns and broadcasts in one step.
     *
     * The plugin lives in another process, so a status nothing broadcasts is
     * a status it never sees. Every transition goes through here.
     */
    private fun setStatus(next: ConnectionStatus) = synchronized(publishLock) {
        _statusFlow.value = next
        broadcast(next)
    }

    /**
     * Repeats the status for a plugin that has just found this process.
     *
     * Only for a live session. `disconnected` is never news to a plugin that
     * is asking, and to one whose connect is still on its way here it would be
     * wrong: it would see its own start reported as already over.
     */
    fun announce() = synchronized(publishLock) {
        val current = _statusFlow.value
        if (current != ConnectionStatus.disconnected) {
            broadcast(current)
        }
    }

    private fun broadcast(status: ConnectionStatus) {
        val context = appContext ?: return
        context.sendBroadcast(VlessIpc.status(context, status))
    }

    /**
     * What the plugin's process may call, handed out by the service's onBind.
     *
     * Owned here rather than by a service instance: the plugin watches this
     * binder to learn that the process died, which no instance outlives.
     */
    val binder: IBinder = object : IVlessCore.Stub() {
        override fun counters(): LongArray {
            // An exception would not cross as one: the caller would be left
            // reading an empty reply.
            val (up, down) = runCatching { this@VlessBackend.counters() }.getOrDefault(0L to 0L)
            return longArrayOf(up, down)
        }

        override fun announce() {
            this@VlessBackend.announce()
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
    fun startTunnelAsync(
        host: VlessVpnService,
        prepared: XrayConfigPreparer.Prepared,
        onResult: (Boolean) -> Unit,
    ) {
        // Set here, by the side that accepted the session. Until this the
        // plugin only assumes `connecting`, and a stop that arrives during the
        // bring-up would find `disconnected` and skip `disconnecting`.
        setStatus(ConnectionStatus.connecting)
        scope.launch {
            val started = startTunnel(host, prepared)
            withContext(Dispatchers.Main) { onResult(started) }
        }
    }

    /**
     * Brings the tunnel up inside the service. Called once the service is in
     * the foreground, so a failure here can still report through the channel.
     */
    private fun startTunnel(
        host: VlessVpnService,
        prepared: XrayConfigPreparer.Prepared,
    ): Boolean {
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

            setStatus(ConnectionStatus.connected)
            return true
        } catch (e: Exception) {
            Log.e(TAG, "failed to start tunnel", e)
            if (fd >= 0) {
                // Only reachable before the descriptor was handed to Go.
                runCatching { ParcelFileDescriptor.adoptFd(fd).close() }
            }
            setStatus(ConnectionStatus.disconnected)
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
            setStatus(ConnectionStatus.disconnecting)
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
        setStatus(ConnectionStatus.disconnected)
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
        appContext = host.applicationContext
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
     * Cumulative proxy counters.
     *
     * Xray's own outbound counters are the source here, unlike Apple where the
     * hev bridge reports them. They measure the same flow; the difference is
     * the proxy framing.
     *
     * Only this process can read them; the plugin asks through [binder].
     */
    fun counters(): Pair<Long, Long> {
        if (!XRay.isRunning()) {
            return 0L to 0L
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
        return up to down
    }
}
