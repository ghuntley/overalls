package dev.overalls.mila.nativeui

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** Provider-issued registration identifier. The value is opaque and never persisted as a token. */
@JvmInline
value class MilaNotificationProviderId private constructor(val value: String) {
    companion object {
        fun parse(value: String): MilaNotificationProviderId? =
            value.takeIf { it.length in 1..512 && it.all { character -> character.code in 0x21..0x7e } }
                ?.let(::MilaNotificationProviderId)
    }
}

/** Boundary implemented by FCM (or another provider) without making the UI depend on it. */
interface MilaNotificationProvider {
    fun registrationId(): MilaNotificationProviderId?
}

fun milaValidNotificationChannelId(value: String): Boolean =
    value.length in 1..100 && value.all { it.isLetterOrDigit() || it in "._-" }

interface MilaNotificationOs {
    fun notificationsEnabled(): Boolean
    fun ensureChannel(channelId: String, name: String)
    fun removeChannel(channelId: String)
}

/** Android NotificationManager adapter. Provider tokens remain owned by the provider. */
class MilaAndroidNotificationOs(context: Context) : MilaNotificationOs {
    private val manager = context.getSystemService(NotificationManager::class.java)
    override fun notificationsEnabled(): Boolean = Build.VERSION.SDK_INT < 24 || manager.areNotificationsEnabled()
    override fun ensureChannel(channelId: String, name: String) {
        if (!milaValidNotificationChannelId(channelId) || name.isBlank() || name.length > 128) return
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
            NotificationChannel(channelId, name, NotificationManager.IMPORTANCE_DEFAULT),
        )
    }
    override fun removeChannel(channelId: String) {
        if (!milaValidNotificationChannelId(channelId)) return
        if (Build.VERSION.SDK_INT >= 26) manager.deleteNotificationChannel(channelId)
    }
}

data class MilaNotificationDevice(val id: String, val enabled: Boolean)

/**
 * @cc [owner:ghuntley,label:security;protocol] android-server-notification-devices
 * Account device rows MUST come from the current authenticated Porsche session. Preference and
 * removal actions MUST target a listed canonical UUID, and a result from an ended generation
 * MUST NOT replace the current projection. Provider tokens are never part of this projection.
 */
class MilaServerNotificationController(private val adapter: MilaFfiAdapter) {
    var devices: List<MilaNotificationDevice> = emptyList()
        private set
    private var generation: Long = 0
    private var active = false

    fun setSession(signedIn: Boolean) {
        generation += 1
        active = signedIn
        devices = emptyList()
    }

    suspend fun refresh(): Boolean {
        if (!active) return false
        val bound = generation
        val rows = withContext(Dispatchers.IO) {
            adapter.notificationDevices().mapCatching(::decode)
        }.getOrNull() ?: return false
        if (!active || generation != bound) return false
        devices = rows
        return true
    }

    suspend fun setEnabled(id: String, enabled: Boolean): Boolean = mutate(id) { adapter.notificationDevicePreferences(id, enabled) }
    suspend fun remove(id: String): Boolean = mutate(id) { adapter.notificationDeviceRemove(id) }

    private suspend fun mutate(id: String, action: () -> Result<Unit>): Boolean {
        if (!active || devices.none { it.id == id }) return false
        val bound = generation
        if (withContext(Dispatchers.IO) { action() }.isFailure || !active || generation != bound) return false
        return refresh()
    }

    companion object {
        internal fun decode(bytes: ByteArray): List<MilaNotificationDevice> {
            require(bytes.size in 1..(256 * 1024))
            val envelope = JSONObject(bytes.toString(Charsets.UTF_8))
            require(envelope.getInt("version") == 1 && envelope.getString("status") == "succeeded")
            val rows = envelope.getJSONObject("result").getJSONArray("items")
            require(rows.length() <= 128)
            val ids = mutableSetOf<String>()
            return (0 until rows.length()).map { index ->
                val row = rows.getJSONObject(index)
                val id = row.getString("id")
                require(UUID.fromString(id).toString() == id && ids.add(id))
                MilaNotificationDevice(id, row.getBoolean("enabled"))
            }
        }
    }
}
interface MilaNotificationStore { fun list(): List<MilaNotificationDevice>; fun setEnabled(id: String, enabled: Boolean): Boolean; fun remove(id: String): Boolean }
fun interface MilaNotificationRegistrationValidator { fun validate(id: MilaNotificationProviderId): Boolean }
interface MilaNotificationRegistrationStore : MilaNotificationStore {
    fun register(id: String, enabled: Boolean = true): Boolean
}

/** Durable device registration projection. Tokens are owned by the OS push provider and are
 * deliberately never persisted here; only the provider registration id and user toggle remain. */
class MilaPreferencesNotificationStore(private val preferences: SharedPreferences) : MilaNotificationRegistrationStore {
    private val key = "registered_devices"
    private val maxDevices = 128
    override fun list(): List<MilaNotificationDevice> = preferences.getStringSet(key, emptySet()).orEmpty()
        .mapNotNull { encoded ->
            val parts = encoded.split("|", limit = 2)
            if (parts.size == 2 && validId(parts[0])) MilaNotificationDevice(parts[0], parts[1] == "1") else null
        }.sortedBy { it.id }

    override fun setEnabled(id: String, enabled: Boolean): Boolean {
        if (!validId(id) || !list().any { it.id == id }) return false
        val next = list().map { if (it.id == id) it.copy(enabled = enabled) else it }
        persist(next); return true
    }

    override fun register(id: String, enabled: Boolean): Boolean {
        if (!validId(id)) return false
        val existing = list().filterNot { it.id == id }
        if (existing.size >= maxDevices) return false
        val next = existing + MilaNotificationDevice(id, enabled)
        persist(next); return true
    }

    override fun remove(id: String): Boolean {
        val next = list().filterNot { it.id == id }
        if (next.size == list().size) return false
        persist(next); return true
    }

    private fun persist(value: List<MilaNotificationDevice>) {
        preferences.edit().putStringSet(key, value.map { "${it.id}|${if (it.enabled) 1 else 0}" }.toSet()).apply()
    }

    private fun validId(id: String): Boolean = id.length in 1..256 && id.all { it.isLetterOrDigit() || it in ".:_-" }
}
class MilaNotificationController(
    private val store: MilaNotificationStore,
    private val validator: MilaNotificationRegistrationValidator? = null,
) {
 var devices: List<MilaNotificationDevice> = store.list().filter { it.id.isNotBlank() }; private set
 fun refresh() { devices = store.list().filter { it.id.isNotBlank() } }
 fun setEnabled(id: String, enabled: Boolean): Boolean = store.setEnabled(id, enabled).also { if (it) refresh() }
 fun remove(id: String): Boolean = store.remove(id).also { if (it) refresh() }

 /** Registers the provider-issued identifier after the OS has granted notifications. */
 fun register(provider: MilaNotificationProvider, os: MilaNotificationOs): Boolean {
  if (!os.notificationsEnabled()) return false
  val id = provider.registrationId() ?: return false
  if (validator != null && !validator.validate(id)) return false
  val register = store as? MilaNotificationRegistrationStore ?: return false
  return register.register(id.value).also { if (it) refresh() }
 }
}

/** Registration lifecycle that requires Rust's typed push metadata validator before the
 * provider identifier is persisted. The token itself remains owned by FCM/Android. */
class MilaAuthenticatedNotificationController(
    private val adapter: MilaFfiAdapter,
    store: MilaNotificationStore,
    private val appId: String,
    private val deployment: String,
) {
    private val delegate = MilaNotificationController(store)
    private var sessionActive = true
    val devices: List<MilaNotificationDevice> get() = if (sessionActive) delegate.devices else emptyList()

    /** Ends the authenticated device session and hides the local projection. */
    fun signOut() { sessionActive = false }

    /** Re-enables the projection after the host establishes an authenticated session. */
    fun signIn() { sessionActive = true; delegate.refresh() }

    /** Refreshes the projection after a provider callback or account change. */
    fun refresh() = delegate.refresh()

    fun register(provider: MilaNotificationProvider, os: MilaNotificationOs): Boolean {
        if (!sessionActive) return false
        if (!os.notificationsEnabled()) return false
        val id = provider.registrationId() ?: return false
        if (adapter.validatePushRegistration(id.value, appId, deployment, null).isFailure) return false
        val registered = delegate.register(object : MilaNotificationProvider { override fun registrationId() = id }, os)
        if (registered) sessionActive = true
        return registered
    }

    fun remove(id: String): Boolean = sessionActive && delegate.remove(id)
    fun setEnabled(id: String, enabled: Boolean): Boolean = sessionActive && delegate.setEnabled(id, enabled)
}

/**
 * Small FCM-facing boundary. Firebase callbacks supply an opaque registration id;
 * this class deliberately does not retain the token and requires the authenticated
 * controller to validate it through Rust before it enters the local projection.
 */
class MilaFcmRegistration(private val controller: MilaAuthenticatedNotificationController) {
    fun onToken(token: String?, os: MilaNotificationOs): Boolean {
        val provider = token?.let(MilaNotificationProviderId::parse) ?: return false
        return controller.register(object : MilaNotificationProvider {
            override fun registrationId(): MilaNotificationProviderId = provider
        }, os)
    }

    /** Removes a provider registration after FCM reports token invalidation. */
    fun onTokenInvalidated(token: String?): Boolean {
        val provider = token?.let(MilaNotificationProviderId::parse) ?: return false
        return controller.remove(provider.value)
    }
}
