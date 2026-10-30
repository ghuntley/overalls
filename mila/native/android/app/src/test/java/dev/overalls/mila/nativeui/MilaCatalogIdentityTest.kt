package dev.overalls.mila.nativeui

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Native message identities used by the session-bound forms, sharing roles and link completion
 * must be existing shared catalog identities, so every locale bundle can translate them.
 */
class MilaCatalogIdentityTest {
    private val english: JSONObject = JSONObject(File("../../../localization/catalogs/app_en.arb").readText())

    private val catalogBacked = listOf(
        MilaMessage.MachineCpu, MilaMessage.MachineMemory, MilaMessage.MachineDisk, MilaMessage.MachineCreate,
        MilaMessage.MachineCreated, MilaMessage.FieldInvalid, MilaMessage.RequestWaiting, MilaMessage.RequestSucceeded,
        MilaMessage.RequestFailed, MilaMessage.RequestRefused, MilaMessage.ShareRole, MilaMessage.ShareRoleViewer,
        MilaMessage.ShareRoleOperator, MilaMessage.ShareRoleManager, MilaMessage.MachineNotFound, MilaMessage.ShareRoute,
        MilaMessage.LinkRefused, MilaMessage.LockUnavailable,
    )

    @Test fun sessionBoundMessagesExistInSharedCatalogWithMatchingFallback() {
        for (message in catalogBacked) {
            assertTrue("missing catalog id ${message.catalogId}", english.has(message.catalogId))
            assertEquals(english.getString(message.catalogId), MilaStrings.text(message))
        }
    }

    @Test fun everyLocaleCatalogTranslatesSessionBoundMessages() {
        val catalogs = File("../../../localization/catalogs").listFiles { file -> file.name.endsWith(".arb") }!!
        assertTrue(catalogs.size >= 28)
        for (catalog in catalogs) {
            val values = JSONObject(catalog.readText())
            for (message in catalogBacked) {
                assertTrue("${catalog.name} lacks ${message.catalogId}", values.optString(message.catalogId).isNotBlank())
            }
        }
    }
}
