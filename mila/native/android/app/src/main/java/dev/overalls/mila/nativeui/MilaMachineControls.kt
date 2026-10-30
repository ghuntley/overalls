package dev.overalls.mila.nativeui

internal fun boundedTerminalInput(value: String, maxBytes: Int = 4096): Boolean =
    value.toByteArray(Charsets.UTF_8).size <= maxBytes

/** UI-facing typed machine action result; operation names never bypass Rust classification. */
sealed interface MilaMachineActionState {
 data object Idle : MilaMachineActionState
 data class Selected(val action: MilaMachineCommand) : MilaMachineActionState
 data class Rejected(val reason: String) : MilaMachineActionState
}

class MilaMachineActionController(private val adapter: MilaFfiAdapter) {
 var state: MilaMachineActionState = MilaMachineActionState.Idle; private set
 fun select(command: String) { state = adapter.machineCommandKind(command).fold({ MilaMachineActionState.Selected(it) }, { MilaMachineActionState.Rejected("unknown action") }) }
}

enum class MilaTerminalPhase { Idle, Attached, ReadOnly, Closed }
data class MilaTerminalState(
    val phase: MilaTerminalPhase = MilaTerminalPhase.Idle,
    val columns: Int = 80,
    val rows: Int = 24,
    /** Absolute PTY byte cursor used to resume a dropped attachment. */
    val cursor: Long = 0,
)
/** Bounded terminal text projection; control bytes and unbounded history never reach Compose. */
class MilaTerminalRenderer {
    private val lines = ArrayDeque<String>()
    private var current = StringBuilder()
    private var escape = false
    private var csi = false
    fun append(bytes: ByteArray) {
        // PTY output is deliberately reduced to display text before it reaches
        // Compose.  Keep CSI state across chunks so a split escape sequence
        // cannot leak control bytes into the UI.
        val decoded = bytes.toString(Charsets.UTF_8)
        val visible = buildString(decoded.length) {
            for (character in decoded) {
                if (escape) {
                    if (!csi && character == '[') { csi = true; continue }
                    if (csi) {
                        if (character in '@'..'~') { escape = false; csi = false }
                    } else if (character in '@'..'~') escape = false
                    continue
                }
                if (character == '\u001b') { escape = true; csi = false; continue }
                append(character)
            }
        }
        for (character in visible) {
            if (character == '\n') {
                val clean = current.toString().filter { it == '\t' || it.code >= 0x20 && it != '\u007f' }.take(4096)
                if (lines.size == 200) lines.removeFirst()
                lines.addLast(clean)
                current = StringBuilder()
            } else if (current.length < 4096) {
                current.append(character)
            }
        }
    }
    fun text(): String = (lines + listOf(current.toString()).filter { it.isNotEmpty() }).joinToString("\n")
    fun clear() { lines.clear(); current = StringBuilder(); escape = false; csi = false }
}
/** Bounded host-side source. Implementations must bind reads to the authenticated session. */
fun interface MilaPtySource {
    /** Returns at most [maxBytes] display bytes, or null when no output is ready. */
    fun read(maxBytes: Int): ByteArray?
}
class MilaTerminalController(private val adapter: MilaFfiAdapter, private val source: MilaPtySource? = null) {
 companion object { const val MAX_READ_BYTES: Int = 64 * 1024 }
 var state = MilaTerminalState(); private set
 val renderer = MilaTerminalRenderer()
 fun attach(readWrite: Boolean): Boolean = adapter.terminalAttach(state.cursor, state.columns, state.rows, readWrite).isSuccess.also { if (it) state = state.copy(phase = if (readWrite) MilaTerminalPhase.Attached else MilaTerminalPhase.ReadOnly) }
 fun reconnect(readWrite: Boolean = state.phase == MilaTerminalPhase.Attached): Boolean { if (state.phase == MilaTerminalPhase.Closed) state = state.copy(phase = MilaTerminalPhase.Idle); return attach(readWrite) }
 /** Send a bounded input payload only while attached read/write. */
 fun input(length: Int): Boolean =
  length in 0..MAX_READ_BYTES &&
   state.phase == MilaTerminalPhase.Attached &&
   adapter.terminalInput(length, true).isSuccess
 fun receive(bytes: ByteArray): Boolean {
  if (state.phase != MilaTerminalPhase.Attached && state.phase != MilaTerminalPhase.ReadOnly) return false
  if (bytes.size > MAX_READ_BYTES) return false
  if (bytes.isEmpty()) {
   // An empty read is a clean PTY EOF. Fence subsequent input until an
   // explicit reconnect establishes a fresh authenticated transport.
   state = state.copy(phase = MilaTerminalPhase.Closed)
   return true
  }
  val next = state.cursor + bytes.size.toLong()
  if (next < state.cursor) return false
  renderer.append(bytes)
  state = state.copy(cursor = next)
  return true
 }
 /** Drain one bounded host read. A null result means the PTY currently has no output. */
 fun pollOutput(): Boolean {
  if (state.phase != MilaTerminalPhase.Attached && state.phase != MilaTerminalPhase.ReadOnly) return false
  return source?.read(MAX_READ_BYTES)?.let(::receive) ?: false
 }
 fun resize(columns: Int, rows: Int): Boolean { if (columns !in 1..500 || rows !in 1..500) return false; return adapter.terminalResize(columns, rows, state.phase == MilaTerminalPhase.Attached).isSuccess.also { if (it) state = state.copy(columns=columns, rows=rows) } }
 fun close() { state = state.copy(phase = MilaTerminalPhase.Closed) }
}
