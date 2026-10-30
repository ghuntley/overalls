package dev.overalls.mila.nativeui

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.UUID

private class ThreadAdapter(private val accepted: Boolean = true) : MilaFfiAdapter {
    override suspend fun call(request: MilaFfiRequest) = MilaFfiResult.Failure(MilaFfiError.Unavailable)
    override suspend fun threadAction(threadId: UUID, command: MilaThreadCommand): Result<Unit> =
        if (accepted) Result.success(Unit) else Result.failure(IllegalStateException("rejected"))
    override suspend fun threadAction(threadId: UUID, command: MilaThreadCommand, input: String?): Result<Unit> =
        if (accepted) Result.success(Unit) else Result.failure(IllegalStateException("rejected"))
}

private class ThreadControlsAdapter(private val shown: String) : MilaFfiAdapter {
    val submitted = mutableListOf<Pair<MilaThreadCommand, UUID?>>()
    var shows = 0
    override suspend fun call(request: MilaFfiRequest) = MilaFfiResult.Failure(MilaFfiError.Unavailable)
    override suspend fun threadShow(threadId: UUID): Result<ByteArray> { shows += 1; return Result.success(shown.toByteArray()) }
    override suspend fun threadAction(threadId: UUID, command: MilaThreadCommand, input: String?, secondary: UUID?): Result<Unit> {
        submitted += command to secondary
        return Result.success(Unit)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class MilaThreadDetailTest {
    private val thread = UUID.fromString("00000000-0000-0000-0000-00000000000a")
    private val question = UUID.fromString("00000000-0000-0000-0000-00000000000b")
    private val plan = UUID.fromString("00000000-0000-0000-0000-00000000000c")
    private val bare = MilaThreadListing(listOf(MilaThreadRow(thread, "Build", "idle")), false)

    @Test fun answerNamesTheQuestionReportedByThreadShow() = runBlocking {
        val adapter = ThreadControlsAdapter("""{"version":1,"status":"succeeded","result":{"id":"$thread","pending_question":{"id":"$question"},"latest_plan":{"id":"$plan"}}}""")
        val controller = MilaThreadDetailController(adapter)
        controller.setSession(true, bare)
        controller.select(thread)
        assertFalse(controller.submit(MilaThreadCommand.Answer, "{}"))
        assertFalse(controller.submit(MilaThreadCommand.PlanApprove))
        assertTrue(adapter.submitted.isEmpty())
        assertTrue(controller.submit(MilaThreadCommand.Show))
        assertEquals(1, adapter.shows)
        // A recomposition re-supplying the same listing keeps the observed controls.
        controller.setSession(true, bare)
        controller.select(thread)
        assertTrue(controller.submit(MilaThreadCommand.Answer, "{}"))
        assertTrue(controller.submit(MilaThreadCommand.PlanApprove))
        assertEquals(listOf(MilaThreadCommand.Answer to question, MilaThreadCommand.PlanApprove to plan), adapter.submitted)
        // The answered question is not resubmitted.
        assertFalse(controller.submit(MilaThreadCommand.Answer, "{}"))
    }

    @Test fun signingOutDiscardsObservedThreadControls() = runBlocking {
        val adapter = ThreadControlsAdapter("""{"result":{"pending_question":{"id":"$question"}}}""")
        val controller = MilaThreadDetailController(adapter)
        controller.setSession(true, bare)
        controller.select(thread)
        assertTrue(controller.submit(MilaThreadCommand.Show))
        controller.setSession(false, null)
        controller.setSession(true, bare)
        controller.select(thread)
        assertFalse(controller.submit(MilaThreadCommand.Answer, "{}"))
        assertTrue(adapter.submitted.isEmpty())
    }

    @Test fun malformedThreadShowIsRefused() = runBlocking {
        val controller = MilaThreadDetailController(ThreadControlsAdapter("""{"result":{"pending_question":{"id":"not-a-uuid"}}}"""))
        controller.setSession(true, bare)
        controller.select(thread)
        assertFalse(controller.submit(MilaThreadCommand.Show))
        assertTrue(controller.state is MilaThreadActionState.Failed)
    }

    @Test fun decodesBoundedThreadListing() {
        val id = "00000000-0000-0000-0000-000000000001"
        val listing = MilaThreadListing.decode("""{"result":{"threads":[{"id":"$id","title":"Build","status":"open"}],"has_more":false}}""".toByteArray())
        assertEquals(1, listing.threads.size)
        assertEquals("Build", listing.threads.single().title)
    }
    private val id = UUID.fromString("00000000-0000-0000-0000-000000000002")
    private val listing = MilaThreadListing(listOf(MilaThreadRow(id, "deploy", "active", UUID.fromString("00000000-0000-0000-0000-000000000006"))), false)


    @Test fun rejectsZeroThreadIdentifier() {
        assertThrows(IllegalArgumentException::class.java) {
            MilaThreadListing.decode("""{"result":{"threads":[{"id":"00000000-0000-0000-0000-000000000000","title":"Build","status":"open"}]}}""".toByteArray())
        }
    }

    @Test fun rejectsOversizedThreadProjectionFields() {
        val id = "00000000-0000-0000-0000-000000000003"
        val title = "x".repeat(257)
        assertThrows(IllegalArgumentException::class.java) {
            MilaThreadListing.decode("""{"result":{"threads":[{"id":"$id","title":"$title","status":"open"}]}}""".toByteArray())
        }
    }

    @Test fun threadActionsRequireAuthenticationAndSelection() = runBlocking {
        val controller = MilaThreadDetailController(ThreadAdapter())
        assertFalse(controller.select(id))
        assertFalse(controller.submit(MilaThreadCommand.Show))
        assertFalse(controller.canSubmit())
        controller.setSession(true, listing)
        assertTrue(controller.select(id))
        assertTrue(controller.canSubmit())
        assertTrue(controller.submit(MilaThreadCommand.Turns))
        assertEquals(MilaThreadActionState.Applied(listing.threads.single(), MilaThreadCommand.Turns), controller.state)
    }

    @Test fun promptAndAnswerRequireBoundedInput() = runBlocking {
        val controller = MilaThreadDetailController(ThreadAdapter())
        controller.setSession(true, listing)
        controller.select(id)
        assertFalse(controller.submit(MilaThreadCommand.Prompt, ""))
        assertTrue(controller.state is MilaThreadActionState.Failed)
        assertTrue(controller.submit(MilaThreadCommand.Prompt, "approve\nplan"))
        assertFalse(controller.submit(MilaThreadCommand.Show, "unexpected"))
    }

    @Test fun promptInputUsesUtf8ByteBound() = runBlocking {
        val controller = MilaThreadDetailController(ThreadAdapter())
        controller.setSession(true, listing)
        controller.select(id)
        assertFalse(controller.submit(MilaThreadCommand.Prompt, "é".repeat(2049)))
        assertTrue(controller.submit(MilaThreadCommand.Prompt, "é".repeat(2048)))
    }

    @Test fun planApprovalUsesClosedCommandInputContract() = runBlocking {
        val controller = MilaThreadDetailController(ThreadAdapter())
        controller.setSession(true, listing)
        controller.select(id)
        assertTrue(controller.submit(MilaThreadCommand.PlanApprove))
        assertFalse(controller.submit(MilaThreadCommand.PlanApprove, "unexpected"))
        assertTrue(controller.submit(MilaThreadCommand.PlanRevise, "tighten rollout"))
    }

    @Test fun rejectedThreadCommandIsTyped() = runBlocking {
        val controller = MilaThreadDetailController(ThreadAdapter(false))
        controller.setSession(true, listing)
        controller.select(id)
        assertFalse(controller.submit(MilaThreadCommand.Answer))
        assertTrue(controller.state is MilaThreadActionState.Failed)
    }
    @Test fun decodesLatestPlanIdForApproval() {
        val id = "00000000-0000-0000-0000-000000000004"
        val plan = "00000000-0000-0000-0000-000000000005"
        val decoded = MilaThreadListing.decode("""{"result":{"threads":[{"id":"$id","title":"Build","status":"open","latest_plan":{"id":"$plan"}}]}}""".toByteArray())
        assertEquals(UUID.fromString(plan), decoded.threads.single().planId)
    }

    @Test fun planApprovalRequiresPlanIdentity() = runBlocking {
        val controller = MilaThreadDetailController(ThreadAdapter())
        controller.setSession(true, MilaThreadListing(listOf(MilaThreadRow(id, "deploy", "active")), false))
        controller.select(id)
        assertFalse(controller.submit(MilaThreadCommand.PlanApprove))
        assertTrue(controller.state is MilaThreadActionState.Failed)
    }

}
