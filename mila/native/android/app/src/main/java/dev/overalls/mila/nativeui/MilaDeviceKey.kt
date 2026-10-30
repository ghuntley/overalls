package dev.overalls.mila.nativeui

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import java.security.AlgorithmParameters
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec

/**
 * @cc [owner:ghuntley,label:security] native-android-deployment-key
 * Each validated deployment host MUST use a distinct nonexportable Android Keystore P-256
 * key. Only StrongBoxUnavailableException permits retry without StrongBox; other failures
 * MUST propagate. Signing MUST NOT create a replacement key after deletion.
 */
class MilaDeviceKey private constructor(private val alias: String) {
    companion object {
        private const val KEYSTORE = "AndroidKeyStore"
        private val hostPattern = Regex("^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$")
        private val creationLock = Any()

        /** Opens or creates the deployment identity; callers run this off the UI thread. */
        fun open(host: String): MilaDeviceKey {
            require(hostPattern.matches(host) || MilaInstrumentationLoopback.permits(host)) { "invalid deployment host" }
            val alias = "dev.overalls.mila.device.$host"
            synchronized(creationLock) {
                if (!keyStore().containsAlias(alias)) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        try {
                            generate(alias, true)
                        } catch (_: StrongBoxUnavailableException) {
                            generate(alias, false)
                        }
                    } else {
                        generate(alias, false)
                    }
                }
            }
            return MilaDeviceKey(alias).also { it.publicKey() }
        }

        private fun keyStore(): KeyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }

        private fun generate(alias: String, strongBox: Boolean) {
            val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) spec.setIsStrongBoxBacked(strongBox)
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE).apply {
                initialize(spec.build())
                generateKeyPair()
            }
        }
    }

    /** OpenSSH ecdsa-sha2-nistp256 public key, without a comment. */
    fun publicKey(): String {
        val publicKey = keyStore().getCertificate(alias)?.publicKey as? ECPublicKey
            ?: error("device key unavailable")
        val expected = AlgorithmParameters.getInstance("EC").apply {
            init(ECGenParameterSpec("secp256r1"))
        }.getParameterSpec(ECParameterSpec::class.java)
        require(publicKey.params.order == expected.order && publicKey.params.curve == expected.curve &&
            publicKey.params.generator == expected.generator && publicKey.params.cofactor == expected.cofactor) {
            "invalid device key curve"
        }
        return MilaP256Encoding.openSsh(publicKey)
    }

    /** Fixed-width r || s signature over SHA-256(message), as required by Rust's signer. */
    fun sign(message: ByteArray): ByteArray {
        require(message.size in 1..65536) { "invalid signing message size" }
        val key = keyStore().getKey(alias, null) as? PrivateKey
            ?: error("device key unavailable")
        check(key.encoded == null) { "exportable device key refused" }
        val der = Signature.getInstance("SHA256withECDSA").run {
            initSign(key)
            update(message)
            sign()
        }
        return MilaP256Encoding.fixedSignature(der)
    }
}
