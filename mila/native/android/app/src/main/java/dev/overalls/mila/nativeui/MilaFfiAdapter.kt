package dev.overalls.mila.nativeui

import java.util.UUID
import java.net.URI

sealed interface MilaRoute {
    data object Machines : MilaRoute
    data class Machine(val id: UUID) : MilaRoute
    data object Threads : MilaRoute
    data class Thread(val id: UUID) : MilaRoute
    data object Settings : MilaRoute
}

/** Parses only navigation routes; query strings and command-like paths are rejected. */
fun parseMilaRoute(value: String): MilaRoute? {
    val uri = runCatching { URI(value) }.getOrNull() ?: return null
    if (uri.scheme != "overalls" || uri.rawQuery != null || uri.rawFragment != null || uri.rawAuthority?.contains('@') == true) return null
    val path = uri.rawPath ?: return null
    if (path.isNotEmpty() && path != "/" && path.contains("//")) return null
    val parts = path.trim('/').takeIf { it.isNotEmpty() }?.split('/') ?: emptyList()
    if (parts.any { it.contains('%') }) return null
    uri.host ?: return null
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

private fun String.toUuid(): UUID? = runCatching { UUID.fromString(this) }.getOrNull()

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
interface MilaFfiAdapter {
    suspend fun call(request: MilaFfiRequest): MilaFfiResult
    /** Rust validates provider metadata while borrowing the token for this call only. */
    fun validatePushRegistration(token: String, appId: String, deployment: String, endpoint: String?): Result<Unit> =
        Result.failure(IllegalStateException("push registration unavailable"))
    /** The currently authenticated session's key store, or null while signed out. */
    fun sshKeyStore(): MilaSshKeyStore? = null
    /** Executes a Rust-classified action for an authenticated machine session. */
    suspend fun machineResize(machineId: UUID, cpu: Int, memoryMiB: Int, diskGiB: Int): Result<Unit> = Result.failure(IllegalStateException("machine resize unavailable"))
    /** Creates a machine through the authenticated session; unauthenticated adapters refuse. */
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
    /** Writes input bytes to the Rust-owned PTY. */
    fun terminalInputBytes(handle: Long, bytes: ByteArray): Result<Unit> =
        terminalInput(bytes.size, true)
    fun terminalResizeHandle(handle: Long, columns: Int, rows: Int): Result<Unit> =
        terminalResize(columns, rows, true)
    /** Closes the Rust-owned PTY handle. */
    fun terminalClose(handle: Long): Result<Unit> = Result.success(Unit)
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
    fun sessionDevicePreferences(handle: Long, device: String, enabled: Boolean): Int = -12
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
    /** Registers this device with Susan's key-issuance reply; returns Porsche's JSON receipt. */
    fun sessionDeviceRegister(handle: Long, platform: Int, susanReply: String, encPubkey: String, label: String?, now: Long): ByteArray? = null
    /** `{"error": <closed code or null>}` for the session's last Porsche refusal. */
    fun sessionLastRefusal(handle: Long): ByteArray? = null
    fun sessionTerminalPoll(handle: Long, maxBytes: Int): ByteArray? = null
    fun sessionTerminalInputBytes(handle: Long, bytes: ByteArray): Int = -12
    fun sessionTerminalResizeHandle(handle: Long, columns: Int, rows: Int): Int = -12
    fun sessionTerminalClose(handle: Long): Int = -12
    /** Revokes one opaque key id using a caller-supplied at-most-once request id. */
    fun sessionSshKeyRevoke(handle: Long, key: String, requestId: String): Int = -12
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
        return nativeSessionConnect(trust, host, publicKey, port, timeoutMs, signer)?.let(::MilaSessionHandle)
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
    override fun sessionMachineCreate(handle: Long, name: String, cpu: Int, memory: Int, disk: Int, requestId: String): Int = nativeSessionMachineCreate(handle, name, cpu, memory, disk, requestId)
    override fun sessionShareMutation(handle: Long, machine: String, email: String, role: String?, add: Boolean, requestId: String): Int = nativeSessionShareMutation(handle, machine, email, role, add, requestId)
    override fun sessionWebShow(handle: Long, machine: String): ByteArray? = nativeSessionWebShow(handle, machine)
    override fun sessionWebSet(handle: Long, machine: String, port: Int, public: Boolean, revision: Long, requestId: String): Int = nativeSessionWebSet(handle, machine, port, public, revision, requestId)
    override fun sessionThreadAction(handle: Long, thread: String, command: String, secondary: String?, input: String?, requestId: String?): ByteArray? = nativeSessionThreadAction(handle, thread, command, secondary, input, requestId)
    override fun sessionSshKeys(handle: Long): ByteArray? = nativeSessionSshKeys(handle)
    override fun sessionDeviceList(handle: Long): ByteArray? = nativeSessionDeviceList(handle)
    override fun sessionDeviceRemove(handle: Long, device: String): Int = nativeSessionDeviceRemove(handle, device)
    override fun sessionDevicePreferences(handle: Long, device: String, enabled: Boolean): Int = nativeSessionDevicePreferences(handle, device, enabled)
    override fun sessionSshKeyRevoke(handle: Long, key: String, requestId: String): Int = nativeSessionSshKeyRevoke(handle, key, requestId)
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
    override fun sessionDeviceRegister(handle: Long, platform: Int, susanReply: String, encPubkey: String, label: String?, now: Long): ByteArray? = nativeSessionDeviceRegister(handle, platform, susanReply, encPubkey, label, now)
    override fun sessionLastRefusal(handle: Long): ByteArray? = nativeSessionLastRefusal(handle)
    override fun sessionTerminalPoll(handle: Long, maxBytes: Int): ByteArray? = nativeSessionTerminalPoll(handle, maxBytes)
    override fun sessionTerminalInputBytes(handle: Long, bytes: ByteArray): Int = nativeSessionTerminalInputBytes(handle, bytes)
    override fun sessionTerminalResizeHandle(handle: Long, columns: Int, rows: Int): Int = nativeSessionTerminalResizeHandle(handle, columns, rows)
    override fun sessionTerminalClose(handle: Long): Int = nativeSessionTerminalClose(handle)

    @JvmStatic
    external fun nativeAbiVersion(): Int

    @JvmStatic
    external fun nativeCanonicalRoute(value: String): String?

    @JvmStatic
    external fun nativeMachineActions(snapshot: ByteArray, host: String, port: Int, hasPort: Boolean, index: Int): Int

    @JvmStatic
    external fun nativeSessionConnect(trust: ByteArray, host: String, publicKey: String, port: Int, timeoutMs: Int, signer: MilaDeviceKey): Long?
    @JvmStatic
    external fun nativeTrustDocumentReconcile(pinned: ByteArray?, fetched: ByteArray?, host: String, now: Long): ByteArray?
    @JvmStatic
    external fun nativeSessionRead(handle: Long, more: Boolean): Int
    @JvmStatic external fun nativeSessionWhoami(handle: Long): ByteArray?
    @JvmStatic external fun nativeSessionMachineAction(handle: Long, machine: String, action: String, requestId: String): Int
    @JvmStatic external fun nativeSessionMachineResize(handle: Long, machine: String, cpu: Int, memory: Int, disk: Int, requestId: String): Int
    @JvmStatic external fun nativeSessionMachineCreate(handle: Long, name: String, cpu: Int, memory: Int, disk: Int, requestId: String): Int
    @JvmStatic external fun nativeSessionShareMutation(handle: Long, machine: String, email: String, role: String?, add: Boolean, requestId: String): Int
    @JvmStatic external fun nativeSessionWebShow(handle: Long, machine: String): ByteArray?
    @JvmStatic external fun nativeSessionWebSet(handle: Long, machine: String, port: Int, public: Boolean, revision: Long, requestId: String): Int
    @JvmStatic external fun nativeSessionThreadAction(handle: Long, thread: String, command: String, secondary: String?, input: String?, requestId: String?): ByteArray?
    @JvmStatic external fun nativeSessionSshKeys(handle: Long): ByteArray?
    @JvmStatic external fun nativeSessionDeviceList(handle: Long): ByteArray?
    @JvmStatic external fun nativeSessionDeviceRemove(handle: Long, device: String): Int
    @JvmStatic external fun nativeSessionDevicePreferences(handle: Long, device: String, enabled: Boolean): Int
    @JvmStatic external fun nativeSessionSshKeyRevoke(handle: Long, key: String, requestId: String): Int
    @JvmStatic external fun nativePushRegistrationValidate(provider: Int, environment: Int, token: String, appId: String, deployment: String, endpoint: String?): Int
    @JvmStatic
    external fun nativeSessionListing(handle: Long): ByteArray?
    @JvmStatic
    external fun nativeSessionSnapshot(handle: Long): ByteArray?
    @JvmStatic
    external fun nativeSessionClose(handle: Long): Int
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
    @JvmStatic external fun nativeSessionDeviceRegister(handle: Long, platform: Int, susanReply: String, encPubkey: String, label: String?, now: Long): ByteArray?
    @JvmStatic external fun nativeSessionLastRefusal(handle: Long): ByteArray?
    @JvmStatic external fun nativeSessionTerminalPoll(handle: Long, maxBytes: Int): ByteArray?
    @JvmStatic external fun nativeSessionTerminalInputBytes(handle: Long, input: ByteArray): Int
    @JvmStatic external fun nativeSessionTerminalResizeHandle(handle: Long, columns: Int, rows: Int): Int
    @JvmStatic external fun nativeSessionTerminalClose(handle: Long): Int
}

/** Porsche at-most-once request identity accepted by every authenticated mutation. */
internal val MILA_REQUEST_ID: Regex = Regex("^porsche-[0-9a-f]{32}$")

/** Mints one fresh request id per user submission; callers never reuse it across submissions. */
internal fun milaRequestId(): String = "porsche-" + UUID.randomUUID().toString().replace("-", "")

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
        check(!closed); require(cpu in 1..256); require(memoryMiB in 256..1_048_576); require(diskGiB in 1..65_536); require(requestId.matches(Regex("^porsche-[0-9a-f]{32}$")))
        check(bindings.sessionMachineResize(nativeHandle, machine.toString(), cpu, memoryMiB, diskGiB, requestId) == 0)
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
    @Synchronized fun terminalOpenSession(machine: UUID, columns: Int, rows: Int, requestId: String): Result<Long> = runCatching {
        check(!closed); require(requestId.matches(MILA_REQUEST_ID)); require(columns in 1..4096 && rows in 1..512)
        val receipt = bindings.sessionTerminalNew(nativeHandle, machine.toString(), requestId) ?: error("terminal new refused")
        require(receipt.size <= 64 * 1024) { "terminal receipt exceeds bound" }
        val result = org.json.JSONObject(receipt.toString(Charsets.UTF_8)).getJSONObject("result")
        val terminal = result.getString("session_id")
        require(terminal.matches(Regex("^[A-Za-z0-9-]{1,64}$"))) { "invalid terminal session id" }
        bindings.sessionTerminalAttachSession(nativeHandle, machine.toString(), terminal, columns, rows).takeIf { it > 0 }
            ?: error("terminal attach rejected")
    }
    /** Registers this device; the Susan reply carries the push key and never enters UI state. */
    @Synchronized fun notificationDeviceRegister(susanReply: String, encPubkey: String, label: String?, now: Long): Result<ByteArray> = runCatching {
        check(!closed); require(susanReply.length <= 4096 && encPubkey.length <= 64 && (label == null || label.length <= 256))
        bindings.sessionDeviceRegister(nativeHandle, 1, susanReply, encPubkey, label, now) ?: error("device registration refused")
    }
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
    @Synchronized fun notificationDeviceRemove(device: String): Result<Unit> = runCatching {
        check(!closed); require(device.matches(Regex("^[A-Za-z0-9._:-]{1,128}$")))
        check(bindings.sessionDeviceRemove(nativeHandle, device) == 0)
    }
    @Synchronized fun notificationDevicePreferences(device: String, enabled: Boolean): Result<Unit> = runCatching {
        check(!closed); require(device.matches(Regex("^[A-Za-z0-9._:-]{1,128}$")))
        check(bindings.sessionDevicePreferences(nativeHandle, device, enabled) == 0)
    }
    /** Revokes one opaque key identity exactly once on this session. */
    @Synchronized fun sshKeyRevoke(key: String, requestId: String): Result<Unit> = runCatching {
        check(!closed)
        require(key.isNotBlank())
        require(requestId.matches(Regex("^porsche-[0-9a-f]{32}$")))
        check(bindings.sessionSshKeyRevoke(nativeHandle, key, requestId) == 0)
    }
    @Synchronized override fun close() { if (!closed) { bindings.sessionClose(nativeHandle); closed = true } }
}

/** Typed Android adapter. Native linkage is lazy so the UI remains testable without a device. */
class LinkedMilaFfiAdapter(
    private val bindings: MilaRustBindings = MilaRustFfi,
) : MilaFfiAdapter, MilaSessionConnector {
    @Volatile private var authenticatedSession: MilaSessionHandle? = null
    @Volatile private var authenticatedFingerprint: String? = null

    /** Binds the adapter to the already certificate-authenticated session. */
    override fun bindSession(session: MilaSessionHandle?) {
        authenticatedSession?.close()
        authenticatedSession = session
        if (session == null) authenticatedFingerprint = null
    }

    override fun connect(deployment: MilaDeployment, config: MilaSessionConnectConfig, signer: MilaDeviceKey): MilaSessionHandle? =
        bindings.sessionConnect(config.trustDocument.copyOf(), deployment.host, config.publicKey,
            deployment.port, config.timeoutMs, signer)?.also { authenticatedFingerprint = milaSshFingerprint(config.publicKey) }

    override suspend fun machineResize(machineId: UUID, cpu: Int, memoryMiB: Int, diskGiB: Int): Result<Unit> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        return session.machineResize(machineId, cpu, memoryMiB, diskGiB, "porsche-" + UUID.randomUUID().toString().replace("-", ""))
    }
    override suspend fun machineCreate(request: MilaMachineCreateRequest): Result<Unit> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        return session.machineCreate(request, milaRequestId())
    }
    override suspend fun machineShare(machineId: UUID, principal: MilaSharePrincipal, role: MilaShareRole?): Result<Unit> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        return session.shareMutation(machineId, principal, role, milaRequestId())
    }
    override suspend fun machineAction(machineId: UUID, command: MilaMachineCommand): Result<Unit> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        val requestId = "porsche-" + java.util.UUID.randomUUID().toString().replace("-", "")
        return session.machineAction(machineId, command, requestId)
    }
    override suspend fun webShow(machineId: UUID): Result<String> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        return session.webShow(machineId).map { it.toString(Charsets.UTF_8) }
    }
    override suspend fun webSet(machineId: UUID, port: Int, public: Boolean, revision: Long): Result<Unit> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        return session.webSet(machineId, port, public, revision, "porsche-" + UUID.randomUUID().toString().replace("-", ""))
    }
    override suspend fun threadAction(threadId: UUID, command: MilaThreadCommand, input: String?, secondary: UUID?): Result<Unit> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        val payload = session.threadAction(threadId, command, secondary = secondary, input = input, requestId = if (command == MilaThreadCommand.Prompt || command == MilaThreadCommand.Answer || command == MilaThreadCommand.PlanApprove || command == MilaThreadCommand.PlanRevise) "porsche-" + UUID.randomUUID().toString().replace("-", "") else null)
        return payload.map { Unit }
    }
    override suspend fun refreshListing(): Result<MilaSessionListing> {
        val session = authenticatedSession ?: return Result.failure(IllegalStateException("session unavailable"))
        return runCatching {
            check(session.readMachines() == 0) { "machine refresh refused" }
            MilaSessionListing.decode(session.listing())
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

    fun notificationDevices(): Result<ByteArray> = authenticatedSession?.notificationDevices()
        ?: Result.failure(IllegalStateException("session unavailable"))
    fun notificationDeviceRemove(device: String): Result<Unit> = authenticatedSession?.notificationDeviceRemove(device)
        ?: Result.failure(IllegalStateException("session unavailable"))
    fun notificationDevicePreferences(device: String, enabled: Boolean): Result<Unit> = authenticatedSession?.notificationDevicePreferences(device, enabled)
        ?: Result.failure(IllegalStateException("session unavailable"))

    override fun validatePushRegistration(token: String, appId: String, deployment: String, endpoint: String?): Result<Unit> = runCatching {
        check(authenticatedSession != null) { "authenticated session unavailable" }
        require(token.isNotBlank() && appId.isNotBlank() && deployment.isNotBlank())
        check(bindings.pushRegistrationValidate(1, 1, token, appId, deployment, endpoint) == 0)
    }

    override suspend fun call(request: MilaFfiRequest): MilaFfiResult {
        return try {
            if (bindings.abiVersion() != 1) MilaFfiResult.Failure(MilaFfiError.IncompatibleAbi)
            else MilaFfiResult.Success(MilaFfiResponse(request.payload))
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

    override fun terminalAttach(from: Long, columns: Int, rows: Int, readWrite: Boolean): Result<Unit> = authenticatedTerminal { authenticatedSession!!.terminalAttach(from, columns, rows, readWrite) }
    override fun terminalInput(length: Int, readWrite: Boolean): Result<Unit> = authenticatedTerminal { authenticatedSession!!.terminalInput(length, readWrite) }
    override fun terminalResize(columns: Int, rows: Int, readWrite: Boolean): Result<Unit> = authenticatedTerminal { authenticatedSession!!.terminalResize(columns, rows, readWrite) }
    // Real Porsche refuses the unnamed attach; terminals must name a machine and session.
    override fun terminalOpen(columns: Int, rows: Int, readWrite: Boolean): Result<Long> =
        Result.failure(IllegalStateException("terminal requires a machine"))
    override fun terminalOpen(machineId: UUID, columns: Int, rows: Int): Result<Long> =
        authenticatedValue { authenticatedSession!!.terminalOpenSession(machineId, columns, rows, milaRequestId()) }
    fun notificationDeviceRegister(susanReply: String, encPubkey: String, label: String? = null): Result<ByteArray> =
        authenticatedSession?.notificationDeviceRegister(susanReply, encPubkey, label, System.currentTimeMillis() / 1000)
            ?: Result.failure(IllegalStateException("session unavailable"))
    /** Closed refusal code for diagnostics; never includes request payloads. */
    fun lastRefusal(): String? = authenticatedSession?.lastRefusal()
    override fun terminalPoll(handle: Long, maxBytes: Int): Result<ByteArray> = authenticatedValue { authenticatedSession!!.terminalPoll(handle, maxBytes) }
    override fun terminalInputBytes(handle: Long, bytes: ByteArray): Result<Unit> = authenticatedTerminal { authenticatedSession!!.terminalInputBytes(handle, bytes) }
    override fun terminalResizeHandle(handle: Long, columns: Int, rows: Int): Result<Unit> = authenticatedTerminal { authenticatedSession!!.terminalResizeHandle(handle, columns, rows) }
    override fun terminalClose(handle: Long): Result<Unit> = authenticatedTerminal { authenticatedSession!!.terminalClose(handle) }

    private fun authenticatedTerminal(operation: () -> Result<Unit>): Result<Unit> =
        if (authenticatedSession == null) Result.failure(IllegalStateException("authenticated session unavailable")) else operation()
    private fun <T> authenticatedValue(operation: () -> Result<T>): Result<T> =
        if (authenticatedSession == null) Result.failure(IllegalStateException("authenticated session unavailable")) else operation()

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
