package dev.overalls.mila.nativeui

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Records the named-terminal JNI calls the packaged adapter makes. */
private class TerminalBindings(private val receipt: String?) : MilaRustBindings {
    val calls = mutableListOf<String>()
    override fun abiVersion(): Int = 1
    override fun canonicalRoute(value: String): String? = value
    override fun machineActions(snapshot: ByteArray, host: String, port: Int?, index: Int): Int? = 0
    override fun sessionConnect(trust: ByteArray, host: String, publicKey: String, port: Int, timeoutMs: Int, signer: MilaDeviceKey): MilaSessionHandle? = null
    override fun sessionTerminalOpen(handle: Long, columns: Int, rows: Int): Long { calls += "legacy"; return 9 }
    override fun sessionTerminalNew(handle: Long, machine: String, requestId: String): ByteArray? {
        calls += "new $machine ${requestId.matches(Regex("^porsche-[0-9a-f]{32}$"))}"; return receipt?.toByteArray()
    }
    override fun sessionTerminalAttachSession(handle: Long, machine: String, terminal: String, columns: Int, rows: Int): Long {
        calls += "attach $machine $terminal $columns $rows"; return 41
    }
    override fun sessionLastRefusal(handle: Long): ByteArray? = "{\"error\":\"terminal_unavailable\"}".toByteArray()
    override fun sessionClose(handle: Long): Int = 0
    override fun threadCommandKind(value: String): Int = 1
    override fun machineCommandKind(value: String): Int = 1
    override fun terminalAttach(from: Long, columns: Int, rows: Int, readWrite: Boolean): Int = 0
    override fun terminalInput(length: Int, readWrite: Boolean): Int = 0
    override fun terminalResize(columns: Int, rows: Int, readWrite: Boolean): Int = 0
}

class MilaTerminalSessionTest {
    private val machine = UUID.fromString("123e4567-e89b-12d3-a456-426614174000")

    @Test fun terminalOpensNamedSessionAndNeverUsesLegacyAttach() {
        val bindings = TerminalBindings("{\"version\":1,\"status\":\"succeeded\",\"result\":{\"session_id\":\"0b6c2c1e-1d9f-4f55-9a43-7d0e0c1f2a3b\"}}")
        val adapter = LinkedMilaFfiAdapter(bindings)
        assertTrue(adapter.terminalOpen(machine, 80, 24).isFailure)
        adapter.bindSession(MilaSessionHandle(3L, bindings))
        assertEquals(41L, adapter.terminalOpen(machine, 80, 24).getOrThrow())
        assertTrue(adapter.terminalOpen(80, 24, true).isFailure)
        assertEquals(listOf("new $machine true", "attach $machine 0b6c2c1e-1d9f-4f55-9a43-7d0e0c1f2a3b 80 24"), bindings.calls)
    }

    @Test fun refusedOrMalformedReceiptNeverAttaches() {
        for (receipt in listOf(null, "{\"result\":{}}", "{\"result\":{\"session_id\":\"../x y\"}}")) {
            val bindings = TerminalBindings(receipt)
            val adapter = LinkedMilaFfiAdapter(bindings).apply { bindSession(MilaSessionHandle(3L, bindings)) }
            assertTrue(adapter.terminalOpen(machine, 80, 24).isFailure)
            assertTrue(bindings.calls.none { it.startsWith("attach") || it == "legacy" })
        }
    }

    @Test fun lastRefusalExposesOnlyClosedCodes() {
        val bindings = TerminalBindings(null)
        val adapter = LinkedMilaFfiAdapter(bindings).apply { bindSession(MilaSessionHandle(3L, bindings)) }
        assertEquals("terminal_unavailable", adapter.lastRefusal())
    }
}
