package dev.overalls.mila.nativeui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.OutlinedTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.State
import androidx.compose.runtime.remember
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import java.util.Locale
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay

internal data class MachineCommandChoice(val label: String, val command: String)

/**
 * @cc [owner:ghuntley,label:architecture] android-machine-command-catalog
 * Every machine command presented by the Android shell MUST be classified through the closed
 * Rust command catalog before it is shown as selected; the UI must not invent operation tags.
 */
internal val machineCommandChoices = listOf(
    MachineCommandChoice("List", "ls"),
    MachineCommandChoice("Show", "show"),
    MachineCommandChoice("New", "new"),
    MachineCommandChoice("Resize", "resize"),
    MachineCommandChoice("Start", "start"),
    MachineCommandChoice("Stop", "stop"),
    MachineCommandChoice("Pause", "pause"),
    MachineCommandChoice("Resume", "resume"),
    MachineCommandChoice("Delete", "rm"),
    MachineCommandChoice("Share add", "share add"),
    MachineCommandChoice("Share remove", "share remove"),
    MachineCommandChoice("Web show", "web show"),
    MachineCommandChoice("Web set", "web set"),
)

/** Commands exposed by the Rust thread catalog; arguments are intentionally not accepted here. */
internal val threadCommandChoices = listOf(
    "List" to "thread ls",
    "Show" to "thread show",
    "Turns" to "thread turns",
    "Prompt" to "thread prompt",
    "Answer" to "thread answer",
    "Plan approve" to "thread plan approve",
    "Plan revise" to "thread plan revise",
    "Mode" to "thread mode",
    "Read" to "thread read",
)

/**
 * @cc [owner:ghuntley,label:security] android-native-deployment-selection
 * The Android shell MUST offer only persisted or user-validated deployments. It MUST NOT invent a
 * host, call the session-material provider without a selected deployment, or pass a different host
 * to that provider than the one selected by the user.
 */
@Composable
fun MilaNativeRoot(
    adapter: MilaFfiAdapter? = null,
    materialProvider: MilaSessionMaterialProvider? = null,
    initialRoute: MilaRoute? = null,
    routeState: State<MilaRoute>? = null,
    appLockController: MilaAppLockController? = null,
    onAuthenticatedRoute: (() -> Unit)? = null,
    onSessionEnded: (() -> Unit)? = null,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    // Keep the default native adapter across recompositions. A live Rust session is
    // owned by this adapter and must not be replaced by a recomposition.
    val sessionAdapter = remember(adapter) { adapter ?: LinkedMilaFfiAdapter() }
    val sessionMaterialProvider = remember(materialProvider, context) {
        materialProvider ?: AndroidMilaSessionMaterialProvider(context)
    }
    val approvalBrowser = remember(context) { AndroidMilaApprovalBrowser(context) }
    var route by remember { mutableStateOf(initialRoute ?: MilaRoute.Machines) }
    LaunchedEffect(routeState?.value) { routeState?.value?.let { route = it } }
    LaunchedEffect(initialRoute) { initialRoute?.let { route = it } }
    var connection by remember { mutableStateOf<MilaSessionConnection>(MilaSessionConnection.Idle) }
    val localContext = LocalContext.current
    val deploymentStore = remember(localContext) { MilaSharedPreferencesDeploymentStore(localContext.getSharedPreferences("mila.deployment", 0)) }
    val savedDeployments = remember {
        val persisted = deploymentStore.readAll()
        val selected = deploymentStore.read()
        if (selected == null) persisted else listOf(selected) + persisted.filterNot { it.host == selected.host && it.port == selected.port }
    }
    val deployment = remember { MilaDeploymentSelection(savedDeployments) }
    var selectedDeployment by remember { mutableStateOf(deployment.selected) }
    var deploymentEntries by remember { mutableStateOf(deployment.deployments) }
    var hostInput by remember { mutableStateOf(selectedDeployment?.host.orEmpty()) }
    var hostInvalid by remember { mutableStateOf(false) }
    val signIn = remember(sessionAdapter) { MilaSignInController(sessionAdapter, deploymentStore) }
    val machineDetail = remember(sessionAdapter) { MilaMachineDetailController(sessionAdapter) }
    val threadDetail = remember(sessionAdapter) { MilaThreadDetailController(sessionAdapter) }
    val machineForm = remember(sessionAdapter) { MilaMachineFormController(sessionAdapter) }
    var signInState by remember { mutableStateOf<MilaSignInState>(MilaSignInState.SignedOut) }
    // A listing re-read on the same authenticated session after a mutation. It is discarded on
    // every sign-in transition so a previous session's machines never stay actionable.
    var refreshedListing by remember { mutableStateOf<MilaSessionListing?>(null) }
    LaunchedEffect(signInState) {
        refreshedListing = null
        if (signInState is MilaSignInState.SignedIn) onAuthenticatedRoute?.invoke() else onSessionEnded?.invoke()
    }
    var threadListing by remember { mutableStateOf<MilaThreadListing?>(null) }
    // Changing the selected deployment fences the authenticated session immediately. This keeps
    // machine/thread data from the previous host from remaining actionable while the user edits
    // or switches deployments.
    fun resetSessionForDeploymentChange() {
        signIn.close()
        signInState = MilaSignInState.SignedOut
        threadListing = null
    }
    DisposableEffect(signIn) {
        onDispose { signIn.close() }
    }
    fun refresh() { scope.launch {
        val current = signInState
        if (current is MilaSignInState.SignedIn) {
            // Authenticated refresh re-reads through the bound Rust session only.
            sessionAdapter.refreshListing().onSuccess { fresh -> if (signInState === current) refreshedListing = fresh }
            return@launch
        }
        connection = MilaSessionConnection.Refreshing
        connection = MilaSessionRefresher.refresh(sessionAdapter)
    } }
    fun reconnect(selected: MilaDeployment) { scope.launch {
        signInState = MilaSignInState.Connecting(selected)
        sessionMaterialProvider.resolve(selected).fold(
            onSuccess = { material ->
                signIn.reconnect(material.config, material.signer)
                signInState = signIn.state
            },
            onFailure = { signInState = MilaSignInState.Failed(selected, MilaFfiError.Unavailable) },
        )
    } }
    val status = when (connection) {
        MilaSessionConnection.Idle -> MilaStrings.text(MilaMessage.Ready)
        MilaSessionConnection.Refreshing -> MilaStrings.text(MilaMessage.Connecting)
        is MilaSessionConnection.Connected -> MilaStrings.text(MilaMessage.Connected)
        is MilaSessionConnection.Failed -> MilaStrings.text(MilaMessage.RuntimeUnavailable)
    }
    val signedIn = signInState is MilaSignInState.SignedIn
    val listing = (signInState as? MilaSignInState.SignedIn)?.let { refreshedListing ?: it.listing } ?: (connection as? MilaSessionConnection.Connected)?.listing
    machineDetail.setSession(signedIn, listing)
    threadDetail.setSession(signedIn, threadListing)
    machineForm.setSession(signedIn, (signInState as? MilaSignInState.SignedIn)?.let { listing })
    val resolution = resolveMilaRoute(route, signedIn, listing, threadListing)
    LaunchedEffect(route, resolution, listing, threadListing) {
        if (resolution != MilaRouteResolution.Resolved) return@LaunchedEffect
        when (val target = route) {
            is MilaRoute.Machine -> machineDetail.select(target.id)
            is MilaRoute.Thread -> threadDetail.select(target.id)
            else -> Unit
        }
    }
    Column(modifier = Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(MilaStrings.text(MilaMessage.AppName), style = MaterialTheme.typography.headlineSmall)
        MilaDeploymentPicker(
            deployments = deploymentEntries,
            selected = selectedDeployment,
            host = hostInput,
            invalidHost = hostInvalid,
            onHostChanged = {
                hostInput = it
                hostInvalid = false
            },
            onSelect = { selected ->
                if (selectedDeployment != selected) resetSessionForDeploymentChange()
                deployment.select(selected.host, selected.port)
                deploymentStore.write(selected)
                selectedDeployment = selected
                hostInput = selected.label
                hostInvalid = false
            },
            onAdd = {
                parseMilaDeploymentHost(hostInput).fold(
                    onSuccess = { added ->
                        if (selectedDeployment != added) resetSessionForDeploymentChange()
                        deployment.add(added)
                        deployment.select(added.host, added.port)
                        deploymentStore.write(added)
                        deploymentEntries = deployment.deployments
                        selectedDeployment = added
                        hostInput = added.label
                        hostInvalid = false
                    },
                    onFailure = { hostInvalid = true },
                )
            },
            onForget = { forgotten ->
                if (deployment.remove(forgotten.host, forgotten.port)) {
                    deploymentStore.remove(forgotten)
                    deploymentEntries = deployment.deployments
                    selectedDeployment = deployment.selected
                    hostInput = selectedDeployment?.label.orEmpty()
                    hostInvalid = false
                    resetSessionForDeploymentChange()
                }
            },
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button({
                selectedDeployment?.let { selected ->
                    scope.launch {
                        signInState = MilaSignInState.Connecting(selected)
                        sessionMaterialProvider.resolve(selected).fold(
                            onSuccess = { material ->
                                signIn.signIn(selected, material.config, material.signer)
                                signInState = signIn.state
                            },
                            onFailure = {
                                signInState = MilaSignInState.Failed(selected, MilaFfiError.Unavailable)
                            },
                        )
                    }
                }
            }, enabled = selectedDeployment != null) { Text(MilaStrings.text(MilaMessage.SignIn)) }
            Button({
                signIn.signOut()
                signInState = MilaSignInState.SignedOut
                threadListing = null
            }, enabled = signInState !is MilaSignInState.SignedOut && signInState !is MilaSignInState.Connecting) {
                Text(MilaStrings.text(MilaMessage.SignOut))
            }
            Button({ route = MilaRoute.Machines }) { Text(MilaStrings.text(MilaMessage.Machines)) }
            Button({ route = MilaRoute.Threads }) { Text(MilaStrings.text(MilaMessage.Threads)) }
            Button({ route = MilaRoute.Settings }) { Text(MilaStrings.text(MilaMessage.Settings)) }
            Button(enabled = signedIn, onClick = {
                MilaShareIntentFactory.authenticatedChooser(route, signInState is MilaSignInState.SignedIn)?.let(context::startActivity)
            }) { Text(MilaStrings.text(MilaMessage.ShareRoute)) }
            Button(::refresh) { Text(MilaStrings.text(MilaMessage.Refresh)) }
        }
        Text(status, style = MaterialTheme.typography.labelSmall)
        if (signInState is MilaSignInState.AwaitingApproval) {
            val awaiting = signInState as MilaSignInState.AwaitingApproval
            LaunchedEffect(awaiting.approval.url) { approvalBrowser.open(awaiting.approval) }
            Text(MilaStrings.text(MilaMessage.ApprovalPending), style = MaterialTheme.typography.bodyMedium)
            Text("${MilaStrings.text(MilaMessage.ApprovalFingerprint)}: ${awaiting.approval.fingerprint}", style = MaterialTheme.typography.labelSmall)
            Button({ approvalBrowser.open(awaiting.approval) }) {
                Text(MilaStrings.text(MilaMessage.OpenApproval))
            }
        }
        if (signInState is MilaSignInState.Expired) {
            Text(MilaStrings.text(MilaMessage.ApprovalExpired), style = MaterialTheme.typography.bodyMedium)
            selectedDeployment?.let { selected ->
                Button({ reconnect(selected) }) { Text(MilaStrings.text(MilaMessage.Reconnect)) }
            }
        }
        if (signInState is MilaSignInState.SignedIn) Text(MilaStrings.text(MilaMessage.Connected), style = MaterialTheme.typography.labelSmall)
        if (resolution == MilaRouteResolution.NotFound) {
            Text(MilaStrings.text(MilaMessage.MachineNotFound), style = MaterialTheme.typography.bodyMedium)
        }
        when (val selected = route) {
            MilaRoute.Machines -> MachineList(sessionAdapter, machineForm, status, listing, signedIn, ::refresh) { route = MilaRoute.Machine(it.id); machineDetail.select(it.id) }
            is MilaRoute.Machine -> if (resolution != MilaRouteResolution.NotFound) MachineDetail(machineDetail, machineForm, selected.id, sessionAdapter, signedIn, listing, ::refresh)
            MilaRoute.Threads -> ThreadList(sessionAdapter, signInState is MilaSignInState.SignedIn, threadListing, onRefresh = {
                scope.launch { threadListing = sessionAdapter.threadListing().getOrNull() }
            }) { route = MilaRoute.Thread(it); threadDetail.select(it) }
            is MilaRoute.Thread -> if (resolution != MilaRouteResolution.NotFound) ThreadDetail(threadDetail, selected.id) {
                scope.launch { threadListing = sessionAdapter.threadListing().getOrNull() }
            }
            MilaRoute.Settings -> MilaSettingsScreen(sessionAdapter, signInState is MilaSignInState.SignedIn, appLockController)
        }
    }
    LaunchedEffect(signIn) {
        val saved = selectedDeployment
        if (saved != null) {
            sessionMaterialProvider.resolve(saved).onSuccess { material ->
                signIn.signIn(saved, material.config, material.signer)
                signInState = signIn.state
            }
        }
    }
    LaunchedEffect(signInState) {
        while (signInState is MilaSignInState.AwaitingApproval) {
            delay(2_000)
            signIn.pollApproval()
            signInState = signIn.state
        }
    }
    LaunchedEffect(signInState) {
        if (signInState is MilaSignInState.SignedIn) {
            threadListing = sessionAdapter.threadListing().getOrNull()
        } else {
            threadListing = null
        }
    }
}

@Composable
private fun MilaDeploymentPicker(
    deployments: List<MilaDeployment>,
    selected: MilaDeployment?,
    host: String,
    invalidHost: Boolean,
    onHostChanged: (String) -> Unit,
    onSelect: (MilaDeployment) -> Unit,
    onAdd: () -> Unit,
    onForget: (MilaDeployment) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(MilaStrings.text(MilaMessage.Deployments), style = MaterialTheme.typography.titleMedium)
        deployments.forEach { deployment ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button({ onSelect(deployment) }, enabled = deployment != selected) {
                    Text(deployment.label, style = MaterialTheme.typography.bodyMedium)
                }
                Button({ onForget(deployment) }) {
                    Text(MilaStrings.text(MilaMessage.ForgetDeployment))
                }
            }
        }
        OutlinedTextField(
            value = host,
            onValueChange = onHostChanged,
            label = { Text(MilaStrings.text(MilaMessage.DeploymentHost)) },
            placeholder = { Text(MilaStrings.text(MilaMessage.DeploymentHostHint)) },
            isError = invalidHost,
            singleLine = true,
        )
        if (invalidHost) {
            Text(MilaStrings.text(MilaMessage.InvalidHost), style = MaterialTheme.typography.labelSmall)
        }
        Button({ onAdd() }, enabled = host.isNotBlank()) {
            Text(MilaStrings.text(MilaMessage.AddDeployment))
        }
    }
}

@Composable
private fun MilaSettingsScreen(adapter: MilaFfiAdapter, signedIn: Boolean, appLockController: MilaAppLockController? = null) {
    val context = LocalContext.current
    val controller = remember { MilaSettingsController(MilaSharedPreferencesStore(context.getSharedPreferences("mila.settings", 0))) }
    var settings by remember { mutableStateOf(controller.load()) }
    // Keep locale choices finite and sourced from the shared catalog bundles. A user supplied
    // locale is still validated by MilaSettings before it reaches persistence.
    val localeChoices = MilaStrings.supportedLocales
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(MilaStrings.text(MilaMessage.Settings), style = MaterialTheme.typography.titleLarge)
        Text("${MilaStrings.text(MilaMessage.Appearance)}: ${settings.appearance}")
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            MilaAppearance.entries.forEach { appearance ->
                Button({ settings = settings.copy(appearance = appearance); controller.save(settings) }) { Text(appearance.name) }
            }
        }
        Text("${MilaStrings.text(MilaMessage.Locale)}: ${settings.locale}")
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            localeChoices.forEach { localeTag ->
                Button(onClick = {
                    val canonical = canonicalMilaLocale(localeTag) ?: return@Button
                    settings = settings.copy(locale = canonical)
                    controller.save(settings)
                    MilaStrings.configure(context, Locale.forLanguageTag(canonical))
                }, enabled = settings.locale != localeTag) {
                    Text(localeTag)
                }
            }
        }
        appLockController?.let { lock ->
            Text(MilaStrings.text(MilaMessage.LockTitle), style = MaterialTheme.typography.titleMedium)
            Text(if (lock.state.availability == MilaLockAvailability.Unavailable) MilaStrings.text(MilaMessage.LockUnavailable) else "${lock.state.phase}: ${lock.state.delay}")
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { lock.setEnabled(!lock.state.enabled) }, enabled = lock.state.availability == MilaLockAvailability.Available && lock.state.phase == MilaLockPhase.Unlocked) {
                    Text(if (lock.state.enabled) "Disable" else "Enable")
                }
                MilaLockDelay.entries.forEach { delay ->
                    Button(onClick = { lock.setDelay(delay) }, enabled = lock.state.phase == MilaLockPhase.Unlocked && lock.state.enabled) { Text(delay.name) }
                }
            }
        }
        MilaSshKeysPanel(adapter, signedIn)
        MilaNotificationsPanel(adapter, signedIn)
    }
}

@Composable
private fun MilaSshKeysPanel(adapter: MilaFfiAdapter, signedIn: Boolean) {
    val store = adapter.sshKeyStore()
    val controller = remember(store) { MilaSshKeyController(store) }
    var keys by remember(controller) { mutableStateOf(controller.keys) }
    LaunchedEffect(store, signedIn) {
        controller.bindStore(if (signedIn) store else null)
        keys = controller.keys
    }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(MilaStrings.text(MilaMessage.SshKeysTitle), style = MaterialTheme.typography.titleMedium)
        Text(MilaStrings.text(MilaMessage.SshKeysExplain), style = MaterialTheme.typography.bodySmall)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = { controller.refresh(); keys = controller.keys }, enabled = signedIn && store != null) {
                Text(MilaStrings.text(MilaMessage.Refresh))
            }
        }
        if (!signedIn || store == null) {
            Text(MilaStrings.text(MilaMessage.RuntimeUnavailable), style = MaterialTheme.typography.labelSmall)
        } else if (keys.isEmpty()) {
            Text(MilaStrings.text(MilaMessage.SshKeysEmpty), style = MaterialTheme.typography.labelSmall)
        } else {
            keys.forEach { key ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Column(modifier = Modifier.width(120.dp)) {
                        Text(key.label.ifBlank { key.fingerprint })
                        Text("${MilaStrings.text(MilaMessage.SshKeyAlgorithm)}: ${key.algorithm}", style = MaterialTheme.typography.labelSmall)
                        Text(key.fingerprint, style = MaterialTheme.typography.labelSmall)
                    }
                    if (key.isCurrentDevice) {
                        Text(MilaStrings.text(MilaMessage.SshKeyThisDevice), style = MaterialTheme.typography.labelSmall)
                    } else {
                        Button(onClick = { if (controller.revoke(key)) keys = controller.keys }, enabled = signedIn) {
                            Text(MilaStrings.text(MilaMessage.SshKeyRevoke))
                        }
                    }
                }
            }
        }
    }
}

@Composable private fun TerminalControls(adapter: MilaFfiAdapter, machineId: java.util.UUID) {
    var result by remember { mutableStateOf("Terminal idle") }
    var terminalHandle by remember { mutableStateOf<Long?>(null) }
    var input by remember { mutableStateOf("") }
    var output by remember { mutableStateOf("") }
    val renderer = remember { MilaTerminalRenderer() }
    LaunchedEffect(terminalHandle) {
        val handle = terminalHandle ?: return@LaunchedEffect
        while (terminalHandle == handle) {
            adapter.terminalPoll(handle).onSuccess { bytes ->
                if (bytes.isNotEmpty()) {
                    renderer.append(bytes)
                    output = renderer.text()
                }
            }
            delay(100)
        }
    }
    DisposableEffect(Unit) { onDispose { terminalHandle?.let { adapter.terminalClose(it) } } }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(MilaStrings.text(MilaMessage.Terminal), style = MaterialTheme.typography.titleMedium)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button({
                terminalHandle?.let { adapter.terminalClose(it) }
                terminalHandle = adapter.terminalOpen(machineId, 80, 24).getOrNull()
                result = if (terminalHandle != null) "Attached" else "Attach rejected"
            }) { Text(MilaStrings.text(MilaMessage.Attach)) }
            Button({
                val handle = terminalHandle
                result = if (handle != null && adapter.terminalInputBytes(handle, input.toByteArray(Charsets.UTF_8)).isSuccess) {
                    input = ""; "Input sent"
                } else "Input rejected"
            }, enabled = terminalHandle != null && input.isNotEmpty()) { Text(MilaStrings.text(MilaMessage.Input)) }
            Button({
                val handle = terminalHandle
                result = if (handle != null && adapter.terminalResizeHandle(handle, 80, 24).isSuccess) "Resized" else "Resize rejected"
            }, enabled = terminalHandle != null) { Text(MilaStrings.text(MilaMessage.Resize)) }
            Button({ terminalHandle?.let { adapter.terminalClose(it) }; terminalHandle = null; result = "Closed" }, enabled = terminalHandle != null) { Text("Close") }
        }
        OutlinedTextField(value = input, onValueChange = { if (boundedTerminalInput(it)) input = it }, label = { Text("Input") }, enabled = terminalHandle != null)
        Text(output, style = MaterialTheme.typography.bodySmall)
        Text(result, style = MaterialTheme.typography.labelSmall)
    }
}

@Composable private fun MachineList(adapter: MilaFfiAdapter, form: MilaMachineFormController, status: String, listing: MilaSessionListing?, signedIn: Boolean, onCreated: () -> Unit, onSelect: (MilaMachineRow) -> Unit) {
    var classified by remember { mutableStateOf<MilaMachineCommand?>(null) }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(status, style = MaterialTheme.typography.bodyMedium)
        listing?.machines?.forEach { machine ->
            Button({ onSelect(machine) }) { Text("${machine.name} · ${machine.status}", style = MaterialTheme.typography.bodyMedium) }
        }
        if (signedIn) MachineCreateControls(form, onCreated)
        Text(MilaStrings.text(MilaMessage.MachineActions), style = MaterialTheme.typography.titleMedium)
        machineCommandChoices.chunked(3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { choice ->
                    Button({ classified = adapter.machineCommandKind(choice.command).getOrNull() }) {
                        Text(choice.label)
                    }
                }
            }
        }
        Text(classified?.name ?: MilaStrings.text(MilaMessage.NoAction), style = MaterialTheme.typography.labelSmall)
    }
}

@Composable private fun MachineCreateControls(form: MilaMachineFormController, onCreated: () -> Unit) {
    var name by remember { mutableStateOf("") }
    var cpu by remember { mutableStateOf("2") }
    var memory by remember { mutableStateOf("1024") }
    var disk by remember { mutableStateOf("20") }
    var state by remember(form) { mutableStateOf(form.state) }
    val scope = rememberCoroutineScope()
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(MilaStrings.text(MilaMessage.MachineCreate), style = MaterialTheme.typography.titleMedium)
        OutlinedTextField(name, { name = it.take(128) }, label = { Text(MilaStrings.text(MilaMessage.MachineName)) }, singleLine = true,
            isError = state == MilaMachineFormState.Invalid(MilaMachineFormKind.Create, MilaMachineField.Name))
        MachineResourceFields(cpu, memory, disk, MilaMachineFormKind.Create, state, { cpu = it }, { memory = it }, { disk = it })
        Button(enabled = form.canSubmit(), onClick = {
            scope.launch {
                val applied = form.create(name, cpu, memory, disk)
                state = form.state
                if (applied) onCreated()
            }
            state = form.state
        }) { Text(MilaStrings.text(MilaMessage.MachineCreate)) }
        machineFormStatus(state, MilaMachineFormKind.Create)?.let { Text(it, style = MaterialTheme.typography.labelSmall) }
    }
}

@Composable private fun MachineResourceFields(
    cpu: String, memory: String, disk: String, kind: MilaMachineFormKind, state: MilaMachineFormState,
    onCpu: (String) -> Unit, onMemory: (String) -> Unit, onDisk: (String) -> Unit,
) {
    fun invalid(field: MilaMachineField) = state == MilaMachineFormState.Invalid(kind, field)
    // Digits only and at most seven characters: every accepted bound fits without overflow.
    fun digits(value: String) = value.filter(Char::isDigit).take(7)
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        OutlinedTextField(cpu, { onCpu(digits(it)) }, label = { Text(MilaStrings.text(MilaMessage.MachineCpu)) }, singleLine = true, isError = invalid(MilaMachineField.Cpu), modifier = Modifier.width(120.dp))
        OutlinedTextField(memory, { onMemory(digits(it)) }, label = { Text(MilaStrings.text(MilaMessage.MachineMemory)) }, singleLine = true, isError = invalid(MilaMachineField.Memory), modifier = Modifier.width(120.dp))
        OutlinedTextField(disk, { onDisk(digits(it)) }, label = { Text(MilaStrings.text(MilaMessage.MachineDisk)) }, singleLine = true, isError = invalid(MilaMachineField.Disk), modifier = Modifier.width(120.dp))
    }
}

/** Localized status line for one form; other forms' states are not shown here. */
internal fun machineFormStatus(state: MilaMachineFormState, kind: MilaMachineFormKind): String? = when (state) {
    MilaMachineFormState.SignedOut -> MilaStrings.text(MilaMessage.RuntimeUnavailable)
    MilaMachineFormState.Idle -> null
    is MilaMachineFormState.Invalid -> if (state.kind == kind) MilaStrings.text(MilaMessage.FieldInvalid) else null
    is MilaMachineFormState.Submitting -> if (state.kind == kind) MilaStrings.text(MilaMessage.RequestWaiting) else null
    is MilaMachineFormState.Applied -> if (state.kind != kind) null
        else if (kind == MilaMachineFormKind.Create) MilaStrings.text(MilaMessage.MachineCreated) else MilaStrings.text(MilaMessage.RequestSucceeded)
    is MilaMachineFormState.Failed -> if (state.kind == kind) MilaStrings.text(MilaMessage.RequestRefused) else null
}

@Composable private fun MachineDetail(controller: MilaMachineDetailController, form: MilaMachineFormController, id: java.util.UUID, adapter: MilaFfiAdapter, signedIn: Boolean, listing: MilaSessionListing?, onResized: () -> Unit) {
    val scope = rememberCoroutineScope()
    var state by remember { mutableStateOf(controller.state) }
    var resizeCpu by remember { mutableStateOf("2") }
    var resizeMemory by remember { mutableStateOf("1024") }
    var resizeDisk by remember { mutableStateOf("20") }
    var resizeState by remember(form) { mutableStateOf(form.state) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(MilaStrings.text(MilaMessage.MachineActions), style = MaterialTheme.typography.titleLarge)
        Text(id.toString(), style = MaterialTheme.typography.labelSmall)
        // The detail row always comes from the authenticated listing, so a deep-linked or refreshed
        // route projects the current session's machine rather than a value captured earlier.
        val machine = if (signedIn) listing?.machines?.firstOrNull { it.id == id } else null
        if (machine != null) Text("${machine.name} · ${machine.status}")
        machineCommandChoices.filter { it.command in setOf("start", "stop", "pause", "resume", "rm", "resize") }.chunked(3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { choice ->
                    Button(
                        enabled = signedIn,
                        onClick = {
                            controller.select(id)
                            controllerSelect(controller, choice.command, scope) { state = controller.state }
                        },
                    ) { Text(choice.label) }
                }
            }
        }
        if (machine != null) {
            Text(MilaStrings.text(MilaMessage.Resize), style = MaterialTheme.typography.titleMedium)
            MachineResourceFields(resizeCpu, resizeMemory, resizeDisk, MilaMachineFormKind.Resize, resizeState, { resizeCpu = it }, { resizeMemory = it }, { resizeDisk = it })
            Button(enabled = signedIn && form.canSubmit(), onClick = {
                scope.launch {
                    val applied = form.resize(id, resizeCpu, resizeMemory, resizeDisk)
                    resizeState = form.state
                    if (applied) onResized()
                }
                resizeState = form.state
            }) { Text(MilaStrings.text(MilaMessage.Resize)) }
            machineFormStatus(resizeState, MilaMachineFormKind.Resize)?.let { Text(it, style = MaterialTheme.typography.labelSmall) }
        }
        MachineSharingControls(adapter, machine, signedIn, listing)
        if (machine != null) MilaWebControls(adapter, machine, signedIn)
        if (machine != null && signedIn) TerminalControls(adapter, machine.id)
        Text(
            when (val current = controller.state) {
                MilaMachineMutationState.SignedOut -> MilaStrings.text(MilaMessage.RuntimeUnavailable)
                MilaMachineMutationState.Idle -> MilaStrings.text(MilaMessage.NoAction)
                is MilaMachineMutationState.Ready -> "Ready"
                is MilaMachineMutationState.Submitting -> "Submitting ${current.command.name}"
                is MilaMachineMutationState.Applied -> "Applied ${current.command.name}"
                is MilaMachineMutationState.Failed -> current.reason
            },
            style = MaterialTheme.typography.labelSmall,
        )
    }
}

@Composable
private fun MachineSharingControls(adapter: MilaFfiAdapter, machine: MilaMachineRow?, signedIn: Boolean, listing: MilaSessionListing?) {
    var principal by remember { mutableStateOf("") }
    var role by remember { mutableStateOf(MilaShareRole.Viewer) }
    var result by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    // Sharing commands are classified and submitted by the typed controller.
    val controller = remember { MilaMachineSharingController(adapter) }
    LaunchedEffect(controller, signedIn, listing, machine?.id) {
        controller.setSession(signedIn, listing)
        if (machine != null) controller.setMachine(machine)
    }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        OutlinedTextField(value = principal, onValueChange = { principal = it.take(320) }, label = { Text(MilaStrings.text(MilaMessage.SharePrincipal)) })
        Text(MilaStrings.text(MilaMessage.ShareRole), style = MaterialTheme.typography.labelSmall)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            MilaShareRole.entries.forEach { choice ->
                Button(enabled = role != choice, onClick = { role = choice }) {
                    Text(MilaStrings.text(when (choice) {
                        MilaShareRole.Viewer -> MilaMessage.ShareRoleViewer
                        MilaShareRole.Operator -> MilaMessage.ShareRoleOperator
                        MilaShareRole.Manager -> MilaMessage.ShareRoleManager
                    }))
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(enabled = signedIn && machine != null, onClick = { scope.launch { result = if (controller.submit(principal, role = role)) MilaStrings.text(MilaMessage.ShareAdded) else MilaStrings.text(MilaMessage.ShareRejected) } }) { Text(MilaStrings.text(MilaMessage.ShareAdd)) }
            Button(enabled = signedIn && machine != null, onClick = { scope.launch { result = if (controller.submit(principal, remove = true)) MilaStrings.text(MilaMessage.ShareRemoved) else MilaStrings.text(MilaMessage.ShareRejected) } }) { Text(MilaStrings.text(MilaMessage.ShareRemove)) }
        }
        if (result.isNotEmpty()) Text(result, style = MaterialTheme.typography.labelSmall)
    }
}

private fun controllerSelect(controller: MilaMachineDetailController, command: String, scope: kotlinx.coroutines.CoroutineScope, onComplete: () -> Unit) {
    val value = MilaMachineCommand.entries.firstOrNull { it.name.equals(command, ignoreCase = true) }
        ?: when (command) { "rm" -> MilaMachineCommand.Delete; else -> null }
        ?: return
    scope.launch { controller.submit(value); onComplete() }
}

@Composable private fun ThreadDetail(
    controller: MilaThreadDetailController,
    id: java.util.UUID,
    onActionApplied: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var input by remember { mutableStateOf("") }
    var actionState by remember { mutableStateOf(controller.state) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(value = input, onValueChange = { if (boundedTerminalInput(it)) input = it }, label = { Text(MilaStrings.text(MilaMessage.Input)) })
        Text(MilaStrings.text(MilaMessage.ThreadCommands), style = MaterialTheme.typography.titleLarge)
        Text(id.toString(), style = MaterialTheme.typography.labelSmall)
        threadCommandChoices.chunked(3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { (label, raw) ->
                    Button(enabled = controller.canSubmit(), onClick = {
                        val command = when (raw) {
                            "thread ls" -> MilaThreadCommand.List
                            "thread show" -> MilaThreadCommand.Show
                            "thread turns" -> MilaThreadCommand.Turns
                            "thread prompt" -> MilaThreadCommand.Prompt
                            "thread answer" -> MilaThreadCommand.Answer
                            "thread plan approve" -> MilaThreadCommand.PlanApprove
                            "thread plan revise" -> MilaThreadCommand.PlanRevise
                            "thread mode" -> MilaThreadCommand.Mode
                            "thread read" -> MilaThreadCommand.Read
                            else -> null
                        } ?: return@Button
                        scope.launch {
                            val payload = input.takeIf { command == MilaThreadCommand.Prompt || command == MilaThreadCommand.Answer || command == MilaThreadCommand.PlanRevise }
                            controller.submit(command, payload)
                            actionState = controller.state
                            if (actionState is MilaThreadActionState.Applied) onActionApplied()
                        }
                    }) { Text(label) }
                }
            }
        }
        Text(
            when (val state = actionState) {
                MilaThreadActionState.SignedOut -> MilaStrings.text(MilaMessage.RuntimeUnavailable)
                MilaThreadActionState.Idle -> MilaStrings.text(MilaMessage.NoCommand)
                is MilaThreadActionState.Ready -> "${state.thread.title} · ${state.thread.status}"
                is MilaThreadActionState.Submitting -> "${MilaStrings.text(MilaMessage.Connecting)} ${state.command.name}"
                is MilaThreadActionState.Applied -> "${MilaStrings.text(MilaMessage.Connected)} ${state.command.name}"
                is MilaThreadActionState.Failed -> state.reason
            }, style = MaterialTheme.typography.labelSmall,
        )
    }
}

@Composable private fun ThreadList(
    adapter: MilaFfiAdapter,
    signedIn: Boolean,
    listing: MilaThreadListing?,
    onRefresh: () -> Unit,
    onSelect: (java.util.UUID) -> Unit,
) {
    var classified by remember { mutableStateOf<MilaThreadCommand?>(null) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(MilaStrings.text(MilaMessage.ThreadCommands), style = MaterialTheme.typography.titleLarge)
        Button(onClick = onRefresh, enabled = signedIn) { Text(MilaStrings.text(MilaMessage.Refresh)) }
        listing?.threads?.forEach { thread ->
            Button({ onSelect(thread.id) }) { Text("${thread.title} · ${thread.status}") }
        }
        if (!signedIn) Text(MilaStrings.text(MilaMessage.RuntimeUnavailable), style = MaterialTheme.typography.labelSmall)
        threadCommandChoices.chunked(3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { (label, command) ->
                    Button({ classified = adapter.threadCommandKind(command).getOrNull() }, enabled = signedIn) { Text(label) }
                }
            }
        }
        Text(classified?.name ?: MilaStrings.text(MilaMessage.NoCommand), style = MaterialTheme.typography.bodyMedium)
    }
}
@Composable private fun Detail(title: String, value: String) { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { Text(title, style = MaterialTheme.typography.titleLarge); Text(value, style = MaterialTheme.typography.bodyMedium) } }

@Composable
private fun MilaNotificationsPanel(adapter: MilaFfiAdapter, signedIn: Boolean) {
    val context = LocalContext.current
    val store = remember { MilaPreferencesNotificationStore(context.getSharedPreferences("mila.notifications", 0)) }
    val controller = remember(store) { MilaAuthenticatedNotificationController(adapter, store, "mila", "selected") }
    var devices by remember(controller) { mutableStateOf(controller.devices) }
    LaunchedEffect(signedIn) {
        if (signedIn) controller.signIn() else controller.signOut()
        devices = controller.devices
    }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(MilaStrings.text(MilaMessage.NotificationsTitle), style = MaterialTheme.typography.titleMedium)
        if (!signedIn) {
            Text(MilaStrings.text(MilaMessage.RuntimeUnavailable), style = MaterialTheme.typography.labelSmall)
        } else if (devices.isEmpty()) {
            Text(MilaStrings.text(MilaMessage.NoAction), style = MaterialTheme.typography.labelSmall)
        } else {
            devices.forEach { device ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(device.id, modifier = Modifier.width(160.dp))
                    Button(onClick = { controller.setEnabled(device.id, !device.enabled); devices = controller.devices }) {
                        Text("${MilaStrings.text(MilaMessage.NotificationEnabled)}: ${device.enabled}")
                    }
                    Button(onClick = { controller.remove(device.id); devices = controller.devices }) {
                        Text(MilaStrings.text(MilaMessage.NotificationRemove))
                    }
                }
            }
        }
    }
}
