package dev.overalls.mila.nativeui

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
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
 * descriptor as the `milaJourneyDescriptor` instrumentation argument (see the android-emulator
 * job in `.github/workflows/mila-builds.yml` and `scripts/run-instrumentation.sh`).
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

    /** Asserts [ok]; the description is built after the call so it reports the resulting state. */
    private inline fun expect(ok: Boolean, describe: () -> String) { assertTrue(describe(), ok) }

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
        expect(detail.submit(command)) { "$command admitted: ${detail.state} ${refusal()}" }
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

    @Test fun j03_createThroughSessionBoundForm() = runBlocking<Unit> {
        val state = signedIn()
        val form = MilaMachineFormController(adapter)
        form.setSession(true, state.listing)
        expect(form.create(createdName, "1", "512", "2")) { "create admitted: ${form.state} ${refusal()}" }
        val created = eventually(120_000) { listing().machines.firstOrNull { it.name == createdName } }
        createdId = created.id
    }

    @Test fun j04_lifecycleAdmissionThenResize() = runBlocking<Unit> {
        val seed = seed(signedIn().listing)
        // Without the provisioner, each intent needs the fixture's observe stand-in first.
        // Observe settles observed_state to the desired state; move away from it and back.
        val settled = fixture.observe(seed.id)
        val order = if (settled == "stopped") listOf(MilaMachineCommand.Start, MilaMachineCommand.Stop)
            else listOf(MilaMachineCommand.Stop, MilaMachineCommand.Start)
        for ((index, command) in order.withIndex()) {
            if (index > 0) fixture.observe(seed.id)
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

        // Resize last: with no provisioner the pinned resize request stays in progress, and
        // Marshall then refuses further lifecycle intents for the seed (resize_in_progress).
        fixture.observe(seed.id)
        val resize = MilaMachineFormController(adapter)
        resize.setSession(true, listing())
        expect(resize.resize(seed.id, "2", "1024", "3")) { "resize admitted: ${resize.state} ${refusal()}" }
        assertEquals(MilaMachineFormState.Applied(MilaMachineFormKind.Resize), resize.state)
    }

    @Test fun j05_shareAddAndRemoveOnSeedMachine() = runBlocking<Unit> {
        val principal = fixture.sharePrincipal
        assumeTrue("descriptor seed.share_principal", principal != null)
        val state = signedIn()
        val sharing = MilaMachineSharingController(adapter)
        sharing.setSession(true, state.listing)
        assertTrue(sharing.setMachine(seed(state.listing)))
        expect(sharing.submit(principal!!, role = MilaShareRole.Operator)) { "share add: ${sharing.state} ${refusal()}" }
        expect(sharing.submit(principal, remove = true)) { "share remove: ${sharing.state} ${refusal()}" }
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
        expect(detail.submit(MilaThreadCommand.Prompt, "Report the hostname please")) { "prompt: ${detail.state} ${refusal()}" }
        val question = fixture.fixture(MilaFixtureAction.ThreadQuestion, JSONObject().put("thread_id", thread.toString())).fixtureId("question_id")
        expect(detail.submit(MilaThreadCommand.Show)) { "show: ${detail.state} ${refusal()}" }
        val shown = (detail.state as MilaThreadActionState.Applied).thread
        assertEquals("pending question reported by thread show", question, shown.questionId)
        expect(detail.submit(MilaThreadCommand.Answer, """{"approach":{"selected":"First","text":""}}""")) { "answer: ${detail.state} ${refusal()}" }
        val plan = fixture.fixture(MilaFixtureAction.ThreadProposal, JSONObject().put("thread_id", thread.toString())).fixtureId("plan_id")
        expect(detail.submit(MilaThreadCommand.Show)) { "show: ${detail.state} ${refusal()}" }
        assertEquals("latest plan reported by thread show", plan, (detail.state as MilaThreadActionState.Applied).thread.planId)
        expect(detail.submit(MilaThreadCommand.PlanApprove)) { "plan approve: ${detail.state} ${refusal()}" }
    }

    @Test fun j07_terminalWithoutGuestIsRefusedClosed() = runBlocking<Unit> {
        val state = signedIn()
        // The unnamed legacy attach is never offered.
        assertTrue(adapter.terminalOpen(80, 24, true).isFailure)
        // Admitted but never observed running: no guest executes for this machine.
        val idleName = "mila-android-idle-" + UUID.randomUUID().toString().take(8)
        val form = MilaMachineFormController(adapter)
        form.setSession(true, state.listing)
        expect(form.create(idleName, "1", "512", "2")) { "idle create admitted: ${form.state} ${refusal()}" }
        val idle = eventually(120_000) { listing().machines.firstOrNull { it.name == idleName } }
        val terminal = MilaTerminalSessionController(adapter)
        terminal.setSession(true)
        assertFalse("terminal must be refused without a guest", terminal.open(idle.id, 80, 24))
        assertTrue(terminal.state is MilaTerminalSessionState.Failed)
        assertEquals("terminal_unavailable", adapter.lastRefusal())
    }

    @Test fun j08_webEndpointShowAndSetMoveRevision() = runBlocking<Unit> {
        val seed = seed(signedIn().listing)
        val web = MilaWebController(adapter)
        web.setSession(true)
        expect(web.show(seed.id)) { "web show: ${web.error} ${refusal()}" }
        val before = web.endpoint!!
        assertEquals(seed.id, before.machineId)
        expect(web.set(seed.id, 8080, public = true)) { "web set: ${web.error} ${refusal()}" }
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
        expect(adapter.notificationDevicePreferences(device, false).isSuccess) { "disable ${refusal()}" }
        expect(adapter.notificationDevicePreferences(device, true).isSuccess) { "enable ${refusal()}" }
        expect(adapter.notificationDeviceRemove(device).isSuccess) { "remove ${refusal()}" }
        assertTrue(adapter.notificationDevicePreferences("bad device", true).isFailure)
    }

    @Test fun j11_deleteCreatedMachine() = runBlocking<Unit> {
        signedIn()
        val made = createdId
        assumeTrue("created machine from j03", made != null)
        lifecycle(made!!, MilaMachineCommand.Delete)
    }

    /** Polls the live terminal until [marker] appears in its output, within [timeoutMs]. */
    private suspend fun MilaTerminalSessionController.awaitOutput(marker: String, timeoutMs: Long): Boolean {
        val seen = StringBuilder()
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            poll()?.let { seen.append(it.toString(Charsets.UTF_8)); if (seen.length > 256 * 1024) seen.delete(0, seen.length - 64 * 1024) }
            if (marker in seen) return true
            delay(200)
        }
        return false
    }

    @Test fun j12_guestTerminalEchoResizeReplayAndKill() = runBlocking<Unit> {
        val machine = checkNotNull(fixture.terminalMachineId) { "descriptor seed.terminal_machine_id" }
        signedIn()
        val terminal = MilaTerminalSessionController(adapter)
        terminal.setSession(true)
        // Only terminal operations run on this machine. Right after boot the guest terminal
        // service can still answer temporarily_unavailable; retry that refusal alone.
        var opened = terminal.open(machine, 100, 30)
        val deadline = System.currentTimeMillis() + 120_000
        while (!opened && adapter.lastRefusal() == "temporarily_unavailable" && System.currentTimeMillis() < deadline) {
            delay(2_000)
            opened = if ((terminal.state as? MilaTerminalSessionState.Failed)?.session != null) terminal.reattach(100, 30)
                else terminal.open(machine, 100, 30)
        }
        expect(opened) { "terminal attach: ${terminal.state} ${refusal()}" }
        val session = (terminal.state as MilaTerminalSessionState.Live).session

        val marker = "mila-" + UUID.randomUUID().toString().replace("-", "").take(12)
        assertTrue(terminal.send("echo $marker-\$((6*7))\r".toByteArray(Charsets.UTF_8)))
        assertTrue("echo output", terminal.awaitOutput("$marker-42", 60_000))

        expect(terminal.resize(132, 40)) { "resize: ${terminal.state} ${refusal()}" }
        assertTrue(terminal.send("stty size\r".toByteArray(Charsets.UTF_8)))
        assertTrue("stty reports the new size", terminal.awaitOutput("40 132", 30_000))

        assertTrue(terminal.detach())
        expect(terminal.reattach(132, 40)) { "reattach: ${terminal.state} ${refusal()}" }
        assertEquals(session, (terminal.state as MilaTerminalSessionState.Live).session)
        assertTrue("replayed output after reattach", terminal.awaitOutput("$marker-42", 60_000))

        expect(terminal.kill()) { "kill: ${terminal.state} ${refusal()}" }
        assertEquals(MilaTerminalSessionState.Ended(session), terminal.state)
    }

    /**
     * Authenticated share-provider completion, as the Windows journey proves it: a SEND share for
     * the fixture deployment received while signed out is held, is not completed by another host,
     * and completes once the fixture deployment signs in through the packaged JNI session. A share
     * the signed-in client creates for the seed machine navigates at once and resolves against the
     * authenticated listing.
     */
    @Test fun j13_signedOutShareCompletesAfterFixtureSignIn() = runBlocking<Unit> {
        val deepLinks = MilaDeepLinkController()
        val generation = deepLinks.beginSession()
        val share = android.content.Intent(android.content.Intent.ACTION_SEND).setType("text/plain")
            .putExtra(android.content.Intent.EXTRA_TEXT, "overalls://${fixture.host}/threads")
        assertEquals(MilaLinkDelivery.Queued, deliverExternalIntent(deepLinks, share, generation, authenticatedHost = null))
        assertEquals(MilaRoute.Machines, deepLinks.target)
        assertEquals(MilaLinkDelivery.Queued, deepLinks.completePending("other.example", generation))

        val state = signedIn()
        assertEquals(fixture.host, state.deployment.host)
        assertEquals(MilaLinkDelivery.Applied, deepLinks.completePending(state.deployment.host, generation))
        assertEquals(MilaRoute.Threads, deepLinks.target)
        assertEquals(MilaLinkDelivery.Refused, deepLinks.completePending(state.deployment.host, generation))

        val seed = seed(state.listing)
        val chooser = checkNotNull(MilaShareIntentFactory.authenticatedChooser(MilaRoute.Machine(seed.id), state.deployment.host)) { "authenticated share chooser" }
        @Suppress("DEPRECATION") val outbound = chooser.getParcelableExtra<android.content.Intent>(android.content.Intent.EXTRA_INTENT)!!
        assertEquals(MilaLinkDelivery.Applied, deliverExternalIntent(deepLinks, outbound, generation, state.deployment.host))
        assertEquals(MilaRoute.Machine(seed.id), deepLinks.target)
        assertEquals(MilaRouteResolution.Resolved, resolveMilaRoute(deepLinks.target, true, state.listing, null))
    }

    /** Runs [command] as the shell user, without a shell, and returns its standard output. */
    private fun shell(command: String): String {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        return ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command)).use {
            it.readBytes().toString(Charsets.UTF_8)
        }
    }

    /** Finishes every Mila activity this process hosts, so each launch starts a fresh shell. */
    private fun finishMilaActivities() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val monitor = ActivityLifecycleMonitorRegistry.getInstance()
            listOf(Stage.PRE_ON_CREATE, Stage.CREATED, Stage.STARTED, Stage.RESUMED, Stage.PAUSED, Stage.STOPPED, Stage.RESTARTED)
                .flatMap { stage -> monitor.getActivitiesInStage(stage) }
                .filterIsInstance<MainActivity>()
                .forEach { it.finish() }
        }
        instrumentation.waitForIdleSync()
    }

    /**
     * Asks the platform which activities handle [link] as a browsable VIEW intent with no component
     * or package, and requires exactly Mila's [MainActivity].
     */
    private fun assertResolvesToMila(context: Context, link: String) {
        val view = Intent(Intent.ACTION_VIEW, Uri.parse(link)).addCategory(Intent.CATEGORY_BROWSABLE)
        assertEquals(null, view.component)
        assertEquals(null, view.`package`)
        val handlers: List<ResolveInfo> = context.packageManager.queryIntentActivities(view, PackageManager.MATCH_DEFAULT_ONLY)
        val names = handlers.map { it.activityInfo.packageName + "/" + it.activityInfo.name }
        assertEquals("system resolver handlers for an overalls link", listOf(context.packageName + "/" + MainActivity::class.java.name), names)
    }

    /**
     * Launches [link] through ActivityManager exactly as another app or the browser would: an
     * implicit VIEW intent carrying only an action and data, resolved by the platform. The
     * `--activity-clear-task` flag replaces any earlier Mila task so the link starts a fresh shell;
     * it does not name a component.
     */
    private fun launchThroughResolver(context: Context, link: String) {
        val output = shell("am start -W --activity-clear-task -a android.intent.action.VIEW -d $link")
        assertTrue("am start reported success: $output", output.lines().any { it.trim() == "Status: ok" })
        assertTrue(
            "the platform resolved the link to Mila: $output",
            output.lines().any { it.trim() == "Activity: ${context.packageName}/.MainActivity" },
        )
    }

    /**
     * Launching a link on the device: the platform resolver, not an explicit component, starts
     * Mila from an `overalls://<fixture-host>/machines/<seed-id>` VIEW link. The persisted fixture
     * deployment signs in through the activity's own production `MilaNativeRoot` (the device key
     * approved in j01; the trust pin persisted by the earlier steps, since the production fetcher
     * has no route to the fixture's HTTPS port), the link held while signing in completes for that
     * host, and the window shows the seed machine's detail page: its ID and its listed name and
     * status, which only the authenticated listing supplies. Non-canonical links for the same
     * machine resolve to Mila through the same filter but are refused: the signed-in window stays on
     * the machine list. MilaMainActivityIntentTest covers an explicit-component launch only; j13
     * covers the controller without an activity.
     */
    @Test fun j14_linkLaunchesThroughSystemResolverToSeedMachine() = runBlocking<Unit> {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val seed = seed(signedIn().listing)
        // The activity owns its own Rust session; release the journey's before it connects.
        signIn.close()

        val preferences = context.getSharedPreferences("mila.deployment", Context.MODE_PRIVATE)
        val saved: Map<String, Any?> = preferences.all.toMap()
        val device = UiDevice.getInstance(instrumentation)
        try {
            preferences.edit().clear().commit()
            MilaSharedPreferencesDeploymentStore(preferences).write(fixture.deployment)
            assertEquals(fixture.deployment, MilaSharedPreferencesDeploymentStore(preferences).read())
            device.wakeUp()
            shell("wm dismiss-keyguard")

            val canonical = "overalls://${fixture.host}/machines/${seed.id}"
            assertEquals(MilaRoute.Machine(seed.id), parseMilaRoute(canonical))
            assertResolvesToMila(context, canonical)
            launchThroughResolver(context, canonical)
            assertTrue(
                "seed machine detail page shows ${seed.id}",
                device.wait(Until.hasObject(By.pkg(context.packageName).text(seed.id.toString())), 120_000),
            )
            assertTrue(
                "seed machine detail shows the authenticated listing row for ${seed.name}",
                device.wait(Until.hasObject(By.pkg(context.packageName).textStartsWith("${seed.name} · ")), 30_000),
            )
            finishMilaActivities()

            for (refused in listOf(
                "overalls://${fixture.host}/machines/${seed.id}?command=rm",
                "overalls://${fixture.host}/machines/${seed.id}/rm",
            )) {
                assertEquals(null, parseMilaRoute(refused))
                assertResolvesToMila(context, refused)
                launchThroughResolver(context, refused)
                // The machine list renders listing rows only once the activity has signed in, and a
                // held link would complete at that same transition.
                assertTrue(
                    "signed-in machine list lists ${seed.name} after $refused",
                    device.wait(Until.hasObject(By.pkg(context.packageName).textStartsWith("${seed.name} · ")), 120_000),
                )
                assertFalse(
                    "non-canonical link $refused must not open the machine detail page",
                    device.wait(Until.hasObject(By.pkg(context.packageName).text(seed.id.toString())), 5_000),
                )
                finishMilaActivities()
            }
        } finally {
            finishMilaActivities()
            val restore = preferences.edit().clear()
            for ((key, value) in saved) when (value) {
                is String -> restore.putString(key, value)
                is Int -> restore.putInt(key, value)
                is Long -> restore.putLong(key, value)
                is Boolean -> restore.putBoolean(key, value)
                is Float -> restore.putFloat(key, value)
                else -> Unit
            }
            restore.commit()
        }
    }
}
