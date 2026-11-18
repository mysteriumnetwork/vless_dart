package network.mysterium.vless_dart

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/** Forwards status changes to the Dart event channel on the main thread. */
class ConnectionStatusBroadcaster : EventChannel.StreamHandler {
    private val handler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    @Volatile
    private var last: ConnectionStatus? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        // The service outlives the engine, so Dart commonly subscribes over a
        // tunnel that is already up. The collector's replayed value arrives
        // before this sink exists and is dropped, leaving the stream silent
        // until the next transition.
        last?.let { status -> handler.post { events?.success(status.name) } }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun send(status: ConnectionStatus) {
        last = status
        val target = sink ?: return
        handler.post { target.success(status.name) }
    }
}
