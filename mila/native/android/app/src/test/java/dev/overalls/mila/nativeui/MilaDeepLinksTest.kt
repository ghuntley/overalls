package dev.overalls.mila.nativeui

import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class MilaDeepLinksTest {
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
        assertEquals(MilaLinkDelivery.Queued, controller.deliver("overalls://mila/machines/$id", generation, signedIn = false))
        assertEquals(MilaRoute.Machines, controller.target)
        assertTrue(controller.hasPending)
        assertTrue(controller.acceptPending(generation))
        assertEquals(MilaRoute.Machine(id), controller.target)
        assertFalse(controller.acceptPending(generation))
    }

    @Test fun authenticatedDeliveryNavigatesImmediatelyAndSupersedesPending() {
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        controller.deliver("overalls://mila/settings", generation, signedIn = false)
        assertEquals(MilaLinkDelivery.Applied, controller.deliver("overalls://mila/threads", generation, signedIn = true))
        assertEquals(MilaRoute.Threads, controller.target)
        assertFalse(controller.hasPending)
    }

    @Test fun endingSessionDropsPendingAndFencesOldGeneration() {
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        controller.deliver("overalls://mila/threads", generation, signedIn = false)
        val next = controller.endSession()
        assertFalse(controller.hasPending)
        assertFalse(controller.acceptPending(next))
        assertEquals(MilaLinkDelivery.Refused, controller.deliver("overalls://mila/threads", generation, signedIn = true))
        assertEquals(MilaRoute.Machines, controller.target)
    }

    @Test fun refusedDeliveryKeepsPendingTarget() {
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        controller.deliver("overalls://mila/threads", generation, signedIn = false)
        assertEquals(MilaLinkDelivery.Refused, controller.deliver("overalls://mila/machines?command=rm", generation, signedIn = false))
        assertTrue(controller.acceptPending(generation))
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
