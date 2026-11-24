package network.mysterium.vless_dart

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.collect

class VlessDartPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener {

    private companion object {
        const val TAG = "VlessDartPlugin"
        const val METHOD_CHANNEL = "id.mysteriumvpn.vless_dart/vpncontrol"
        const val EVENT_CHANNEL = "id.mysteriumvpn.vless_dart/vpnstatus"
        const val VPN_CONSENT_REQUEST = 10015
    }

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private val broadcaster = ConnectionStatusBroadcaster()
    private var scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private var activityBinding: ActivityPluginBinding? = null
    private val activity: Activity?
        get() = activityBinding?.activity

    private var consentResult: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(broadcaster)

        // Rebuilt per attach: cancel() is permanent, so reusing the old scope
        // after a detach would silently start no collector and swallow every
        // method call launched into it.
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        // The tunnel runs in `:vless`; this listens for the state it
        // broadcasts. Nothing here may reach the core directly -- see
        // [VlessIpc] for why.
        VlessClient.attach(context)
        scope.launch {
            VlessClient.statusFlow.collect { broadcaster.send(it) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        VlessClient.detach(context)
        // Stops the status collector; without this a re-attach adds a second
        // one against a broadcaster the first no longer feeds.
        scope.cancel()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // Apple needs an extension bundle id and a description; Android
            // declares its service in the manifest and needs neither.
            "initialize" -> result.success(null)
            "status" -> result.success(VlessClient.status.name)
            // Served from the last broadcast rather than the core, so this is
            // a cheap local read now and needs no thread of its own.
            "tunnelStatistics" -> result.success(VlessClient.statisticsJson())
            "checkTunnelConfiguration" -> result.success(hasConsent())
            "setupTunnel" -> requestConsent(result)
            "connect" -> connect(call, result)
            // Android keeps no persistent profile: consent is granted to the
            // app and revoked from system settings, never by us.
            "disconnect", "removeTunnelConfiguration" -> {
                VlessClient.disconnect(context)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun connect(call: MethodCall, result: MethodChannel.Result) {
        val config = call.argument<String>("config")
        if (config.isNullOrEmpty()) {
            result.error("err_config_empty", "No config provided", null)
            return
        }
        if (!hasConsent()) {
            result.error("err_permission", "VPN permission has not been granted", null)
            return
        }
        scope.launch {
            try {
                VlessClient.connect(context, config)
                result.success(null)
            } catch (e: Exception) {
                Log.e(TAG, "connect failed", e)
                result.error("err_connect", e.message, null)
            }
        }
    }

    /**
     * Consent is granted to the app, not to a service, so the application
     * context answers this as well as the activity does — and prepare() throws
     * on a null context, which is what a detached plugin would pass.
     */
    private fun hasConsent(): Boolean = VpnService.prepare(activity ?: context) == null

    private fun requestConsent(result: MethodChannel.Result) {
        val intent = VpnService.prepare(activity ?: context)
        if (intent == null) {
            result.success(null)
            return
        }
        val host = activity
        if (host == null) {
            result.error("err_setup_tunnel", "Activity is not attached", null)
            return
        }
        if (consentResult != null) {
            result.error("err_setup_tunnel", "A consent dialog is already open", null)
            return
        }
        consentResult = result
        host.startActivityForResult(intent, VPN_CONSENT_REQUEST)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != VPN_CONSENT_REQUEST) return false
        val pending = consentResult ?: return true
        consentResult = null
        if (resultCode == Activity.RESULT_OK) {
            pending.success(null)
        } else {
            pending.error("err_setup_tunnel", "VPN permission was denied", null)
        }
        return true
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        // A consent dialog in flight will never deliver its result now, so the
        // Dart Future is resolved here instead of hanging forever.
        consentResult?.error("err_setup_tunnel", "Activity detached during consent", null)
        consentResult = null
    }
}
