package dev.overalls.mila.nativeui

/** Result of handing an external VIEW/SEND target to the shell. */
enum class MilaLinkDelivery { Applied, Queued, Refused }

/** How a navigated route resolves against the authenticated session's listings. */
sealed interface MilaRouteResolution {
    /** The route needs no session data, or names an entity in the current listing. */
    data object Resolved : MilaRouteResolution
    /** The session has not produced the listing that can resolve this route yet. */
    data object Awaiting : MilaRouteResolution
    /** The authenticated listing does not contain the routed entity. */
    data object NotFound : MilaRouteResolution
}

/**
 * @cc [owner:ghuntley,label:security] android-route-resolution-authenticated
 * A machine or thread route from an external link MUST resolve only to an entity present in the
 * signed-in session's listing; a signed-out shell or an absent entity never projects detail state.
 *
 * Resolves an entity route only against data produced by the authenticated session.
 */
fun resolveMilaRoute(route: MilaRoute, signedIn: Boolean, machines: MilaSessionListing?, threads: MilaThreadListing?): MilaRouteResolution = when (route) {
    MilaRoute.Machines, MilaRoute.Threads, MilaRoute.Settings -> MilaRouteResolution.Resolved
    is MilaRoute.Machine -> when {
        !signedIn || machines == null -> MilaRouteResolution.Awaiting
        machines.machines.any { it.id == route.id } -> MilaRouteResolution.Resolved
        else -> MilaRouteResolution.NotFound
    }
    is MilaRoute.Thread -> when {
        !signedIn || threads == null -> MilaRouteResolution.Awaiting
        threads.threads.any { it.id == route.id } -> MilaRouteResolution.Resolved
        else -> MilaRouteResolution.NotFound
    }
}

/** Lower-cased host of a canonical route, or null when [uri] is not one. */
internal fun milaRouteHost(uri: String): String? =
    if (parseMilaRoute(uri) == null) null else runCatching { java.net.URI(uri).host?.lowercase() }.getOrNull()

/**
 * Generation-safe target routing for external Android intents.
 *
 * [clock] returns wall-clock seconds; tests inject a fixed clock to cross the pending lifetime.
 */
class MilaDeepLinkController(private val clock: () -> Long = { System.currentTimeMillis() / 1000 }) {
    companion object {
        /** A share held for sign-in completes only within this many seconds of its arrival. */
        const val PENDING_LIFETIME_SECONDS: Long = 600
    }

    private class Pending(val uri: String, val host: String, val generation: Long, val receivedAt: Long)

    var target: MilaRoute = MilaRoute.Machines
        private set
    private var generation: Long = 0
    private var pending: Pending? = null

    /** Host of the target waiting for authentication, or null when none is held. */
    val pendingHost: String? get() = pending?.host

    /** True while a validated target waits for authentication. */
    val hasPending: Boolean get() = pending != null

    /** Queues a validated external target until the authenticated shell consumes it. */
    fun queue(uri: String, expectedGeneration: Long = generation): Boolean {
        if (expectedGeneration != generation) return false
        val host = milaRouteHost(uri) ?: return false
        pending = Pending(uri, host, generation, clock())
        return true
    }

    fun accept(uri: String, expectedGeneration: Long = generation): Boolean {
        if (expectedGeneration != generation) return false
        val route = parseMilaRoute(uri) ?: return false
        target = route
        return true
    }

    /**
     * @cc [owner:ghuntley,label:security] android-share-provider-completion
     * An external target MUST navigate immediately only while the shell is authenticated to the
     * deployment the link names; otherwise it is held as the single pending target. A held target
     * MUST complete at most once, only through [completePending] for that exact host, within the
     * activation generation it arrived in and [PENDING_LIFETIME_SECONDS]. [endSession] MUST discard
     * it, so a link received during one session never navigates a later session after sign-out or a
     * deployment change. Completion is navigation only and never mutates data.
     *
     * Completes a VIEW or share-provider SEND target for the current session; [authenticatedHost]
     * is the host of the signed-in deployment, or null while signed out.
     */
    fun deliver(uri: String, expectedGeneration: Long, authenticatedHost: String?): MilaLinkDelivery {
        if (expectedGeneration != generation) return MilaLinkDelivery.Refused
        val host = milaRouteHost(uri) ?: return MilaLinkDelivery.Refused
        if (authenticatedHost != null && host == authenticatedHost.lowercase()) {
            pending = null
            return if (accept(uri, expectedGeneration)) MilaLinkDelivery.Applied else MilaLinkDelivery.Refused
        }
        // A newer target replaces an older held one.
        pending = Pending(uri, host, generation, clock())
        return MilaLinkDelivery.Queued
    }

    /**
     * Called once [authenticatedHost] has an authenticated session. Applies the held target when it
     * names that host; a target for another host stays held ([MilaLinkDelivery.Queued]); nothing
     * held, an expired target or one from an older generation is [MilaLinkDelivery.Refused].
     */
    fun completePending(authenticatedHost: String, expectedGeneration: Long = generation): MilaLinkDelivery {
        val held = pending ?: return MilaLinkDelivery.Refused
        if (held.host != authenticatedHost.lowercase()) return MilaLinkDelivery.Queued
        pending = null
        val now = clock()
        if (expectedGeneration != generation || held.generation != generation ||
            now < held.receivedAt || now - held.receivedAt > PENDING_LIFETIME_SECONDS
        ) return MilaLinkDelivery.Refused
        return if (accept(held.uri, expectedGeneration)) MilaLinkDelivery.Applied else MilaLinkDelivery.Refused
    }

    /** Ends an authenticated session: drops pending and current targets and fences old generations. */
    fun endSession(): Long = beginSession()

    fun beginSession(): Long {
        generation += 1
        target = MilaRoute.Machines
        pending = null
        return generation
    }
}
