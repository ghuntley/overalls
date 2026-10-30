package dev.overalls.mila.nativeui

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

private class SharingAdapter(private val accepted: Boolean = true) : MilaFfiAdapter {
    val calls = mutableListOf<Triple<UUID, String, MilaShareRole?>>()
    override suspend fun call(request: MilaFfiRequest) = MilaFfiResult.Failure(MilaFfiError.Unavailable)
    override suspend fun machineAction(machineId: UUID, command: MilaMachineCommand): Result<Unit> =
        error("sharing must not use the lifecycle action seam")
    override suspend fun machineShare(machineId: UUID, principal: MilaSharePrincipal, role: MilaShareRole?): Result<Unit> {
        calls += Triple(machineId, principal.value, role)
        return if (accepted) Result.success(Unit) else Result.failure(IllegalStateException("rejected"))
    }
}

class MilaMachineSharingTest {
    private val id = UUID.fromString("00000000-0000-0000-0000-000000000001")
    private val row = MilaMachineRow(id, "build", "running")
    private val listing = MilaSessionListing(listOf(row), false)

    @Test fun sharingRequiresAuthenticatedMachine() = runBlocking {
        val c = MilaMachineSharingController(SharingAdapter())
        c.setSession(false, listing)
        assertFalse(c.setMachine(row))
        assertFalse(c.submit("person@example.test"))
        assertEquals(MilaMachineSharingState.SignedOut, c.state)
    }

    @Test fun addAndRemoveUseClosedCommands() = runBlocking {
        val c = MilaMachineSharingController(SharingAdapter())
        c.setSession(true, listing)
        assertTrue(c.setMachine(row))
        assertTrue(c.submit("person@example.test"))
        assertTrue((c.state as MilaMachineSharingState.Applied).principal.value.contains("@"))
        assertTrue(c.submit("person@example.test", remove = true))
        assertTrue((c.state as MilaMachineSharingState.Applied).remove)
    }

    @Test fun addCarriesClosedRoleAndRemoveCarriesNone() = runBlocking {
        val adapter = SharingAdapter()
        val c = MilaMachineSharingController(adapter)
        c.setSession(true, listing)
        c.setMachine(row)
        assertTrue(c.submit("person@example.test", role = MilaShareRole.Operator))
        assertTrue(c.submit("person@example.test", remove = true, role = MilaShareRole.Manager))
        assertEquals(listOf(Triple(id, "person@example.test", MilaShareRole.Operator), Triple<UUID, String, MilaShareRole?>(id, "person@example.test", null)), adapter.calls)
    }

    @Test fun rejectedShareIsReportedAsFailure() = runBlocking {
        val c = MilaMachineSharingController(SharingAdapter(accepted = false))
        c.setSession(true, listing)
        c.setMachine(row)
        assertFalse(c.submit("person@example.test"))
        assertTrue(c.state is MilaMachineSharingState.Failed)
    }

    @Test fun selectResolvesOnlyMachinesInAuthenticatedListing() {
        val c = MilaMachineSharingController(SharingAdapter())
        c.setSession(true, listing)
        assertTrue(c.select(id))
        assertEquals(MilaMachineSharingState.Ready(row), c.state)
        assertFalse(c.select(UUID.fromString("00000000-0000-0000-0000-000000000002")))
    }

    @Test fun cannotShareMachineOutsideAuthenticatedListing() = runBlocking {
        val c = MilaMachineSharingController(SharingAdapter())
        c.setSession(true, listing)
        val other = MilaMachineRow(UUID.fromString("00000000-0000-0000-0000-000000000002"), "other", "running")
        assertFalse(c.setMachine(other))
        assertFalse(c.submit("person@example.test"))
    }

    @Test fun principalRejectsWhitespaceAndUtf8Overflow() = runBlocking {
        val c = MilaMachineSharingController(SharingAdapter())
        c.setSession(true, listing)
        c.setMachine(row)
        assertFalse(c.submit("person @example.test"))
        assertFalse(c.submit("é".repeat(130)))
        assertTrue(c.state is MilaMachineSharingState.Failed)
    }

    @Test fun malformedPrincipalIsRejectedBeforeRustCall() = runBlocking {
        val c = MilaMachineSharingController(SharingAdapter())
        c.setSession(true, listing)
        c.setMachine(row)
        assertFalse(c.submit("\u0000"))
        assertTrue(c.state is MilaMachineSharingState.Failed)
    }
}
