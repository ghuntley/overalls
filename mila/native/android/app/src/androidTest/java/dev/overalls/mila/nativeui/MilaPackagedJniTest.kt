package dev.overalls.mila.nativeui

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Proves the packaged `mila_ffi` library exports the session-bound create and share JNI entry
 * points with the Kotlin signatures, and that Rust refuses them without an authenticated handle.
 */
@RunWith(AndroidJUnit4::class)
class MilaPackagedJniTest {
    private val requestId = "porsche-" + "0".repeat(32)
    private val machine = "123e4567-e89b-12d3-a456-426614174000"

    @Test
    fun machineCreateIsLinkedAndRefusedWithoutSession() {
        assertEquals(1, MilaRustFfi.abiVersion())
        val status = MilaRustFfi.sessionMachineCreate(0L, "devbox", 1, 512, 5, requestId)
        assertNotEquals(0, status)
        // Negative resources are refused in the JNI shim before reaching the C ABI.
        assertEquals(-4, MilaRustFfi.sessionMachineCreate(0L, "devbox", -1, 512, 5, requestId))
    }

    @Test
    fun shareMutationIsLinkedAndRefusedWithoutSession() {
        assertNotEquals(0, MilaRustFfi.sessionShareMutation(0L, machine, "person@example.test", "viewer", true, requestId))
        assertNotEquals(0, MilaRustFfi.sessionShareMutation(0L, machine, "person@example.test", null, false, requestId))
    }

    @Test
    fun packagedAdapterRefusesCreateAndShareWhileSignedOut() = kotlinx.coroutines.runBlocking {
        val adapter = LinkedMilaFfiAdapter()
        assert(adapter.machineCreate(MilaMachineCreateRequest("devbox", 1, 512, 5)).isFailure)
        val principal = MilaSharePrincipal.parse("person@example.test").getOrThrow()
        assert(adapter.machineShare(java.util.UUID.fromString(machine), principal, MilaShareRole.Viewer).isFailure)
        assert(adapter.refreshListing().isFailure)
    }
}
