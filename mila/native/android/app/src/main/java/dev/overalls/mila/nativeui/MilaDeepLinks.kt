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

/** Generation-safe target routing for external Android intents. */
class MilaDeepLinkController {
    var target: MilaRoute = MilaRoute.Machines
        private set
    private var generation: Long = 0
    private var pending: String? = null

    /** Queues a validated external target until the authenticated shell consumes it. */
    fun queue(uri: String, expectedGeneration: Long = generation): Boolean {
        if (expectedGeneration != generation || parseMilaRoute(uri) == null) return false
        pending = uri
        return true
    }

    /** Applies the queued target after authentication, refusing stale generations. */
    fun acceptPending(expectedGeneration: Long = generation): Boolean {
        val uri = pending ?: return false
        pending = null
        return accept(uri, expectedGeneration)
    }

    fun accept(uri: String, expectedGeneration: Long = generation): Boolean {
        if (expectedGeneration != generation) return false
        val route = parseMilaRoute(uri) ?: return false
        target = route
        return true
    }

    /**
     * @cc [owner:ghuntley,label:security] android-share-provider-completion
     * An external target MUST navigate immediately only while the shell is authenticated; while
     * signed out it is held as the single pending target and applied at most once by the next
     * authenticated session. [endSession] MUST discard a pending target so a link received during
     * one session never navigates a later session after sign-out or a deployment change.
     *
     * Completes a VIEW or share-provider SEND target for the current session.
     */
    fun deliver(uri: String, expectedGeneration: Long, signedIn: Boolean): MilaLinkDelivery = when {
        expectedGeneration != generation || parseMilaRoute(uri) == null -> MilaLinkDelivery.Refused
        signedIn -> { pending = null; if (accept(uri, expectedGeneration)) MilaLinkDelivery.Applied else MilaLinkDelivery.Refused }
        else -> { pending = uri; MilaLinkDelivery.Queued }
    }

    /** True while a validated target waits for authentication. */
    val hasPending: Boolean get() = pending != null

    /** Ends an authenticated session: drops pending and current targets and fences old generations. */
    fun endSession(): Long = beginSession()

    fun beginSession(): Long {
        generation += 1
        target = MilaRoute.Machines
        pending = null
        return generation
    }
}
