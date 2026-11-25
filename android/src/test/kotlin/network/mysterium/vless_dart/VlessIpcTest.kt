package network.mysterium.vless_dart

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class VlessIpcTest {

    /**
     * Status crosses from `:vless` to the plugin as `status.name` in a
     * broadcast extra. A name that does not come back as itself would be read
     * as `unknown` by the process that tells the user whether they are
     * protected.
     */
    @Test
    fun `every status survives the process boundary`() {
        for (status in ConnectionStatus.entries) {
            assertEquals(status, VlessIpc.statusOf(status.name))
        }
    }

    /**
     * The two halves ship in one apk, but a broadcast can outlive an update:
     * the receiver must not throw on a name it has never heard of.
     */
    @Test
    fun `a name this build does not know is unknown`() {
        assertEquals(ConnectionStatus.unknown, VlessIpc.statusOf("reasserting"))
        assertEquals(ConnectionStatus.unknown, VlessIpc.statusOf(""))
        assertEquals(ConnectionStatus.unknown, VlessIpc.statusOf(null))
        // Matched exactly: Dart lower-cases what it receives, this side does not.
        assertEquals(ConnectionStatus.unknown, VlessIpc.statusOf("Connected"))
    }

    /**
     * This decides whether VlessBackend, and with it the core's Go runtime,
     * may load. Too loose and the guard passes in the app's own process, which
     * is the crash the split exists to prevent.
     */
    @Test
    fun `only the tunnel's process counts as the core's`() {
        assertTrue(VlessIpc.isCoreProcess("com.example.app:vless"))

        assertFalse(VlessIpc.isCoreProcess("com.example.app"))
        // An app whose own package happens to end in the word.
        assertFalse(VlessIpc.isCoreProcess("com.example.vless"))
        assertFalse(VlessIpc.isCoreProcess("com.example.app:vless2"))
        assertFalse(VlessIpc.isCoreProcess("com.example.app:other"))
        assertFalse(VlessIpc.isCoreProcess(""))
    }
}
