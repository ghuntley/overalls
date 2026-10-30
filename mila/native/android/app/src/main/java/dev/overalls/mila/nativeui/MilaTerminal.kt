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
class MilaTerminalSessionController(private val adapter: MilaFfiAdapter) {
    var state: MilaTerminalSessionState = MilaTerminalSessionState.SignedOut
        private set
    private var authenticated = false

    fun setSession(signedIn: Boolean) {
        if (signedIn == authenticated) return
        authenticated = signedIn
        if (!signedIn) (state as? MilaTerminalSessionState.Live)?.let { adapter.terminalClose(it.handle) }
        state = if (signedIn) MilaTerminalSessionState.Idle else MilaTerminalSessionState.SignedOut
    }

    /** Opens (or rejoins) the caller's named session on [machine] and attaches a PTY. */
    suspend fun open(machine: UUID, columns: Int, rows: Int): Boolean {
        if (!authenticated) return signedOut(null)
        detachLive()
        state = MilaTerminalSessionState.Attaching
        val session = io { adapter.terminalNew(machine) }.getOrElse { return fail(null) }
        return attach(session, columns, rows)
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
        state = MilaTerminalSessionState.Attaching
        return attach(session, columns, rows)
    }

    /** Reads one bounded output chunk; null when no output is available yet. */
    suspend fun poll(maxBytes: Int = 64 * 1024): ByteArray? {
        val live = state as? MilaTerminalSessionState.Live ?: return null
        return io { adapter.terminalPoll(live.handle, maxBytes) }.getOrNull()?.takeIf { it.isNotEmpty() }
    }

    suspend fun send(bytes: ByteArray): Boolean {
        val live = state as? MilaTerminalSessionState.Live ?: return false
        if (bytes.isEmpty() || bytes.size > 64 * 1024) return false
        return io { adapter.terminalInputBytes(live.handle, bytes) }.isSuccess
    }

    suspend fun resize(columns: Int, rows: Int): Boolean {
        val live = state as? MilaTerminalSessionState.Live ?: return false
        if (columns !in 1..4096 || rows !in 1..512) return false
        return io { adapter.terminalResizeHandle(live.handle, columns, rows) }.fold(
            { state = live.copy(columns = columns, rows = rows); true },
            { false },
        )
    }

    /** Closes the PTY only; the named session keeps running on the server. */
    fun detach(): Boolean {
        val live = state as? MilaTerminalSessionState.Live ?: return false
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
        return io { adapter.terminalEnd(session) }.fold(
            { closed -> if (closed) { state = MilaTerminalSessionState.Ended(session); true } else fail(session) },
            { fail(session) },
        )
    }

    private suspend fun attach(session: MilaTerminalSessionRef, columns: Int, rows: Int): Boolean =
        io { adapter.terminalAttach(session, columns, rows) }.fold(
            { handle -> state = MilaTerminalSessionState.Live(session, handle, columns, rows); true },
            { fail(session) },
        )

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
