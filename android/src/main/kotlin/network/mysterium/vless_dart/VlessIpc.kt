package network.mysterium.vless_dart

import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Build
import java.io.File

/**
 * The process boundary between the plugin and the tunnel.
 *
 * [VlessVpnService] runs in `:vless` so the Xray core's Go runtime never
 * shares a process with wireguard-go's. Two Go runtimes in one process is
 * unsupported upstream (golang/go#65050): each one claims the process-wide
 * signal handlers, and the second to run takes a SIGSEGV with no tombstone,
 * because Go has replaced Android's debuggerd handler by then.
 *
 * Three things cross the boundary, each by the mechanism that survives the
 * failures of the other two:
 *
 * - Commands, plugin to core, as service start intents. A connect has to be a
 *   foreground-service start anyway.
 * - Status, core to plugin, as a package-scoped broadcast. Connectionless on
 *   purpose: a start that fails before anything has bound can still report.
 * - [IVlessCore], over a binding that never creates the service: counters on
 *   demand, and a binder whose death is the one signal left when the tunnel's
 *   process is killed and nothing in it runs to say so.
 *
 * Nothing on the plugin's side may touch an `XRay` class, directly or through
 * [VlessBackend]. The backend refuses to load outside the core's process, and
 * `test/android_process_boundary_test.dart` holds the rest of the line.
 */
internal object VlessIpc {
    /** Must match `android:process` on the service in the manifest. */
    const val CORE_PROCESS_SUFFIX = ":vless"

    /** Plugin -> core, as start commands. */
    const val ACTION_CONNECT = "network.mysterium.vless_dart.CONNECT"
    const val ACTION_DISCONNECT = "network.mysterium.vless_dart.DISCONNECT"

    /** Binds [IVlessCore]. Any other bind is the framework's, for VpnService. */
    const val ACTION_BIND = "network.mysterium.vless_dart.BIND"

    /** Core -> plugin. */
    const val ACTION_STATUS = "network.mysterium.vless_dart.STATUS"

    const val EXTRA_CONFIG = "config"
    const val EXTRA_SOCKS_PORT = "socksPort"
    const val EXTRA_USERNAME = "username"
    const val EXTRA_PASSWORD = "password"
    const val EXTRA_SERVER = "server"

    const val EXTRA_STATUS = "status"

    fun command(context: Context, action: String): Intent =
        Intent(context, VlessVpnService::class.java).setAction(action)

    /**
     * Scoped to our own package, and received by a receiver that is not
     * exported: the app trusts this for what it tells the user about their
     * protection, so no other app may read it or forge it.
     */
    fun status(context: Context, status: ConnectionStatus): Intent =
        Intent(ACTION_STATUS)
            .setPackage(context.packageName)
            .putExtra(EXTRA_STATUS, status.name)

    /** Lenient on purpose: an unknown name must not crash the plugin process. */
    fun statusOf(name: String?): ConnectionStatus =
        ConnectionStatus.entries.firstOrNull { it.name == name } ?: ConnectionStatus.unknown

    fun inCoreProcess(): Boolean = isCoreProcess(processName())

    /** The rule on its own, so it can be tested without a device. */
    fun isCoreProcess(name: String): Boolean = name.endsWith(CORE_PROCESS_SUFFIX)

    fun processName(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            Application.getProcessName()
        } else {
            // NUL-terminated, and padded with more of them.
            File("/proc/self/cmdline").readText().substringBefore('\u0000')
        }
}
