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
        assertTrue(acceptAuthenticatedExternalIntent(controller, Intent(Intent.ACTION_VIEW).setData(android.net.Uri.parse("overalls://mila/machines/$id")), generation, authenticatedHost = "mila"))
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
        assertFalse(acceptAuthenticatedExternalIntent(controller, share, generation, authenticatedHost = null))
        assertEquals(MilaRoute.Machines, controller.target)
        assertFalse(acceptAuthenticatedExternalIntent(controller, share, generation, authenticatedHost = "other.example"))
        assertEquals(MilaRoute.Machines, controller.target)
        assertTrue(acceptAuthenticatedExternalIntent(controller, share, generation, authenticatedHost = "mila"))
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
        val share = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "overalls://a.example/machines/$id")
        assertEquals(MilaLinkDelivery.Queued, deliverExternalIntent(controller, share, generation, authenticatedHost = null))
        assertEquals(MilaLinkDelivery.Applied, controller.completePending("a.example", generation))
        assertEquals(MilaRoute.Machine(id), controller.target)
        val view = Intent(Intent.ACTION_VIEW).setData(android.net.Uri.parse("overalls://a.example/threads"))
        assertEquals(MilaLinkDelivery.Applied, deliverExternalIntent(controller, view, generation, authenticatedHost = "a.example"))
        assertEquals(MilaRoute.Threads, controller.target)
        assertEquals(MilaLinkDelivery.Refused, deliverExternalIntent(controller, Intent(Intent.ACTION_SEND).setType("image/png"), generation, authenticatedHost = "a.example"))
    }

    @Test fun outboundShareCarriesOnlyCanonicalRouteWhenAuthenticated() {
        val id = UUID.randomUUID()
        assertNull(MilaShareIntentFactory.authenticatedChooser(MilaRoute.Machine(id), authenticatedHost = null))
        assertNull(MilaShareIntentFactory.authenticatedChooser(MilaRoute.Machine(id), authenticatedHost = "a.example/x"))
        val chooser = MilaShareIntentFactory.authenticatedChooser(MilaRoute.Machine(id), authenticatedHost = "a.example")!!
        @Suppress("DEPRECATION") val inner = chooser.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)!!
        assertEquals("overalls://a.example/machines/$id", inner.getStringExtra(Intent.EXTRA_TEXT))
        assertEquals("text/plain", inner.type)
    }

    @Test fun outboundShareRoundTripsThroughSignedOutCompletion() {
        val id = UUID.randomUUID()
        val chooser = MilaShareIntentFactory.authenticatedChooser(MilaRoute.Thread(id), authenticatedHost = "a.example")!!
        @Suppress("DEPRECATION") val inner = chooser.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)!!
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        assertEquals(MilaLinkDelivery.Queued, deliverExternalIntent(controller, inner, generation, authenticatedHost = null))
        assertEquals(MilaLinkDelivery.Queued, controller.completePending("b.example", generation))
        assertEquals(MilaLinkDelivery.Applied, controller.completePending("a.example", generation))
        assertEquals(MilaRoute.Thread(id), controller.target)
    }
}
