package dev.overalls.mila.nativeui

import android.content.Intent
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class MilaIntentRoutingTest {
    @Test fun viewAndShareRoutesAreAccepted() {
        val id = UUID.randomUUID()
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        assertTrue(acceptExternalIntent(controller, Intent(Intent.ACTION_VIEW).setData(android.net.Uri.parse("overalls://mila/machines/$id")), generation))
        assertEquals(MilaRoute.Machines, controller.target)
        assertTrue(acceptAuthenticatedExternalIntent(controller, Intent(Intent.ACTION_VIEW).setData(android.net.Uri.parse("overalls://mila/machines/$id")), generation, signedIn = true))
        assertEquals(MilaRoute.Machine(id), controller.target)
        val share = Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_TEXT, "overalls://mila/threads")
        assertTrue(acceptExternalIntent(controller, share, generation))
        // External intents are queued until authenticated consumption; the
        // currently displayed machine remains selected while queued.
        assertEquals(MilaRoute.Machine(id), controller.target)
    }

    @Test fun authenticatedShareTargetRefusesSignedOutSession() {
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        val share = Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_TEXT, "overalls://mila/threads")
        assertFalse(acceptAuthenticatedExternalIntent(controller, share, generation, signedIn = false))
        assertEquals(MilaRoute.Machines, controller.target)
        assertTrue(acceptAuthenticatedExternalIntent(controller, share, generation, signedIn = true))
        assertEquals(MilaRoute.Threads, controller.target)
    }

    @Test fun nonTextSharePayloadIsRejected() {
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        val share = Intent(Intent.ACTION_SEND).setType("image/png")
            .putExtra(Intent.EXTRA_TEXT, "overalls://mila/threads")
        assertFalse(acceptExternalIntent(controller, share, generation))
        assertEquals(MilaRoute.Machines, controller.target)
    }

    @Test fun nonNavigationShareTextIsRejected() {
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        val share = Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_TEXT, "https://example.invalid/command?rm")
        assertFalse(acceptExternalIntent(controller, share, generation))
        assertEquals(MilaRoute.Machines, controller.target)
    }

    @Test fun oversizedShareTextIsRejected() {
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        val share = Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_TEXT, "overalls://mila/threads" + "x".repeat(2048))
        assertFalse(acceptExternalIntent(controller, share, generation))
        assertEquals(MilaRoute.Machines, controller.target)
    }

    @Test fun shareProviderSendCompletesThroughSessionState() {
        val id = UUID.randomUUID()
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        val share = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "overalls://mila/machines/$id")
        assertEquals(MilaLinkDelivery.Queued, deliverExternalIntent(controller, share, generation, signedIn = false))
        assertTrue(controller.acceptPending(generation))
        assertEquals(MilaRoute.Machine(id), controller.target)
        val view = Intent(Intent.ACTION_VIEW).setData(android.net.Uri.parse("overalls://mila/threads"))
        assertEquals(MilaLinkDelivery.Applied, deliverExternalIntent(controller, view, generation, signedIn = true))
        assertEquals(MilaRoute.Threads, controller.target)
        assertEquals(MilaLinkDelivery.Refused, deliverExternalIntent(controller, Intent(Intent.ACTION_SEND).setType("image/png"), generation, signedIn = true))
    }

    @Test fun outboundShareCarriesOnlyCanonicalRouteWhenAuthenticated() {
        val id = UUID.randomUUID()
        assertNull(MilaShareIntentFactory.authenticatedChooser(MilaRoute.Machine(id), signedIn = false))
        val chooser = MilaShareIntentFactory.authenticatedChooser(MilaRoute.Machine(id), signedIn = true)!!
        @Suppress("DEPRECATION") val inner = chooser.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)!!
        assertEquals("overalls://mila/machines/$id", inner.getStringExtra(Intent.EXTRA_TEXT))
        assertEquals("text/plain", inner.type)
    }
}
