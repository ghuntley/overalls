package dev.overalls.mila.nativeui

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MilaFfiAdapterTest {
    @Test
    fun payloadCopiesInputAndOutput() {
        val input = byteArrayOf(1, 2, 3)
        val payload = MilaFfiPayload(input)
        input[0] = 9

        val output = payload.copyBytes()
        output[1] = 8

        assertArrayEquals(byteArrayOf(1, 2, 3), payload.copyBytes())
    }

    @Test
    fun unavailableAdapterFailsWithoutLeakingPayload() = runBlocking {
        val request = MilaFfiRequest(
            operation = MilaFfiOperation.Bootstrap,
            payload = MilaFfiPayload(byteArrayOf(4, 5)),
        )

        val result = UnavailableMilaFfiAdapter.call(request)

        assertEquals(MilaFfiResult.Failure(MilaFfiError.Unavailable), result)
    }

    @Test
    fun linkedAdapterReportsUnavailableWhenNativeLibraryIsAbsent() = runBlocking {
        val result = LinkedMilaFfiAdapter().call(MilaFfiRequest(MilaFfiOperation.Refresh))

        assertTrue(result is MilaFfiResult.Failure)
        assertEquals(MilaFfiError.Unavailable, (result as MilaFfiResult.Failure).error)
    }
}

class MilaSessionRefresherTest {
    @Test
    fun refreshPublishesTypedListing() = runBlocking {
        val listing = "{\"machines\":[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"demo\",\"status\":\"running\"}],\"has_more\":false}"
        val adapter = object : MilaFfiAdapter {
            override suspend fun call(request: MilaFfiRequest): MilaFfiResult = MilaFfiResult.Success(
                MilaFfiResponse(MilaFfiPayload(listing.toByteArray()))
            )
        }
        val state = MilaSessionRefresher.refresh(adapter)
        assertEquals("demo", (state as MilaSessionConnection.Connected).listing.machines.single().name)
    }

    @Test
    fun malformedListingFailsClosed() = runBlocking {
        val adapter = object : MilaFfiAdapter {
            override suspend fun call(request: MilaFfiRequest): MilaFfiResult = MilaFfiResult.Success(
                MilaFfiResponse(MilaFfiPayload("not-json".toByteArray()))
            )
        }
        assertTrue(MilaSessionRefresher.refresh(adapter) is MilaSessionConnection.Failed)
    }
}

internal open class FakeRustBindings(
    private val version: Int = 1,
    private val route: String? = "overalls://machines",
    private val actions: Int? = 5,
) : MilaRustBindings {
    override fun abiVersion(): Int = version
    override fun canonicalRoute(value: String): String? = route
    override fun machineActions(snapshot: ByteArray, host: String, port: Int?, index: Int): Int? = actions
    override fun sessionConnect(trust: ByteArray, host: String, publicKey: String, port: Int, timeoutMs: Int, signer: MilaDeviceKey): MilaSessionHandle? = null
    override fun threadCommandKind(value: String): Int = 1
    override fun machineCommandKind(value: String): Int = 10
    override fun terminalAttach(from: Long, columns: Int, rows: Int, readWrite: Boolean): Int = 0
    override fun terminalInput(length: Int, readWrite: Boolean): Int = 0
    override fun terminalResize(columns: Int, rows: Int, readWrite: Boolean): Int = 0
}

private class SessionReadBindings : FakeRustBindings() {
    val pages = mutableListOf<Boolean>()
    var closeCalls = 0

    override fun sessionRead(handle: Long, more: Boolean): Int {
        pages += more
        return 0
    }

    override fun sessionListing(handle: Long): ByteArray =
        "{\"machines\":[],\"has_more\":false}".toByteArray()

    override fun sessionSnapshot(handle: Long): ByteArray =
        "{\"machines\":[],\"has_more\":false}".toByteArray()

    override fun sessionClose(handle: Long): Int {
        closeCalls++
        return 0
    }
}

private open class SessionOperationBindings : FakeRustBindings() {
    var cloneCalls = 0
    var readLimit = 0

    override fun sessionMachineClone(handle: Long, machine: String, name: String, requestId: String): Int {
        cloneCalls++
        return 0
    }

    override fun sessionTerminalReadWithin(handle: Long, waitMilliseconds: Int, maxBytes: Int): ByteArray {
        readLimit = maxBytes
        return byteArrayOf(0)
    }
}

internal fun machineListingProjection(count: Int, hasMore: Boolean): ByteArray {
    val rows = (1..count).joinToString(",") { index ->
        "{\"id\":\"${UUID(0L, index.toLong())}\",\"name\":\"m$index\",\"status\":\"running\"}"
    }
    return "{\"machines\":[$rows],\"has_more\":$hasMore}".toByteArray()
}

internal open class PaginatedListingBindings(
    private val projections: List<ByteArray> = listOf(machineListingProjection(250, true), machineListingProjection(500, false)),
    private val refusedRead: Int? = null,
) : FakeRustBindings() {
    val pages = mutableListOf<Boolean>()
    val handles = mutableListOf<Long>()
    var listingReads = 0
    var closeCalls = 0
    var beforeRead: ((Int) -> Unit)? = null
    private var projectionIndex = 0

    init { require(projections.isNotEmpty()) }

    override fun sessionRead(handle: Long, more: Boolean): Int {
        pages += more
        handles += handle
        beforeRead?.invoke(pages.size)
        if (pages.size == refusedRead) return -5
        projectionIndex = minOf(pages.size - 1, projections.lastIndex)
        return 0
    }
    override fun sessionListing(handle: Long): ByteArray {
        listingReads += 1
        return projections[projectionIndex]
    }
    override fun sessionSnapshot(handle: Long): ByteArray? {
        val encoded = projections[projectionIndex]
        return encoded.takeUnless { MilaSessionListing.decode(it).hasMore }
    }
    override fun sessionClose(handle: Long): Int { closeCalls += 1; return 0 }
}

class MilaSessionHandleTest {
    @Test
    fun machineReadsUseTheInjectedAuthenticatedBinding() {
        val bindings = SessionReadBindings()
        val session = MilaSessionHandle(42L, bindings)

        assertEquals(0, session.readMachines())
        assertEquals(0, session.readMachines(more = true))
        assertEquals("{\"machines\":[],\"has_more\":false}", session.listing().toString(Charsets.UTF_8))
        assertEquals("{\"machines\":[],\"has_more\":false}", session.snapshot().toString(Charsets.UTF_8))
        session.close()

        assertEquals(listOf(false, true), bindings.pages)
        assertEquals(1, bindings.closeCalls)
        assertThrows(IllegalStateException::class.java) { session.listing() }
    }

    @Test
    fun cloneFencesClosedHandlesAndTerminalReadKeepsCallerLimit() {
        val bindings = SessionOperationBindings()
        val session = MilaSessionHandle(42L, bindings)
        val machine = java.util.UUID.randomUUID()
        assertTrue(session.machineClone(machine, "copy", milaRequestId()).isSuccess)
        assertEquals(1, bindings.cloneCalls)
        assertTrue(session.terminalReadWithin(7L, 0, 4096).isSuccess)
        assertEquals(4096, bindings.readLimit)
        session.close()
        assertTrue(session.machineClone(machine, "copy", milaRequestId()).isFailure)
        assertEquals(1, bindings.cloneCalls)
    }

    @Test
    fun notificationDeviceMutationsRequireCanonicalUuidIdentities() {
        val bindings = object : SessionOperationBindings() {
            var removeCalls = 0
            var preferenceCalls = 0
            val requestIds = mutableListOf<String>()
            override fun sessionDeviceRemoveWithRequest(handle: Long, device: String, requestId: String): Int {
                requestIds += requestId
                removeCalls++
                return 0
            }
            override fun sessionDevicePreferencesWithRequest(handle: Long, device: String, enabled: Boolean, requestId: String): Int {
                requestIds += requestId
                preferenceCalls++
                return 0
            }
            override fun sessionDeviceRemove(handle: Long, device: String): Int {
                removeCalls++
                return 0
            }
            override fun sessionDevicePreferences(handle: Long, device: String, enabled: Boolean): Int {
                preferenceCalls++
                return 0
            }
        }
        val session = MilaSessionHandle(42L, bindings)
        val device = "00000000-0000-0000-0000-00000000000a"

        assertTrue(session.notificationDeviceRemove(device).isSuccess)
        assertTrue(session.notificationDevicePreferences(device, enabled = true).isSuccess)
        assertTrue(session.notificationDeviceRemove("Phone").isFailure)
        assertTrue(session.notificationDevicePreferences(device.uppercase(), enabled = false).isFailure)
        assertEquals(1, bindings.removeCalls)
        assertEquals(1, bindings.preferenceCalls)
        assertEquals(2, bindings.requestIds.distinct().size)
    }
}

private class TrustBindings : FakeRustBindings() {
    var seenPinned: ByteArray? = null
    var seenFetched: ByteArray? = null
    override fun reconcileTrust(pinned: ByteArray?, fetched: ByteArray?, host: String, now: Long): ByteArray? {
        seenPinned = pinned?.copyOf()
        seenFetched = fetched?.copyOf()
        return when {
            fetched?.contentEquals(byteArrayOf(9)) == true -> null
            fetched != null -> byteArrayOf(7, 7)
            pinned != null -> pinned.copyOf()
            else -> null
        }
    }
}

private class MemoryTrustStore(var value: ByteArray? = null) : MilaTrustStore {
    var writes = 0
    override fun read(host: String): ByteArray? = value?.copyOf()
    override fun write(host: String, document: ByteArray) { value = document.copyOf(); writes++ }
}

class MilaLinkedFfiAdapterTest {
    @Test
    fun refreshLoadsEveryMachinePageBeforePublishingAndSnapshotting() = runBlocking {
        val bindings = PaginatedListingBindings()
        val adapter = LinkedMilaFfiAdapter(bindings)
        adapter.bindSession(MilaSessionHandle(42L, bindings))

        val listing = adapter.refreshListing().getOrThrow()

        assertFalse(listing.hasMore)
        assertEquals(500, listing.machines.size)
        assertEquals("m500", listing.machines.last().name)
        assertEquals(listOf(false, true), bindings.pages)
        assertEquals(listOf(42L, 42L), bindings.handles)
        assertEquals(500, MilaSessionListing.decode(adapter.snapshotData().getOrThrow()).machines.size)
    }

    @Test
    fun genericRefreshAlsoLoadsTheCompleteListing() = runBlocking {
        val bindings = PaginatedListingBindings()
        val adapter = LinkedMilaFfiAdapter(bindings)
        adapter.bindSession(MilaSessionHandle(42L, bindings))

        val result = adapter.call(MilaFfiRequest(MilaFfiOperation.Refresh)) as MilaFfiResult.Success

        assertEquals(500, MilaSessionListing.decode(result.response.payload.copyBytes()).machines.size)
        assertEquals(listOf(false, true), bindings.pages)
    }

    @Test
    fun refusedContinuationNeverPublishesThePartialListing() = runBlocking {
        for (generic in listOf(false, true)) {
            val bindings = PaginatedListingBindings(refusedRead = 2)
            val adapter = LinkedMilaFfiAdapter(bindings)
            adapter.bindSession(MilaSessionHandle(42L, bindings))

            if (generic) assertTrue(adapter.call(MilaFfiRequest(MilaFfiOperation.Refresh)) is MilaFfiResult.Failure)
            else assertTrue(adapter.refreshListing().isFailure)

            assertEquals(listOf(false, true), bindings.pages)
            assertEquals(1, bindings.listingReads)
            assertTrue(adapter.snapshotData().isFailure)
        }
    }

    @Test
    fun endlessContinuationStopsAtTheFiveHundredPageBound() = runBlocking {
        val bindings = PaginatedListingBindings(listOf(machineListingProjection(0, true)))
        val adapter = LinkedMilaFfiAdapter(bindings)
        adapter.bindSession(MilaSessionHandle(42L, bindings))

        assertTrue(adapter.refreshListing().isFailure)

        assertEquals(500, bindings.pages.size)
        assertFalse(bindings.pages.first())
        assertTrue(bindings.pages.drop(1).all { it })
        assertTrue(adapter.snapshotData().isFailure)
    }

    @Test
    fun replacementFencesAPaginatedReadBeforeWaitingForItsSessionMonitor() = runBlocking {
        val entered = CompletableDeferred<Unit>()
        val released = CountDownLatch(1)
        val bindings = PaginatedListingBindings().apply {
            beforeRead = { page -> if (page == 2) {
                entered.complete(Unit)
                check(released.await(5, TimeUnit.SECONDS)) { "listing read gate timed out" }
            } }
        }
        val adapter = LinkedMilaFfiAdapter(bindings)
        adapter.bindSession(MilaSessionHandle(42L, bindings))
        val pending = async(Dispatchers.Default) { adapter.refreshListing() }
        try {
            withTimeout(5_000) { entered.await() }
            val replacing = async(Dispatchers.IO) { adapter.bindSession(null) }
            withTimeout(5_000) { while (adapter.sshKeyStore() != null) delay(1) }
            released.countDown()
            withTimeout(5_000) { replacing.await() }
        } finally { released.countDown() }

        assertTrue(withTimeout(5_000) { pending.await() }.isFailure)
        assertEquals(1, bindings.listingReads)
        assertEquals(1, bindings.closeCalls)
        assertNull(adapter.sshKeyStore())
    }

    @Test
    fun rebindingTheSameSessionKeepsItLive() = runBlocking {
        val bindings = PaginatedListingBindings()
        val adapter = LinkedMilaFfiAdapter(bindings)
        val session = MilaSessionHandle(42L, bindings)
        adapter.bindSession(session)
        adapter.bindSession(session)

        assertEquals(0, bindings.closeCalls)
        assertTrue(adapter.refreshListing().isSuccess)
    }

    @Test
    fun lateOldMutationSuccessPreservesTheNewSessionsUncertainRequestId() = runBlocking {
        val machine = UUID(0L, 1L)
        var beforeOldCompletion: (() -> Unit)? = null
        val bindings = object : FakeRustBindings() {
            val newRequestIds = mutableListOf<String>()
            override fun sessionMachineAction(handle: Long, machine: String, action: String, requestId: String): Int {
                if (handle == 42L) {
                    // Fix the completion order without a scheduler race: replace the session
                    // and submit its uncertain operation before the old result is delivered.
                    beforeOldCompletion?.invoke()
                    return 0
                }
                newRequestIds += requestId
                return -5
            }
            override fun sessionClose(handle: Long): Int = 0
        }
        val adapter = LinkedMilaFfiAdapter(bindings)
        adapter.bindSession(MilaSessionHandle(42L, bindings))
        beforeOldCompletion = {
            adapter.bindSession(MilaSessionHandle(99L, bindings))
            runBlocking { assertTrue(adapter.machineAction(machine, MilaMachineCommand.Start).isFailure) }
        }

        assertTrue(adapter.machineAction(machine, MilaMachineCommand.Start).isSuccess)
        assertTrue(adapter.machineAction(machine, MilaMachineCommand.Start).isFailure)

        assertEquals(2, bindings.newRequestIds.size)
        assertEquals(bindings.newRequestIds.first(), bindings.newRequestIds.last())
    }

    @Test
    fun pushRegistrationUsesRustValidatorWithoutRetainingToken() {
        val bindings = object : FakeRustBindings() {
            var seen: String? = null
            override fun pushRegistrationValidate(provider: Int, environment: Int, token: String, appId: String, deployment: String, endpoint: String?): Int {
                seen = token
                return if (provider == 1 && environment == 1 && endpoint == null) 0 else -4
            }
        }
        val adapter = LinkedMilaFfiAdapter(bindings)
        adapter.bindSession(MilaSessionHandle(1, bindings))
        assertTrue(adapter.validatePushRegistration("provider-token", "com.example.mila", "mila.example", null).isSuccess)
        assertEquals("provider-token", bindings.seen)
        assertTrue(adapter.validatePushRegistration("", "com.example.mila", "mila.example", null).isFailure)
    }

    @Test
    fun genericCallsNeverEchoBootstrapOrMutationPayloads() = runBlocking {
        val bindings = SessionReadBindings()
        val adapter = LinkedMilaFfiAdapter(bindings)
        adapter.bindSession(MilaSessionHandle(42L, bindings))
        val payload = MilaFfiPayload(byteArrayOf(7, 8))
        for (operation in listOf(MilaFfiOperation.Bootstrap, MilaFfiOperation.MachineAction,
            MilaFfiOperation.ThreadAction, MilaFfiOperation.MachineCreate, MilaFfiOperation.Refresh)) {
            assertEquals(MilaFfiResult.Failure(MilaFfiError.Unavailable),
                adapter.call(MilaFfiRequest(operation, payload)))
        }
        assertTrue(bindings.pages.isEmpty())
    }

    @Test
    fun genericRefreshReadsTheBoundSessionAndRefusesAfterSignOut() = runBlocking {
        val bindings = SessionReadBindings()
        val adapter = LinkedMilaFfiAdapter(bindings)
        assertTrue(adapter.call(MilaFfiRequest(MilaFfiOperation.Refresh)) is MilaFfiResult.Failure)
        adapter.bindSession(MilaSessionHandle(42L, bindings))

        val result = adapter.call(MilaFfiRequest(MilaFfiOperation.Refresh)) as MilaFfiResult.Success
        assertEquals("{\"machines\":[],\"has_more\":false}", result.response.payload.copyBytes().toString(Charsets.UTF_8))
        assertEquals(listOf(false), bindings.pages)
        adapter.bindSession(null)
        assertTrue(adapter.call(MilaFfiRequest(MilaFfiOperation.Refresh)) is MilaFfiResult.Failure)
        assertEquals(listOf(false), bindings.pages)
    }

    @Test
    fun genericRefreshNeverReturnsCachedListingWhenRustReadFails() = runBlocking {
        val bindings = object : FakeRustBindings() {
            var listingCalls = 0
            override fun sessionRead(handle: Long, more: Boolean): Int = -5
            override fun sessionListing(handle: Long): ByteArray {
                listingCalls++
                return "{\"machines\":[],\"has_more\":false}".toByteArray()
            }
        }
        val adapter = LinkedMilaFfiAdapter(bindings)
        adapter.bindSession(MilaSessionHandle(42L, bindings))
        assertEquals(MilaFfiResult.Failure(MilaFfiError.Unavailable),
            adapter.call(MilaFfiRequest(MilaFfiOperation.Refresh)))
        assertEquals(0, bindings.listingCalls)
    }

    @Test
    fun everyThreadActionOverloadUsesTheAuthenticatedRustSession() = runBlocking {
        data class Seen(val handle: Long, val thread: String, val command: String,
            val secondary: String?, val input: String?, val requestId: String?)
        val bindings = object : FakeRustBindings() {
            val calls = mutableListOf<Seen>()
            var refuse = false
            override fun sessionThreadAction(handle: Long, thread: String, command: String,
                secondary: String?, input: String?, requestId: String?): ByteArray? {
                calls += Seen(handle, thread, command, secondary, input, requestId)
                return if (refuse) null else "{}".toByteArray()
            }
        }
        val linked = LinkedMilaFfiAdapter(bindings)
        val adapter: MilaFfiAdapter = linked
        val thread = UUID.fromString("00000000-0000-0000-0000-000000000001")
        val question = UUID.fromString("00000000-0000-0000-0000-000000000002")
        assertTrue(adapter.threadAction(thread, MilaThreadCommand.Show).isFailure)
        assertTrue(adapter.threadAction(thread, MilaThreadCommand.Prompt, "hello").isFailure)
        assertTrue(bindings.calls.isEmpty())

        linked.bindSession(MilaSessionHandle(42L, bindings))
        assertTrue(adapter.threadAction(thread, MilaThreadCommand.Show).isSuccess)
        assertTrue(adapter.threadAction(thread, MilaThreadCommand.Prompt, "hello").isSuccess)
        assertTrue(adapter.threadAction(thread, MilaThreadCommand.Answer, "yes", question).isSuccess)
        assertEquals(listOf("thread show", "thread prompt", "thread answer"), bindings.calls.map { it.command })
        assertTrue(bindings.calls.all { it.handle == 42L && it.thread == thread.toString() })
        assertEquals(null, bindings.calls[0].requestId)
        assertEquals("hello", bindings.calls[1].input)
        assertTrue(bindings.calls[1].requestId?.matches(MILA_REQUEST_ID) == true)
        assertEquals(question.toString(), bindings.calls[2].secondary)
        assertEquals("yes", bindings.calls[2].input)
        bindings.refuse = true
        assertTrue(adapter.threadAction(thread, MilaThreadCommand.Show).isFailure)
        assertTrue(adapter.threadAction(thread, MilaThreadCommand.Prompt, "hello again").isFailure)
    }

    @Test
    fun linkedAdapterRejectsIncompatibleAbi() = runBlocking {
        val result = LinkedMilaFfiAdapter(FakeRustBindings(version = 2))
            .call(MilaFfiRequest(MilaFfiOperation.Refresh))
        assertEquals(MilaFfiResult.Failure(MilaFfiError.IncompatibleAbi), result)
    }

    @Test
    fun canonicalRouteReturnsNativeResult() {
        val adapter = LinkedMilaFfiAdapter(FakeRustBindings(route = "overalls://threads"))
        assertEquals(Result.success("overalls://threads"), adapter.canonicalizeRoute("overalls://threads"))
    }

    @Test
    fun canonicalRouteRejectsNativeNull() {
        val adapter = LinkedMilaFfiAdapter(FakeRustBindings(route = null))
        assertTrue(adapter.canonicalizeRoute("bad").isFailure)
    }

    @Test
    fun machineActionsExposeOnlyRustPolicyBits() {
        val adapter = LinkedMilaFfiAdapter(FakeRustBindings(actions = 9))
        assertEquals(Result.success(9), adapter.machineActions(byteArrayOf(1), "mgmt.example.test", 443, 0))
    }

    @Test
    fun machineActionsRejectInvalidSnapshot() {
        val adapter = LinkedMilaFfiAdapter(FakeRustBindings(actions = null))
        assertTrue(adapter.machineActions(byteArrayOf(1), "mgmt.example.test", null, 0).isFailure)
    }

    @Test
    fun threadCommandKindUsesClosedRustTags() {
        val adapter = LinkedMilaFfiAdapter(FakeRustBindings())
        assertEquals(Result.success(MilaThreadCommand.List), adapter.threadCommandKind("thread ls"))
    }

    @Test
    fun machineCommandKindUsesClosedRustTags() {
        val adapter = LinkedMilaFfiAdapter(FakeRustBindings())
        assertEquals(Result.success(MilaMachineCommand.ShareAdd), adapter.machineCommandKind("machine share add"))
    }

    @Test
    fun machineCommandPaletteCoversClosedRustCatalog() {
        assertEquals(
            listOf(
                "ls", "show", "new", "resize", "start", "stop", "pause", "resume", "rm",
                "share add", "share remove", "web show", "web set",
            ),
            machineCommandChoices.map { it.command },
        )
        assertEquals(MilaMachineCommand.entries.size, machineCommandChoices.size)
    }

    @Test
    fun threadCommandPaletteCoversClosedRustCatalog() {
        assertEquals(
            listOf(
                "thread ls", "thread show", "thread turns", "thread prompt", "thread answer",
                "thread plan approve", "thread plan revise", "thread mode", "thread read",
            ),
            threadCommandChoices.map { it.second },
        )
        assertEquals(MilaThreadCommand.entries.size, threadCommandChoices.size)
    }
}

class MilaTrustEnrollmentTest {
    @Test
    fun fetchedTrustIsRustSelectedAndPersisted() = runBlocking {
        val bindings = TrustBindings()
        val store = MemoryTrustStore()
        val result = MilaTrustEnrollment(bindings, store, MilaTrustFetcher { byteArrayOf(1) })
            .resolve("mila.example")
        assertArrayEquals(byteArrayOf(7, 7), result.getOrThrow())
        assertEquals(1, store.writes)
        assertArrayEquals(byteArrayOf(1), bindings.seenFetched)
    }

    @Test
    fun transportFailureUsesPinnedTrustWithoutReplacingIt() = runBlocking {
        val bindings = TrustBindings()
        val store = MemoryTrustStore(byteArrayOf(4))
        val result = MilaTrustEnrollment(bindings, store, MilaTrustFetcher { throw IOException("offline") })
            .resolve("mila.example")
        assertArrayEquals(byteArrayOf(4), result.getOrThrow())
        assertEquals(0, store.writes)
        assertEquals(null, bindings.seenFetched)
    }

    @Test
    fun conflictingFetchedTrustFailsClosedAndDoesNotPersist() = runBlocking {
        val bindings = TrustBindings()
        val store = MemoryTrustStore(byteArrayOf(4))
        val result = MilaTrustEnrollment(bindings, store, MilaTrustFetcher { byteArrayOf(9) })
            .resolve("mila.example")
        assertTrue(result.isFailure)
        assertEquals(0, store.writes)
    }

    @Test
    fun malformedFetchedTrustDoesNotFallBackToPinnedTrust() = runBlocking {
        val bindings = TrustBindings()
        val store = MemoryTrustStore(byteArrayOf(4))
        val result = MilaTrustEnrollment(bindings, store, MilaTrustFetcher {
            throw IllegalArgumentException("malformed trust response")
        }).resolve("mila.example")
        assertTrue(result.isFailure)
        assertEquals(0, store.writes)
        assertEquals(null, bindings.seenFetched)
    }
}

private class TerminalSessionBindings : FakeRustBindings() {
    val calls = mutableListOf<String>()
    override fun sessionTerminalAttach(handle: Long, from: Long, columns: Int, rows: Int, readWrite: Boolean): Int {
        calls += "attach:$handle:$from:$columns:$rows:$readWrite"; return 0
    }
    override fun sessionTerminalInput(handle: Long, length: Int, readWrite: Boolean): Int {
        calls += "input:$handle:$length:$readWrite"; return 0
    }
    override fun sessionTerminalResize(handle: Long, columns: Int, rows: Int, readWrite: Boolean): Int {
        calls += "resize:$handle:$columns:$rows:$readWrite"; return 0
    }
    override fun sessionClose(handle: Long): Int = 0
}

class MilaAuthenticatedTerminalTest {
    @Test
    fun terminalOperationsUseTheBoundAuthenticatedSession() {
        val bindings = TerminalSessionBindings()
        val adapter = LinkedMilaFfiAdapter(bindings)
        val session = MilaSessionHandle(91L, bindings)
        adapter.bindSession(session)

        assertTrue(adapter.terminalAttach(7L, 120, 40, true).isSuccess)
        assertTrue(adapter.terminalInput(4, true).isSuccess)
        assertTrue(adapter.terminalResize(100, 30, true).isSuccess)
        assertEquals(
            listOf("attach:91:7:120:40:true", "input:91:4:true", "resize:91:100:30:true"),
            bindings.calls,
        )
        adapter.bindSession(null)
        assertTrue(adapter.terminalAttach(0, 80, 24, false).isFailure)
    }
}
