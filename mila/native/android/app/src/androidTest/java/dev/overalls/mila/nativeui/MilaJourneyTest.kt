package dev.overalls.mila.nativeui

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.security.KeyStore
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.BeforeClass
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.MethodSorters

/** In-memory deployment store; the journey must not disturb the app's persisted selection. */
private class JourneyStore : MilaDeploymentStore {
    var deployment: MilaDeployment? = null
    override fun read(): MilaDeployment? = deployment
    override fun write(deployment: MilaDeployment) { this.deployment = deployment }
    override fun clear() { deployment = null }
}

/**
 * Hermetic emulator journey against the `mila-journey-fixture` Marshall+Porsche backend.
 *
 * Every step uses the packaged Rust JNI session (`LinkedMilaFfiAdapter`) and the production
 * controllers; nothing is faked. The suite is skipped unless the CI step passes the fixture
 * descriptor as the `milaJourneyDescriptor` instrumentation argument (see the android-native job
 * in `.github/workflows/mila-builds.yml` and `scripts/run-instrumentation.sh`).
 *
 * Steps run in name order because later steps reuse the device key approved by the first one.
 */
@RunWith(AndroidJUnit4::class)
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class MilaJourneyTest {
    companion object {
        private var descriptor: MilaJourneyDescriptor? = null
        /** Name of the machine created by the journey; shared by the lifecycle steps. */
        private val createdName = "mila-android-" + UUID.randomUUID().toString().take(8)
        private var createdId: UUID? = null

        @BeforeClass @JvmStatic fun loadDescriptor() {
            descriptor = MilaJourneyDescriptor.fromArguments(InstrumentationRegistry.getArguments())
            if (descriptor != null) MilaInstrumentationLoopback.allowed = true
        }

        @AfterClass @JvmStatic fun restoreLoopback() { MilaInstrumentationLoopback.allowed = false }
    }

    private lateinit var fixture: MilaJourneyDescriptor
    private lateinit var adapter: LinkedMilaFfiAdapter
    private lateinit var signIn: MilaSignInController
    private val store = JourneyStore()

    @Before fun requireFixture() {
        val current = descriptor
        assumeTrue("mila-journey-fixture descriptor not supplied", current != null)
        fixture = current!!
        adapter = LinkedMilaFfiAdapter()
        signIn = MilaSignInController(adapter, store)
    }

    @After fun closeSession() { if (::signIn.isInitialized) signIn.close() }

    private suspend fun material(): MilaSessionMaterial {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val provider = AndroidMilaSessionMaterialProvider(context, fetcher = MilaJourneyTrustFetcher(fixture))
        return provider.resolve(fixture.deployment).getOrThrow()
    }

    private suspend fun <T> eventually(timeoutMs: Long, step: String, probe: suspend () -> T?): T =
        withTimeout(timeoutMs) {
            var value = probe()
            while (value == null) { delay(1_000); value = probe() }
            value
        }.also { assertNotNull(step, it) }

    /** Signs in, approving through the fixture's approver hook when Porsche requires it. */
    private suspend fun signedIn(): MilaSignInState.SignedIn {
        val resolved = material()
        signIn.signIn(fixture.deployment, resolved.config, resolved.signer)
        (signIn.state as? MilaSignInState.AwaitingApproval)?.let { awaiting ->
            assertEquals(milaSshFingerprint(resolved.signer.publicKey()), awaiting.approval.fingerprint)
            fixture.approve(awaiting.approval)
            eventually(60_000, "approval completes on the same session") {
                signIn.pollApproval()
                signIn.state as? MilaSignInState.SignedIn
            }
        }
        val state = signIn.state
        assertTrue("signed in, was $state", state is MilaSignInState.SignedIn)
        return state as MilaSignInState.SignedIn
    }

    private suspend fun listing(): MilaSessionListing = adapter.refreshListing().getOrThrow()

    private fun machineNamed(listing: MilaSessionListing, name: String): MilaMachineRow? = listing.machines.firstOrNull { it.name == name }

    @Test fun j01_signInRequiresBrowserApprovalThenReconnectsWithoutIt() = runBlocking<Unit> {
        // A fresh device key always needs approval; delete any key left by an earlier run.
        KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("dev.overalls.mila.device.${fixture.host}") }
        val resolved = material()
        signIn.signIn(fixture.deployment, resolved.config, resolved.signer)
        val awaiting = signIn.state as? MilaSignInState.AwaitingApproval
        assertNotNull("fresh key must await approval, was ${signIn.state}", awaiting)
        assertEquals(fixture.host, java.net.URI(awaiting!!.approval.url).host)
        fixture.approve(awaiting.approval)
        eventually(60_000, "approval") { signIn.pollApproval(); signIn.state as? MilaSignInState.SignedIn }
        assertEquals(MilaApprovalState.Approved, (signIn.state as MilaSignInState.SignedIn).approval)

        signIn.close()
        assertTrue("approved key reconnects without approval", signIn.reconnect(resolved.config, resolved.signer))
    }

    @Test fun j02_machineListingIncludesSeedMachine() = runBlocking<Unit> {
        val state = signedIn()
        fixture.seedMachineName?.let { name -> assertNotNull("seed machine $name", machineNamed(state.listing, name)) }
        val detail = MilaMachineDetailController(adapter)
        detail.setSession(true, state.listing)
        state.listing.machines.firstOrNull()?.let { assertTrue(detail.select(it.id)) }
        assertFalse(detail.select(UUID.randomUUID()))
    }

    @Test fun j03_createAndResizeThroughSessionBoundForm() = runBlocking<Unit> {
        val state = signedIn()
        val form = MilaMachineFormController(adapter)
        form.setSession(true, state.listing)
        assertTrue("create accepted: ${form.state}", form.create(createdName, "1", "512", "5"))
        val created = eventually(180_000, "created machine is listed") { machineNamed(listing(), createdName) }
        createdId = created.id
        form.setSession(true, listing())
        // Porsche may refuse a resize while the new machine is still provisioning; retry until applied.
        eventually(300_000, "resize applied") { if (form.resize(created.id, "2", "1024", "6")) true else null }
        assertEquals(MilaMachineFormState.Applied(MilaMachineFormKind.Resize), form.state)
    }

    @Test fun j04_lifecycleStopStartPauseResume() = runBlocking<Unit> {
        val state = signedIn()
        val id = createdId ?: machineNamed(state.listing, createdName)?.id
        assumeTrue("created machine from j03", id != null)
        val detail = MilaMachineDetailController(adapter)
        for (command in listOf(MilaMachineCommand.Stop, MilaMachineCommand.Start, MilaMachineCommand.Pause, MilaMachineCommand.Resume)) {
            eventually<Boolean>(300_000, "$command applied") {
                detail.setSession(true, listing())
                detail.select(id!!)
                if (detail.submit(command)) true else null
            }
        }
    }

    @Test fun j05_shareAddAndRemoveOnSeedMachine() = runBlocking<Unit> {
        val principal = fixture.sharePrincipal
        assumeTrue("descriptor seed.share_principal", principal != null)
        val state = signedIn()
        val target = fixture.seedMachineName?.let { machineNamed(state.listing, it) } ?: state.listing.machines.first()
        val sharing = MilaMachineSharingController(adapter)
        sharing.setSession(true, state.listing)
        assertTrue(sharing.setMachine(target))
        assertTrue("share add: ${sharing.state}", sharing.submit(principal!!, role = MilaShareRole.Operator))
        assertTrue("share remove: ${sharing.state}", sharing.submit(principal, remove = true))
    }

    @Test fun j06_threadListingAndDetail() = runBlocking<Unit> {
        signedIn()
        val threads = adapter.threadListing().getOrThrow()
        val detail = MilaThreadDetailController(adapter)
        detail.setSession(true, threads)
        threads.threads.firstOrNull()?.let { thread ->
            assertTrue(detail.select(thread.id))
            assertTrue("thread show: ${detail.state}", detail.submit(MilaThreadCommand.Show))
        }
    }

    @Test fun j07_terminalRoundTripsInputThroughPty() = runBlocking<Unit> {
        signedIn()
        val handle = adapter.terminalOpen(80, 24, true).getOrThrow()
        val renderer = MilaTerminalRenderer()
        try {
            val marker = "mila-journey-" + UUID.randomUUID().toString().take(8)
            assertTrue(adapter.terminalResizeHandle(handle, 100, 30).isSuccess)
            assertTrue(adapter.terminalInputBytes(handle, "echo $marker\n".toByteArray(Charsets.UTF_8)).isSuccess)
            eventually<String>(60_000, "terminal echoes marker") {
                adapter.terminalPoll(handle).getOrNull()?.let { renderer.append(it) }
                renderer.text().lines().firstOrNull { it.trim() == marker }
            }
        } finally {
            adapter.terminalClose(handle)
        }
    }

    @Test fun j08_webEndpointShowsForSeedMachine() = runBlocking<Unit> {
        val state = signedIn()
        val target = fixture.seedMachineName?.let { machineNamed(state.listing, it) } ?: state.listing.machines.first()
        val web = MilaWebController(adapter)
        web.setSession(true)
        assertTrue("web show: ${web.error}", web.show(target.id))
        assertEquals(target.id, web.endpoint?.machineId)
    }

    @Test fun j09_sshKeysListIncludesThisDevice() = runBlocking<Unit> {
        signedIn()
        val controller = MilaSshKeyController(adapter.sshKeyStore())
        controller.refresh()
        assertTrue("current device key listed", controller.keys.any { it.isCurrentDevice })
        assertFalse("current device key cannot be revoked", controller.revoke(controller.keys.first { it.isCurrentDevice }))
    }

    @Test fun j10_notificationDeviceListAndRefusals() = runBlocking<Unit> {
        signedIn()
        // Device creation needs a real FCM registration token, which cannot be hermetic; the
        // journey covers authenticated listing and refusal of malformed device identities.
        assertTrue(adapter.notificationDevices().isSuccess)
        assertTrue(adapter.notificationDevicePreferences("bad device", true).isFailure)
        assertTrue(adapter.notificationDeviceRemove("").isFailure)
    }

    @Test fun j11_deleteCreatedMachine() = runBlocking<Unit> {
        val state = signedIn()
        val id = createdId ?: machineNamed(state.listing, createdName)?.id
        assumeTrue("created machine from j03", id != null)
        val detail = MilaMachineDetailController(adapter)
        eventually<Boolean>(300_000, "delete applied") {
            detail.setSession(true, listing())
            detail.select(id!!)
            if (detail.submit(MilaMachineCommand.Delete)) true else null
        }
    }
}
