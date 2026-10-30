package dev.overalls.mila.nativeui

import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.security.KeyStore
import java.security.SecureRandom
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
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
 * Hermetic emulator journey against the `mila-journey-fixture` Marshall+Porsche backend (ADR-0264).
 *
 * Every step uses the packaged Rust JNI session (`LinkedMilaFfiAdapter`) and the production
 * controllers; nothing is faked. The suite is skipped unless the CI step passes the fixture
 * descriptor as the `milaJourneyDescriptor` instrumentation argument (see the android-native job
 * in `.github/workflows/mila-builds.yml` and `scripts/run-instrumentation.sh`).
 *
 * No provisioner or guest runs in the fixture: lifecycle steps prove admission by Porsche, the
 * terminal step proves the closed `terminal_unavailable` refusal, and steps that need the
 * fixture's `/fixture/<action>` hooks (observe, thread-*) stand in for the provisioner and agent and
 * are required.
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

    private suspend fun <T : Any> eventually(timeoutMs: Long, probe: suspend () -> T?): T =
        withTimeout(timeoutMs) {
            var value = probe()
            while (value == null) { delay(1_000); value = probe() }
            value
        }

    /** Signs in, approving through the fixture's approver hook when Porsche requires it. */
    private suspend fun signedIn(): MilaSignInState.SignedIn {
        val resolved = material()
        signIn.signIn(fixture.deployment, resolved.config, resolved.signer)
        (signIn.state as? MilaSignInState.AwaitingApproval)?.let { awaiting ->
            fixture.approve(awaiting.approval)
            eventually(90_000) { signIn.pollApproval(); signIn.state as? MilaSignInState.SignedIn }
        }
        val state = signIn.state
        assertTrue("signed in, was $state", state is MilaSignInState.SignedIn)
        return state as MilaSignInState.SignedIn
    }

    private suspend fun listing(): MilaSessionListing = adapter.refreshListing().getOrThrow()
    private fun refusal(): String = "refusal=${adapter.lastRefusal()}"

    private fun seed(listing: MilaSessionListing): MilaMachineRow {
        val id = fixture.seedMachineId
        val row = if (id != null) listing.machines.firstOrNull { it.id == id }
            else fixture.seedMachineName?.let { name -> listing.machines.firstOrNull { it.name == name } }
        assertNotNull("seed machine in listing ${listing.machines.map { it.id }}", row)
        return row!!
    }

    /** Submits one lifecycle mutation once; Porsche admission is the asserted effect. */
    private suspend fun lifecycle(machine: UUID, command: MilaMachineCommand) {
        val detail = MilaMachineDetailController(adapter)
        detail.setSession(true, listing())
        assertTrue("machine $machine listed", detail.select(machine))
        assertTrue("$command admitted: ${detail.state} ${refusal()}", detail.submit(command))
    }

    @Test fun j01_signInRequiresBrowserApprovalThenReconnectsWithoutIt() = runBlocking<Unit> {
        // A fresh device key always needs approval; delete any key left by an earlier run.
        KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("dev.overalls.mila.device.${fixture.host}") }
        val resolved = material()
        signIn.signIn(fixture.deployment, resolved.config, resolved.signer)
        val awaiting = signIn.state as? MilaSignInState.AwaitingApproval
        assertNotNull("fresh key must await approval, was ${signIn.state}", awaiting)
        assertEquals(fixture.host, java.net.URI(awaiting!!.approval.url).host)
        assertEquals(milaSshFingerprint(resolved.signer.publicKey()), awaiting.approval.fingerprint)
        fixture.approve(awaiting.approval)
        eventually(90_000) { signIn.pollApproval(); signIn.state as? MilaSignInState.SignedIn }
        assertEquals(MilaApprovalState.Approved, (signIn.state as MilaSignInState.SignedIn).approval)

        signIn.close()
        assertTrue("approved key reconnects without approval", signIn.reconnect(resolved.config, resolved.signer))
    }

    @Test fun j02_machineListingIncludesSeedMachine() = runBlocking<Unit> {
        val state = signedIn()
        val seed = seed(state.listing)
        val detail = MilaMachineDetailController(adapter)
        detail.setSession(true, state.listing)
        assertTrue(detail.select(seed.id))
        assertFalse(detail.select(UUID.randomUUID()))
        assertEquals(MilaRouteResolution.Resolved, resolveMilaRoute(MilaRoute.Machine(seed.id), true, state.listing, null))
    }

    @Test fun j03_createAndResizeThroughSessionBoundForm() = runBlocking<Unit> {
        val state = signedIn()
        val form = MilaMachineFormController(adapter)
        form.setSession(true, state.listing)
        assertTrue("create admitted: ${form.state} ${refusal()}", form.create(createdName, "1", "512", "2"))
        val created = eventually(120_000) { listing().machines.firstOrNull { it.name == createdName } }
        createdId = created.id

        val seed = seed(listing())
        fixture.observe(seed.id)
        form.setSession(true, listing())
        assertTrue("resize admitted: ${form.state} ${refusal()}", form.resize(seed.id, "2", "1024", "3"))
        assertEquals(MilaMachineFormState.Applied(MilaMachineFormKind.Resize), form.state)
    }

    @Test fun j04_lifecycleAdmission() = runBlocking<Unit> {
        val seed = seed(signedIn().listing)
        // Without the provisioner, each intent needs the fixture's observe stand-in first.
        for (command in listOf(MilaMachineCommand.Stop, MilaMachineCommand.Start)) {
            fixture.observe(seed.id)
            lifecycle(seed.id, command)
        }
        fixture.observe(seed.id)
        val made = checkNotNull(createdId) { "created machine from j03" }
        fixture.observe(made)
        lifecycle(made, MilaMachineCommand.Pause)
        // The unobserved pause keeps an operation open, so Marshall refuses a resize with its
        // closed vm_busy reason and the form reports it rather than retrying.
        val form = MilaMachineFormController(adapter)
        form.setSession(true, listing())
        assertFalse("resize while paused is refused", form.resize(made, "2", "1024", "3"))
        assertEquals("vm_busy", adapter.lastRefusal())
        // Resume is a durable wake request; with no checkpoint it is asserted as admitted only.
        lifecycle(made, MilaMachineCommand.Resume)
    }

    @Test fun j05_shareAddAndRemoveOnSeedMachine() = runBlocking<Unit> {
        val principal = fixture.sharePrincipal
        assumeTrue("descriptor seed.share_principal", principal != null)
        val state = signedIn()
        val sharing = MilaMachineSharingController(adapter)
        sharing.setSession(true, state.listing)
        assertTrue(sharing.setMachine(seed(state.listing)))
        assertTrue("share add: ${sharing.state} ${refusal()}", sharing.submit(principal!!, role = MilaShareRole.Operator))
        assertTrue("share remove: ${sharing.state} ${refusal()}", sharing.submit(principal, remove = true))
    }

    @Test fun j06_threadPromptAnswerAndPlanApproval() = runBlocking<Unit> {
        signedIn()
        val thread = fixture.fixture(MilaFixtureAction.ThreadCreate).fixtureId("thread_id")
        val ready = fixture.fixture(MilaFixtureAction.ThreadReady, JSONObject().put("thread_id", thread.toString()))
        assertEquals("ready", ready.optString("status"))
        val listed = adapter.threadListing().getOrThrow()
        assertTrue("thread $thread listed", listed.threads.any { it.id == thread })
        val detail = MilaThreadDetailController(adapter)
        detail.setSession(true, listed)
        assertTrue(detail.select(thread))
        assertTrue("prompt: ${detail.state} ${refusal()}", detail.submit(MilaThreadCommand.Prompt, "Report the hostname please"))
        val question = fixture.fixture(MilaFixtureAction.ThreadQuestion, JSONObject().put("thread_id", thread.toString())).fixtureId("question_id")
        assertTrue("show: ${detail.state} ${refusal()}", detail.submit(MilaThreadCommand.Show))
        val shown = (detail.state as MilaThreadActionState.Applied).thread
        assertEquals("pending question reported by thread show", question, shown.questionId)
        assertTrue("answer: ${detail.state} ${refusal()}", detail.submit(MilaThreadCommand.Answer, """{"approach":{"selected":"First","text":""}}"""))
        val plan = fixture.fixture(MilaFixtureAction.ThreadProposal, JSONObject().put("thread_id", thread.toString())).fixtureId("plan_id")
        assertTrue("show: ${detail.state} ${refusal()}", detail.submit(MilaThreadCommand.Show))
        assertEquals("latest plan reported by thread show", plan, (detail.state as MilaThreadActionState.Applied).thread.planId)
        assertTrue("plan approve: ${detail.state} ${refusal()}", detail.submit(MilaThreadCommand.PlanApprove))
    }

    @Test fun j07_terminalWithoutGuestIsRefusedClosed() = runBlocking<Unit> {
        val seed = seed(signedIn().listing)
        // The unnamed legacy attach is never offered.
        assertTrue(adapter.terminalOpen(80, 24, true).isFailure)
        val opened = adapter.terminalOpen(seed.id, 80, 24)
        // No guest executes in the fixture: Marshall refuses with the closed terminal_unavailable code.
        assertTrue("terminal must be refused without a guest", opened.isFailure)
        assertEquals("terminal_unavailable", adapter.lastRefusal())
    }

    @Test fun j08_webEndpointShowAndSetMoveRevision() = runBlocking<Unit> {
        val seed = seed(signedIn().listing)
        val web = MilaWebController(adapter)
        web.setSession(true)
        assertTrue("web show: ${web.error} ${refusal()}", web.show(seed.id))
        val before = web.endpoint!!
        assertEquals(seed.id, before.machineId)
        assertTrue("web set: ${web.error} ${refusal()}", web.set(seed.id, 8080, public = true))
        assertTrue(web.show(seed.id))
        assertEquals(before.revision + 1, web.endpoint!!.revision)
        assertEquals(8080, web.endpoint!!.port)
        assertTrue(web.endpoint!!.public)
    }

    @Test fun j09_sshKeysListIncludesThisDevice() = runBlocking<Unit> {
        signedIn()
        val controller = MilaSshKeyController(adapter.sshKeyStore())
        controller.refresh()
        assertTrue("current device key listed: ${controller.keys.map { it.fingerprint }}", controller.keys.any { it.isCurrentDevice })
        assertFalse("current device key cannot be revoked", controller.revoke(controller.keys.first { it.isCurrentDevice }))
    }

    @Test fun j10_notificationDeviceCrud() = runBlocking<Unit> {
        signedIn()
        // The fixture has no Susan or FCM; stand in for Susan's key-issuance reply exactly as the
        // headless driver does, so Rust's own reply validation and stdin push-key path still run.
        val random = SecureRandom()
        fun base64url(size: Int): String = Base64.encodeToString(ByteArray(size).also(random::nextBytes), Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
        val reply = JSONObject().put("push_key", base64url(48)).put("key_id", "mila-android-journey").put("expires_at", "2099-01-01T00:00:00Z").toString()
        val receipt = adapter.notificationDeviceRegister(reply, base64url(32)).getOrElse { throw AssertionError("register: ${refusal()}", it) }
        val device = JSONObject(receipt.toString(Charsets.UTF_8)).getJSONObject("result").getString("id")
        assertTrue(adapter.notificationDevices().getOrThrow().toString(Charsets.UTF_8).contains(device))
        assertTrue("disable ${refusal()}", adapter.notificationDevicePreferences(device, false).isSuccess)
        assertTrue("enable ${refusal()}", adapter.notificationDevicePreferences(device, true).isSuccess)
        assertTrue("remove ${refusal()}", adapter.notificationDeviceRemove(device).isSuccess)
        assertTrue(adapter.notificationDevicePreferences("bad device", true).isFailure)
    }

    @Test fun j11_deleteCreatedMachine() = runBlocking<Unit> {
        signedIn()
        val made = createdId
        assumeTrue("created machine from j03", made != null)
        lifecycle(made!!, MilaMachineCommand.Delete)
    }
}
