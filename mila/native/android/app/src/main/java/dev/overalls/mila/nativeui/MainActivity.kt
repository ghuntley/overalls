package dev.overalls.mila.nativeui

import android.os.Bundle
import android.os.SystemClock
import java.util.Locale
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.activity.ComponentActivity
import androidx.fragment.app.FragmentActivity
import androidx.activity.compose.setContent
import androidx.core.content.ContextCompat
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.material3.*
import androidx.compose.foundation.layout.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/** Authenticators accepted by the app lock: a strong biometric or the device credential. */
internal const val MILA_LOCK_AUTHENTICATORS: Int = BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL

/**
 * @cc [owner:ghuntley,label:security] android-lock-availability
 * App lock is available only when the platform reports that a strong biometric or the device
 * credential can authenticate now; every other BiometricManager status (no hardware, none enrolled,
 * security update required, unsupported) MUST project as unavailable so the lock cannot strand the
 * user behind an unusable prompt.
 */
internal fun milaLockAvailability(manager: BiometricManager): MilaLockAvailability =
    if (manager.canAuthenticate(MILA_LOCK_AUTHENTICATORS) == BiometricManager.BIOMETRIC_SUCCESS) MilaLockAvailability.Available
    else MilaLockAvailability.Unavailable

class MainActivity : FragmentActivity() {
    private val nativeAdapter: MilaFfiAdapter by lazy { LinkedMilaFfiAdapter() }
    private lateinit var lockController: MilaAppLockController
    private var lockState = mutableStateOf<MilaAppLockState?>(null)
    private var prompt: BiometricPrompt? = null
    private val deepLinks = MilaDeepLinkController()
    private val routeState = mutableStateOf<MilaRoute>(MilaRoute.Machines)
    private var deepLinkGeneration: Long = 0
    private var sessionAuthenticated = false
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        deepLinkGeneration = deepLinks.beginSession()
        deliverExternalIntent(deepLinks, intent, deepLinkGeneration, signedIn = false)
        routeState.value = deepLinks.target
        val persisted = MilaSettingsController(
            MilaSharedPreferencesStore(getSharedPreferences("mila.settings", MODE_PRIVATE)),
        ).load()
        MilaStrings.configure(this, Locale.forLanguageTag(persisted.locale))
        lockController = MilaAppLockController(MilaAppLockPreferencesStore(getSharedPreferences("mila.app-lock", MODE_PRIVATE)))
        lockController.setAvailability(milaLockAvailability(BiometricManager.from(this)))
        lockState.value = lockController.state
        prompt = BiometricPrompt(this, ContextCompat.getMainExecutor(this), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) { lockController.pendingAttempt()?.let { lockController.finishUnlock(it, true) }; lockState.value = lockController.state }
            override fun onAuthenticationFailed() { lockController.pendingAttempt()?.let { lockController.finishUnlock(it, false) }; lockState.value = lockController.state }
            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) { lockController.pendingAttempt()?.let { lockController.finishUnlock(it, false) }; lockState.value = lockController.state }
        })
        setContent {
            MilaTheme {
                val state = lockState.value ?: lockController.state
                if (state.obscured) Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(MilaStrings.text(MilaMessage.LockTitle), style = MaterialTheme.typography.headlineSmall)
                    Text(MilaStrings.text(MilaMessage.LockExplain))
                    Button(onClick = ::authenticate) { Text(MilaStrings.text(MilaMessage.LockUnlock)) }
                    if (state.lastFailed) Text(MilaStrings.text(MilaMessage.LockFailed))
                } else MilaNativeRoot(adapter = nativeAdapter, routeState = routeState, appLockController = lockController, onAuthenticatedRoute = {
                    sessionAuthenticated = true
                    if (deepLinks.acceptPending(deepLinkGeneration)) routeState.value = deepLinks.target
                }, onSessionEnded = {
                    // Only an authenticated session can end; the initial signed-out state must keep
                    // a link that launched the app pending until the first sign-in.
                    if (sessionAuthenticated) {
                        sessionAuthenticated = false
                        deepLinkGeneration = deepLinks.endSession()
                        routeState.value = deepLinks.target
                    }
                })
            }
        }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (deliverExternalIntent(deepLinks, intent, deepLinkGeneration, sessionAuthenticated) == MilaLinkDelivery.Applied) {
            routeState.value = deepLinks.target
        }
    }

    override fun onPause() { lockController.onBackground(SystemClock.elapsedRealtime()); lockState.value = lockController.state; super.onPause() }
    override fun onResume() {
        super.onResume()
        if (::lockController.isInitialized) {
            // Enrollment can change while Mila is backgrounded; re-read it before deciding to lock.
            lockController.setAvailability(milaLockAvailability(BiometricManager.from(this)))
            lockController.onForeground(SystemClock.elapsedRealtime())
            lockState.value = lockController.state
        }
    }
    private fun authenticate() {
        if (lockController.requestUnlock() == null) return
        lockState.value = lockController.state
        prompt?.authenticate(BiometricPrompt.PromptInfo.Builder().setTitle(MilaStrings.text(MilaMessage.LockTitle)).setSubtitle(MilaStrings.text(MilaMessage.LockExplain)).setAllowedAuthenticators(MILA_LOCK_AUTHENTICATORS).build())
    }
}
