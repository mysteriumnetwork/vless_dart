package network.mysterium.vless_dart

import kotlin.test.Test
import kotlin.test.assertEquals

class ConnectionStatusTest {

    /**
     * The names cross the event channel verbatim and are matched by string in
     * `lib/vpn_status.dart`. A rename here does not fail any build; it just
     * makes the app see `unknown` forever and stop tracking the tunnel.
     */
    @Test
    fun `names match the Dart contract`() {
        assertEquals(
            listOf("connecting", "connected", "disconnecting", "disconnected", "unknown"),
            ConnectionStatus.entries.map { it.name },
        )
    }
}
