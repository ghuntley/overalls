package dev.overalls.mila.nativeui

import android.content.Context
import android.content.Intent
import android.os.ParcelFileDescriptor
import androidx.biometric.BiometricManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

private const val TEST_PIN = "4729"
private const val WAIT_MS = 15_000L

/**
 * Emulator coverage for the platform authenticator states the app lock depends on.
 *
 * The emulator image has no enrolled biometric. These tests toggle the device credential through
 * `locksettings` to exercise both the unavailable and the enrolled (device credential) states of
 * the real BiometricManager and BiometricPrompt, and always restore a credential-free device.
 */
@RunWith(AndroidJUnit4::class)
class MilaAppLockDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private val device: UiDevice = UiDevice.getInstance(instrumentation)

    private fun shell(command: String): String =
        ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command)).use {
            it.readBytes().toString(Charsets.UTF_8)
        }

    private fun clearCredential() { shell("locksettings clear --old $TEST_PIN") }

    private fun persistLock(enabled: Boolean) {
        context.getSharedPreferences("mila.app-lock", Context.MODE_PRIVATE).edit()
            .putBoolean("enabled", enabled).putString("delay", MilaLockDelay.Immediate.name).commit()
    }

    private fun launch() {
        device.wakeUp()
        shell("wm dismiss-keyguard")
        context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        assertTrue(device.wait(Until.hasObject(By.pkg(context.packageName).depth(0)), WAIT_MS))
    }

    /** Waits for the platform prompt to take focus from Mila and reports what is focused otherwise. */
    private fun awaitPlatformPrompt() {
        val deadline = System.currentTimeMillis() + WAIT_MS
        while (System.currentTimeMillis() < deadline) {
            if (device.currentPackageName != null && device.currentPackageName != context.packageName) return
            Thread.sleep(250)
        }
        val focus = shell("dumpsys window").lines().filter { "mCurrentFocus" in it || "mFocusedApp" in it }.joinToString(" | ")
        throw AssertionError("BiometricPrompt did not take focus; current=${device.currentPackageName} $focus")
    }

    private fun lockScreenShown(): Boolean = device.wait(Until.hasObject(By.text(MilaStrings.text(MilaMessage.LockUnlock))), WAIT_MS) == true
    private fun shellShown(): Boolean = device.wait(Until.hasObject(By.text(MilaStrings.text(MilaMessage.SignIn))), WAIT_MS) == true

    @Before fun resetDevice() {
        clearCredential()
        persistLock(false)
    }

    @After fun restoreDevice() {
        device.pressHome()
        clearCredential()
        persistLock(false)
    }

    @Test
    fun noDeviceCredentialProjectsUnavailableAndNeverObscuresTheShell() {
        val manager = BiometricManager.from(context)
        assertNotEquals(BiometricManager.BIOMETRIC_SUCCESS, manager.canAuthenticate(MILA_LOCK_AUTHENTICATORS))
        assertEquals(MilaLockAvailability.Unavailable, milaLockAvailability(manager))
        // A previously enabled lock must not strand the user when no authenticator exists.
        persistLock(true)
        launch()
        assertTrue("shell must remain reachable", shellShown())
        assertTrue(device.findObject(By.text(MilaStrings.text(MilaMessage.LockUnlock))) == null)
    }

    @Test
    fun enrolledDeviceCredentialLocksAndBiometricPromptUnlocksOnlyWithCredential() {
        assertTrue(shell("locksettings set-pin $TEST_PIN").contains("set", ignoreCase = true))
        val manager = BiometricManager.from(context)
        assertEquals(BiometricManager.BIOMETRIC_SUCCESS, manager.canAuthenticate(MILA_LOCK_AUTHENTICATORS))
        assertEquals(MilaLockAvailability.Available, milaLockAvailability(manager))

        persistLock(true)
        launch()
        assertTrue("enabled lock must obscure the shell", lockScreenShown())

        // Cancelling the platform prompt is a failed attempt and keeps the shell obscured.
        device.findObject(By.text(MilaStrings.text(MilaMessage.LockUnlock))).click()
        awaitPlatformPrompt()
        device.pressBack()
        assertNotNull(device.wait(Until.findObject(By.text(MilaStrings.text(MilaMessage.LockFailed))), WAIT_MS))
        assertTrue(device.findObject(By.text(MilaStrings.text(MilaMessage.SignIn))) == null)

        // The device credential completes the prompt and reveals the shell.
        device.findObject(By.text(MilaStrings.text(MilaMessage.LockUnlock))).click()
        awaitPlatformPrompt()
        Thread.sleep(1_000)
        shell("input text $TEST_PIN")
        shell("input keyevent KEYCODE_ENTER")
        assertTrue("credential must unlock the shell", shellShown())
    }
}
