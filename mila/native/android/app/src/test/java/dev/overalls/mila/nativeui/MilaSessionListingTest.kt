package dev.overalls.mila.nativeui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class MilaSessionListingTest {
    /** Exactly what `mila_session_listing` emits: serde_json sorts object keys. */
    @Test fun decodesRustSortedKeyListing() {
        val rust = """{"has_more":false,"machines":[{"action_bits":6,"desired_state":"running","id":"00000000-0000-0000-0000-000000000001","manage":true,"name":"seed","observed_state":"stopped","owner":"owner@example.test","pinned":false,"read":true,"write":true},{"action_bits":0,"desired_state":"paused","id":"00000000-0000-0000-0000-000000000002","manage":false,"name":"made","observed_state":null,"owner":"owner@example.test","pinned":true,"read":true,"write":false}]}"""
        val listing = MilaSessionListing.decode(rust.toByteArray())
        assertEquals(listOf("seed", "made"), listing.machines.map { it.name })
        assertEquals(listOf("stopped", "paused"), listing.machines.map { it.status })
        assertEquals(false, listing.hasMore)
    }

    @Test(expected = IllegalArgumentException::class)
    fun refusesListingWithoutMachines() {
        MilaSessionListing.decode("""{"has_more":false}""".toByteArray())
    }

    @Test fun decodesBoundedValidatedRows() {
        val listing = MilaSessionListing.decode("{\"machines\":[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"build\",\"status\":\"running\"}],\"has_more\":true}".toByteArray())
        assertEquals("build", listing.machines.single().name)
        assertEquals(true, listing.hasMore)
    }
    @Test fun retainsAllFiveHundredValidatedMachines() {
        val listing = MilaSessionListing.decode(machineListingProjection(500, hasMore = false))
        assertEquals(500, listing.machines.size)
        assertEquals("m500", listing.machines.last().name)
        assertEquals(false, listing.hasMore)
    }
    @Test fun refusesMoreThanFiveHundredMachines() {
        assertThrows(IllegalArgumentException::class.java) {
            MilaSessionListing.decode(machineListingProjection(501, hasMore = false))
        }
    }
    @Test fun completeSnapshotsNeedNoContinuationField() {
        val snapshot = org.json.JSONObject(machineListingProjection(500, false).toString(Charsets.UTF_8))
        snapshot.remove("has_more")
        val listing = MilaSessionListing.decode(snapshot.toString().toByteArray())
        assertEquals(500, listing.machines.size)
        assertEquals(false, listing.hasMore)
    }
    @Test fun refusesCoercedContinuationFlags() {
        for (value in listOf("\"true\"", "1", "null", "{}", "[]")) {
            assertThrows(IllegalArgumentException::class.java) {
                MilaSessionListing.decode("{\"machines\":[],\"has_more\":$value}".toByteArray())
            }
        }
    }
    @Test(expected = IllegalArgumentException::class) fun rejectsMalformedRows() {
        MilaSessionListing.decode("{\"machines\":[{\"id\":\"bad\"}]}".toByteArray())
    }
    @Test(expected = IllegalArgumentException::class) fun rejectsUnsafeDisplayText() {
        MilaSessionListing.decode("{\"machines\":[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"bad\\nname\"}]}".toByteArray())
    }
    @Test(expected = IllegalArgumentException::class) fun rejectsOversizedDisplayText() {
        val name = "x".repeat(129)
        MilaSessionListing.decode("{\"machines\":[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"$name\"}]}".toByteArray())
    }
}
