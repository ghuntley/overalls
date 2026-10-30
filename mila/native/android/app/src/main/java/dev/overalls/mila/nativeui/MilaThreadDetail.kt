package dev.overalls.mila.nativeui

import java.util.UUID
import org.json.JSONObject

data class MilaThreadRow(val id: UUID, val title: String, val status: String, val planId: UUID? = null, val questionId: UUID? = null)

/** Pending question and latest plan read from an authenticated `thread show`. */
data class MilaThreadControls(val questionId: UUID?, val planId: UUID?) {
    companion object {
        fun decode(bytes: ByteArray): MilaThreadControls {
            require(bytes.size <= 256 * 1024)
            var view = JSONObject(bytes.toString(Charsets.UTF_8))
            repeat(2) { if (!view.has("pending_question") && !view.has("latest_plan")) view = view.optJSONObject("result") ?: view }
            fun id(key: String): UUID? = view.optJSONObject(key)?.optString("id")?.takeIf { it.isNotBlank() }?.let(UUID::fromString)
                ?.also { require(it != UUID(0L, 0L)) }
            return MilaThreadControls(id("pending_question"), id("latest_plan"))
        }
    }
}
data class MilaThreadListing(val threads: List<MilaThreadRow>, val hasMore: Boolean) {
 companion object {
  fun decode(bytes: ByteArray): MilaThreadListing {
    require(bytes.size <= 256 * 1024)
    val result = JSONObject(bytes.toString(Charsets.UTF_8)).optJSONObject("result") ?: JSONObject()
    val rows = result.optJSONArray("threads") ?: result.optJSONArray("items") ?: error("threads missing")
    require(rows.length() <= 500)
    val threads = buildList {
        for (index in 0 until rows.length()) {
            val row = rows.getJSONObject(index)
            val title = row.optString("title")
            val status = row.optString("status")
            require(title.toByteArray(Charsets.UTF_8).size <= 256)
            require(status.toByteArray(Charsets.UTF_8).size <= 64)
            val id = UUID.fromString(row.getString("id"))
            require(id != UUID(0L, 0L))
            val planId = row.optJSONObject("latest_plan")?.optString("id")?.takeIf { it.isNotBlank() }?.let { UUID.fromString(it) }
            add(MilaThreadRow(id, title, status, planId))
        }
    }
    return MilaThreadListing(threads, result.optBoolean("has_more", false))
  }
 }
}

sealed interface MilaThreadActionState {
    data object SignedOut : MilaThreadActionState
    data object Idle : MilaThreadActionState
    data class Ready(val thread: MilaThreadRow) : MilaThreadActionState
    data class Submitting(val thread: MilaThreadRow, val command: MilaThreadCommand) : MilaThreadActionState
    data class Applied(val thread: MilaThreadRow, val command: MilaThreadCommand) : MilaThreadActionState
    data class Failed(val thread: MilaThreadRow, val command: MilaThreadCommand, val reason: String) : MilaThreadActionState
}

/**
 * @cc [owner:ghuntley,label:protocol] android-thread-answer-binding
 * Android thread answers MUST name the pending question that an authenticated `thread show` on the
 * same session reported, and plan approval/revision MUST name the latest reported plan; neither is
 * submitted without one, and signing out discards the observed ids.
 */
class MilaThreadDetailController(private val adapter: MilaFfiAdapter) {
    var state: MilaThreadActionState = MilaThreadActionState.SignedOut
        private set
    private var listing: MilaThreadListing? = null
    private var authenticated = false
    private val observed = mutableMapOf<UUID, MilaThreadControls>()

    fun setSession(signedIn: Boolean, current: MilaThreadListing?) {
        val active = signedIn && current != null
        if (active == authenticated && current == listing) return
        if (!active) observed.clear()
        authenticated = active
        listing = if (active) current else null
        state = if (active) MilaThreadActionState.Idle else MilaThreadActionState.SignedOut
    }

    fun select(id: UUID): Boolean {
        val listed = listing?.threads?.firstOrNull { it.id == id } ?: return false
        val thread = observed[id]?.let { listed.copy(questionId = it.questionId, planId = it.planId ?: listed.planId) } ?: listed
        state = MilaThreadActionState.Ready(thread)
        return true
    }

    /** Whether the selected thread can accept a command in the current authenticated lifecycle. */
    fun canSubmit(): Boolean = authenticated && state is MilaThreadActionState.Ready

    suspend fun submit(command: MilaThreadCommand): Boolean = submit(command, null)

    suspend fun submit(command: MilaThreadCommand, input: String?): Boolean {
        val thread = when (val current = state) {
            is MilaThreadActionState.Ready -> current.thread
            is MilaThreadActionState.Failed -> current.thread
            is MilaThreadActionState.Applied -> current.thread
            else -> return false
        }
        if (!authenticated) { state = MilaThreadActionState.SignedOut; return false }
        val needsInput = command == MilaThreadCommand.Prompt || command == MilaThreadCommand.Answer || command == MilaThreadCommand.PlanRevise
        val inputBytes = input?.toByteArray(Charsets.UTF_8)
        if (needsInput && (inputBytes == null || inputBytes.isEmpty() || inputBytes.size > 4096 || input.any { it.code < 0x20 && it !in "\n\r\t" })) {
            state = MilaThreadActionState.Failed(thread, command, "invalid thread input")
            return false
        }
        if (!needsInput && input != null) {
            state = MilaThreadActionState.Failed(thread, command, "input is not accepted for this command")
            return false
        }
        state = MilaThreadActionState.Submitting(thread, command)
        if (command == MilaThreadCommand.Show) {
            return adapter.threadShow(thread.id).mapCatching(MilaThreadControls::decode).fold(
                { controls ->
                    observed[thread.id] = controls
                    val refreshed = thread.copy(questionId = controls.questionId, planId = controls.planId ?: thread.planId)
                    state = MilaThreadActionState.Applied(refreshed, command)
                    true
                },
                { error -> state = MilaThreadActionState.Failed(thread, command, error.message ?: "command rejected"); false },
            )
        }
        val secondary = when (command) {
            MilaThreadCommand.PlanApprove, MilaThreadCommand.PlanRevise -> thread.planId ?: run {
                state = MilaThreadActionState.Failed(thread, command, "plan is unavailable")
                return false
            }
            MilaThreadCommand.Answer -> thread.questionId ?: run {
                state = MilaThreadActionState.Failed(thread, command, "question is unavailable")
                return false
            }
            else -> null
        }
        return adapter.threadAction(thread.id, command, input, secondary).fold(
            {
                val answered = if (command == MilaThreadCommand.Answer) {
                    observed[thread.id] = MilaThreadControls(null, thread.planId)
                    thread.copy(questionId = null)
                } else thread
                state = MilaThreadActionState.Applied(answered, command)
                true
            },
            { error -> state = MilaThreadActionState.Failed(thread, command, error.message ?: "command rejected"); false },
        )
    }
}
