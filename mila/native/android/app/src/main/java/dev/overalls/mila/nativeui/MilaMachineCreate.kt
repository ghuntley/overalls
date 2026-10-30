package dev.overalls.mila.nativeui

import java.util.UUID

/** Field that failed client-side validation; Rust remains authoritative for the mutation. */
enum class MilaMachineField { Name, Cpu, Memory, Disk }

/**
 * Validated machine creation request. Bounds mirror `mila-session`'s `machine_create`, so a value
 * accepted here is never refused for shape by Rust and a value refused here never crosses JNI.
 */
data class MilaMachineCreateRequest(val name: String, val cpu: Int, val memoryMiB: Int, val diskGiB: Int) {
    init {
        require(name.matches(NAME)) { "invalid machine name" }
        require(cpu in CPU) { "invalid cpu" }
        require(memoryMiB in CREATE_MEMORY) { "invalid memory" }
        require(diskGiB in CREATE_DISK) { "invalid disk" }
    }

    companion object {
        private val NAME = Regex("^[A-Za-z0-9_-]{1,128}$")
        internal val CPU = 1..256
        internal val CREATE_MEMORY = 256..4_194_304
        internal val CREATE_DISK = 1..500

        /** Parses raw form text; the first invalid field is reported for presentation. */
        fun parse(name: String, cpu: String, memory: String, disk: String): Result<MilaMachineCreateRequest> {
            val trimmed = name.trim()
            if (!trimmed.matches(NAME)) return Result.failure(MilaMachineFieldException(MilaMachineField.Name))
            val cores = cpu.toIntOrNull()?.takeIf { it in CPU } ?: return Result.failure(MilaMachineFieldException(MilaMachineField.Cpu))
            val mib = memory.toIntOrNull()?.takeIf { it in CREATE_MEMORY } ?: return Result.failure(MilaMachineFieldException(MilaMachineField.Memory))
            val gib = disk.toIntOrNull()?.takeIf { it in CREATE_DISK } ?: return Result.failure(MilaMachineFieldException(MilaMachineField.Disk))
            return Result.success(MilaMachineCreateRequest(trimmed, cores, mib, gib))
        }
    }
}

/** Validated resize request; bounds mirror [MilaSessionHandle.machineResize]. */
data class MilaMachineResizeRequest(val machineId: UUID, val cpu: Int, val memoryMiB: Int, val diskGiB: Int) {
    init {
        require(machineId != UUID(0L, 0L)) { "invalid machine" }
        require(cpu in MilaMachineCreateRequest.CPU) { "invalid cpu" }
        require(memoryMiB in RESIZE_MEMORY) { "invalid memory" }
        require(diskGiB in RESIZE_DISK) { "invalid disk" }
    }

    companion object {
        internal val RESIZE_MEMORY = 256..1_048_576
        internal val RESIZE_DISK = 1..65_536

        fun parse(machineId: UUID, cpu: String, memory: String, disk: String): Result<MilaMachineResizeRequest> {
            val cores = cpu.toIntOrNull()?.takeIf { it in MilaMachineCreateRequest.CPU } ?: return Result.failure(MilaMachineFieldException(MilaMachineField.Cpu))
            val mib = memory.toIntOrNull()?.takeIf { it in RESIZE_MEMORY } ?: return Result.failure(MilaMachineFieldException(MilaMachineField.Memory))
            val gib = disk.toIntOrNull()?.takeIf { it in RESIZE_DISK } ?: return Result.failure(MilaMachineFieldException(MilaMachineField.Disk))
            return runCatching { MilaMachineResizeRequest(machineId, cores, mib, gib) }
        }
    }
}

class MilaMachineFieldException(val field: MilaMachineField) : IllegalArgumentException("invalid machine field")

enum class MilaMachineFormKind { Create, Resize }

/** Typed projection of the create/resize forms. */
sealed interface MilaMachineFormState {
    data object SignedOut : MilaMachineFormState
    data object Idle : MilaMachineFormState
    data class Invalid(val kind: MilaMachineFormKind, val field: MilaMachineField) : MilaMachineFormState
    data class Submitting(val kind: MilaMachineFormKind) : MilaMachineFormState
    data class Applied(val kind: MilaMachineFormKind) : MilaMachineFormState
    data class Failed(val kind: MilaMachineFormKind) : MilaMachineFormState
}

/**
 * @cc [owner:ghuntley,label:security] android-machine-form-session-binding
 * Create and resize MUST be submitted only while the authenticated Rust session that produced the
 * current listing is bound; resize MUST target a machine in that listing. At most one submission is
 * in flight, each submission mints one request id inside the adapter, and a result that completes
 * after sign-out or a session change MUST NOT update the form or trigger a refresh.
 *
 * Binds the create and resize forms to the authenticated session.
 */
class MilaMachineFormController(private val adapter: MilaFfiAdapter) {
    var state: MilaMachineFormState = MilaMachineFormState.SignedOut
        private set
    private var listing: MilaSessionListing? = null
    private var authenticated = false
    private var generation = 0L

    fun setSession(signedIn: Boolean, current: MilaSessionListing?) {
        val next = signedIn && current != null
        if (next == authenticated && listing == current) return
        // A refreshed listing for the same session keeps an in-flight submission valid;
        // a sign-in transition fences it.
        if (next != authenticated) generation += 1
        authenticated = next
        listing = if (next) current else null
        if (!next) state = MilaMachineFormState.SignedOut
        else if (state == MilaMachineFormState.SignedOut) state = MilaMachineFormState.Idle
    }

    fun canSubmit(): Boolean = authenticated && state !is MilaMachineFormState.Submitting

    /** Returns true only when Rust accepted the creation for the still-current session. */
    suspend fun create(name: String, cpu: String, memory: String, disk: String): Boolean {
        if (!canSubmit()) return false
        val request = MilaMachineCreateRequest.parse(name, cpu, memory, disk).getOrElse {
            state = MilaMachineFormState.Invalid(MilaMachineFormKind.Create, (it as MilaMachineFieldException).field)
            return false
        }
        return submit(MilaMachineFormKind.Create) { adapter.machineCreate(request) }
    }

    suspend fun resize(machineId: UUID, cpu: String, memory: String, disk: String): Boolean {
        if (!canSubmit()) return false
        if (listing?.machines?.none { it.id == machineId } != false) {
            state = MilaMachineFormState.Failed(MilaMachineFormKind.Resize)
            return false
        }
        val request = MilaMachineResizeRequest.parse(machineId, cpu, memory, disk).getOrElse {
            state = MilaMachineFormState.Invalid(MilaMachineFormKind.Resize, (it as? MilaMachineFieldException)?.field ?: MilaMachineField.Cpu)
            return false
        }
        return submit(MilaMachineFormKind.Resize) {
            adapter.machineResize(request.machineId, request.cpu, request.memoryMiB, request.diskGiB)
        }
    }

    private suspend fun submit(kind: MilaMachineFormKind, operation: suspend () -> Result<Unit>): Boolean {
        val submitted = generation
        state = MilaMachineFormState.Submitting(kind)
        val result = operation()
        if (submitted != generation || !authenticated) return false
        state = if (result.isSuccess) MilaMachineFormState.Applied(kind) else MilaMachineFormState.Failed(kind)
        return result.isSuccess
    }
}

/** Compatibility entry point; creation always dispatches through the authenticated session. */
suspend fun MilaFfiAdapter.createMachine(request: MilaMachineCreateRequest): Result<Unit> = machineCreate(request)
