package dev.overalls.mila.nativeui

import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.delay

internal data class MilaWatchFilters(val machines: List<UUID>, val threads: List<UUID>) {
    companion object {
        /**
         * @cc [owner:ghuntley,label:security;recovery] mila-android-watch-filter-window
         * Each retained machine or thread identity MUST be deduplicated before
         * applying the 500-machine or 256-thread window, then emitted in subscriptions of at most
         * 64 IDs; duplicates MUST NOT hide later displayed identities.
         */
        fun groups(machines: List<UUID>, threads: List<UUID>): List<MilaWatchFilters> {
            // Deduplicate before applying the identity windows so repeated rows
            // cannot consume the bound and silently hide later identities.
            val machineGroups = machines.distinct().sortedBy(UUID::toString).take(MILA_MAX_MACHINES).chunked(64).map { MilaWatchFilters(it, emptyList()) }
            val threadGroups = threads.distinct().sortedBy(UUID::toString).take(256).chunked(64).map { MilaWatchFilters(emptyList(), it) }
            return (machineGroups + threadGroups).ifEmpty { listOf(MilaWatchFilters(emptyList(), emptyList())) }
        }
    }
}

/**
 * @cc [owner:ghuntley,label:security;recovery] mila-android-watch-generation
 * Each approved generation owns bounded, read-only watch subscriptions. Hints
 * perform ordinary authenticated reads; reconnect retries only watch, never a
 * mutation. Authority loss signs out. Cancellation closes the subscription and
 * the caller fences late reads before publishing state or persisting snapshots.
 * Acquiring or replacing a handle MUST record ownership before cancellation can
 * resume, so cleanup always closes the acquired subscription.
 */
internal suspend fun runMilaWatch(
    adapter: MilaFfiAdapter,
    filters: MilaWatchFilters,
    onHint: suspend () -> Unit,
    onAuthorityLost: () -> Unit,
) {
    var handle = 0L
    try {
        while (currentCoroutineContext().isActive && handle == 0L) {
            // Keep the dispatcher handoff inside NonCancellable: otherwise a successful
            // native result can be discarded on return before this owner records it.
            withContext(NonCancellable) {
                handle = withContext(Dispatchers.IO) { adapter.watchOpen(filters.machines, filters.threads).getOrNull() } ?: 0L
            }
            if (handle == 0L) delay(3000)
        }
        while (currentCoroutineContext().isActive) {
            val notice = withContext(Dispatchers.IO) { adapter.watchRead(handle, 250).getOrNull() }
            when (notice) {
                is MilaWatchRead.Hint -> if (notice.kind != MilaWatchHint.Heartbeat && notice.kind != MilaWatchHint.Unknown) onHint()
                MilaWatchRead.Idle -> Unit
                MilaWatchRead.AuthorityLost -> { onAuthorityLost(); return }
                MilaWatchRead.Closed, MilaWatchRead.TransportLost, null -> {
                    var reconnected = false
                    while (currentCoroutineContext().isActive && !reconnected) {
                        delay(1000)
                        withContext(NonCancellable) {
                            val next = withContext(Dispatchers.IO) { adapter.watchReconnect(handle).getOrNull() }
                            if (next != null) { handle = next; reconnected = true }
                        }
                    }
                }
            }
        }
    } finally {
        if (handle != 0L) withContext(NonCancellable + Dispatchers.IO) { adapter.watchClose(handle) }
    }
}
