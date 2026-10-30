package dev.overalls.mila.nativeui

import android.os.Bundle
import android.util.Base64
import java.io.ByteArrayInputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManagerFactory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** Instrumentation argument carrying the base64 (standard, unwrapped) descriptor JSON. */
const val MILA_JOURNEY_ARGUMENT: String = "milaJourneyDescriptor"

/**
 * Validated `mila-journey-fixture` descriptor, version 1.
 *
 * The fixture owns the backend; the emulator reaches its unprivileged ports through
 * `adb reverse`, so [host] is dialled exactly as written and matches the trust document's
 * management host, the Porsche host-certificate principal and the HTTPS certificate SAN.
 */
data class MilaJourneyDescriptor(
    val host: String,
    val sshPort: Int,
    val httpsPort: Int,
    val caPem: String,
    val serverName: String,
    val approverUrl: URI,
    val approverToken: String,
    /** Base of the Bearer-protected `POST <fixtureUrl><action>` hooks; always ends with `/`. */
    val fixtureUrl: URI,
    val seedMachineName: String?,
    val seedMachineId: java.util.UUID?,
    val sharePrincipal: String?,
    val accountEmail: String?,
) {
    init {
        require(host.isNotEmpty() && host.length <= 253 && host.all { it.isLetterOrDigit() || it == '.' || it == '-' }) { "invalid host" }
        require(sshPort in 1024..65535 && httpsPort in 1024..65535) { "fixture ports must be unprivileged" }
        require(caPem.contains("BEGIN CERTIFICATE") && caPem.length <= 64 * 1024) { "invalid CA PEM" }
        require(serverName.isNotEmpty() && serverName.length <= 253) { "invalid TLS server name" }
        require(approverUrl.scheme == "https" && approverUrl.userInfo == null && approverUrl.host != null) { "approver hook must be HTTPS" }
        require(fixtureUrl.scheme == "https" && fixtureUrl.userInfo == null && fixtureUrl.host == approverUrl.host && fixtureUrl.port == approverUrl.port) {
            "fixture hook must share the approver origin"
        }
        require(approverToken.isNotBlank() && approverToken.length <= 4096 && approverToken.none { it.isISOControl() }) { "invalid approver token" }
    }

    /** Machine creation names must satisfy the Rust create bounds, so the seed name is optional data only. */
    val deployment: MilaDeployment get() = MilaDeployment(host, sshPort, "$host:$sshPort")

    /** TLS socket factory that trusts only the fixture CA. */
    val socketFactory: SSLSocketFactory by lazy {
        val certificates = CertificateFactory.getInstance("X.509")
            .generateCertificates(ByteArrayInputStream(caPem.toByteArray(Charsets.US_ASCII)))
        require(certificates.isNotEmpty()) { "CA PEM contained no certificate" }
        val store = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null)
            certificates.forEachIndexed { index, certificate -> setCertificateEntry("fixture-$index", certificate as X509Certificate) }
        }
        val trust = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(store) }
        SSLContext.getInstance("TLS").apply { init(null, trust.trustManagers, null) }.socketFactory
    }

    /** Opens an HTTPS connection that verifies the fixture certificate against [serverName]. */
    fun open(url: URL): HttpsURLConnection = (url.openConnection() as HttpsURLConnection).apply {
        sslSocketFactory = socketFactory
        val defaultVerifier = HttpsURLConnection.getDefaultHostnameVerifier()
        hostnameVerifier = javax.net.ssl.HostnameVerifier { _, session -> defaultVerifier.verify(serverName, session) }
        instanceFollowRedirects = false
        connectTimeout = 15_000
        readTimeout = 30_000
    }

    companion object {
        /** Returns null when the journey was not requested; malformed descriptors fail loudly. */
        fun fromArguments(arguments: Bundle): MilaJourneyDescriptor? {
            val encoded = arguments.getString(MILA_JOURNEY_ARGUMENT)?.takeIf { it.isNotBlank() } ?: return null
            require(encoded.length <= 256 * 1024) { "descriptor argument too large" }
            return parse(Base64.decode(encoded, Base64.DEFAULT).toString(Charsets.UTF_8))
        }

        fun parse(json: String): MilaJourneyDescriptor {
            val root = JSONObject(json)
            require(root.getInt("version") == 1) { "unsupported descriptor version" }
            val deployment = root.getJSONObject("deployment")
            val tls = root.getJSONObject("tls")
            val approver = root.getJSONObject("approver")
            val seed = root.optJSONObject("seed")
            val host = deployment.getString("host")
            return MilaJourneyDescriptor(
                host = host,
                sshPort = deployment.getInt("ssh_port"),
                httpsPort = deployment.getInt("https_port"),
                caPem = tls.getString("ca_pem"),
                serverName = tls.optString("server_name").ifBlank { host },
                approverUrl = URI(approver.getString("url")),
                approverToken = approver.getString("bearer_token"),
                fixtureUrl = URI(
                    approver.optString("fixture_url").ifBlank { URI(approver.getString("url")).resolve("/fixture/").toString() }
                        .let { if (it.endsWith("/")) it else "$it/" },
                ),
                seedMachineName = seed?.optString("machine_name")?.takeIf { it.isNotBlank() },
                seedMachineId = seed?.optString("machine_id")?.takeIf { it.isNotBlank() }?.let(java.util.UUID::fromString),
                sharePrincipal = seed?.optString("share_principal")?.takeIf { it.isNotBlank() },
                accountEmail = seed?.optString("account_email")?.takeIf { it.isNotBlank() },
            )
        }
    }
}

/** Fetches `/bin/ssh-trust.json` from the fixture's HTTPS port with fixture-CA verification. */
class MilaJourneyTrustFetcher(private val descriptor: MilaJourneyDescriptor) : MilaTrustFetcher {
    override suspend fun fetch(host: String): ByteArray = withContext(Dispatchers.IO) {
        require(host == descriptor.host) { "trust fetch for an unexpected host" }
        val connection = descriptor.open(URL("https://${descriptor.host}:${descriptor.httpsPort}/bin/ssh-trust.json"))
        try {
            require(connection.responseCode in 200..299) { "trust fetch refused" }
            val bytes = connection.inputStream.use { it.readBytes() }
            require(bytes.size in 1..8192) { "invalid trust document size" }
            bytes
        } finally {
            connection.disconnect()
        }
    }
}

/** Asks the fixture's approver hook to approve one pending device key as the owner user. */
suspend fun MilaJourneyDescriptor.approve(approval: MilaApprovalInfo): Unit = withContext(Dispatchers.IO) {
    val connection = open(approverUrl.toURL()).apply {
        requestMethod = "POST"
        doOutput = true
        setRequestProperty("Content-Type", "application/json")
        setRequestProperty("Authorization", "Bearer $approverToken")
    }
    try {
        val body = JSONObject().put("approval_url", approval.url).put("fingerprint", approval.fingerprint).toString()
        connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
        check(connection.responseCode in 200..299) { "approver hook refused (${connection.responseCode})" }
    } finally {
        (connection as HttpURLConnection).disconnect()
    }
}

/** Fixture hook actions agreed with `mila-journey-fixture` (ADR-0264). */
enum class MilaFixtureAction(val wire: String) {
    Observe("observe"), ThreadCreate("thread-create"), ThreadReady("thread-ready"),
    ThreadQuestion("thread-question"), ThreadProposal("thread-proposal"),
}

/** POSTs one fixture hook; any non-2xx answer (including 404) fails the journey. */
suspend fun MilaJourneyDescriptor.fixture(action: MilaFixtureAction, body: JSONObject = JSONObject()): JSONObject = withContext(Dispatchers.IO) {
    val connection = open(fixtureUrl.resolve(action.wire).toURL()).apply {
        requestMethod = "POST"
        doOutput = true
        setRequestProperty("Content-Type", "application/json")
        setRequestProperty("Authorization", "Bearer $approverToken")
    }
    try {
        connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
        when (val code = connection.responseCode) {
            in 200..299 -> {
                val bytes = connection.inputStream.use { it.readBytes() }
                require(bytes.size <= 64 * 1024) { "fixture hook reply too large" }
                JSONObject(bytes.toString(Charsets.UTF_8))
            }
            else -> error("fixture ${action.wire} hook refused ($code)")
        }
    } finally {
        (connection as HttpURLConnection).disconnect()
    }
}

/**
 * Asks the fixture to stand in for the absent provisioner for one machine (`observe`), so the next
 * lifecycle intent is admissible. Returns the settled observed state (the machine's desired state).
 */
suspend fun MilaJourneyDescriptor.observe(machine: java.util.UUID): String {
    val reply = fixture(MilaFixtureAction.Observe, JSONObject().put("machine_id", machine.toString()))
    return reply.optString("observed_state").also { check(it.isNotBlank()) { "observe hook returned no observed_state" } }
}

/** Reads one UUID field from a fixture hook reply. */
fun JSONObject.fixtureId(key: String): java.util.UUID = java.util.UUID.fromString(getString(key))
