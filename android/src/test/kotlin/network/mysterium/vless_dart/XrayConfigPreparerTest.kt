package network.mysterium.vless_dart

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue
import org.json.JSONObject

class XrayConfigPreparerTest {

    /** The shape Dart emits: port 0, no accounts, address as a hostname. */
    private fun rawConfig(): String = """
        {
          "inbounds": [
            {
              "tag": "socks-in",
              "protocol": "socks",
              "listen": "127.0.0.1",
              "port": 0,
              "settings": {"auth": "password", "accounts": [], "udp": true}
            }
          ],
          "outbounds": [
            {
              "tag": "proxy",
              "protocol": "vless",
              "settings": {
                "vnext": [{"address": "vpn.example.com", "port": 443, "users": []}]
              },
              "streamSettings": {
                "network": "ws",
                "security": "tls",
                "tlsSettings": {"serverName": "vpn.example.com", "allowInsecure": false},
                "wsSettings": {"path": "/vless", "host": "vpn.example.com"}
              }
            },
            {"tag": "direct", "protocol": "freedom"}
          ]
        }
    """.trimIndent()

    private fun socksSettings(config: JSONObject): JSONObject =
        config.getJSONArray("inbounds").getJSONObject(0).getJSONObject("settings")

    private fun proxyStream(config: JSONObject): JSONObject =
        config.getJSONArray("outbounds").getJSONObject(0).getJSONObject("streamSettings")

    @Test
    fun `binds the socks inbound to a real port`() {
        val prepared = XrayConfigPreparer.prepare(rawConfig())

        assertTrue(prepared.socksPort in 1..65535, "got ${prepared.socksPort}")
        assertEquals(
            prepared.socksPort,
            prepared.config.getJSONArray("inbounds").getJSONObject(0).getInt("port"),
        )
    }

    @Test
    fun `mints credentials the bridge can authenticate with`() {
        val prepared = XrayConfigPreparer.prepare(rawConfig())
        val accounts = socksSettings(prepared.config).getJSONArray("accounts")

        assertEquals("password", socksSettings(prepared.config).getString("auth"))
        assertEquals(1, accounts.length())
        assertEquals(prepared.username, accounts.getJSONObject(0).getString("user"))
        assertEquals(prepared.password, accounts.getJSONObject(0).getString("pass"))
        // Hex of 16 and 32 bytes.
        assertEquals(32, prepared.username.length)
        assertEquals(64, prepared.password.length)
    }

    @Test
    fun `credentials are per session`() {
        // Reusing them across sessions would let anything that saw one set
        // keep using the proxy after the tunnel it belonged to went away.
        val first = XrayConfigPreparer.prepare(rawConfig())
        val second = XrayConfigPreparer.prepare(rawConfig())

        assertNotEquals(first.password, second.password)
        assertNotEquals(first.username, second.username)
    }

    @Test
    fun `reports the server address before it is resolved`() {
        assertEquals("vpn.example.com", XrayConfigPreparer.prepare(rawConfig()).serverAddress)
    }

    @Test
    fun `pinning replaces only the dial address`() {
        val prepared = XrayConfigPreparer.prepare(rawConfig())
        XrayConfigPreparer.pinServerAddress(prepared.config, "203.0.113.7")

        val vnext = prepared.config.getJSONArray("outbounds").getJSONObject(0)
            .getJSONObject("settings").getJSONArray("vnext").getJSONObject(0)
        assertEquals("203.0.113.7", vnext.getString("address"))

        // TLS and the WebSocket Host must keep the hostname: pinning them to
        // the IP fails certificate validation and the exit's routing.
        val stream = proxyStream(prepared.config)
        assertEquals(
            "vpn.example.com",
            stream.getJSONObject("tlsSettings").getString("serverName"),
        )
        assertEquals("vpn.example.com", stream.getJSONObject("wsSettings").getString("host"))
    }

    @Test
    fun `rejects a config with no socks inbound`() {
        val raw = JSONObject(rawConfig())
        raw.getJSONArray("inbounds").getJSONObject(0).put("protocol", "http")

        assertFailsWith<IllegalArgumentException> { XrayConfigPreparer.prepare(raw.toString()) }
    }

    @Test
    fun `rejects a config with no proxy outbound`() {
        val raw = JSONObject(rawConfig())
        raw.getJSONArray("outbounds").getJSONObject(0).put("tag", "something-else")

        assertFailsWith<IllegalArgumentException> { XrayConfigPreparer.prepare(raw.toString()) }
    }
}
