package dev.overalls.mila.nativeui

import org.json.JSONObject
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID

/** A validated row from Porsche's `ssh-key list --json` response. */
data class MilaSshKey(
    val fingerprint: String,
    val label: String,
    val revoked: Boolean = false,
    val id: UUID? = null,
    val algorithm: String = "",
    val isCurrentDevice: Boolean = false,
) {
    /** Compatibility constructor for old offline store callers. */
    constructor(
        id: UUID,
        fingerprint: String,
        algorithm: String,
        label: String? = null,
        isCurrentDevice: Boolean = false,
    ) : this(fingerprint, label.orEmpty(), false, id, algorithm, isCurrentDevice)
}

interface MilaSshKeyStore {
    fun list(): List<MilaSshKey>
    /** The argument is an opaque key id for an authenticated store. */
    fun revoke(fingerprint: String): Boolean
}

/**
 * @cc [owner:ghuntley,label:security] mila-android-ssh-key-session
 * Android MUST read and revoke approved SSH keys only through the currently bound,
 * authenticated Rust session; a missing or closed session MUST produce no mutation.
 */
class MilaSshKeyController(initialStore: MilaSshKeyStore? = null) {
    private var store: MilaSshKeyStore? = initialStore
    private var generation: Long = 0
    var keys: List<MilaSshKey> = readKeys()
        private set

    /** Replaces the authority without retaining the previous session handle. */
    fun bindSession(session: MilaSessionHandle?, currentFingerprint: String? = null) {
        generation++
        store = session?.let { MilaSessionSshKeyStore(it, currentFingerprint) }
        refresh()
    }

    fun bindStore(value: MilaSshKeyStore?) {
        generation++
        store = value
        refresh()
    }

    fun refresh() {
        // A reconnect may close the previous Rust handle while a refresh is in flight.
        // Fail closed and clear the projection rather than retaining stale keys.
        keys = runCatching { readKeys() }.getOrElse { emptyList() }
    }

    fun revoke(fingerprint: String): Boolean {
        val target = keys.firstOrNull { it.fingerprint == fingerprint || it.id?.toString() == fingerprint }
            ?: return false
        return revoke(target)
    }

    fun revoke(key: MilaSshKey): Boolean {
        if (key.isCurrentDevice) return false
        val observedGeneration = generation
        val observedStore = store ?: return false
        val target = key.id?.toString() ?: key.fingerprint
        val ok = observedStore.revoke(target)
        // A session switch may complete while the revoke request is in flight.
        // Never refresh a projection from the old authority after that switch.
        if (ok && observedGeneration == generation && observedStore === store) refresh()
        return ok
    }

    private fun readKeys(): List<MilaSshKey> = runCatching {
        store?.list()?.filter { it.fingerprint.isNotBlank() }.orEmpty()
    }.getOrElse { emptyList() }
}

/** Typed store backed by one certificate-authenticated Rust session handle. */
class MilaSessionSshKeyStore(
    private val session: MilaSessionHandle,
    private val currentFingerprint: String? = null,
) : MilaSshKeyStore {
    override fun list(): List<MilaSshKey> = session.sshKeys()
        .map { decode(it, currentFingerprint) }
        .getOrElse { emptyList() }

    override fun revoke(fingerprint: String): Boolean = session
        .sshKeyRevoke(fingerprint, requestId())
        .isSuccess

    private companion object {
        fun requestId(): String = "porsche-" + UUID.randomUUID().toString().replace("-", "")

        fun decode(bytes: ByteArray, currentFingerprint: String?): List<MilaSshKey> {
            require(bytes.size <= 256 * 1024) { "SSH key listing exceeds bound" }
            // Porsche wraps reads in a `{version, status, result}` envelope; accept the bare form too.
            val root = JSONObject(bytes.toString(Charsets.UTF_8)).let { it.optJSONObject("result") ?: it }
            val values = root.optJSONArray("keys") ?: throw IllegalArgumentException("keys missing")
            require(values.length() <= 256) { "too many SSH keys" }
            return buildList(values.length()) {
                for (index in 0 until values.length()) {
                    val value = values.optJSONObject(index) ?: throw IllegalArgumentException("invalid key row")
                    val id = runCatching { UUID.fromString(value.getString("id")) }
                        .getOrElse { throw IllegalArgumentException("invalid key id", it) }
                    val fingerprint = value.getString("fingerprint")
                    val algorithm = value.getString("algorithm")
                    val label = value.optString("label", "")
                    require(fingerprint.isNotEmpty() && fingerprint.utf8Length() <= 256)
                    require(algorithm.isNotEmpty() && algorithm.utf8Length() <= 256)
                    require(label.utf8Length() <= 256)
                    require(listOf(fingerprint, algorithm, label).all { text ->
                        text.none { it.code < 0x20 || it.code == 0x7f } &&
                            text == text.trim()
                    })
                    require(fingerprint.none { it.isWhitespace() } && algorithm.none { it.isWhitespace() })
                    add(MilaSshKey(id, fingerprint, algorithm, label, fingerprint == currentFingerprint))
                }
            }
        }
    }
}

private fun String.utf8Length(): Int = toByteArray(Charsets.UTF_8).size

/** Computes the OpenSSH SHA-256 fingerprint without retaining public-key material. */
internal fun milaSshFingerprint(publicKey: String): String? = runCatching {
    val fields = publicKey.trim().split(Regex("[ \\t]+"))
    require(fields.size >= 2)
    val blob = Base64.getDecoder().decode(fields[1])
    "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(blob))
}.getOrNull()
