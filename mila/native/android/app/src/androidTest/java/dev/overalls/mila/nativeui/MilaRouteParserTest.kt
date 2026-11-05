package dev.overalls.mila.nativeui

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MilaRouteParserTest {
    @Test
    fun acceptsNavigationRoutesAndRejectsAmbiguousInput() {
        val id = "123e4567-e89b-12d3-a456-426614174000"

        assertEquals(MilaRoute.Machines, parseMilaRoute("overalls://overalls.example/machines"))
        assertEquals(MilaRoute.Machine(UUID.fromString(id)), parseMilaRoute("overalls://overalls.example/machines/$id"))
        assertNull(parseMilaRoute("overalls://overalls.example/machines/$id?debug=true"))
        assertNull(parseMilaRoute("overalls://overalls.example/machines/%2F$id"))
        assertNull(parseMilaRoute("overalls://overalls.example:443/machines/$id"))
        assertNull(parseMilaRoute("overalls://Overalls.example/machines/$id"))
        assertNull(parseMilaRoute("overalls://overalls.example/machines/123E4567-E89B-12D3-A456-426614174000"))
        assertNull(parseMilaRoute("overalls://overalls.example/machines/$id\u0001"))
    }

    @Test
    fun invokesRustJniRouteCanonicalization() {
        assertEquals("overalls://overalls.example/machines", MilaRustFfi.canonicalRoute("overalls://overalls.example/machines"))
        assertNull(MilaRustFfi.canonicalRoute("overalls://overalls.example/machines?command=bad"))
        assertEquals(1, MilaRustFfi.abiVersion())
    }
}
