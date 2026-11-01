package dev.overalls.mila.nativeui

import android.content.Intent

/**
 * Builds a text share intent only for a canonical navigation route.
 *
 * The link's authority is the signed-in deployment's host, so the receiving Mila completes it only
 * against that deployment ([MilaDeepLinkController.completePending]).
 */
internal object MilaShareIntentFactory {
    fun create(route: MilaRoute, host: String): Intent = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, route.toCanonicalUri(host))
    }

    /** Wraps the route payload in the platform chooser without exposing arbitrary text. */
    fun chooser(route: MilaRoute, host: String): Intent = Intent.createChooser(create(route, host), null)

    /**
     * Returns a chooser only for an authenticated session whose host forms a canonical route;
     * signed-out callers cannot share routes.
     */
    fun authenticatedChooser(route: MilaRoute, authenticatedHost: String?): Intent? =
        authenticatedHost?.takeIf { milaRouteHost(route.toCanonicalUri(it)) == it }?.let { chooser(route, it) }

    private fun MilaRoute.toCanonicalUri(host: String): String = when (this) {
        MilaRoute.Machines -> "overalls://$host/machines"
        MilaRoute.Threads -> "overalls://$host/threads"
        MilaRoute.Settings -> "overalls://$host/settings"
        is MilaRoute.Machine -> "overalls://$host/machines/${id}"
        is MilaRoute.Thread -> "overalls://$host/threads/${id}"
    }
}
