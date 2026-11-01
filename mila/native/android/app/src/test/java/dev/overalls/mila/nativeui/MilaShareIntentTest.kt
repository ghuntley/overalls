package dev.overalls.mila.nativeui

import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.UUID

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class MilaShareIntentTest {
    @Test fun refusesShareChooserWhenSignedOut() {
        assertEquals(null, MilaShareIntentFactory.authenticatedChooser(MilaRoute.Machines, null))
    }

    @Test fun createsCanonicalTextShareIntent() {
        val intent = MilaShareIntentFactory.create(MilaRoute.Machine(UUID.fromString("11111111-1111-1111-1111-111111111111")), "a.example")
        assertEquals(Intent.ACTION_SEND, intent.action)
        assertEquals("text/plain", intent.type)
        assertEquals("overalls://a.example/machines/11111111-1111-1111-1111-111111111111", intent.getStringExtra(Intent.EXTRA_TEXT))
    }
}
