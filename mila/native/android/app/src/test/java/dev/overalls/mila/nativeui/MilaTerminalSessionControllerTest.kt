package dev.overalls.mila.nativeui

import java.util.Collections
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

private enum class TerminalStep { New, Attach, Read, Frame, Resize, Kill }

/** Holds synchronous JNI-shaped calls while the controller changes session on its caller. */
private class TerminalGate(private val step: TerminalStep) {
    val entered = CompletableDeferred<Unit>()
    private val released = CountDownLatch(1)

    fun block(current: TerminalStep) {
        if (current != step) return
        entered.complete(Unit)
        check(released.await(5, TimeUnit.SECONDS)) { "terminal test gate timed out" }
    }

    fun release() { released.countDown() }
}

private class TerminalAdapter(private val closedOnKill: Boolean = true) : MilaFfiAdapter {
    val calls: MutableList<String> = Collections.synchronizedList(mutableListOf<String>())
    var gate: TerminalGate? = null
    var newRefused = false
    var attachRefused = false
    var readResult: Result<ByteArray>? = null
    val terminalFrame = MilaTerminalFrame(80, 24, emptyList())
    var frameReads = 0
    private var nextHandle = 10L
    override suspend fun call(request: MilaFfiRequest) = MilaFfiResult.Failure(MilaFfiError.Unavailable)
    override fun terminalNew(machineId: UUID): Result<MilaTerminalSessionRef> {
        calls += "new"
        gate?.block(TerminalStep.New)
        return if (newRefused) Result.failure(IllegalStateException("refused")) else Result.success(MilaTerminalSessionRef(machineId, "term-1"))
    }
    override fun terminalAttach(session: MilaTerminalSessionRef, columns: Int, rows: Int): Result<Long> {
        calls += "attach ${session.id} ${columns}x$rows"
        gate?.block(TerminalStep.Attach)
        return if (attachRefused) Result.failure(IllegalStateException("refused")) else Result.success(nextHandle++)
    }
    override fun terminalPoll(handle: Long, maxBytes: Int): Result<ByteArray> = Result.success("out-$handle".toByteArray())
    override fun terminalReadWithin(handle: Long, waitMilliseconds: Int, maxBytes: Int): Result<ByteArray> {
        gate?.block(TerminalStep.Read)
        return readResult ?: terminalPoll(handle, maxBytes).map { byteArrayOf(0) + it }
    }
    override fun terminalFrame(handle: Long): Result<MilaTerminalFrame> {
        frameReads += 1
        gate?.block(TerminalStep.Frame)
        return Result.success(terminalFrame)
    }
    override fun terminalInputBytes(handle: Long, bytes: ByteArray): Result<Unit> { calls += "input $handle"; return Result.success(Unit) }
    override fun terminalResizeHandle(handle: Long, columns: Int, rows: Int): Result<Unit> {
        calls += "resize $handle ${columns}x$rows"
        gate?.block(TerminalStep.Resize)
        return Result.success(Unit)
    }
    override fun terminalClose(handle: Long): Result<Unit> { calls += "close $handle"; return Result.success(Unit) }
    override fun terminalEnd(session: MilaTerminalSessionRef): Result<Boolean> {
        calls += "kill ${session.id}"
        gate?.block(TerminalStep.Kill)
        return Result.success(closedOnKill)
    }
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

    @Test fun sessionChangesAndFreshAttachmentsClearThePreviousFrame() = runBlocking {
        val adapter = TerminalAdapter()
        val controller = MilaTerminalSessionController(adapter)
        controller.setSession(true)
        assertTrue(controller.open(machine, 80, 24))
        controller.poll()
        assertSame(adapter.terminalFrame, controller.frame)
        controller.setSession(false)
        assertNull(controller.frame)
        controller.setSession(true)
        assertTrue(controller.open(machine, 80, 24))
        controller.poll()
        assertTrue(controller.detach())
        assertTrue(controller.reattach(80, 24))
        assertNull(controller.frame)
        controller.poll()
        assertSame(adapter.terminalFrame, controller.frame)
        assertTrue(controller.open(machine, 100, 30))
        assertNull(controller.frame)
    }

    @Test fun lateNewReceiptsCannotAttachOrFailTheReplacementSession() = runBlocking {
        for (refused in listOf(false, true)) {
            val gate = TerminalGate(TerminalStep.New)
            val adapter = TerminalAdapter().apply { this.gate = gate; newRefused = refused }
            val controller = MilaTerminalSessionController(adapter)
            controller.setSession(true)
            val pending = async { controller.open(machine, 80, 24) }
            try {
                withTimeout(5_000) { gate.entered.await() }
                controller.setSession(false)
                controller.setSession(true)
            } finally { gate.release() }
            assertFalse(pending.await())
            assertEquals(MilaTerminalSessionState.Idle, controller.state)
            assertNull(controller.frame)
            assertEquals(listOf("new"), adapter.calls)
        }
    }

    @Test fun lateAttachReceiptsCannotRestoreTheReplacementSessionAndCloseOnlyTheirPty() = runBlocking {
        for (refused in listOf(false, true)) {
            val gate = TerminalGate(TerminalStep.Attach)
            val adapter = TerminalAdapter().apply { this.gate = gate; attachRefused = refused }
            val controller = MilaTerminalSessionController(adapter)
            controller.setSession(true)
            val pending = async { controller.open(machine, 80, 24) }
            try {
                withTimeout(5_000) { gate.entered.await() }
                controller.setSession(false)
                controller.setSession(true)
            } finally { gate.release() }
            assertFalse(pending.await())
            assertEquals(MilaTerminalSessionState.Idle, controller.state)
            assertNull(controller.frame)
            val expected = if (refused) listOf("new", "attach term-1 80x24") else listOf("new", "attach term-1 80x24", "close 10")
            assertEquals(expected, adapter.calls)
        }
    }

    @Test fun lateReadBytesAndFailuresCannotAffectTheReplacementSession() = runBlocking {
        val events: List<Result<ByteArray>> = listOf(
            Result.success(byteArrayOf(0, 65)),
            Result.success(byteArrayOf(2)),
            Result.success(byteArrayOf(7)),
            Result.failure(IllegalStateException("refused")),
        )
        for (event in events) {
            val adapter = TerminalAdapter()
            val controller = MilaTerminalSessionController(adapter)
            controller.setSession(true)
            assertTrue(controller.open(machine, 80, 24))
            controller.poll()
            assertSame(adapter.terminalFrame, controller.frame)
            val gate = TerminalGate(TerminalStep.Read)
            adapter.gate = gate
            adapter.readResult = event
            val pending = async { controller.poll() }
            try {
                withTimeout(5_000) { gate.entered.await() }
                controller.setSession(false)
                controller.setSession(true)
            } finally { gate.release() }
            assertNull(pending.await())
            assertEquals(MilaTerminalSessionState.Idle, controller.state)
            assertNull(controller.frame)
            assertEquals(1, adapter.frameReads)
        }
    }

    @Test fun lateFramesCannotRestoreOutputAfterSessionReplacement() = runBlocking {
        val gate = TerminalGate(TerminalStep.Frame)
        val adapter = TerminalAdapter().apply { this.gate = gate }
        val controller = MilaTerminalSessionController(adapter)
        controller.setSession(true)
        assertTrue(controller.open(machine, 80, 24))
        val pending = async { controller.poll() }
        try {
            withTimeout(5_000) { gate.entered.await() }
            controller.setSession(false)
            controller.setSession(true)
        } finally { gate.release() }
        assertNull(pending.await())
        assertNull(controller.frame)
        assertEquals(MilaTerminalSessionState.Idle, controller.state)
    }

    @Test fun lateResizeAndKillReceiptsCannotRestoreTheReplacementSession() = runBlocking {
        for (step in listOf(TerminalStep.Resize, TerminalStep.Kill)) {
            val gate = TerminalGate(step)
            val adapter = TerminalAdapter().apply { this.gate = gate }
            val controller = MilaTerminalSessionController(adapter)
            controller.setSession(true)
            assertTrue(controller.open(machine, 80, 24))
            val pending = async { if (step == TerminalStep.Resize) controller.resize(100, 30) else controller.kill() }
            try {
                withTimeout(5_000) { gate.entered.await() }
                controller.setSession(false)
                controller.setSession(true)
            } finally { gate.release() }
            assertFalse(pending.await())
            assertEquals(MilaTerminalSessionState.Idle, controller.state)
        }
    }

    @Test fun lateReadCannotChangeANewAttachmentWithinTheSameSession() = runBlocking {
        val adapter = TerminalAdapter()
        val controller = MilaTerminalSessionController(adapter)
        controller.setSession(true)
        assertTrue(controller.open(machine, 80, 24))
        val gate = TerminalGate(TerminalStep.Read)
        adapter.gate = gate
        val pending = async { controller.poll() }
        try {
            withTimeout(5_000) { gate.entered.await() }
            assertTrue(controller.detach())
            assertTrue(controller.reattach(100, 30))
        } finally { gate.release() }
        assertNull(pending.await())
        assertEquals(MilaTerminalSessionState.Live(MilaTerminalSessionRef(machine, "term-1"), 11, 100, 30), controller.state)
        assertNull(controller.frame)
        assertEquals(0, adapter.frameReads)
    }
}
