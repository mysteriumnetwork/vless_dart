package network.mysterium.vless_dart

import java.net.InetAddress
import java.net.ServerSocket
import java.security.SecureRandom
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fills in the parts of the Xray config only the device can know.
 *
 * Dart emits the config with `port: 0` and no accounts on purpose, so its
 * output stays comparable in golden tests. The loopback port and the
 * per-session SOCKS credentials are minted here, so nothing else on the device
 * can use the proxy.
 */
object XrayConfigPreparer {

    /** A config ready to start, plus what the tun2socks bridge needs to reach it. */
    data class Prepared(
        val config: JSONObject,
        val socksPort: Int,
        val username: String,
        val password: String,
        /** The VLESS server as the config names it, before any resolution. */
        val serverAddress: String,
    )

    fun prepare(raw: String): Prepared {
        val config = JSONObject(raw)
        val port = freeLoopbackPort()
        val username = randomHex(16)
        val password = randomHex(32)

        val inbounds = config.optJSONArray("inbounds")
            ?: throw IllegalArgumentException("config has no inbounds")
        val socks = (0 until inbounds.length())
            .map { inbounds.getJSONObject(it) }
            .firstOrNull { it.optString("protocol") == "socks" }
            ?: throw IllegalArgumentException("config has no socks inbound")

        socks.put("port", port)
        val settings = socks.optJSONObject("settings") ?: JSONObject().also {
            socks.put("settings", it)
        }
        settings.put("auth", "password")
        settings.put(
            "accounts",
            JSONArray().put(JSONObject().put("user", username).put("pass", password)),
        )

        return Prepared(
            config = config,
            socksPort = port,
            username = username,
            password = password,
            serverAddress = proxyVnext(config).getString("address"),
        )
    }

    /**
     * Replaces the proxy outbound's address with a resolved IP literal.
     *
     * Android's resolver does the lookup rather than Xray's: Go's pure-Go
     * resolver has no usable `/etc/resolv.conf` here, and a lookup attempted
     * after the tunnel is up would route into it. TLS `serverName` and the
     * WebSocket `Host` header are deliberately untouched and keep the
     * hostname, or the handshake fails.
     */
    fun pinServerAddress(config: JSONObject, resolved: String) {
        proxyVnext(config).put("address", resolved)
    }

    private fun proxyVnext(config: JSONObject): JSONObject {
        val outbounds = config.optJSONArray("outbounds")
            ?: throw IllegalArgumentException("config has no outbounds")
        val proxy = (0 until outbounds.length())
            .map { outbounds.getJSONObject(it) }
            .firstOrNull { it.optString("tag") == "proxy" }
            ?: throw IllegalArgumentException("config has no proxy outbound")
        val vnext = proxy.getJSONObject("settings").optJSONArray("vnext")
        if (vnext == null || vnext.length() == 0) {
            throw IllegalArgumentException("proxy outbound has no vnext entry")
        }
        return vnext.getJSONObject(0)
    }

    /**
     * Binding to port 0 and reading the assignment back races anything else
     * claiming it in between. A fixed port would instead fail every time two
     * sessions overlap.
     */
    private fun freeLoopbackPort(): Int =
        ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }

    private fun randomHex(bytes: Int): String {
        val buffer = ByteArray(bytes)
        SecureRandom().nextBytes(buffer)
        return buffer.joinToString("") { "%02x".format(it) }
    }
}
