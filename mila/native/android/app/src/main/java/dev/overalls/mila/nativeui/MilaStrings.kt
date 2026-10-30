package dev.overalls.mila.nativeui

import java.util.Locale
import android.content.Context
import org.json.JSONObject

/** Typed, shared message identities. Translations are kept in native resources at build time. */
internal enum class MilaMessage(val catalogId: String) {
    AppName("appTitle"), Machines("machinesTitle"), Threads("tabThreads"), Settings("settingsTitle"),
    Ready("ready"), Refresh("refresh"), Connecting("signInConnecting"), Connected("connected"),
    Deployments("deploymentsTitle"), DeploymentHost("deploymentHostLabel"), DeploymentHostHint("deploymentHostHint"),
    AddDeployment("addDeployment"), ForgetDeployment("forgetDeployment"), InvalidHost("invalidHost"), SignIn("signInTitle"), SignOut("signOut"), Reconnect("signInReconnect"), ApprovalPending("signInApprove"), OpenApproval("signInOpenBrowser"), ApprovalFingerprint("signInFingerprint"), ApprovalExpired("signInExpired"),
    LockTitle("lockTitle"), LockExplain("lockExplain"), LockUnlock("lockUnlock"), LockFailed("lockFailed"),
    SshKeysTitle("sshKeysTitle"), SshKeysExplain("sshKeysExplain"), SshKeysEmpty("sshKeysEmpty"),
    SshKeyRevoke("sshKeyRevoke"), NotificationsTitle("notificationsTitle"), NotificationEnabled("notificationEnabled"), NotificationRemove("notificationRemove"), SshKeyAlgorithm("sshKeyAlgorithm"), SshKeyThisDevice("sshKeyThisDevice"),
    RuntimeUnavailable("runtimeUnavailable"), NoAction("noAction"), Terminal("tabTerminals"), Attach("terminalAttach"), Input("terminalAttach"), Resize("actionResize"), MachineActions("machineMore"), MachineName("machineName"), MachineCpu("kvCpu"), MachineMemory("memoryFieldMib"), MachineDisk("diskFieldGib"), MachineCreate("actionCreate"), MachineCreated("machineCreated"), MachineCreateFailed("machineCreateFailed"), SharePrincipal("sharePrincipal"), ShareAdd("shareAdd"), ShareRemove("shareRemove"), ShareRejected("shareRejected"), ShareAdded("shareAdded"), ShareRemoved("shareRemoved"), Appearance("appearance"), Locale("locale"), ThreadCommands("tabThreads"), NoCommand("noAction"), WebEndpoint("webEndpoint"), WebShow("webOpen"), WebSave("webSave"), WebPort("webPort"), WebPublic("webPublic"), WebPrivate("webPrivate"),
    FieldInvalid("machineFieldInvalid"), RequestWaiting("requestWaiting"), RequestSucceeded("requestSucceeded"), RequestFailed("requestFailed"), RequestRefused("requestRefused"),
    ShareRole("sharingRole"), ShareRoleViewer("shareRoleViewer"), ShareRoleOperator("shareRoleOperator"), ShareRoleManager("shareRoleManager"),
    MachineNotFound("machineNotFound"), ShareRoute("webShare"), LinkRefused("linkRefused"), LockUnavailable("lockUnavailable"),
    TerminalNew("terminalNew"), TerminalReconnect("terminalReconnect"), TerminalSend("terminalSend"), TerminalClose("terminalClose"),
    TerminalLive("terminalLive"), TerminalAttaching("terminalAttaching"), TerminalEnded("terminalEnded"),
    TerminalRefused("terminalRefused"), TerminalInvalid("terminalInvalid"), TerminalSignedOut("terminalSignedOut"),
}

internal object MilaStrings {
    /** Locale bundles shipped by the native Android artifact. Keep this list bounded and typed. */
    // Keep the picker in lockstep with mila-localization's generated catalog
    // set. The JSON bundles and the Rust locale policy are the source of truth;
    // this list only gives the shell a deterministic ordering for its UI.
    val supportedLocales: List<String> = listOf(
        "en", "zh-Hans", "hi", "es", "ar", "fr", "bn", "pt-BR", "pt-PT",
        "ru", "ur", "id", "de", "ja", "pcm", "mr", "te", "tr", "ta", "vi",
        "ko", "fil", "et", "fi", "sv", "arz", "sw", "ha",
    )
    private var catalog: Map<String, String> = emptyMap()
    private val english = mapOf(
        MilaMessage.AppName to "Mila", MilaMessage.Machines to "Machines", MilaMessage.Threads to "Threads",
        MilaMessage.Settings to "Settings", MilaMessage.Ready to "Ready", MilaMessage.Refresh to "Refresh",
        MilaMessage.Deployments to "Deployments", MilaMessage.DeploymentHost to "Deployment host", MilaMessage.DeploymentHostHint to "overalls.example", MilaMessage.AddDeployment to "Add deployment", MilaMessage.ForgetDeployment to "Forget", MilaMessage.InvalidHost to "Enter a host name such as overalls.example.", MilaMessage.SignIn to "Sign in", MilaMessage.SignOut to "Sign out", MilaMessage.Reconnect to "Reconnect", MilaMessage.ApprovalPending to "Approve this device in your browser, then return here.", MilaMessage.OpenApproval to "Open approval page", MilaMessage.ApprovalFingerprint to "Key fingerprint", MilaMessage.ApprovalExpired to "The approval link is no longer valid. Start again to get a new one.",
        MilaMessage.LockTitle to "App lock", MilaMessage.LockExplain to "Authenticate to continue.", MilaMessage.LockUnlock to "Unlock", MilaMessage.LockFailed to "Authentication failed.",
        MilaMessage.SshKeysTitle to "SSH keys", MilaMessage.SshKeysExplain to "Keys approved to sign in to your account on this deployment. A revoked key must be approved again before it can sign in.", MilaMessage.SshKeysEmpty to "No approved keys.", MilaMessage.SshKeyRevoke to "Revoke", MilaMessage.SshKeyAlgorithm to "Type", MilaMessage.SshKeyThisDevice to "This device", MilaMessage.NotificationsTitle to "Notifications", MilaMessage.NotificationEnabled to "Enabled", MilaMessage.NotificationRemove to "Remove",
        MilaMessage.Connecting to "Connecting…", MilaMessage.Connected to "Connected",
        MilaMessage.RuntimeUnavailable to "Native runtime unavailable", MilaMessage.NoAction to "No action selected", MilaMessage.Terminal to "Terminals", MilaMessage.Attach to "Attach", MilaMessage.Input to "Input", MilaMessage.Resize to "Resize", MilaMessage.MachineActions to "Machine actions", MilaMessage.MachineName to "Name", MilaMessage.MachineCpu to "CPU", MilaMessage.MachineMemory to "Memory (MiB)", MilaMessage.MachineDisk to "Disk (GiB)", MilaMessage.MachineCreate to "Create", MilaMessage.MachineCreated to "Created", MilaMessage.MachineCreateFailed to "Machine creation failed", MilaMessage.SharePrincipal to "Share principal", MilaMessage.ShareAdd to "Share add", MilaMessage.ShareRemove to "Share remove", MilaMessage.ShareRejected to "Share rejected", MilaMessage.ShareAdded to "Share added", MilaMessage.ShareRemoved to "Share removed", MilaMessage.Appearance to "Appearance", MilaMessage.Locale to "Locale", MilaMessage.ThreadCommands to "Thread commands", MilaMessage.NoCommand to "No command selected", MilaMessage.WebEndpoint to "Web endpoint", MilaMessage.WebShow to "Show", MilaMessage.WebSave to "Save", MilaMessage.WebPort to "Port", MilaMessage.WebPublic to "Public", MilaMessage.WebPrivate to "Private",
        MilaMessage.FieldInvalid to "Check this value.", MilaMessage.RequestWaiting to "Waiting for the request to finish…", MilaMessage.RequestSucceeded to "Done.", MilaMessage.RequestFailed to "The request failed.", MilaMessage.RequestRefused to "The deployment refused the request.",
        MilaMessage.ShareRole to "Role", MilaMessage.ShareRoleViewer to "viewer", MilaMessage.ShareRoleOperator to "operator", MilaMessage.ShareRoleManager to "manager",
        MilaMessage.MachineNotFound to "This machine is not available.", MilaMessage.ShareRoute to "Share", MilaMessage.LinkRefused to "Mila cannot open this link.", MilaMessage.LockUnavailable to "App lock is not available on this device.",
        MilaMessage.TerminalNew to "New terminal", MilaMessage.TerminalReconnect to "Reconnect", MilaMessage.TerminalSend to "Send", MilaMessage.TerminalClose to "Close",
        MilaMessage.TerminalLive to "live", MilaMessage.TerminalAttaching to "attaching", MilaMessage.TerminalEnded to "The terminal session ended.",
        MilaMessage.TerminalRefused to "The deployment refused to attach to this terminal session.", MilaMessage.TerminalInvalid to "Mila could not attach to this terminal session.",
        MilaMessage.TerminalSignedOut to "This device is no longer authorized. Sign in again to attach.",
    )
    fun configure(context: Context, locale: Locale = Locale.getDefault()) {
        val tag = locale.toLanguageTag().replace('_', '-')
        val candidates = listOf(tag, locale.language, "en")
        catalog = candidates.asSequence().mapNotNull { candidate ->
            runCatching {
                val json = context.assets.open("${candidate}.json").bufferedReader().use { it.readText() }
                val messages = JSONObject(json).getJSONObject("domains").getJSONObject("mila").getJSONArray("messages")
                buildMap {
                    for (index in 0 until messages.length()) {
                        val message = messages.getJSONObject(index)
                        val forms = message.getJSONArray("forms")
                        if (forms.length() > 0) put(message.getString("id"), forms.getString(0))
                    }
                }
            }.getOrNull()
        }.firstOrNull().orEmpty()
    }

    fun text(message: MilaMessage, locale: Locale = Locale.getDefault()): String =
        catalog[message.catalogId] ?: english.getValue(message)
}
