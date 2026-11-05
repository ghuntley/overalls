package dev.overalls.mila.nativeui

import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class MilaDeepLinksTest {
    @Test fun routesRejectNonCanonicalAuthorityAndPathForms() {
        val id = "11111111-1111-4111-8111-111111111111"
        assertEquals(MilaRoute.Machine(UUID.fromString(id)), parseMilaRoute("overalls://mila.example/machines/$id"))
        listOf(
            "overalls://Mila.example/machines/$id",
            "overalls://mila.example:443/machines/$id",
            "overalls://user@mila.example/machines/$id",
            "overalls://mila.example/machines/$id/",
            "overalls://mila.example/machines/%2F$id",
            "overalls://mila.example/machines/$id?command=rm",
            "overalls://mila.example/machines/$id#fragment",
            "overalls://mila.example/machines/11111111-1111-4111-8111-11111111111",
        ).forEach { value -> assertNull("unexpectedly accepted $value", parseMilaRoute(value)) }
    }

    @Test fun acceptsMachineTargetAndRejectsStaleGeneration() {
        val id = UUID.randomUUID()
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        assertTrue(controller.accept("overalls://mila/machines/$id", generation))
        assertEquals(MilaRoute.Machine(id), controller.target)
        assertFalse(controller.accept("overalls://mila/threads", generation - 1))
        assertEquals(MilaRoute.Machine(id), controller.target)
    }

    @Test fun malformedAndCommandLikeLinksDoNotChangeTarget() {
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        assertFalse(controller.accept("overalls://mila/machines/not-an-id", generation))
        assertFalse(controller.accept("overalls://mila/machines?command=rm", generation))
        assertEquals(MilaRoute.Machines, controller.target)
    }

    @Test fun signedOutDeliveryQueuesAndFirstSessionAppliesOnce() {
        val id = UUID.randomUUID()
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        assertEquals(MilaLinkDelivery.Queued, controller.deliver("overalls://a.example/machines/$id", generation, authenticatedHost = null))
        assertEquals(MilaRoute.Machines, controller.target)
        assertTrue(controller.hasPending)
        assertEquals("a.example", controller.pendingHost)
        assertEquals(MilaLinkDelivery.Applied, controller.completePending("a.example", generation))
        assertEquals(MilaRoute.Machine(id), controller.target)
        assertEquals(MilaLinkDelivery.Refused, controller.completePending("a.example", generation))
    }

    @Test fun authenticatedDeliveryNavigatesImmediatelyAndSupersedesPending() {
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        controller.deliver("overalls://a.example/settings", generation, authenticatedHost = null)
        assertEquals(MilaLinkDelivery.Applied, controller.deliver("overalls://a.example/threads", generation, authenticatedHost = "a.example"))
        assertEquals(MilaRoute.Threads, controller.target)
        assertFalse(controller.hasPending)
    }

    @Test fun pendingShareCompletesOnlyForTheHostItNames() {
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        // Signed in to another deployment: the link is held, not applied to the wrong host.
        assertEquals(MilaLinkDelivery.Queued, controller.deliver("overalls://b.example/threads", generation, authenticatedHost = "a.example"))
        assertEquals(MilaRoute.Machines, controller.target)
        assertEquals(MilaLinkDelivery.Queued, controller.completePending("a.example", generation))
        assertTrue(controller.hasPending)
        assertEquals(MilaLinkDelivery.Applied, controller.completePending("B.Example", generation))
        assertEquals(MilaRoute.Threads, controller.target)
    }

    @Test fun pendingShareExpiresAfterItsLifetime() {
        var now = 1_000L
        val controller = MilaDeepLinkController { now }
        val generation = controller.beginSession()
        controller.deliver("overalls://a.example/threads", generation, authenticatedHost = null)
        now += MilaDeepLinkController.PENDING_LIFETIME_SECONDS + 1
        assertEquals(MilaLinkDelivery.Refused, controller.completePending("a.example", generation))
        assertFalse(controller.hasPending)
        assertEquals(MilaRoute.Machines, controller.target)
        // A clock that moved backwards is refused rather than trusted.
        controller.deliver("overalls://a.example/threads", generation, authenticatedHost = null)
        now -= 10
        assertEquals(MilaLinkDelivery.Refused, controller.completePending("a.example", generation))
        assertEquals(MilaRoute.Machines, controller.target)
    }

    @Test fun pendingShareWithinItsLifetimeCompletes() {
        var now = 1_000L
        val controller = MilaDeepLinkController { now }
        val generation = controller.beginSession()
        controller.deliver("overalls://a.example/threads", generation, authenticatedHost = null)
        now += MilaDeepLinkController.PENDING_LIFETIME_SECONDS
        assertEquals(MilaLinkDelivery.Applied, controller.completePending("a.example", generation))
        assertEquals(MilaRoute.Threads, controller.target)
    }

    @Test fun endingSessionDropsPendingAndFencesOldGeneration() {
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        controller.deliver("overalls://a.example/threads", generation, authenticatedHost = null)
        val next = controller.endSession()
        assertFalse(controller.hasPending)
        assertEquals(MilaLinkDelivery.Refused, controller.completePending("a.example", next))
        assertEquals(MilaLinkDelivery.Refused, controller.deliver("overalls://a.example/threads", generation, authenticatedHost = "a.example"))
        assertEquals(MilaRoute.Machines, controller.target)
    }

    @Test fun staleGenerationCompletionIsRefusedAndDropsPending() {
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        controller.deliver("overalls://a.example/threads", generation, authenticatedHost = null)
        assertEquals(MilaLinkDelivery.Refused, controller.completePending("a.example", generation - 1))
        assertFalse(controller.hasPending)
        assertEquals(MilaRoute.Machines, controller.target)
    }

    @Test fun refusedDeliveryKeepsPendingTarget() {
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        controller.deliver("overalls://a.example/threads", generation, authenticatedHost = null)
        assertEquals(MilaLinkDelivery.Refused, controller.deliver("overalls://a.example/machines?command=rm", generation, authenticatedHost = null))
        assertEquals(MilaLinkDelivery.Applied, controller.completePending("a.example", generation))
        assertEquals(MilaRoute.Threads, controller.target)
    }

    @Test fun routesResolveOnlyAgainstAuthenticatedListings() {
        val id = UUID.randomUUID()
        val machines = MilaSessionListing(listOf(MilaMachineRow(id, "m", "running")), false)
        val threads = MilaThreadListing(listOf(MilaThreadRow(id, "t", "ready")), false)
        assertEquals(MilaRouteResolution.Resolved, resolveMilaRoute(MilaRoute.Settings, false, null, null))
        assertEquals(MilaRouteResolution.Awaiting, resolveMilaRoute(MilaRoute.Machine(id), false, machines, threads))
        assertEquals(MilaRouteResolution.Awaiting, resolveMilaRoute(MilaRoute.Thread(id), true, machines, null))
        assertEquals(MilaRouteResolution.Resolved, resolveMilaRoute(MilaRoute.Machine(id), true, machines, threads))
        assertEquals(MilaRouteResolution.Resolved, resolveMilaRoute(MilaRoute.Thread(id), true, machines, threads))
        assertEquals(MilaRouteResolution.NotFound, resolveMilaRoute(MilaRoute.Machine(UUID.randomUUID()), true, machines, threads))
        assertEquals(MilaRouteResolution.NotFound, resolveMilaRoute(MilaRoute.Thread(UUID.randomUUID()), true, machines, threads))
    }
}
