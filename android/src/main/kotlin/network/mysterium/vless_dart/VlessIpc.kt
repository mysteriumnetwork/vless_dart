package network.mysterium.vless_dart

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build

/**
 * The process boundary between the plugin and the tunnel.
 *
 * [VlessVpnService] runs in `:vless` so the Xray core's Go runtime never
 * shares a process with wireguard-go's. Two Go runtimes in one process is
 * unsupported upstream (golang/go#65050): each one claims the process-wide
 * signal handlers, and the second to run takes a SIGSEGV with no tombstone,
 * because Go has replaced Android's debuggerd handler by then.
 *
 * Commands travel as service intents, state comes back as a package-scoped
 * broadcast. Nothing richer is needed: the Dart side already learns the
 * outcome of a connect from the status stream rather than its return value.
 */
internal object VlessIpc {
    /** Plugin -> `:vless`. */
    const val ACTION_CONNECT = "network.mysterium.vless_dart.CONNECT"
    const val ACTION_DISCONNECT = "network.mysterium.vless_dart.DISCONNECT"

    /** `:vless` -> plugin. */
    const val ACTION_STATE = "network.mysterium.vless_dart.STATE"

    const val EXTRA_CONFIG = "config"
    const val EXTRA_SOCKS_PORT = "socksPort"
    const val EXTRA_USERNAME = "username"
    const val EXTRA_PASSWORD = "password"
    const val EXTRA_SERVER = "server"

    const val EXTRA_STATUS = "status"
    const val EXTRA_UPLOAD = "upload"
    const val EXTRA_DOWNLOAD = "download"

    fun command(context: Context, action: String): Intent =
        Intent(context, VlessVpnService::class.java).setAction(action)

    /**
     * Scoped to our own package. The broadcast carries session counters, and
     * an implicit one would hand them to anything with a matching filter.
     */
    fun state(context: Context): Intent =
        Intent(ACTION_STATE).setPackage(context.packageName)

    fun registerStateReceiver(context: Context, receiver: BroadcastReceiver) {
        val filter = IntentFilter(ACTION_STATE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
    }

    /** Lenient on purpose: an unknown name must not crash the plugin process. */
    fun statusOf(name: String?): ConnectionStatus =
        ConnectionStatus.entries.firstOrNull { it.name == name } ?: ConnectionStatus.unknown
}
