package dev.overalls.mila.nativeui

import android.content.Intent

/** Extracts navigation-only targets from Android external intents. */
internal fun externalMilaUri(intent: Intent): String? = when (intent.action) {
    Intent.ACTION_VIEW -> intent.dataString
    Intent.ACTION_SEND -> {
        // Route shares are navigation text only; reject binary or ambiguous MIME payloads.
        val mime = intent.type
        if (mime != null && mime != "text/plain") null else intent.getStringExtra(Intent.EXTRA_TEXT)
    }
    else -> null
}?.takeIf { it.length <= 2048 }

/** A share target is accepted only when its text is itself a canonical Mila route. */
internal fun acceptExternalIntent(controller: MilaDeepLinkController, intent: Intent, generation: Long): Boolean =
    externalMilaUri(intent)?.let { controller.queue(it, generation) } ?: false

/** Accepts an external route only while the native session is authenticated to the host it names. */
internal fun acceptAuthenticatedExternalIntent(
    controller: MilaDeepLinkController,
    intent: Intent,
    generation: Long,
    authenticatedHost: String?,
): Boolean = authenticatedHost != null &&
    deliverExternalIntent(controller, intent, generation, authenticatedHost) == MilaLinkDelivery.Applied

/** Hands one external VIEW/SEND intent to [MilaDeepLinkController.deliver] for the current session. */
internal fun deliverExternalIntent(
    controller: MilaDeepLinkController,
    intent: Intent,
    generation: Long,
    authenticatedHost: String?,
): MilaLinkDelivery = externalMilaUri(intent)?.let { controller.deliver(it, generation, authenticatedHost) } ?: MilaLinkDelivery.Refused
