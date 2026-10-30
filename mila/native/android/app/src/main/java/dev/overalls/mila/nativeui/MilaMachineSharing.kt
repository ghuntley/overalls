package dev.overalls.mila.nativeui

import java.util.UUID

/** A validated machine principal used by the sharing surface. */
data class MilaSharePrincipal private constructor(val value: String) {
    companion object {
        fun parse(raw: String): Result<MilaSharePrincipal> {
            val value = raw.trim()
            if (value.length !in 3..256 || value.toByteArray(Charsets.UTF_8).size > 256 || value.any { it.isISOControl() || it.isWhitespace() }) {
                return Result.failure(IllegalArgumentException("invalid share principal"))
            }
            return Result.success(MilaSharePrincipal(value))
        }
    }
}

/** Closed Porsche share roles; the wire value is the only form that crosses JNI. */
enum class MilaShareRole(val wire: String) { Viewer("viewer"), Operator("operator"), Manager("manager") }

sealed interface MilaMachineSharingState {
    data object SignedOut : MilaMachineSharingState
    data object Idle : MilaMachineSharingState
    data class Ready(val machine: MilaMachineRow) : MilaMachineSharingState
    data class Submitting(val machine: MilaMachineRow, val principal: MilaSharePrincipal, val remove: Boolean) : MilaMachineSharingState
    data class Applied(val machine: MilaMachineRow, val principal: MilaSharePrincipal, val remove: Boolean) : MilaMachineSharingState
    data class Failed(val machine: MilaMachineRow, val principal: MilaSharePrincipal?, val remove: Boolean, val reason: String) : MilaMachineSharingState
}

/**
 * Coordinates authenticated machine sharing. Principal syntax is checked before the Rust
 * machine command is submitted; the closed command catalog remains authoritative for add/remove.
 */
class MilaMachineSharingController(private val adapter: MilaFfiAdapter) {
    var state: MilaMachineSharingState = MilaMachineSharingState.SignedOut
        private set
    private var machine: MilaMachineRow? = null
    private var listing: MilaSessionListing? = null
    private var authenticated = false

    fun setSession(signedIn: Boolean, listing: MilaSessionListing?) {
        this.listing = listing
        authenticated = signedIn && listing != null
        machine = if (authenticated) machine?.let { current -> listing!!.machines.firstOrNull { it.id == current.id } } else null
        state = if (!authenticated) MilaMachineSharingState.SignedOut else machine?.let { MilaMachineSharingState.Ready(it) } ?: MilaMachineSharingState.Idle
    }

    fun select(machineId: UUID): Boolean {
        if (!authenticated) return false
        val selected = listing?.machines?.firstOrNull { it.id == machineId } ?: return false
        machine = selected
        state = MilaMachineSharingState.Ready(selected)
        return true
    }

    fun setMachine(selected: MilaMachineRow): Boolean {
        if (!authenticated || listing?.machines?.none { it.id == selected.id } == true) return false
        machine = selected
        state = MilaMachineSharingState.Ready(selected)
        return true
    }

    /**
     * @cc [owner:ghuntley,label:security] android-share-authenticated-mutation
     * Share add/remove MUST dispatch the validated principal and closed role through the
     * authenticated session's share mutation, never through the lifecycle action seam.
     */
    suspend fun submit(rawPrincipal: String, remove: Boolean = false, role: MilaShareRole = MilaShareRole.Viewer): Boolean {
        val current = machine ?: return false
        val principal = MilaSharePrincipal.parse(rawPrincipal).getOrElse {
            state = MilaMachineSharingState.Failed(current, null, remove, "invalid share principal")
            return false
        }
        if (!authenticated) { state = MilaMachineSharingState.SignedOut; return false }
        state = MilaMachineSharingState.Submitting(current, principal, remove)
        return adapter.machineShare(current.id, principal, if (remove) null else role).fold(
            onSuccess = { state = MilaMachineSharingState.Applied(current, principal, remove); true },
            onFailure = { error -> state = MilaMachineSharingState.Failed(current, principal, remove, error.message ?: "sharing rejected"); false },
        )
    }
}
