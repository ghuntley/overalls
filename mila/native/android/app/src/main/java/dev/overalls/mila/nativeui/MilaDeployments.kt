package dev.overalls.mila.nativeui

import java.util.Locale

/** Validated deployment entry shown by the native sign-in selector. */
data class MilaDeployment(val host: String, val port: Int = 22, val label: String = host) {
    init {
        require(host.matches(HOST) || MilaInstrumentationLoopback.permits(host)) { "invalid deployment host" }
        require(port in 1..65535)
        require(label.isNotBlank() && label.toByteArray(Charsets.UTF_8).size <= 128) { "invalid deployment label" }
        require(label.none { it.isISOControl() }) { "invalid deployment label" }
    }
    companion object { private val HOST = Regex("^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$") }
}

/**
 * @cc [owner:ghuntley,label:security] android-loopback-instrumentation-only
 * Production code MUST NOT set [allowed]; only instrumentation tests that reach a fixture through
 * `adb reverse` enable it. While unset, `localhost` is refused exactly like any other single-label
 * host, so user input and persisted deployments can never select a device-local endpoint.
 *
 * Loopback deployment allowance for the hermetic emulator journey only.
 */
internal object MilaInstrumentationLoopback {
    @Volatile internal var allowed: Boolean = false
    internal fun permits(host: String): Boolean = allowed && host == "localhost"
}

/**
 * Parses the host field at the UI boundary. Host names are canonicalized before validation so
 * selecting a deployment is stable across case and surrounding whitespace. Invalid input returns
 * a failure and never reaches the trust or device-key providers.
 *
 * @cc [owner:ghuntley,label:security] android-deployment-input-validated
 * Every deployment created from user input MUST be canonicalized and pass [MilaDeployment]'s
 * bounded DNS and port validation before it is added to the selection model or persisted.
 */
internal fun parseMilaDeploymentHost(input: String): Result<MilaDeployment> {
    val value = input.trim().lowercase(Locale.ROOT)
    val separator = value.lastIndexOf(':')
    if (separator < 0) return runCatching { MilaDeployment(value) }
    val host = value.substring(0, separator)
    val port = value.substring(separator + 1).toIntOrNull()
    return runCatching {
        require(port != null) { "invalid deployment port" }
        MilaDeployment(host, port, "$host:$port")
    }
}

/** Deterministic, duplicate-free deployment selection model. */
class MilaDeploymentSelection(initial: List<MilaDeployment> = emptyList()) {
    private val entries = initial.distinctBy { it.host to it.port }.toMutableList()
    val deployments: List<MilaDeployment> get() = entries.toList()
    var selected: MilaDeployment? = entries.firstOrNull(); private set
    fun add(deployment: MilaDeployment) { if (entries.none { it.host == deployment.host && it.port == deployment.port }) entries += deployment; if (selected == null) selected = deployment }
    fun select(host: String, port: Int = 22): Boolean = entries.firstOrNull { it.host == host && it.port == port }?.let { selected = it; true } ?: false
    fun remove(host: String, port: Int = 22): Boolean {
        val removed = entries.removeIf { it.host == host && it.port == port }
        if (removed && selected?.host == host && selected?.port == port) selected = entries.firstOrNull()
        return removed
    }
}
