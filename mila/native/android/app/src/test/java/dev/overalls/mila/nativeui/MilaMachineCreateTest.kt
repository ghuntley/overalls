package dev.overalls.mila.nativeui

import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

private data class CreateCall(val handle: Long, val name: String, val cpu: Int, val memory: Int, val disk: Int, val requestId: String)
private data class ResizeCall(val machine: String, val cpu: Int, val memory: Int, val disk: Int, val requestId: String)

/** Records the exact JNI arguments the packaged adapter would pass to Rust. */
private class FormBindings(private val status: Int = 0) : MilaRustBindings {
    val creates = mutableListOf<CreateCall>()
    val resizes = mutableListOf<ResizeCall>()
    override fun abiVersion(): Int = 1
    override fun canonicalRoute(value: String): String? = value
    override fun machineActions(snapshot: ByteArray, host: String, port: Int?, index: Int): Int? = 0
    override fun sessionConnect(trust: ByteArray, host: String, publicKey: String, port: Int, timeoutMs: Int, signer: MilaDeviceKey): MilaSessionHandle? = null
    override fun sessionMachineCreate(handle: Long, name: String, cpu: Int, memory: Int, disk: Int, requestId: String): Int {
        creates += CreateCall(handle, name, cpu, memory, disk, requestId); return status
    }
    override fun sessionMachineResize(handle: Long, machine: String, cpu: Int, memory: Int, disk: Int, requestId: String): Int {
        resizes += ResizeCall(machine, cpu, memory, disk, requestId); return status
    }
    override fun sessionClose(handle: Long): Int = 0
    override fun threadCommandKind(value: String): Int = 1
    override fun machineCommandKind(value: String): Int = 1
    override fun terminalAttach(from: Long, columns: Int, rows: Int, readWrite: Boolean): Int = 0
    override fun terminalInput(length: Int, readWrite: Boolean): Int = 0
    override fun terminalResize(columns: Int, rows: Int, readWrite: Boolean): Int = 0
}

/** Adapter whose mutation completes only when the test releases it. */
private class GatedAdapter : MilaFfiAdapter {
    val gate = CompletableDeferred<Result<Unit>>()
    var calls = 0
    override suspend fun call(request: MilaFfiRequest): MilaFfiResult = MilaFfiResult.Failure(MilaFfiError.Unavailable)
    override suspend fun machineCreate(request: MilaMachineCreateRequest): Result<Unit> { calls += 1; return gate.await() }
}

class MilaMachineCreateTest {
    private val id = UUID.fromString("00000000-0000-0000-0000-00000000000a")
    private val listing = MilaSessionListing(listOf(MilaMachineRow(id, "build", "running")), false)

    @Test fun createRequestBoundsMirrorRustSession() {
        assertTrue(MilaMachineCreateRequest.parse("dev-box_1", "2", "1024", "20").isSuccess)
        assertEquals(MilaMachineField.Name, (MilaMachineCreateRequest.parse("dev\"box", "2", "1024", "20").exceptionOrNull() as MilaMachineFieldException).field)
        assertEquals(MilaMachineField.Name, (MilaMachineCreateRequest.parse("", "2", "1024", "20").exceptionOrNull() as MilaMachineFieldException).field)
        assertEquals(MilaMachineField.Cpu, (MilaMachineCreateRequest.parse("x", "0", "1024", "20").exceptionOrNull() as MilaMachineFieldException).field)
        assertEquals(MilaMachineField.Memory, (MilaMachineCreateRequest.parse("x", "1", "255", "20").exceptionOrNull() as MilaMachineFieldException).field)
        assertEquals(MilaMachineField.Disk, (MilaMachineCreateRequest.parse("x", "1", "256", "501").exceptionOrNull() as MilaMachineFieldException).field)
        assertThrows(IllegalArgumentException::class.java) { MilaMachineCreateRequest("x", 257, 256, 1) }
    }

    @Test fun resizeBoundsMirrorSessionHandle() {
        assertTrue(MilaMachineResizeRequest.parse(id, "1", "256", "65536").isSuccess)
        assertTrue(MilaMachineResizeRequest.parse(id, "1", "2", "3").isFailure)
        assertTrue(MilaMachineResizeRequest.parse(id, "1", "", "3").isFailure)
        assertTrue(MilaMachineResizeRequest.parse(id, "1", "256", "65537").isFailure)
        assertTrue(MilaMachineResizeRequest.parse(UUID(0L, 0L), "1", "256", "1").isFailure)
    }

    @Test fun packagedAdapterCreatesOnlyThroughBoundSessionWithFreshRequestIds() = runBlocking {
        val bindings = FormBindings()
        val adapter = LinkedMilaFfiAdapter(bindings)
        val request = MilaMachineCreateRequest("devbox", 2, 1024, 20)
        assertTrue(adapter.machineCreate(request).isFailure)
        assertTrue(bindings.creates.isEmpty())
        adapter.bindSession(MilaSessionHandle(77L, bindings))
        assertTrue(adapter.machineCreate(request).isSuccess)
        assertTrue(adapter.machineCreate(request).isSuccess)
        assertEquals(2, bindings.creates.size)
        assertEquals(CreateCall(77L, "devbox", 2, 1024, 20, bindings.creates[0].requestId), bindings.creates[0])
        assertTrue(bindings.creates.all { it.requestId.matches(Regex("^porsche-[0-9a-f]{32}$")) })
        assertNotEquals(bindings.creates[0].requestId, bindings.creates[1].requestId)
        adapter.bindSession(null)
        assertTrue(adapter.machineCreate(request).isFailure)
        assertEquals(2, bindings.creates.size)
    }

    @Test fun rustRefusalIsAFailedSubmission() = runBlocking {
        val bindings = FormBindings(status = -4)
        val adapter = LinkedMilaFfiAdapter(bindings).apply { bindSession(MilaSessionHandle(5L, bindings)) }
        val form = MilaMachineFormController(adapter)
        form.setSession(true, listing)
        assertFalse(form.create("devbox", "2", "1024", "20"))
        assertEquals(MilaMachineFormState.Failed(MilaMachineFormKind.Create), form.state)
    }

    @Test fun formRefusesWhileSignedOutAndReportsInvalidField() = runBlocking {
        val bindings = FormBindings()
        val adapter = LinkedMilaFfiAdapter(bindings).apply { bindSession(MilaSessionHandle(5L, bindings)) }
        val form = MilaMachineFormController(adapter)
        assertFalse(form.create("devbox", "2", "1024", "20"))
        assertEquals(MilaMachineFormState.SignedOut, form.state)
        form.setSession(true, listing)
        assertFalse(form.create("dev box", "2", "1024", "20"))
        assertEquals(MilaMachineFormState.Invalid(MilaMachineFormKind.Create, MilaMachineField.Name), form.state)
        assertTrue(form.create("devbox", "2", "1024", "20"))
        assertEquals(MilaMachineFormState.Applied(MilaMachineFormKind.Create), form.state)
        assertEquals(1, bindings.creates.size)
    }

    @Test fun resizeTargetsOnlyListedMachines() = runBlocking {
        val bindings = FormBindings()
        val adapter = LinkedMilaFfiAdapter(bindings).apply { bindSession(MilaSessionHandle(5L, bindings)) }
        val form = MilaMachineFormController(adapter)
        form.setSession(true, listing)
        assertFalse(form.resize(UUID.randomUUID(), "2", "1024", "20"))
        assertTrue(bindings.resizes.isEmpty())
        assertTrue(form.resize(id, "4", "2048", "40"))
        assertEquals(ResizeCall(id.toString(), 4, 2048, 40, bindings.resizes.single().requestId), bindings.resizes.single())
        assertEquals(MilaMachineFormState.Applied(MilaMachineFormKind.Resize), form.state)
    }

    @Test fun oneSubmissionInFlightAndSignOutFencesLateResult() = runBlocking {
        val adapter = GatedAdapter()
        val form = MilaMachineFormController(adapter)
        form.setSession(true, listing)
        val first = async { form.create("devbox", "2", "1024", "20") }
        yield()
        assertEquals(MilaMachineFormState.Submitting(MilaMachineFormKind.Create), form.state)
        assertFalse(form.create("devbox", "2", "1024", "20"))
        assertEquals(1, adapter.calls)
        form.setSession(false, null)
        adapter.gate.complete(Result.success(Unit))
        assertFalse(first.await())
        assertEquals(MilaMachineFormState.SignedOut, form.state)
    }

    @Test fun listingRefreshKeepsSameSessionSubmissionValid() = runBlocking {
        val adapter = GatedAdapter()
        val form = MilaMachineFormController(adapter)
        form.setSession(true, listing)
        val first = async { form.create("devbox", "2", "1024", "20") }
        yield()
        form.setSession(true, MilaSessionListing(emptyList(), false))
        adapter.gate.complete(Result.success(Unit))
        assertTrue(first.await())
        assertEquals(MilaMachineFormState.Applied(MilaMachineFormKind.Create), form.state)
    }
}
