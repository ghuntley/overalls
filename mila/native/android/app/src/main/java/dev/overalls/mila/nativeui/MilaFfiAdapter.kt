package dev.overalls.mila.nativeui

import java.util.UUID
import java.net.URI
import java.util.Locale

sealed interface MilaRoute {
    data object Machines : MilaRoute
    data class Machine(val id: UUID) : MilaRoute
    data object Threads : MilaRoute
    data class Thread(val id: UUID) : MilaRoute
    data object Settings : MilaRoute
}

/**
 * Parses only navigation routes; query strings and command-like paths are rejected.
 *
 * @cc [owner:ghuntley,label:security;navigation] mila-android-route-boundary
 * A route entering Android intent handling MUST match the bounded canonical
 * `overalls://<lowercase DNS host>/<navigation path>` form: no controls,
 * query/fragment, userinfo, port, percent encoding, or non-canonical UUIDs may
 * cross into navigation.
 */
fun parseMilaRoute(value: String): MilaRoute? {
    if (value.length > 2_048 || value.toByteArray(Charsets.UTF_8).size > 2_048 ||
        value.any { it.isISOControl() || it == ' ' }) return null
    val uri = runCatching { URI(value) }.getOrNull() ?: return null
    if (uri.scheme != "overalls" || uri.rawQuery != null || uri.rawFragment != null ||
        uri.port != -1 || uri.rawAuthority?.contains('@') == true) return null
    val host = uri.host ?: return null
    if (uri.rawAuthority != host || !validRouteHost(host)) return null
    val path = uri.rawPath ?: return null
    if (path.isEmpty() || path == "/" || path.endsWith('/') || path.contains("//")) return null
    val parts = path.trim('/').takeIf { it.isNotEmpty() }?.split('/') ?: emptyList()
    if (parts.any { it.contains('%') }) return null
    val page = parts.firstOrNull() ?: return null
    val tail = parts.drop(1)
    return when {
        page == "machines" && tail.isEmpty() -> MilaRoute.Machines
        page == "threads" && tail.isEmpty() -> MilaRoute.Threads
        page == "settings" && tail.isEmpty() -> MilaRoute.Settings
        page == "machines" && tail.size == 1 -> tail[0].toUuid()?.let(MilaRoute::Machine)
        page == "threads" && tail.size == 1 -> tail[0].toUuid()?.let(MilaRoute::Thread)
        else -> null
    }
}

private fun validRouteHost(host: String): Boolean {
    if (host.isEmpty() || host.length > 253 || host != host.lowercase(Locale.ROOT)) return false
    return host.split('.').all { label ->
        label.isNotEmpty() && label.length <= 63 &&
            label.first() != '-' && label.last() != '-' &&
            label.all { it in 'a'..'z' || it in '0'..'9' || it == '-' }
    }
}

private fun String.toUuid(): UUID? = runCatching {
    UUID.fromString(this).takeIf { it.toString() == this }
}.getOrNull()

/** The operation names exported by the generated Rust FFI binding. */
@JvmInline
value class MilaFfiOperation private constructor(val value: String) {
    companion object {
        val Bootstrap: MilaFfiOperation = MilaFfiOperation("bootstrap")
        val Refresh: MilaFfiOperation = MilaFfiOperation("refresh")
        val MachineAction: MilaFfiOperation = MilaFfiOperation("machine_action")
        val ThreadAction: MilaFfiOperation = MilaFfiOperation("thread_action")
        val MachineCreate: MilaFfiOperation = MilaFfiOperation("machine_create")
    }
}

/** Immutable byte ownership at the native/Rust boundary. */
class MilaFfiPayload(bytes: ByteArray) {
    private val value: ByteArray = bytes.copyOf()

    fun copyBytes(): ByteArray = value.copyOf()
}

data class MilaFfiRequest(
    val operation: MilaFfiOperation,
    val payload: MilaFfiPayload = MilaFfiPayload(byteArrayOf()),
)

data class MilaFfiResponse(val payload: MilaFfiPayload)

sealed interface MilaFfiError {
    data object Unavailable : MilaFfiError
    data object IncompatibleAbi : MilaFfiError
    data object InvalidRoute : MilaFfiError
}

sealed interface MilaFfiResult {
    data class Success(val response: MilaFfiResponse) : MilaFfiResult
    data class Failure(val error: MilaFfiError) : MilaFfiResult
}

/**
 * @cc [owner:ghuntley,label:security] mila-android-ffi-typed-boundary
 * The Android UI MUST exchange only typed `MilaFfiRequest` and `MilaFfiResponse` values with Rust;
 * raw pointers, credentials, and terminal bytes MUST NOT appear in this interface.
 */
enum class MilaWatchHint(val tag: Int) {
    Unknown(0), Watching(1), Heartbeat(2), Machine(3), TerminalSession(4), Thread(5), Resync(6), Session(7);
    companion object { fun fromTag(tag: Int): MilaWatchHint? = entries.firstOrNull { it.tag == tag } }
}
sealed interface MilaWatchRead {
    data class Hint(val kind: MilaWatchHint) : MilaWatchRead
    data object Idle : MilaWatchRead
    data object Closed : MilaWatchRead
    data object AuthorityLost : MilaWatchRead
    data object TransportLost : MilaWatchRead
}

interface MilaFfiAdapter {
    fun watchOpen(machineIds: List<UUID>, threadIds: List<UUID>): Result<Long> = Result.failure(IllegalStateException("watch unavailable"))
    fun watchRead(handle: Long, waitMilliseconds: Int): Result<MilaWatchRead> = Result.failure(IllegalStateException("watch unavailable"))
    fun watchReconnect(handle: Long): Result<Long> = Result.failure(IllegalStateException("watch unavailable"))
    fun watchClose(handle: Long): Result<Unit> = Result.success(Unit)

    /** Only Rust exports complete validated snapshots; a partial listing refuses. */
    fun snapshotData(): Result<ByteArray> = Result.failure(IllegalStateException("snapshot unavailable"))
    fun notificationDevices(): Result<ByteArray> = Result.failure(IllegalStateException("session unavailable"))
    fun notificationDeviceRemove(device: String): Result<Unit> = Result.failure(IllegalStateException("session unavailable"))
    fun notificationDevicePreferences(device: String, enabled: Boolean): Result<Unit> = Result.failure(IllegalStateException("session unavailable"))
    suspend fun call(request: MilaFfiRequest): MilaFfiResult
    /** Rust validates provider metadata while borrowing the token for this call only. */
    fun validatePushRegistration(token: String, appId: String, deployment: String, endpoint: String?): Result<Unit> =
        Result.failure(IllegalStateException("push registration unavailable"))
    /** The currently authenticated session's key store, or null while signed out. */
    fun sshKeyStore(): MilaSshKeyStore? = null
    /** Executes a Rust-classified action for an authenticated machine session. */
    suspend fun machineResize(machineId: UUID, cpu: Int, memoryMiB: Int, diskGiB: Int): Result<Unit> = Result.failure(IllegalStateException("machine resize unavailable"))
    /** Creates a machine through the authenticated session; unauthenticated adapters refuse. */
    suspend fun machineClone(machineId: UUID, name: String, requestId: String): Result<Unit> = Result.failure(IllegalStateException("clone unavailable"))
    suspend fun machineCreate(request: MilaMachineCreateRequest): Result<Unit> = Result.failure(IllegalStateException("machine create unavailable"))
    /** Adds ([role] non-null) or removes ([role] null) one principal through the authenticated session. */
    suspend fun machineShare(machineId: UUID, principal: MilaSharePrincipal, role: MilaShareRole?): Result<Unit> = Result.failure(IllegalStateException("machine sharing unavailable"))
    suspend fun machineAction(machineId: UUID, command: MilaMachineCommand): Result<Unit> =
        when (call(MilaFfiRequest(MilaFfiOperation.MachineAction, MilaFfiPayload(
            "{\"machine_id\":\"$machineId\",\"command\":${command.tag}}".toByteArray(Charsets.UTF_8)
        )))) {
            is MilaFfiResult.Success -> Result.success(Unit)
            is MilaFfiResult.Failure -> Result.failure(IllegalStateException("machine action unavailable"))
        }
    suspend fun webShow(machineId: UUID): Result<String> = Result.failure(IllegalStateException("web endpoint unavailable"))
    suspend fun webSet(machineId: UUID, port: Int, public: Boolean, revision: Long): Result<Unit> = Result.failure(IllegalStateException("web endpoint unavailable"))

    suspend fun threadAction(threadId: UUID, command: MilaThreadCommand): Result<Unit> =
        when (call(MilaFfiRequest(MilaFfiOperation.ThreadAction, MilaFfiPayload(
            "{\"thread_id\":\"$threadId\",\"command\":${command.tag}}".toByteArray(Charsets.UTF_8)
        )))) {
            is MilaFfiResult.Success -> Result.success(Unit)
            is MilaFfiResult.Failure -> Result.failure(IllegalStateException("thread action unavailable"))
        }

    suspend fun threadAction(threadId: UUID, command: MilaThreadCommand, input: String?, secondary: UUID?): Result<Unit> = threadAction(threadId, command, input)

    /** Authenticated thread mutation with an optional bounded prompt/answer payload. */
    suspend fun threadAction(threadId: UUID, command: MilaThreadCommand, input: String?): Result<Unit> {
        if (input == null) return threadAction(threadId, command)
        val payload = buildString {
            append("{\"thread_id\":\"$threadId\",\"command\":${command.tag}")
            if (input != null) append(",\"input\":\"").append(input.jsonEscaped()).append('\"')
            append('}')
        }
        return when (call(MilaFfiRequest(MilaFfiOperation.ThreadAction, MilaFfiPayload(payload.toByteArray(Charsets.UTF_8))))) {
            is MilaFfiResult.Success -> Result.success(Unit)
            is MilaFfiResult.Failure -> Result.failure(IllegalStateException("thread action unavailable"))
        }
    }
    suspend fun threadListing(): Result<MilaThreadListing> = Result.failure(IllegalStateException("thread listing unavailable"))
    /** Authenticated `thread show`; adapters without a session payload report no pending controls. */
    suspend fun threadShow(threadId: UUID): Result<ByteArray> =
        threadAction(threadId, MilaThreadCommand.Show).map { "{}".toByteArray(Charsets.UTF_8) }
    /** Re-reads the first machine page on the authenticated session that produced the current listing. */
    suspend fun refreshListing(): Result<MilaSessionListing> = Result.failure(IllegalStateException("session listing unavailable"))

    private fun String.jsonEscaped(): String = buildString(length) {
        for (character in this@jsonEscaped) when (character) {
            '\\' -> append("\\\\")
            '\"' -> append("\\\"")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> if (character.code < 0x20) append("\\u%04x".format(character.code)) else append(character)
        }
    }

    fun threadCommandKind(value: String): Result<MilaThreadCommand> = Result.failure(IllegalStateException("native runtime unavailable"))
    fun machineCommandKind(value: String): Result<MilaMachineCommand> = Result.failure(IllegalStateException("native runtime unavailable"))
    fun terminalAttach(from: Long, columns: Int, rows: Int, readWrite: Boolean): Result<Unit> = Result.failure(IllegalStateException("native runtime unavailable"))
    fun terminalInput(length: Int, readWrite: Boolean): Result<Unit> = Result.failure(IllegalStateException("native runtime unavailable"))
    fun terminalResize(columns: Int, rows: Int, readWrite: Boolean): Result<Unit> = Result.failure(IllegalStateException("native runtime unavailable"))
    /** Opens a real Rust PTY and returns its opaque handle. */
    fun terminalOpen(columns: Int, rows: Int, readWrite: Boolean): Result<Long> =
        terminalAttach(0, columns, rows, readWrite).map { 0L }
    /** Opens the caller's named terminal session on [machineId] and attaches a PTY to it. */
    fun terminalOpen(machineId: UUID, columns: Int, rows: Int): Result<Long> =
        Result.failure(IllegalStateException("terminal unavailable"))
    /** Polls bounded output bytes from the Rust-owned PTY. */
    fun terminalPoll(handle: Long, maxBytes: Int = 64 * 1024): Result<ByteArray> =
        Result.failure(IllegalStateException("terminal output unavailable"))
    /** Bounded event read encoded as one event byte followed by display bytes. */
    fun terminalReadWithin(handle: Long, waitMilliseconds: Int, maxBytes: Int = 64 * 1024): Result<ByteArray> =
        terminalPoll(handle, maxBytes).map { bytes -> byteArrayOf(0) + bytes }
    /** Writes input bytes to the Rust-owned PTY. */
    fun terminalInputBytes(handle: Long, bytes: ByteArray): Result<Unit> =
        terminalInput(bytes.size, true)
    fun terminalResizeHandle(handle: Long, columns: Int, rows: Int): Result<Unit> =
        terminalResize(columns, rows, true)
    /** Closes the Rust-owned PTY handle. */
    fun terminalClose(handle: Long): Result<Unit> = Result.success(Unit)
    /** `terminal new`: opens or rejoins the caller's named session on [machineId]. */
    fun terminalNew(machineId: UUID): Result<MilaTerminalSessionRef> = Result.failure(IllegalStateException("terminal unavailable"))
    /** Attaches a PTY to [session]; returns the PTY handle. */
    fun terminalAttach(session: MilaTerminalSessionRef, columns: Int, rows: Int): Result<Long> = Result.failure(IllegalStateException("terminal unavailable"))
    fun terminalFrame(handle: Long): Result<MilaTerminalFrame> = Result.failure(IllegalStateException("terminal unavailable"))
    /** `terminal kill`: true when the server reports the session closed. */
    fun terminalEnd(session: MilaTerminalSessionRef): Result<Boolean> = Result.failure(IllegalStateException("terminal unavailable"))
}

/** Inputs needed to establish the certificate-authenticated Porsche session. */
data class MilaSessionConnectConfig(
    val trustDocument: ByteArray,
    val publicKey: String,
    val timeoutMs: Int = 15_000,
) {
    init {
        require(trustDocument.isNotEmpty()) { "empty SSH trust document" }
        require(publicKey.isNotBlank()) { "empty device public key" }
        require(timeoutMs in 1..120_000) { "invalid session timeout" }
    }
}

/** Adapter capability used by sign-in to retain the live Rust session authority. */
interface MilaSessionConnector {
    fun connect(deployment: MilaDeployment, config: MilaSessionConnectConfig, signer: MilaDeviceKey): MilaSessionHandle?
    fun bindSession(session: MilaSessionHandle?)
}

/** Explicit placeholder until generated Rust bindings are linked by the host app. */
object UnavailableMilaFfiAdapter : MilaFfiAdapter {
    override suspend fun call(request: MilaFfiRequest): MilaFfiResult {
        request.operation
        return MilaFfiResult.Failure(MilaFfiError.Unavailable)
    }
}

/** Narrow JNI surface implemented by the host application's Rust `mila-ffi` library. */
interface MilaRustBindings {
    fun abiVersion(): Int
    fun snapshotSavedAt(snapshot: ByteArray, host: String, port: Int): Long? = null
    fun canonicalRoute(value: String): String?
    /** Returns the closed machine-action bit mask, or null for invalid input. */
    fun machineActions(snapshot: ByteArray, host: String, port: Int?, index: Int): Int?
    fun sessionConnect(trust: ByteArray, host: String, publicKey: String, port: Int, timeoutMs: Int, signer: MilaDeviceKey): MilaSessionHandle?
    /** Reads one bounded machine page from the authenticated session. */
    fun sessionRead(handle: Long, more: Boolean): Int = -12
    /** Returns the latest validated machine listing for the authenticated session. */
    fun sessionListing(handle: Long): ByteArray? = null
    /** Returns the latest complete machine snapshot for the authenticated session. */
    fun sessionSnapshot(handle: Long): ByteArray? = null
    /** Returns the bounded `whoami --json` envelope, including pending approval links. */
    fun sessionWhoami(handle: Long): ByteArray? = null
    /** Returns the canonical Rust-selected trust document, or null on refusal. */
    fun reconcileTrust(pinned: ByteArray?, fetched: ByteArray?, host: String, now: Long): ByteArray? = null
    fun sessionMachineAction(handle: Long, machine: String, action: String, requestId: String): Int = -12
    fun sessionMachineResize(handle: Long, machine: String, cpu: Int, memory: Int, disk: Int, requestId: String): Int = -12
    fun sessionMachineClone(handle: Long, machine: String, name: String, requestId: String): Int = -12
    fun sessionMachineCreate(handle: Long, name: String, cpu: Int, memory: Int, disk: Int, requestId: String): Int = -12
    /** A null [role] selects removal; Rust validates the closed role set and principal bounds. */
    fun sessionShareMutation(handle: Long, machine: String, email: String, role: String?, add: Boolean, requestId: String): Int = -12
    fun sessionWebShow(handle: Long, machine: String): ByteArray? = null
    fun sessionWebSet(handle: Long, machine: String, port: Int, public: Boolean, revision: Long, requestId: String): Int = -12
    fun sessionThreadAction(handle: Long, thread: String, command: String, secondary: String?, input: String?, requestId: String?): ByteArray? = null
    /** Returns the validated `ssh-key list --json` result for an authenticated session. */
    fun sessionSshKeys(handle: Long): ByteArray? = null
    /** Authenticated Porsche notification-device CRUD. Tokens never cross this boundary. */
    fun sessionDeviceList(handle: Long): ByteArray? = null
    fun sessionDeviceRemove(handle: Long, device: String): Int = -12
    fun sessionDeviceRemoveWithRequest(handle: Long, device: String, requestId: String): Int =
        sessionDeviceRemove(handle, device)
    fun sessionDevicePreferences(handle: Long, device: String, enabled: Boolean): Int = -12
    fun sessionDevicePreferencesWithRequest(handle: Long, device: String, enabled: Boolean, requestId: String): Int =
        sessionDevicePreferences(handle, device, enabled)
    /** Opens a PTY through the authenticated session; terminal bytes stay outside this ABI. */
    fun sessionTerminalAttach(handle: Long, from: Long, columns: Int, rows: Int, readWrite: Boolean): Int = -12
    /** Validates a bounded PTY input write against the authenticated session. */
    fun sessionTerminalInput(handle: Long, length: Int, readWrite: Boolean): Int = -12
    /** Resizes a PTY owned by the authenticated session. */
    fun sessionTerminalResize(handle: Long, columns: Int, rows: Int, readWrite: Boolean): Int = -12
    fun sessionTerminalOpen(handle: Long, columns: Int, rows: Int): Long = 0
    /** `terminal new`: opens or rejoins the caller's named terminal session; returns its JSON receipt. */
    fun sessionTerminalNew(handle: Long, machine: String, requestId: String): ByteArray? = null
    /** Attaches a PTY to one named terminal session of one machine; 0 on refusal. */
    fun sessionTerminalAttachSession(handle: Long, machine: String, terminal: String, columns: Int, rows: Int): Long = 0
    fun sessionTerminalScreen(handle: Long): ByteArray? = null
    /** `terminal kill` for one named session; returns its JSON receipt, or null on refusal. */
    fun sessionTerminalEnd(handle: Long, machine: String, terminal: String, requestId: String): ByteArray? = null
    /** Registers this device with Susan's key-issuance reply; returns Porsche's JSON receipt. */
    fun sessionDeviceRegister(handle: Long, platform: Int, susanReply: String, encPubkey: String, label: String?, now: Long): ByteArray? = null
    /** Registers with a caller-owned request id for at-most-once resolution. */
    fun sessionDeviceRegisterWithRequest(handle: Long, platform: Int, susanReply: String, encPubkey: String, label: String?, requestId: String, now: Long): ByteArray? =
        sessionDeviceRegister(handle, platform, susanReply, encPubkey, label, now)
    /** `{"error": <closed code or null>}` for the session's last Porsche refusal. */
    fun sessionLastRefusal(handle: Long): ByteArray? = null
    fun sessionTerminalPoll(handle: Long, maxBytes: Int): ByteArray? = null
    fun sessionTerminalReadWithin(handle: Long, waitMilliseconds: Int, maxBytes: Int): ByteArray? = sessionTerminalPoll(handle, maxBytes)
    fun sessionTerminalInputBytes(handle: Long, bytes: ByteArray): Int = -12
    fun sessionTerminalResizeHandle(handle: Long, columns: Int, rows: Int): Int = -12
    fun sessionTerminalClose(handle: Long): Int = -12
    /** Revokes one opaque key id using a caller-supplied at-most-once request id. */
    fun sessionSshKeyRevoke(handle: Long, key: String, requestId: String): Int = -12
    fun sessionWatchOpen(handle: Long, filters: ByteArray): Long = 0
    fun sessionWatchRead(handle: Long, waitMilliseconds: Int): ByteArray? = null
    fun sessionWatchReconnect(handle: Long): Long = 0
    fun sessionWatchClose(handle: Long): Int = -12
    fun sessionClose(handle: Long): Int = -12
    fun pushRegistrationValidate(provider: Int, environment: Int, token: String, appId: String, deployment: String, endpoint: String?): Int = -12
    /** Returns the closed Rust thread-command tag, or -1 for an unknown command. */
    fun threadCommandKind(value: String): Int
    fun machineCommandKind(value: String): Int
    fun terminalAttach(from: Long, columns: Int, rows: Int, readWrite: Boolean): Int
    fun terminalInput(length: Int, readWrite: Boolean): Int
    fun terminalResize(columns: Int, rows: Int, readWrite: Boolean): Int
}

/** JNI entry points backed by the stable `mila-ffi` C ABI in the host application. */
internal object MilaRustFfi : MilaRustBindings {
    private val loaded: Boolean = runCatching {
        System.loadLibrary("mila_ffi")
        true
    }.getOrDefault(false)

    override fun abiVersion(): Int {
        check(loaded) { "mila_ffi is unavailable" }
        return nativeAbiVersion()
    }

    override fun snapshotSavedAt(snapshot: ByteArray, host: String, port: Int): Long? {
        check(loaded) { "mila_ffi is unavailable" }
        return nativeSnapshotSavedAt(snapshot, host, port).takeIf { it >= 0 }
    }

    override fun canonicalRoute(value: String): String? {
        check(loaded) { "mila_ffi is unavailable" }
        return nativeCanonicalRoute(value)
    }

    override fun machineActions(snapshot: ByteArray, host: String, port: Int?, index: Int): Int? {
        check(loaded) { "mila_ffi is unavailable" }
        val value = nativeMachineActions(snapshot, host, port ?: 0, port != null, index)
        return value.takeUnless { it < 0 }
    }

    override fun sessionConnect(trust: ByteArray, host: String, publicKey: String, port: Int, timeoutMs: Int, signer: MilaDeviceKey): MilaSessionHandle? {
        check(loaded) { "mila_ffi is unavailable" }
        return nativeSessionConnect(trust, host, publicKey, port, timeoutMs, signer).takeIf { it != 0L }?.let(::MilaSessionHandle)
    }
    override fun sessionRead(handle: Long, more: Boolean): Int = nativeSessionRead(handle, more)
    override fun sessionListing(handle: Long): ByteArray? = nativeSessionListing(handle)
    override fun sessionSnapshot(handle: Long): ByteArray? = nativeSessionSnapshot(handle)
    override fun sessionWhoami(handle: Long): ByteArray? = nativeSessionWhoami(handle)
    override fun reconcileTrust(pinned: ByteArray?, fetched: ByteArray?, host: String, now: Long): ByteArray? {
        check(loaded) { "mila_ffi is unavailable" }
        return nativeTrustDocumentReconcile(pinned, fetched, host, now)
    }
    override fun sessionMachineAction(handle: Long, machine: String, action: String, requestId: String): Int = nativeSessionMachineAction(handle, machine, action, requestId)
    override fun sessionMachineResize(handle: Long, machine: String, cpu: Int, memory: Int, disk: Int, requestId: String): Int = nativeSessionMachineResize(handle, machine, cpu, memory, disk, requestId)
    override fun sessionMachineClone(handle: Long, machine: String, name: String, requestId: String): Int = nativeSessionMachineClone(handle, machine, name, requestId)
    override fun sessionMachineCreate(handle: Long, name: String, cpu: Int, memory: Int, disk: Int, requestId: String): Int = nativeSessionMachineCreate(handle, name, cpu, memory, disk, requestId)
    override fun sessionShareMutation(handle: Long, machine: String, email: String, role: String?, add: Boolean, requestId: String): Int = nativeSessionShareMutation(handle, machine, email, role, add, requestId)
    override fun sessionWebShow(handle: Long, machine: String): ByteArray? = nativeSessionWebShow(handle, machine)
    override fun sessionWebSet(handle: Long, machine: String, port: Int, public: Boolean, revision: Long, requestId: String): Int = nativeSessionWebSet(handle, machine, port, public, revision, requestId)
    override fun sessionThreadAction(handle: Long, thread: String, command: String, secondary: String?, input: String?, requestId: String?): ByteArray? = nativeSessionThreadAction(handle, thread, command, secondary, input, requestId)
    override fun sessionSshKeys(handle: Long): ByteArray? = nativeSessionSshKeys(handle)
    override fun sessionDeviceList(handle: Long): ByteArray? = nativeSessionDeviceList(handle)
    override fun sessionDeviceRemove(handle: Long, device: String): Int = nativeSessionDeviceRemove(handle, device)
    override fun sessionDeviceRemoveWithRequest(handle: Long, device: String, requestId: String): Int = nativeSessionDeviceRemoveWithRequest(handle, device, requestId)
    override fun sessionDevicePreferences(handle: Long, device: String, enabled: Boolean): Int = nativeSessionDevicePreferences(handle, device, enabled)
    override fun sessionDevicePreferencesWithRequest(handle: Long, device: String, enabled: Boolean, requestId: String): Int = nativeSessionDevicePreferencesWithRequest(handle, device, enabled, requestId)
    override fun sessionSshKeyRevoke(handle: Long, key: String, requestId: String): Int = nativeSessionSshKeyRevoke(handle, key, requestId)
    override fun sessionWatchOpen(handle: Long, filters: ByteArray): Long = nativeSessionWatchOpen(handle, filters)
    override fun sessionWatchRead(handle: Long, waitMilliseconds: Int): ByteArray? = nativeSessionWatchRead(handle, waitMilliseconds)
    override fun sessionWatchReconnect(handle: Long): Long = nativeSessionWatchReconnect(handle)
    override fun sessionWatchClose(handle: Long): Int = nativeSessionWatchClose(handle)
    override fun sessionClose(handle: Long): Int = nativeSessionClose(handle)
    override fun pushRegistrationValidate(provider: Int, environment: Int, token: String, appId: String, deployment: String, endpoint: String?): Int =
        nativePushRegistrationValidate(provider, environment, token, appId, deployment, endpoint)

    override fun threadCommandKind(value: String): Int {
        check(loaded) { "mila_ffi is unavailable" }
        return nativeThreadCommandKind(value)
    }

    override fun machineCommandKind(value: String): Int {
        check(loaded) { "mila_ffi is unavailable" }
        return nativeMachineCommandKind(value)
    }

    override fun terminalAttach(from: Long, columns: Int, rows: Int, readWrite: Boolean): Int = nativeTerminalAttach(from, columns, rows, readWrite)
    override fun terminalInput(length: Int, readWrite: Boolean): Int = nativeTerminalInput(length, readWrite)
    override fun terminalResize(columns: Int, rows: Int, readWrite: Boolean): Int = nativeTerminalResize(columns, rows, readWrite)
    override fun sessionTerminalAttach(handle: Long, from: Long, columns: Int, rows: Int, readWrite: Boolean): Int = nativeSessionTerminalAttach(handle, from, columns, rows, readWrite)
    override fun sessionTerminalInput(handle: Long, length: Int, readWrite: Boolean): Int = nativeSessionTerminalInput(handle, length, readWrite)
    override fun sessionTerminalResize(handle: Long, columns: Int, rows: Int, readWrite: Boolean): Int = nativeSessionTerminalResize(handle, columns, rows, readWrite)
    override fun sessionTerminalOpen(handle: Long, columns: Int, rows: Int): Long = nativeSessionTerminalOpen(handle, columns, rows)
    override fun sessionTerminalNew(handle: Long, machine: String, requestId: String): ByteArray? = nativeSessionTerminalNew(handle, machine, requestId)
    override fun sessionTerminalAttachSession(handle: Long, machine: String, terminal: String, columns: Int, rows: Int): Long = nativeSessionTerminalAttachSession(handle, machine, terminal, columns, rows)
    override fun sessionTerminalScreen(handle: Long): ByteArray? = nativeSessionTerminalScreen(handle)
    override fun sessionTerminalEnd(handle: Long, machine: String, terminal: String, requestId: String): ByteArray? = nativeSessionTerminalEnd(handle, machine, terminal, requestId)
    override fun sessionDeviceRegister(handle: Long, platform: Int, susanReply: String, encPubkey: String, label: String?, now: Long): ByteArray? = nativeSessionDeviceRegister(handle, platform, susanReply, encPubkey, label, now)
    override fun sessionDeviceRegisterWithRequest(handle: Long, platform: Int, susanReply: String, encPubkey: String, label: String?, requestId: String, now: Long): ByteArray? = nativeSessionDeviceRegisterWithRequest(handle, platform, susanReply, encPubkey, label, requestId, now)
    override fun sessionLastRefusal(handle: Long): ByteArray? = nativeSessionLastRefusal(handle)
    override fun sessionTerminalPoll(handle: Long, maxBytes: Int): ByteArray? = nativeSessionTerminalPoll(handle, maxBytes)
    override fun sessionTerminalReadWithin(handle: Long, waitMilliseconds: Int, maxBytes: Int): ByteArray? = nativeSessionTerminalReadWithin(handle, waitMilliseconds, maxBytes)
    override fun sessionTerminalInputBytes(handle: Long, bytes: ByteArray): Int = nativeSessionTerminalInputBytes(handle, bytes)
    override fun sessionTerminalResizeHandle(handle: Long, columns: Int, rows: Int): Int = nativeSessionTerminalResizeHandle(handle, columns, rows)
    override fun sessionTerminalClose(handle: Long): Int = nativeSessionTerminalClose(handle)

    @JvmStatic
    external fun nativeSnapshotSavedAt(snapshot: ByteArray, host: String, port: Int): Long
    external fun nativeAbiVersion(): Int

    @JvmStatic
    external fun nativeCanonicalRoute(value: String): String?

    @JvmStatic
    external fun nativeMachineActions(snapshot: ByteArray, host: String, port: Int, hasPort: Boolean, index: Int): Int

    @JvmStatic
    /** Returns the session handle, or 0 when Rust refused; Rust returns a primitive `jlong`. */
    external fun nativeSessionConnect(trust: ByteArray, host: String, publicKey: String, port: Int, timeoutMs: Int, signer: MilaDeviceKey): Long
    @JvmStatic
    external fun nativeTrustDocumentReconcile(pinned: ByteArray?, fetched: ByteArray?, host: String, now: Long): ByteArray?
    @JvmStatic
    external fun nativeSessionRead(handle: Long, more: Boolean): Int
    @JvmStatic external fun nativeSessionWhoami(handle: Long): ByteArray?
    @JvmStatic external fun nativeSessionTerminalScreen(handle: Long): ByteArray?
    @JvmStatic external fun nativeSessionTerminalState(handle: Long): ByteArray?
    @JvmStatic external fun nativeSessionTerminalAttachOptions(handle: Long, machine: String, terminal: String, columns: Int, rows: Int, cursor: Long, hasCursor: Boolean, readOnly: Boolean): Long
    @JvmStatic external fun nativeSessionMachineAction(handle: Long, machine: String, action: String, requestId: String): Int
    @JvmStatic external fun nativeSessionMachineResize(handle: Long, machine: String, cpu: Int, memory: Int, disk: Int, requestId: String): Int
    @JvmStatic external fun nativeSessionMachineClone(handle: Long, machine: String, name: String, requestId: String): Int
    @JvmStatic external fun nativeSessionMachineCreate(handle: Long, name: String, cpu: Int, memory: Int, disk: Int, requestId: String): Int
    @JvmStatic external fun nativeSessionShareMutation(handle: Long, machine: String, email: String, role: String?, add: Boolean, requestId: String): Int
    @JvmStatic external fun nativeSessionWebShow(handle: Long, machine: String): ByteArray?
    @JvmStatic external fun nativeSessionWebSet(handle: Long, machine: String, port: Int, public: Boolean, revision: Long, requestId: String): Int
    @JvmStatic external fun nativeSessionThreadAction(handle: Long, thread: String, command: String, secondary: String?, input: String?, requestId: String?): ByteArray?
    @JvmStatic external fun nativeSessionSshKeys(handle: Long): ByteArray?
    @JvmStatic external fun nativeSessionDeviceList(handle: Long): ByteArray?
    @JvmStatic external fun nativeSessionDeviceRemove(handle: Long, device: String): Int
    @JvmStatic external fun nativeSessionDeviceRemoveWithRequest(handle: Long, device: String, requestId: String): Int
    @JvmStatic external fun nativeSessionDevicePreferences(handle: Long, device: String, enabled: Boolean): Int
    @JvmStatic external fun nativeSessionDevicePreferencesWithRequest(handle: Long, device: String, enabled: Boolean, requestId: String): Int
    @JvmStatic external fun nativeSessionSshKeyRevoke(handle: Long, key: String, requestId: String): Int
    @JvmStatic external fun nativePushRegistrationValidate(provider: Int, environment: Int, token: String, appId: String, deployment: String, endpoint: String?): Int
    @JvmStatic
    external fun nativeSessionListing(handle: Long): ByteArray?
    @JvmStatic
    external fun nativeSessionSnapshot(handle: Long): ByteArray?
    @JvmStatic
    external fun nativeSessionClose(handle: Long): Int
    @JvmStatic external fun nativeSessionWatchOpen(handle: Long, filters: ByteArray): Long
    @JvmStatic external fun nativeSessionWatchRead(handle: Long, waitMilliseconds: Int): ByteArray?
    @JvmStatic external fun nativeSessionWatchReconnect(handle: Long): Long
    @JvmStatic external fun nativeSessionWatchClose(handle: Long): Int
    @JvmStatic
    external fun nativeThreadCommandKind(value: String): Int
    @JvmStatic
    external fun nativeMachineCommandKind(value: String): Int
    @JvmStatic external fun nativeTerminalAttach(from: Long, columns: Int, rows: Int, readWrite: Boolean): Int
    @JvmStatic external fun nativeTerminalInput(length: Int, readWrite: Boolean): Int
    @JvmStatic external fun nativeTerminalResize(columns: Int, rows: Int, readWrite: Boolean): Int
    @JvmStatic external fun nativeSessionTerminalAttach(handle: Long, from: Long, columns: Int, rows: Int, readWrite: Boolean): Int
    @JvmStatic external fun nativeSessionTerminalInput(handle: Long, length: Int, readWrite: Boolean): Int
    @JvmStatic external fun nativeSessionTerminalResize(handle: Long, columns: Int, rows: Int, readWrite: Boolean): Int
    @JvmStatic external fun nativeSessionTerminalOpen(handle: Long, columns: Int, rows: Int): Long
    @JvmStatic external fun nativeSessionTerminalNew(handle: Long, machine: String, requestId: String): ByteArray?
    @JvmStatic external fun nativeSessionTerminalAttachSession(handle: Long, machine: String, terminal: String, columns: Int, rows: Int): Long
    @JvmStatic external fun nativeSessionTerminalEnd(handle: Long, machine: String, terminal: String, requestId: String): ByteArray?
    @JvmStatic external fun nativeSessionDeviceRegister(handle: Long, platform: Int, susanReply: String, encPubkey: String, label: String?, now: Long): ByteArray?
    @JvmStatic external fun nativeSessionDeviceRegisterWithRequest(handle: Long, platform: Int, susanReply: String, encPubkey: String, label: String?, requestId: String, now: Long): ByteArray?
    @JvmStatic external fun nativeSessionLastRefusal(handle: Long): ByteArray?
    @JvmStatic external fun nativeSessionTerminalPoll(handle: Long, maxBytes: Int): ByteArray?
    @JvmStatic external fun nativeSessionTerminalReadWithin(handle: Long, waitMilliseconds: Int, maxBytes: Int): ByteArray?
    @JvmStatic external fun nativeSessionTerminalInputBytes(handle: Long, input: ByteArray): Int
    @JvmStatic external fun nativeSessionTerminalResizeHandle(handle: Long, columns: Int, rows: Int): Int
    @JvmStatic external fun nativeSessionTerminalClose(handle: Long): Int
}

/** Porsche at-most-once request identity accepted by every authenticated mutation. */
internal val MILA_REQUEST_ID: Regex = Regex("^porsche-[0-9a-f]{32}$")

/** Mints one fresh request id per user submission; callers never reuse it across submissions. */
internal fun milaRequestId(): String = "porsche-" + UUID.randomUUID().toString().replace("-", "")

/** Porsche device mutations accept only the canonical lowercase UUID identity. */
private fun isCanonicalIdentifier(value: String): Boolean =
    value.length == 36 && runCatching { UUID.fromString(value).toString() == value && value != UUID(0L, 0L).toString() }.getOrDefault(false)

/** Opaque, one-shot authority for a live Rust session. */
/**
 * @cc [owner:ghuntley,label:architecture] mila-android-session-binding-parity
 * Every operation on a packaged Android session handle MUST dispatch through the binding supplied
 * by its adapter, so injected bindings and the production JNI implementation observe the same
 * authenticated machine-list lifecycle.
 */
class MilaSessionHandle internal constructor(
    private val nativeHandle: Long,
    private val bindings: MilaRustBindings = MilaRustFfi,
) : AutoCloseable {
    private var closed = false
    @Synchronized fun readMachines(more: Boolean = false): Int { check(!closed); return bindings.sessionRead(nativeHandle, more) }
    @Synchronized fun listing(): ByteArray { check(!closed); return bindings.sessionListing(nativeHandle) ?: error("listing unavailable") }
    /**
     * @cc [owner:ghuntley,label:security;recovery] android-complete-machine-listing
     * A successful fresh machine read MUST follow Rust's accumulated continuation on the same
     * session until complete, within 500 pages and 500 machines. Failed pages and session
     * replacement MUST refuse the whole result before it is published or used for a snapshot.
     */
    @Synchronized fun readCompleteListing(stillCurrent: () -> Boolean = { true }): ByteArray {
        check(!closed)
        repeat(MILA_MAX_MACHINES) { page ->
            check(stillCurrent()) { "session replaced during machine read" }
            check(readMachines(more = page != 0) == 0) { "machine read refused" }
            check(stillCurrent()) { "session replaced during machine read" }
            val encoded = listing()
            val decoded = MilaSessionListing.decode(encoded)
            check(stillCurrent()) { "session replaced during machine read" }
            if (!decoded.hasMore) return encoded
        }
        error("machine pagination exceeds bound")
    }
    @Synchronized fun whoami(): ByteArray {
        check(!closed)
        return bindings.sessionWhoami(nativeHandle) ?: error("whoami unavailable")
    }
    @Synchronized fun snapshot(): ByteArray { check(!closed); return bindings.sessionSnapshot(nativeHandle) ?: error("snapshot unavailable") }
    @Synchronized fun machineAction(machine: UUID, command: MilaMachineCommand, requestId: String): Result<Unit> = runCatching {
        check(!closed)
        require(requestId.matches(Regex("^porsche-[0-9a-f]{32}$")))
        val action = when (command) { MilaMachineCommand.Start -> "start"; MilaMachineCommand.Stop -> "stop"; MilaMachineCommand.Pause -> "pause"; MilaMachineCommand.Resume -> "resume"; MilaMachineCommand.Delete -> "rm"; else -> throw IllegalArgumentException("command is not a mutation") }
        val status = bindings.sessionMachineAction(nativeHandle, machine.toString(), action, requestId)
        if (status != 0) error("machine action rejected")
    }
    @Synchronized fun machineResize(machine: UUID, cpu: Int, memoryMiB: Int, diskGiB: Int, requestId: String): Result<Unit> = runCatching {
        check(!closed); require(cpu in 1..256); require(memoryMiB in 256..4_194_304); require(diskGiB in 1..500); require(requestId.matches(Regex("^porsche-[0-9a-f]{32}$")))
        check(bindings.sessionMachineResize(nativeHandle, machine.toString(), cpu, memoryMiB, diskGiB, requestId) == 0)
    }
    /**
     * @cc [owner:ghuntley,label:security;recovery] android-session-handle-fencing
     * A closed handle MUST refuse clone submission locally, and the name/request
     * identity MUST satisfy the same bounds as the Rust ABI before dispatch.
     */
    @Synchronized fun machineClone(machine: UUID, name: String, requestId: String): Result<Unit> = runCatching {
        check(!closed)
        require(name.isNotEmpty() && name.length <= 128 && name.all {
            it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-' || it == '_'
        })
        require(requestId.matches(MILA_REQUEST_ID))
        check(bindings.sessionMachineClone(nativeHandle, machine.toString(), name, requestId) == 0) { "clone rejected" }
    }
    @Synchronized fun machineCreate(request: MilaMachineCreateRequest, requestId: String): Result<Unit> = runCatching {
        check(!closed); require(requestId.matches(MILA_REQUEST_ID))
        check(bindings.sessionMachineCreate(nativeHandle, request.name, request.cpu, request.memoryMiB, request.diskGiB, requestId) == 0) { "machine create rejected" }
    }
    @Synchronized fun shareMutation(machine: UUID, principal: MilaSharePrincipal, role: MilaShareRole?, requestId: String): Result<Unit> = runCatching {
        check(!closed); require(requestId.matches(MILA_REQUEST_ID))
        check(bindings.sessionShareMutation(nativeHandle, machine.toString(), principal.value, role?.wire, role != null, requestId) == 0) { "sharing rejected" }
    }
    @Synchronized fun webShow(machine: UUID): Result<ByteArray> = runCatching {
        check(!closed)
        bindings.sessionWebShow(nativeHandle, machine.toString()) ?: error("web endpoint unavailable")
    }
    @Synchronized fun webSet(machine: UUID, port: Int, public: Boolean, revision: Long, requestId: String): Result<Unit> = runCatching {
        check(!closed)
        require(port in 1..65_535)
        require(revision > 0)
        require(requestId.matches(Regex("^porsche-[0-9a-f]{32}$")))
        check(bindings.sessionWebSet(nativeHandle, machine.toString(), port, public, revision, requestId) == 0)
    }
    @Synchronized fun threadAction(thread: UUID, command: MilaThreadCommand, secondary: UUID? = null, input: String? = null, requestId: String? = null): Result<ByteArray> = runCatching {
        check(!closed)
        val wire = when (command) {
            MilaThreadCommand.List -> "thread ls"
            MilaThreadCommand.Show -> "thread show"
            MilaThreadCommand.Turns -> "thread turns"
            MilaThreadCommand.Prompt -> "thread prompt"
            MilaThreadCommand.Answer -> "thread answer"
            MilaThreadCommand.PlanApprove -> "thread plan approve"
            MilaThreadCommand.PlanRevise -> "thread plan revise"
            MilaThreadCommand.Mode -> "thread mode"
            MilaThreadCommand.Read -> "thread read"
        }
        bindings.sessionThreadAction(nativeHandle, thread.toString(), wire, secondary?.toString(), input, requestId)
            ?: error("thread action rejected")
    }
    @Synchronized fun threadListing(): Result<ByteArray> = runCatching {
        check(!closed)
        bindings.sessionThreadAction(nativeHandle, "", "thread ls", null, null, null)
            ?: error("thread listing unavailable")
    }
    /** Reads keys through the same authenticated, certificate-pinned session handle. */
    @Synchronized fun terminalAttach(from: Long, columns: Int, rows: Int, readWrite: Boolean): Result<Unit> = runCatching {
        check(!closed)
        check(bindings.sessionTerminalAttach(nativeHandle, from, columns, rows, readWrite) == 0)
    }
    @Synchronized fun terminalInput(length: Int, readWrite: Boolean): Result<Unit> = runCatching {
        check(!closed)
        check(bindings.sessionTerminalInput(nativeHandle, length, readWrite) == 0)
    }
    @Synchronized fun terminalResize(columns: Int, rows: Int, readWrite: Boolean): Result<Unit> = runCatching {
        check(!closed)
        check(bindings.sessionTerminalResize(nativeHandle, columns, rows, readWrite) == 0)
    }
    @Synchronized fun terminalOpen(columns: Int, rows: Int): Result<Long> = runCatching {
        check(!closed)
        bindings.sessionTerminalOpen(nativeHandle, columns, rows).takeIf { it > 0 }
            ?: error("terminal attach rejected")
    }
    /**
     * @cc [owner:ghuntley,label:security;protocol] android-terminal-named-session
     * A packaged terminal MUST open the caller's named Porsche terminal session for one machine
     * (`terminal new`) and attach to that machine and session id; the unnamed legacy attach is
     * never used because real Porsche refuses it.
     */
    @Synchronized fun terminalNew(machine: UUID, requestId: String): Result<MilaTerminalSessionRef> = runCatching {
        check(!closed); require(requestId.matches(MILA_REQUEST_ID))
        val receipt = bindings.sessionTerminalNew(nativeHandle, machine.toString(), requestId) ?: error("terminal new refused")
        require(receipt.size <= 64 * 1024) { "terminal receipt exceeds bound" }
        val result = org.json.JSONObject(receipt.toString(Charsets.UTF_8)).getJSONObject("result")
        MilaTerminalSessionRef(machine, result.getString("session_id"))
    }
    @Synchronized fun terminalAttach(session: MilaTerminalSessionRef, columns: Int, rows: Int): Result<Long> = runCatching {
        check(!closed); require(columns in 1..4096 && rows in 1..512)
        bindings.sessionTerminalAttachSession(nativeHandle, session.machine.toString(), session.id, columns, rows).takeIf { it > 0 }
            ?: error("terminal attach rejected")
    }
    @Synchronized fun terminalFrame(handle: Long): Result<MilaTerminalFrame> = runCatching {
        check(!closed); require(handle > 0)
        val bytes = bindings.sessionTerminalScreen(handle) ?: error("terminal screen unavailable")
        MilaTerminalFrame.decode(bytes)
    }
    @Synchronized fun terminalEnd(session: MilaTerminalSessionRef, requestId: String): Result<Boolean> = runCatching {
        check(!closed); require(requestId.matches(MILA_REQUEST_ID))
        val receipt = bindings.sessionTerminalEnd(nativeHandle, session.machine.toString(), session.id, requestId) ?: error("terminal kill refused")
        require(receipt.size <= 64 * 1024) { "terminal receipt exceeds bound" }
        val root = org.json.JSONObject(receipt.toString(Charsets.UTF_8))
        (root.optJSONObject("result") ?: root).optBoolean("closed", false)
    }
    @Synchronized fun terminalOpenSession(machine: UUID, columns: Int, rows: Int, requestId: String): Result<Long> =
        terminalNew(machine, requestId).mapCatching { terminalAttach(it, columns, rows).getOrThrow() }
    /** Registers this device; the Susan reply carries the push key and never enters UI state. */
    @Synchronized fun notificationDeviceRegister(susanReply: String, encPubkey: String, label: String?, now: Long, requestId: String): Result<ByteArray> = runCatching {
        check(!closed); require(susanReply.length <= 4096 && encPubkey.length <= 64 && (label == null || label.length <= 256))
        require(requestId.matches(MILA_REQUEST_ID))
        bindings.sessionDeviceRegisterWithRequest(nativeHandle, 1, susanReply, encPubkey, label, requestId, now) ?: error("device registration refused")
    }
    @Synchronized fun notificationDeviceRegister(susanReply: String, encPubkey: String, label: String?, now: Long): Result<ByteArray> =
        notificationDeviceRegister(susanReply, encPubkey, label, now, milaRequestId())
    /** Closed refusal code from Porsche's last error envelope, or null. Never carries payloads. */
    @Synchronized fun lastRefusal(): String? = runCatching {
        check(!closed)
        val value = bindings.sessionLastRefusal(nativeHandle) ?: return@runCatching null
        org.json.JSONObject(value.toString(Charsets.UTF_8)).optString("error").takeIf { it.matches(Regex("^[a-z0-9_]{1,64}$")) }
    }.getOrNull()
    @Synchronized fun terminalPoll(handle: Long, maxBytes: Int): Result<ByteArray> = runCatching {
        check(!closed); require(handle > 0); require(maxBytes in 1..(64 * 1024))
        bindings.sessionTerminalPoll(handle, maxBytes) ?: error("terminal poll rejected")
    }
    /**
     * @cc [owner:ghuntley,label:security;reliability] android-terminal-read-bound
     * The caller's maximum byte limit MUST reach the native binding unchanged;
     * a read may never allocate or return beyond that requested limit.
     */
    @Synchronized fun terminalReadWithin(handle: Long, waitMilliseconds: Int, maxBytes: Int): Result<ByteArray> = runCatching {
        check(!closed); require(handle > 0); require(waitMilliseconds in 0..1_000); require(maxBytes in 1..(1 shl 20))
        val result = bindings.sessionTerminalReadWithin(handle, waitMilliseconds, maxBytes) ?: error("terminal read rejected")
        require(result.isNotEmpty())
        result
    }
    @Synchronized fun terminalInputBytes(handle: Long, bytes: ByteArray): Result<Unit> = runCatching {
        check(!closed); require(handle > 0); require(bytes.size <= 1 shl 20)
        check(bindings.sessionTerminalInputBytes(handle, bytes) == 0)
    }
    @Synchronized fun terminalResizeHandle(handle: Long, columns: Int, rows: Int): Result<Unit> = runCatching {
        check(!closed); require(handle > 0)
        check(bindings.sessionTerminalResizeHandle(handle, columns, rows) == 0)
    }
    @Synchronized fun terminalClose(handle: Long): Result<Unit> = runCatching {
        check(!closed); require(handle > 0)
        check(bindings.sessionTerminalClose(handle) == 0)
    }
    @Synchronized fun sshKeys(): Result<ByteArray> = runCatching {
        check(!closed)
        bindings.sessionSshKeys(nativeHandle) ?: error("SSH key listing unavailable")
    }
    @Synchronized fun notificationDevices(): Result<ByteArray> = runCatching {
        check(!closed)
        bindings.sessionDeviceList(nativeHandle) ?: error("notification devices unavailable")
    }
    /**
     * @cc [owner:ghuntley,label:security;protocol] android-device-id-bound
     * Notification device mutations MUST use the canonical lowercase UUID returned by Porsche;
     * arbitrary display identifiers MUST be refused before crossing the native ABI.
     */
    @Synchronized fun notificationDeviceRemove(device: String, requestId: String): Result<Unit> = runCatching {
        check(!closed); require(isCanonicalIdentifier(device))
        require(requestId.matches(MILA_REQUEST_ID))
        check(bindings.sessionDeviceRemoveWithRequest(nativeHandle, device, requestId) == 0)
    }
    @Synchronized fun notificationDeviceRemove(device: String): Result<Unit> =
        notificationDeviceRemove(device, milaRequestId())
    @Synchronized fun notificationDevicePreferences(device: String, enabled: Boolean, requestId: String): Result<Unit> = runCatching {
        check(!closed); require(isCanonicalIdentifier(device))
        require(requestId.matches(MILA_REQUEST_ID))
        check(bindings.sessionDevicePreferencesWithRequest(nativeHandle, device, enabled, requestId) == 0)
    }
    @Synchronized fun notificationDevicePreferences(device: String, enabled: Boolean): Result<Unit> =
        notificationDevicePreferences(device, enabled, milaRequestId())
    /** Revokes one opaque key identity exactly once on this session. */
    @Synchronized fun sshKeyRevoke(key: String, requestId: String): Result<Unit> = runCatching {
        check(!closed)
        require(key.isNotBlank())
        require(requestId.matches(Regex("^porsche-[0-9a-f]{32}$")))
        check(bindings.sessionSshKeyRevoke(nativeHandle, key, requestId) == 0)
    }
    /** Up to 64 filters are sharded by Rust over the one SSH connection. */
    @Synchronized fun watchOpen(machineIds: List<UUID>, threadIds: List<UUID>): Result<Long> = runCatching {
        check(!closed)
        val machines = machineIds.distinct().sortedBy(UUID::toString)
        val threads = threadIds.distinct().sortedBy(UUID::toString)
        require(machines.size + threads.size <= 64)
        fun ids(values: List<UUID>): String = values.joinToString(",", "[", "]") { "\"$it\"" }
        val filters = "{\"machines\":${ids(machines)},\"threads\":${ids(threads)}}".toByteArray(Charsets.UTF_8)
        bindings.sessionWatchOpen(nativeHandle, filters).also { check(it != 0L) }
    }
    @Synchronized fun watchRead(handle: Long, waitMilliseconds: Int): Result<MilaWatchRead> = runCatching {
        check(!closed); require(waitMilliseconds in 0..1000)
        val bytes = bindings.sessionWatchRead(handle, waitMilliseconds) ?: error("watch unavailable")
        require(bytes.size == 2)
        when (bytes[0].toInt()) {
            0 -> MilaWatchRead.Hint(MilaWatchHint.fromTag(bytes[1].toInt()) ?: error("invalid watch hint"))
            1 -> MilaWatchRead.Idle
            2 -> MilaWatchRead.Closed
            3 -> MilaWatchRead.AuthorityLost
            4 -> MilaWatchRead.TransportLost
            else -> error("invalid watch state")
        }
    }
    @Synchronized fun watchReconnect(handle: Long): Result<Long> = runCatching {
        check(!closed); bindings.sessionWatchReconnect(handle).also { check(it != 0L) }
    }
    @Synchronized fun watchClose(handle: Long): Result<Unit> = runCatching {
        check(!closed); check(bindings.sessionWatchClose(handle) == 0)
    }
    @Synchronized override fun close() { if (!closed) { bindings.sessionClose(nativeHandle); closed = true } }
}

/** Typed Android adapter. Native linkage is lazy so the UI remains testable without a device. */
class LinkedMilaFfiAdapter(
    private val bindings: MilaRustBindings = MilaRustFfi,
) : MilaFfiAdapter, MilaSessionConnector {
    @Volatile private var authenticatedSession: MilaSessionHandle? = null
    @Volatile private var authenticatedFingerprint: String? = null
    /**
     * @cc [owner:ghuntley,label:protocol;recovery] android-mutation-request-ledger
     * Every authenticated Android mutation MUST retain its request id after an uncertain failure,
     * reuse it for an identical retry, and discard it only after a successful outcome or session
     * replacement; a retry MUST never submit a fresh identity for the same operation. A late
     * outcome from a replaced session MUST NOT clear the new session's request identity.
     */
    private val pendingMutationIds = mutableMapOf<String, String>()

    private fun <T> submitMutation(session: MilaSessionHandle, key: String, submit: (String) -> Result<T>): Result<T> {
        val requestId = synchronized(pendingMutationIds) {
            if (authenticatedSession !== session) return Result.failure(IllegalStateException("session replaced before mutation"))
            pendingMutationIds.getOrPut(key, ::milaRequestId)
        }
        val result = submit(requestId)
        if (result.isSuccess) synchronized(pendingMutationIds) {
            if (pendingMutationIds[key] == requestId) pendingMutationIds.remove(key)
        }
        return result
    }

    /** Binds the adapter to the already certificate-authenticated session. */
    override fun watchOpen(machineIds: List<UUID>, threadIds: List<UUID>): Result<Long> =
        authenticatedValue { it.watchOpen(machineIds, threadIds) }
    override fun watchRead(handle: Long, waitMilliseconds: Int): Result<MilaWatchRead> =
        authenticatedValue { it.watchRead(handle, waitMilliseconds) }
    override fun watchReconnect(handle: Long): Result<Long> =
        authenticatedValue { it.watchReconnect(handle) }
    override fun watchClose(handle: Long): Result<Unit> =
        authenticatedValue { it.watchClose(handle) }
    override fun snapshotData(): Result<ByteArray> = runCatching {
        (authenticatedSession ?: error("session unavailable")).snapshot()
    }

    /**
     * @cc [owner:ghuntley,label:security;recovery] android-linked-session-replacement
     * Replacing a binding MUST publish the new authority before waiting for the previous session
     * to close, so in-flight paginated reads can refuse their stale results. Rebinding the same
     * session MUST preserve that live session rather than closing it.
     */
    @Synchronized override fun bindSession(session: MilaSessionHandle?) {
        val previous = authenticatedSession
        if (previous === session && session != null) return
        synchronized(pendingMutationIds) {
            authenticatedSession = session
            if (session == null) authenticatedFingerprint = null
            pendingMutationIds.clear()
        }
        previous?.close()
    }

    override fun connect(deployment: MilaDeployment, config: MilaSessionConnectConfig, signer: MilaDeviceKey): MilaSessionHandle? =
        bindings.sessionConnect(config.trustDocument.copyOf(), deployment.host, config.publicKey,
            deployment.port, config.timeoutMs, signer)?.also { authenticatedFingerprint = milaSshFingerprint(config.publicKey) }

    override suspend fun machineResize(machineId: UUID, cpu: Int, memoryMiB: Int, diskGiB: Int): Result<Unit> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        val key = "machine-resize|$machineId|$cpu|$memoryMiB|$diskGiB"
        return submitMutation(session, key) { session.machineResize(machineId, cpu, memoryMiB, diskGiB, it) }
    }
    override suspend fun machineClone(machineId: UUID, name: String, requestId: String): Result<Unit> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        return session.machineClone(machineId, name, requestId)
    }
    override suspend fun machineCreate(request: MilaMachineCreateRequest): Result<Unit> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        val key = "machine-create|${request.name}|${request.cpu}|${request.memoryMiB}|${request.diskGiB}"
        return submitMutation(session, key) { session.machineCreate(request, it) }
    }
    override suspend fun machineShare(machineId: UUID, principal: MilaSharePrincipal, role: MilaShareRole?): Result<Unit> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        val key = "machine-share|$machineId|${principal.value}|${role?.wire ?: "remove"}"
        return submitMutation(session, key) { session.shareMutation(machineId, principal, role, it) }
    }
    override suspend fun machineAction(machineId: UUID, command: MilaMachineCommand): Result<Unit> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        val key = "machine-action|$machineId|${command.tag}"
        return submitMutation(session, key) { session.machineAction(machineId, command, it) }
    }
    override suspend fun webShow(machineId: UUID): Result<String> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        return session.webShow(machineId).map { it.toString(Charsets.UTF_8) }
    }
    override suspend fun webSet(machineId: UUID, port: Int, public: Boolean, revision: Long): Result<Unit> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        val key = "web-set|$machineId|$port|$public|$revision"
        return submitMutation(session, key) { session.webSet(machineId, port, public, revision, it) }
    }

    override suspend fun threadAction(threadId: UUID, command: MilaThreadCommand): Result<Unit> =
        threadAction(threadId, command, null, null)

    override suspend fun threadAction(threadId: UUID, command: MilaThreadCommand, input: String?): Result<Unit> =
        threadAction(threadId, command, input, null)

    /**
     * @cc [owner:ghuntley,label:security;protocol] android-linked-thread-dispatch
     * Every thread-action overload MUST dispatch through the current authenticated session;
     * a missing session or Rust refusal MUST NOT be reported as an applied operation.
     */
    override suspend fun threadAction(threadId: UUID, command: MilaThreadCommand, input: String?, secondary: UUID?): Result<Unit> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        val mutating = command !in setOf(MilaThreadCommand.List, MilaThreadCommand.Show, MilaThreadCommand.Turns)
        val key = "thread|$threadId|${command.tag}|${secondary ?: ""}|${input ?: ""}"
        return if (mutating) submitMutation(session, key) { requestId ->
            session.threadAction(threadId, command, secondary = secondary, input = input, requestId = requestId).map { Unit }
        } else session.threadAction(threadId, command, secondary = secondary, input = input).map { Unit }
    }
    override suspend fun refreshListing(): Result<MilaSessionListing> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        return runCatching {
            val encoded = session.readCompleteListing { authenticatedSession === session }
            val listing = MilaSessionListing.decode(encoded)
            check(authenticatedSession === session) { "session replaced during refresh" }
            listing
        }
    }
    override suspend fun threadShow(threadId: UUID): Result<ByteArray> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        return session.threadAction(threadId, MilaThreadCommand.Show)
    }
    override suspend fun threadListing(): Result<MilaThreadListing> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        return session.threadListing().map { MilaThreadListing.decode(it) }
    }

    override fun sshKeyStore(): MilaSshKeyStore? = authenticatedSession?.let {
        MilaSessionSshKeyStore(it, authenticatedFingerprint)
    }

    override fun notificationDevices(): Result<ByteArray> = authenticatedSession?.notificationDevices()
        ?: Result.failure(IllegalStateException("session unavailable"))
    override fun notificationDeviceRemove(device: String): Result<Unit> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        val key = "device-remove|$device"
        return submitMutation(session, key) { session.notificationDeviceRemove(device, it) }
    }
    override fun notificationDevicePreferences(device: String, enabled: Boolean): Result<Unit> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        val key = "device-prefs|$device|$enabled"
        return submitMutation(session, key) { session.notificationDevicePreferences(device, enabled, it) }
    }

    override fun validatePushRegistration(token: String, appId: String, deployment: String, endpoint: String?): Result<Unit> = runCatching {
        check(authenticatedSession != null) { "authenticated session unavailable" }
        require(token.isNotBlank() && appId.isNotBlank() && deployment.isNotBlank())
        check(bindings.pushRegistrationValidate(1, 1, token, appId, deployment, endpoint) == 0)
    }

    /**
     * @cc [owner:ghuntley,label:security;protocol] android-linked-call-dispatch
     * Generic calls MUST never echo input as success. Only an empty refresh request may return
     * the listing from a successful Rust read on the still-current authenticated session;
     * bootstrap and mutations MUST use their dedicated typed session APIs.
     */
    override suspend fun call(request: MilaFfiRequest): MilaFfiResult {
        return try {
            if (bindings.abiVersion() != 1) return MilaFfiResult.Failure(MilaFfiError.IncompatibleAbi)
            if (request.operation != MilaFfiOperation.Refresh || request.payload.copyBytes().isNotEmpty()) {
                return MilaFfiResult.Failure(MilaFfiError.Unavailable)
            }
            val session = authenticatedSession ?: return MilaFfiResult.Failure(MilaFfiError.Unavailable)
            val listing = runCatching {
                session.readCompleteListing { authenticatedSession === session }
            }.getOrElse { return MilaFfiResult.Failure(MilaFfiError.Unavailable) }
            check(authenticatedSession === session) { "session replaced during refresh" }
            MilaFfiResult.Success(MilaFfiResponse(MilaFfiPayload(listing)))
        } catch (_: UnsatisfiedLinkError) {
            MilaFfiResult.Failure(MilaFfiError.Unavailable)
        } catch (_: IllegalStateException) {
            MilaFfiResult.Failure(MilaFfiError.Unavailable)
        }
    }

    fun canonicalizeRoute(value: String): Result<String> = runCatching {
        bindings.canonicalRoute(value) ?: throw IllegalArgumentException("invalid route")
    }

    fun machineActions(snapshot: ByteArray, host: String, port: Int?, index: Int): Result<Int> = runCatching {
        bindings.machineActions(snapshot, host, port, index) ?: throw IllegalArgumentException("invalid snapshot")
    }

    override fun threadCommandKind(value: String): Result<MilaThreadCommand> = runCatching {
        MilaThreadCommand.fromTag(bindings.threadCommandKind(value))
            ?: throw IllegalArgumentException("unknown thread command")
    }

    override fun machineCommandKind(value: String): Result<MilaMachineCommand> = runCatching {
        MilaMachineCommand.fromTag(bindings.machineCommandKind(value))
            ?: throw IllegalArgumentException("unknown machine command")
    }

    override fun terminalAttach(from: Long, columns: Int, rows: Int, readWrite: Boolean): Result<Unit> = authenticatedTerminal { it.terminalAttach(from, columns, rows, readWrite) }
    override fun terminalInput(length: Int, readWrite: Boolean): Result<Unit> = authenticatedTerminal { it.terminalInput(length, readWrite) }
    override fun terminalResize(columns: Int, rows: Int, readWrite: Boolean): Result<Unit> = authenticatedTerminal { it.terminalResize(columns, rows, readWrite) }
    // Real Porsche refuses the unnamed attach; terminals must name a machine and session.
    override fun terminalOpen(columns: Int, rows: Int, readWrite: Boolean): Result<Long> =
        Result.failure(IllegalStateException("terminal requires a machine"))
    override fun terminalOpen(machineId: UUID, columns: Int, rows: Int): Result<Long> =
        authenticatedValue { it.terminalOpenSession(machineId, columns, rows, milaRequestId()) }
    override fun terminalNew(machineId: UUID): Result<MilaTerminalSessionRef> =
        authenticatedValue { it.terminalNew(machineId, milaRequestId()) }
    override fun terminalAttach(session: MilaTerminalSessionRef, columns: Int, rows: Int): Result<Long> =
        authenticatedValue { it.terminalAttach(session, columns, rows) }
    override fun terminalEnd(session: MilaTerminalSessionRef): Result<Boolean> =
        authenticatedValue { it.terminalEnd(session, milaRequestId()) }
    fun notificationDeviceRegister(susanReply: String, encPubkey: String, label: String? = null, requestId: String = milaRequestId()): Result<ByteArray> =
        authenticatedSession?.notificationDeviceRegister(susanReply, encPubkey, label, System.currentTimeMillis() / 1000, requestId)
            ?: Result.failure(IllegalStateException("session unavailable"))
    /** Closed refusal code for diagnostics; never includes request payloads. */
    fun lastRefusal(): String? = authenticatedSession?.lastRefusal()
    override fun terminalPoll(handle: Long, maxBytes: Int): Result<ByteArray> = authenticatedValue { it.terminalPoll(handle, maxBytes) }
    override fun terminalFrame(handle: Long): Result<MilaTerminalFrame> = authenticatedValue { it.terminalFrame(handle) }
    override fun terminalReadWithin(handle: Long, waitMilliseconds: Int, maxBytes: Int): Result<ByteArray> =
        authenticatedValue { it.terminalReadWithin(handle, waitMilliseconds, maxBytes) }
    override fun terminalInputBytes(handle: Long, bytes: ByteArray): Result<Unit> = authenticatedTerminal { it.terminalInputBytes(handle, bytes) }
    override fun terminalResizeHandle(handle: Long, columns: Int, rows: Int): Result<Unit> = authenticatedTerminal { it.terminalResizeHandle(handle, columns, rows) }
    override fun terminalClose(handle: Long): Result<Unit> = authenticatedTerminal { it.terminalClose(handle) }

    private fun authenticatedTerminal(operation: (MilaSessionHandle) -> Result<Unit>): Result<Unit> = authenticatedValue(operation)
    private fun <T> authenticatedValue(operation: (MilaSessionHandle) -> Result<T>): Result<T> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("authenticated session unavailable"))
        return operation(session)
    }

    private fun status(value: Int): Result<Unit> = if (value == 0) Result.success(Unit) else Result.failure(IllegalArgumentException("terminal operation rejected"))
}

enum class MilaThreadCommand(val tag: Int) {
    List(1), Show(2), Turns(3), Prompt(4), Answer(5), PlanApprove(6),
    PlanRevise(7), Mode(8), Read(9);
    companion object { fun fromTag(tag: Int): MilaThreadCommand? = entries.firstOrNull { it.tag == tag } }
}

enum class MilaMachineCommand(val tag: Int) {
    List(1), Show(2), New(3), Resize(4), Start(5), Stop(6), Pause(7), Resume(8),
    Delete(9), ShareAdd(10), ShareRemove(11), WebShow(12), WebSet(13);
    companion object { fun fromTag(tag: Int): MilaMachineCommand? = entries.firstOrNull { it.tag == tag } }
}
