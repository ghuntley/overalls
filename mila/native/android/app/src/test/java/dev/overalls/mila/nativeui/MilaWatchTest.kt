package dev.overalls.mila.nativeui

import java.util.Collections
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test

/** Blocks a JNI-shaped acquisition until its coroutine owner has been cancelled. */
private class WatchAcquireGate {
    val entered = CompletableDeferred<Unit>()
    private val released = CountDownLatch(1)

    fun block() {
        entered.complete(Unit)
        check(released.await(5, TimeUnit.SECONDS)) { "watch acquisition gate timed out" }
    }

    fun release() { released.countDown() }
}

private class WatchAcquireAdapter(private val gate: WatchAcquireGate, private val blockReconnect: Boolean) : MilaFfiAdapter {
    val calls: MutableList<String> = Collections.synchronizedList(mutableListOf<String>())
    override suspend fun call(request: MilaFfiRequest): MilaFfiResult = MilaFfiResult.Failure(MilaFfiError.Unavailable)
    override fun watchOpen(machineIds: List<UUID>, threadIds: List<UUID>): Result<Long> {
        calls += "open"
        if (!blockReconnect) gate.block()
        return Result.success(10L)
    }
    override fun watchRead(handle: Long, waitMilliseconds: Int): Result<MilaWatchRead> {
        calls += "read $handle"
        return Result.success(MilaWatchRead.TransportLost)
    }
    override fun watchReconnect(handle: Long): Result<Long> {
        calls += "reconnect $handle"
        gate.block()
        return Result.success(20L)
    }
    override fun watchClose(handle: Long): Result<Unit> {
        calls += "close $handle"
        return Result.success(Unit)
    }
}

class MilaWatchTest {
    @Test fun groupsCoverAllDisplayedIdentitiesWithinRustBound() {
        val machines = List(500) { UUID.randomUUID() }
        val threads = List(256) { UUID.randomUUID() }
        val groups = MilaWatchFilters.groups(machines, threads)
        assertTrue(groups.all { it.machines.size + it.threads.size <= 64 })
        assertEquals(machines.toSet(), groups.flatMap { it.machines }.toSet())
        assertEquals(threads.toSet(), groups.flatMap { it.threads }.toSet())
        assertEquals(1, MilaWatchFilters.groups(emptyList(), emptyList()).size)
    }

    @Test fun duplicateRowsDoNotConsumeTheBoundedIdentityWindow() {
        val repeated = UUID.randomUUID()
        val later = List(500) { UUID.randomUUID() }
        val groups = MilaWatchFilters.groups(List(500) { repeated } + later, emptyList())
        assertEquals(500, groups.flatMap { it.machines }.toSet().size)
    }

    @Test fun cancellationDuringOpenClosesTheSuccessfullyAcquiredHandle() = runBlocking {
        val gate = WatchAcquireGate()
        val adapter = WatchAcquireAdapter(gate, blockReconnect = false)
        val watcher = launch {
            runMilaWatch(adapter, MilaWatchFilters(emptyList(), emptyList()), {}, { fail("unexpected authority loss") })
        }
        try {
            withTimeout(5_000) { gate.entered.await() }
            watcher.cancel()
        } finally { gate.release() }
        withTimeout(5_000) { watcher.join() }
        assertEquals(listOf("open", "close 10"), adapter.calls)
    }

    @Test fun cancellationDuringReconnectClosesTheReplacementHandle() = runBlocking {
        val gate = WatchAcquireGate()
        val adapter = WatchAcquireAdapter(gate, blockReconnect = true)
        val watcher = launch {
            runMilaWatch(adapter, MilaWatchFilters(emptyList(), emptyList()), {}, { fail("unexpected authority loss") })
        }
        try {
            withTimeout(5_000) { gate.entered.await() }
            watcher.cancel()
        } finally { gate.release() }
        withTimeout(5_000) { watcher.join() }
        assertEquals(listOf("open", "read 10", "reconnect 10", "close 20"), adapter.calls)
    }
}
