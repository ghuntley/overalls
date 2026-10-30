package dev.overalls.mila.nativeui

import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private class TerminalAdapter(private val closedOnKill: Boolean = true) : MilaFfiAdapter {
    val calls = mutableListOf<String>()
    var attachRefused = false
    private var nextHandle = 10L
    override suspend fun call(request: MilaFfiRequest) = MilaFfiResult.Failure(MilaFfiError.Unavailable)
    override fun terminalNew(machineId: UUID): Result<MilaTerminalSessionRef> {
        calls += "new"
        return Result.success(MilaTerminalSessionRef(machineId, "term-1"))
    }
    override fun terminalAttach(session: MilaTerminalSessionRef, columns: Int, rows: Int): Result<Long> {
        calls += "attach ${session.id} ${columns}x$rows"
        return if (attachRefused) Result.failure(IllegalStateException("refused")) else Result.success(nextHandle++)
    }
    override fun terminalPoll(handle: Long, maxBytes: Int): Result<ByteArray> = Result.success("out-$handle".toByteArray())
    override fun terminalInputBytes(handle: Long, bytes: ByteArray): Result<Unit> { calls += "input $handle"; return Result.success(Unit) }
    override fun terminalResizeHandle(handle: Long, columns: Int, rows: Int): Result<Unit> { calls += "resize $handle ${columns}x$rows"; return Result.success(Unit) }
    override fun terminalClose(handle: Long): Result<Unit> { calls += "close $handle"; return Result.success(Unit) }
    override fun terminalEnd(session: MilaTerminalSessionRef): Result<Boolean> { calls += "kill ${session.id}"; return Result.success(closedOnKill) }
}

class MilaTerminalSessionControllerTest {
    private val machine = UUID.fromString("00000000-0000-0000-0000-0000000000aa")

    @Test fun signedOutControllerNeverOpens() = runBlocking {
        val adapter = TerminalAdapter()
        val controller = MilaTerminalSessionController(adapter)
        assertFalse(controller.open(machine, 80, 24))
        assertTrue(adapter.calls.isEmpty())
    }

    @Test fun opensResizesDetachesReattachesAndKillsTheSameNamedSession() = runBlocking {
        val adapter = TerminalAdapter()
        val controller = MilaTerminalSessionController(adapter)
        controller.setSession(true)
        assertTrue(controller.open(machine, 100, 30))
        assertEquals("out-10", controller.poll()?.toString(Charsets.UTF_8))
        assertTrue(controller.send("echo\r".toByteArray()))
        assertTrue(controller.resize(132, 40))
        assertEquals(132, (controller.state as MilaTerminalSessionState.Live).columns)
        assertTrue(controller.detach())
        assertNull(controller.poll())
        assertTrue(controller.reattach(132, 40))
        assertTrue(controller.kill())
        assertEquals(MilaTerminalSessionState.Ended(MilaTerminalSessionRef(machine, "term-1")), controller.state)
        assertEquals(
            listOf("new", "attach term-1 100x30", "input 10", "resize 10 132x40", "close 10", "attach term-1 132x40", "close 11", "kill term-1"),
            adapter.calls,
        )
    }

    @Test fun killWithoutClosedReceiptIsAFailureNotEnded() = runBlocking {
        val controller = MilaTerminalSessionController(TerminalAdapter(closedOnKill = false))
        controller.setSession(true)
        assertTrue(controller.open(machine, 80, 24))
        assertFalse(controller.kill())
        assertTrue(controller.state is MilaTerminalSessionState.Failed)
    }

    @Test fun refusedAttachKeepsTheSessionForReconnect() = runBlocking {
        val adapter = TerminalAdapter().apply { attachRefused = true }
        val controller = MilaTerminalSessionController(adapter)
        controller.setSession(true)
        assertFalse(controller.open(machine, 80, 24))
        assertEquals(MilaTerminalSessionState.Failed(MilaTerminalSessionRef(machine, "term-1"), MilaTerminalFailure.Refused), controller.state)
        adapter.attachRefused = false
        assertTrue(controller.reattach(80, 24))
        assertEquals(listOf("new", "attach term-1 80x24", "attach term-1 80x24"), adapter.calls)
    }

    @Test fun signingOutDetachesWithoutKillingTheServerSession() = runBlocking {
        val adapter = TerminalAdapter()
        val controller = MilaTerminalSessionController(adapter)
        controller.setSession(true)
        assertTrue(controller.open(machine, 80, 24))
        controller.setSession(false)
        assertEquals(MilaTerminalSessionState.SignedOut, controller.state)
        assertFalse(controller.kill())
        assertEquals(listOf("new", "attach term-1 80x24", "close 10"), adapter.calls)
    }

    @Test fun refusesInvalidSessionIdsAndBounds() = runBlocking {
        assertTrue(runCatching { MilaTerminalSessionRef(machine, "bad id") }.isFailure)
        assertTrue(runCatching { MilaTerminalSessionRef(UUID(0L, 0L), "ok") }.isFailure)
        val controller = MilaTerminalSessionController(TerminalAdapter())
        controller.setSession(true)
        assertTrue(controller.open(machine, 80, 24))
        assertFalse(controller.resize(0, 24))
        assertFalse(controller.send(ByteArray(0)))
    }
}
