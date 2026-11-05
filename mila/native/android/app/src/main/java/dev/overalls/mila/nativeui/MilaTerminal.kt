package dev.overalls.mila.nativeui

import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** One of the caller's named Porsche terminal sessions on one machine. */
data class MilaTerminalSessionRef(val machine: UUID, val id: String) {
    init {
        require(machine != UUID(0L, 0L)) { "invalid terminal machine" }
        require(id.matches(ID)) { "invalid terminal session id" }
    }

    companion object {
        private val ID = Regex("^[A-Za-z0-9-]{1,64}$")
    }
}

/** Closed reasons a terminal step can fail with; server text never reaches the UI. */
enum class MilaTerminalFailure { SignedOut, Refused, Invalid }

sealed interface MilaTerminalSessionState {
    data object SignedOut : MilaTerminalSessionState
    data object Idle : MilaTerminalSessionState
    data object Attaching : MilaTerminalSessionState
    data class Live(val session: MilaTerminalSessionRef, val handle: Long, val columns: Int, val rows: Int) : MilaTerminalSessionState
    /** The PTY is detached; the server session keeps running and can be reattached. */
    data class Detached(val session: MilaTerminalSessionRef) : MilaTerminalSessionState
    /** The server session was killed (`terminal kill` reported `closed`). */
    data class Ended(val session: MilaTerminalSessionRef) : MilaTerminalSessionState
    data class Failed(val session: MilaTerminalSessionRef?, val reason: MilaTerminalFailure) : MilaTerminalSessionState
}

/**
 * @cc [owner:ghuntley,label:security;protocol] android-terminal-session-lifecycle
 * Android terminals MUST open the caller's named session (`terminal new`), attach by that
 * machine and session id, and reattach to the same session after a detach; killing it MUST go
 * through `terminal kill` once and report Ended only when the server reports `closed`. Every
 * step requires the authenticated session, and signing out detaches the PTY without killing
 * the server session. Terminal bytes pass through and are never retained beyond the caller.
 */
/**
 * @cc [owner:ghuntley,label:security;terminal] android-terminal-session-generation
 * Session changes and fresh attachments MUST clear the previous frame and invalidate pending
 * terminal operations. Late completions MUST NOT restore a previous attachment, frame, output,
 * or state; a late successful attach MUST close only its PTY without killing its server session.
 */
class MilaTerminalSessionController(private val adapter: MilaFfiAdapter) {
    var frame: MilaTerminalFrame? = null
        private set
    var state: MilaTerminalSessionState = MilaTerminalSessionState.SignedOut
        private set
    private var authenticated = false
    private var generation = 0L

    fun setSession(signedIn: Boolean) {
        if (signedIn == authenticated) return
        advanceGeneration(clearFrame = true)
        authenticated = signedIn
        if (!signedIn) (state as? MilaTerminalSessionState.Live)?.let { adapter.terminalClose(it.handle) }
        state = if (signedIn) MilaTerminalSessionState.Idle else MilaTerminalSessionState.SignedOut
    }

    /** Opens (or rejoins) the caller's named session on [machine] and attaches a PTY. */
    suspend fun open(machine: UUID, columns: Int, rows: Int): Boolean {
        if (!authenticated) return signedOut(null)
        detachLive()
        val operation = advanceGeneration(clearFrame = true)
        state = MilaTerminalSessionState.Attaching
        val result = io { adapter.terminalNew(machine) }
        if (!isCurrent(operation)) return false
        val session = result.getOrElse { return fail(null) }
        return attach(session, columns, rows, operation)
    }

    /** Reattaches a PTY to the detached (or failed) session; the server replays its output. */
    suspend fun reattach(columns: Int, rows: Int): Boolean {
        val session = when (val current = state) {
            is MilaTerminalSessionState.Detached -> current.session
            is MilaTerminalSessionState.Failed -> current.session ?: return false
            is MilaTerminalSessionState.Live -> current.session.also { detachLive() }
            else -> return false
        }
        if (!authenticated) return signedOut(session)
        val operation = advanceGeneration(clearFrame = true)
        state = MilaTerminalSessionState.Attaching
        return attach(session, columns, rows, operation)
    }

    /** Reads one bounded event; null means transport loss or idle/closed with no bytes. */
    suspend fun poll(maxBytes: Int = 64 * 1024): ByteArray? {
        val live = state as? MilaTerminalSessionState.Live ?: return null
        val operation = generation
        val result = io { adapter.terminalReadWithin(live.handle, 0, maxBytes) }
        if (!isCurrent(operation, live.handle)) return null
        val encoded = result.getOrNull() ?: run {
            state = MilaTerminalSessionState.Failed(live.session, MilaTerminalFailure.Refused)
            return null
        }
        if (encoded.isEmpty()) return null
        return when (encoded[0].toInt()) {
            0 -> {
                val nextFrame = io { adapter.terminalFrame(live.handle) }.getOrNull()
                if (!isCurrent(operation, live.handle)) return null
                frame = nextFrame
                encoded.copyOfRange(1, encoded.size).takeIf { it.isNotEmpty() }
            }
            1 -> null
            2 -> { state = MilaTerminalSessionState.Detached(live.session); null }
            else -> { state = MilaTerminalSessionState.Failed(live.session, MilaTerminalFailure.Invalid); null }
        }
    }

    suspend fun send(bytes: ByteArray): Boolean {
        val live = state as? MilaTerminalSessionState.Live ?: return false
        if (bytes.isEmpty() || bytes.size > 64 * 1024) return false
        val operation = generation
        val result = io { adapter.terminalInputBytes(live.handle, bytes) }
        return isCurrent(operation, live.handle) && result.isSuccess
    }

    suspend fun resize(columns: Int, rows: Int): Boolean {
        val live = state as? MilaTerminalSessionState.Live ?: return false
        if (columns !in 1..4096 || rows !in 1..512) return false
        val operation = generation
        val result = io { adapter.terminalResizeHandle(live.handle, columns, rows) }
        if (!isCurrent(operation, live.handle)) return false
        return result.fold(
            { state = live.copy(columns = columns, rows = rows); true },
            { false },
        )
    }

    /** Closes the PTY only; the named session keeps running on the server. */
    fun detach(): Boolean {
        val live = state as? MilaTerminalSessionState.Live ?: return false
        advanceGeneration(clearFrame = false)
        adapter.terminalClose(live.handle)
        state = MilaTerminalSessionState.Detached(live.session)
        return true
    }

    /** Kills the named session for everyone attached (`terminal kill`). */
    suspend fun kill(): Boolean {
        val session = when (val current = state) {
            is MilaTerminalSessionState.Live -> current.session.also { detachLive() }
            is MilaTerminalSessionState.Detached -> current.session
            is MilaTerminalSessionState.Failed -> current.session ?: return false
            else -> return false
        }
        if (!authenticated) return signedOut(session)
        val operation = advanceGeneration(clearFrame = false)
        val result = io { adapter.terminalEnd(session) }
        if (!isCurrent(operation)) return false
        return result.fold(
            { closed -> if (closed) { state = MilaTerminalSessionState.Ended(session); true } else fail(session) },
            { fail(session) },
        )
    }

    private suspend fun attach(session: MilaTerminalSessionRef, columns: Int, rows: Int, operation: Long): Boolean {
        if (!isCurrent(operation)) return false
        val result = io { adapter.terminalAttach(session, columns, rows) }
        if (!isCurrent(operation)) {
            result.getOrNull()?.let { adapter.terminalClose(it) }
            return false
        }
        return result.fold(
            { handle -> state = MilaTerminalSessionState.Live(session, handle, columns, rows); true },
            { fail(session) },
        )
    }

    private fun advanceGeneration(clearFrame: Boolean): Long {
        generation += 1
        if (clearFrame) frame = null
        return generation
    }

    private fun isCurrent(operation: Long): Boolean = authenticated && operation == generation

    private fun isCurrent(operation: Long, handle: Long): Boolean =
        isCurrent(operation) && (state as? MilaTerminalSessionState.Live)?.handle == handle

    private fun detachLive() {
        (state as? MilaTerminalSessionState.Live)?.let {
            adapter.terminalClose(it.handle)
            state = MilaTerminalSessionState.Detached(it.session)
        }
    }

    private fun fail(session: MilaTerminalSessionRef?): Boolean {
        state = MilaTerminalSessionState.Failed(session, if (authenticated) MilaTerminalFailure.Refused else MilaTerminalFailure.SignedOut)
        return false
    }

    private fun signedOut(session: MilaTerminalSessionRef?): Boolean {
        state = MilaTerminalSessionState.Failed(session, MilaTerminalFailure.SignedOut)
        return false
    }

    private suspend fun <T> io(block: () -> T): T = withContext(Dispatchers.IO) { block() }
}
