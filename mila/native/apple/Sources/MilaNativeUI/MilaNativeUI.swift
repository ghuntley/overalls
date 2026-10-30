import SwiftUI
import Combine

/// @cc [owner:ghuntley,label:security] mila-apple-app-model-binding
/// Owns the deployment session, sign-in lifecycle and feature controllers.
/// Feature controllers are bound only to the adapter of an approved sign-in
/// generation, and every phase change rebinds them, so sign-out, expiry or a
/// deployment switch clears machine and thread state in one place.
@MainActor public final class MilaAppModel: ObservableObject {
    public let session: MilaDeploymentSessionController
    public let signIn: MilaSignInController
    public let machines = MilaMachinesController()
    public let threads = MilaThreadsController()
    public let web = MilaWebViewLifecycle()
    private var boundGeneration: UInt64?
    private var observation: AnyCancellable?

    public init(session: MilaDeploymentSessionController, signIn: MilaSignInController? = nil) {
        self.session = session
        self.signIn = signIn ?? MilaSignInController(session: session)
        observation = self.signIn.$phase.sink { [weak self] phase in
            // `@Published` emits before the stored value changes.
            MainActor.assumeIsolated { self?.phaseChanged(phase) }
        }
    }

    /// The authenticated adapter, only while the approved generation is current.
    public var adapter: (any MilaFFIAdapter)? { signIn.adapter }

    private func phaseChanged(_ phase: MilaSignInPhase) {
        let generation: UInt64?
        if case .signedIn(_, let value) = phase { generation = value } else { generation = nil }
        guard generation != boundGeneration else { return }
        boundGeneration = generation
        let adapter = generation.flatMap { $0 == session.generation ? session.adapter() : nil }
        machines.bind(adapter)
        threads.bind(adapter)
        web.invalidate()
        if adapter != nil { Task { await machines.refresh() } }
    }
}

/// Native presentation shell. Machine records are supplied by the validated Rust snapshot boundary.
public struct MilaNativeRootView: View {
    @StateObject private var model: MilaAppModel

    public init(adapter: any MilaFFIAdapter = LinkedMilaFFIAdapter(), snapshot: MilaValidatedSnapshot? = nil) {
        _ = adapter; _ = snapshot
        _model = StateObject(wrappedValue: MilaAppModel(session: MilaDeploymentSessionController { deployment in
            let signer = try MilaDeviceSigner(deploymentHost: deployment.host)
            return try LinkedMilaFFIAdapter(trust: deployment.trust, host: deployment.host, port: deployment.port, signer: signer)
        }))
    }

    public init(model: MilaAppModel) { _model = StateObject(wrappedValue: model) }

    public var body: some View {
        MilaRootContent(model: model, session: model.session, signIn: model.signIn, machines: model.machines)
    }
}

private struct MilaRootContent: View {
    let model: MilaAppModel
    @ObservedObject var session: MilaDeploymentSessionController
    @ObservedObject var signIn: MilaSignInController
    @ObservedObject var machines: MilaMachinesController
    @State private var selection: MilaRoute = .machines
    @State private var deepLinkRouter = MilaDeepLinkRouter()
    @State private var pendingDeepLink: MilaRoute?
    @State private var showCreate = false
    @StateObject private var appLock = MilaAppLockController()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("mila.appearance") private var appearance = "system"
    @AppStorage("mila.locale") private var locale = "en"

    var body: some View {
        MilaAppLockView(controller: appLock) {
        NavigationSplitView {
            // iOS offers List selection only through an optional binding.
            List(selection: Binding<MilaRoute?>(get: { selection }, set: { if let route = $0 { selection = route } })) {
                Label(MilaStrings.text(.machines), systemImage: "desktopcomputer").tag(MilaRoute.machines)
                Label(MilaStrings.text(.threads), systemImage: "bubble.left.and.bubble.right").tag(MilaRoute.threads)
                Label(MilaStrings.text(.settings), systemImage: "gearshape").tag(MilaRoute.settings)
            }.navigationTitle(MilaStrings.text(.appName))
        } detail: {
            Group {
                switch selection {
                case .machines:
                    MachinesView(controller: machines, create: { showCreate = true }) { id in
                        machines.select(id); selection = .machine(id: id)
                    }
                case .machine(let id):
                    if let adapter = model.adapter, let machine = machines.machine(id) {
                        MachineDetailView(machine: machine, adapter: adapter, web: model.web) {
                            Task { await machines.refresh() }
                        }.id(machine.id)
                    } else {
                        ContentUnavailableView(MilaStrings.text(.machineUnavailable), systemImage: "questionmark")
                    }
                case .threads: ThreadsView(controller: model.threads, select: { selection = .thread(id: $0) })
                case .thread(let id): ThreadDetailView(id: id, controller: model.threads)
                case .settings: SettingsView(model: model, lockController: appLock, session: session, signIn: signIn)
                }
            }
            .toolbar { ToolbarItem { Button(MilaStrings.text(.refresh)) { Task { await machines.refresh() } }.disabled(model.adapter == nil) } }
            .safeAreaInset(edge: .bottom) { Text(status).font(.caption).foregroundStyle(.secondary).padding(4) }
        }.sheet(isPresented: $showCreate) {
            if let adapter = model.adapter {
                MilaMachineCreateView(adapter: adapter) { result in
                    if result { Task { await machines.refresh() } }
                }
            }
        }
        .milaDesignSystem()
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .environment(\.locale, Locale(identifier: MilaStrings.canonicalLocale(locale)))
        .onChange(of: signIn.phase) { _, phase in
            let signedIn: Bool
            if case .signedIn = phase { signedIn = true } else { signedIn = false }
            deepLinkRouter.setSession(signedIn: signedIn)
            if signedIn, let pendingDeepLink { selection = pendingDeepLink; self.pendingDeepLink = nil }
            if !signedIn, selection != .settings { selection = .machines }
        }.onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive, .background: appLock.sceneDidEnterBackground()
            case .active: Task { await appLock.sceneWillEnterForeground() }
            default: break
            }
        }.onOpenURL { url in
            let decision = deepLinkRouter.decide(url.absoluteString)
            switch decision {
            case .open(let route, let generation) where deepLinkRouter.accepts(decision, generation: generation):
                if case .machine(let id) = route { machines.select(id) }
                selection = route
            case .signedOut(let route):
                pendingDeepLink = route
                selection = .settings
            default:
                break
            }
        }
        }
    }

    private var status: String {
        switch machines.state {
        case .signedOut: return MilaStrings.text(.ready)
        case .loading: return MilaStrings.text(.connecting)
        case .loaded: return MilaStrings.text(.snapshotLoaded)
        case .failed: return MilaStrings.text(.noSnapshotLoaded)
        }
    }
}

private struct MachinesView: View {
    @ObservedObject var controller: MilaMachinesController
    let create: () -> Void
    let select: (UUID) -> Void
    var body: some View {
        List {
            if controller.state == .failed {
                VStack(alignment: .leading) {
                    Text(MilaStrings.text(.noSnapshotLoaded))
                    Button(MilaStrings.text(.retry)) { Task { await controller.refresh() } }
                }
            } else if controller.machines.isEmpty, controller.state != .loading {
                ContentUnavailableView(MilaStrings.text(.machinesEmpty), systemImage: "desktopcomputer", description: Text(MilaStrings.text(.machinesHint)))
            }
            ForEach(controller.machines) { machine in
                Button { select(machine.id) } label: {
                    VStack(alignment: .leading) {
                        Text(machine.machine.name)
                        Text(machine.machine.observedState ?? machine.machine.desiredState).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if controller.hasMore {
                Button(MilaStrings.text(.machineMore)) { Task { await controller.loadMore() } }
            }
        }
        .overlay { if controller.state == .loading { ProgressView() } }
        .navigationTitle(MilaStrings.text(.machines))
        .toolbar { ToolbarItem(placement: .primaryAction) {
            Button(MilaStrings.text(.actionCreate)) { create() }.disabled(controller.state == .signedOut)
        } }
    }
}

private struct MilaMachineCreateView: View {
    let adapter: any MilaFFIAdapter
    let completed: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var cpu = "2"
    @State private var memory = "2048"
    @State private var disk = "20"
    @State private var busy = false
    @State private var error = false
    var body: some View {
        NavigationStack { Form {
            TextField("Name", text: $name).textContentType(.nickname)
            TextField("CPU", text: $cpu)
            TextField("Memory (MiB)", text: $memory)
            TextField("Disk (GiB)", text: $disk)
            if error { Text(MilaStrings.text(.actionNotSubmitted)).foregroundStyle(.secondary) }
        }.navigationTitle(MilaStrings.text(.actionCreate)).toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(MilaStrings.text(.cancel)) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button(MilaStrings.text(.actionCreate)) { submit() }.disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }}
    }
    private func submit() {
        guard let c = UInt32(cpu), let m = UInt64(memory), let d = UInt64(disk), c > 0, m > 0, d > 0 else { error = true; return }
        busy = true
        Task {
            do { try await adapter.createMachine(name: name.trimmingCharacters(in: .whitespacesAndNewlines), cpu: c, memory: m, disk: d, requestID: UUID()); completed(true); dismiss() }
            catch { busy = false; self.error = true; completed(false) }
        }
    }
}

private struct MachineDetailView: View {
    let machine: MilaMachinePresentation
    let adapter: any MilaFFIAdapter
    @ObservedObject var web: MilaWebViewLifecycle
    let refresh: () -> Void
    @StateObject private var workflow: MilaMachineWorkflow
    @StateObject private var sharing: MilaMachineSharingController
    @State private var showTerminal = false
    @State private var showWeb = false
    @State private var webGeneration: UInt64 = 0
    @State private var webLoading = false
    @State private var webError = false
    @State private var confirmDelete = false
    @State private var sharePrincipal = ""
    @State private var shareRole: MilaShareRole = .viewer
    @State private var resizeCPU = "2"
    @State private var resizeMemory = "2048"
    @State private var resizeDisk = "20"
    @State private var resizeStatus = ""

    init(machine: MilaMachinePresentation, adapter: any MilaFFIAdapter, web: MilaWebViewLifecycle, refresh: @escaping () -> Void) {
        self.machine = machine
        self.adapter = adapter
        self.web = web
        self.refresh = refresh
        _workflow = StateObject(wrappedValue: MilaMachineWorkflow(adapter: adapter))
        _sharing = StateObject(wrappedValue: MilaMachineSharingController(adapter: adapter))
    }

    var body: some View {
        Form {
            Section {
                Text(machine.machine.name).font(.title)
                Text(machine.id.uuidString.lowercased()).font(.caption).textSelection(.enabled)
                Text(machine.machine.observedState ?? machine.machine.desiredState).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    ForEach(machine.actions.lifecycle, id: \.self) { action in
                        Button(action.title, role: action == .delete ? .destructive : nil) {
                            if action == .delete { confirmDelete = true } else { workflow.submit(action, machine: machine) }
                        }
                        .disabled(workflow.isSubmitting)
                    }
                }
                Text(mutationStatus).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    TextField("CPU", text: $resizeCPU).frame(width: 60)
                    TextField("MiB", text: $resizeMemory).frame(width: 110)
                    TextField("GiB", text: $resizeDisk).frame(width: 100)
                    Button(MilaStrings.text(.actionResize)) { resize() }.disabled(!machine.machine.write)
                }
                Text(resizeStatus).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(MilaStrings.text(.openTerminal)) { showTerminal = true }.disabled(!machine.machine.write)
                Button(MilaStrings.text(.webOpen)) { openWeb() }.disabled(webLoading || !machine.machine.read)
                if webError { Text(MilaStrings.text(.webFailed)).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                TextField(MilaStrings.text(.sharePrincipal), text: $sharePrincipal).autocorrectionDisabled()
                Picker(MilaStrings.text(.sharePrincipal), selection: $shareRole) {
                    ForEach(MilaShareRole.allCases) { role in Text(Self.roleTitle(role)).tag(role) }
                }
                HStack {
                    Button(MilaStrings.text(.shareAdd)) { sharing.submit(principal: sharePrincipal, role: shareRole) }
                        .disabled(!machine.machine.write || sharePrincipal.isEmpty)
                    Button(MilaStrings.text(.shareRemove)) { sharing.submit(principal: sharePrincipal, remove: true) }
                        .disabled(!machine.machine.write || sharePrincipal.isEmpty)
                }
                Text(shareStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            sharing.setSession(signedIn: true, machine: machine)
            workflow.onApplied = { _ in refresh() }
        }
        .confirmationDialog(MilaStrings.text(.confirmDelete, ["name": machine.machine.name]), isPresented: $confirmDelete) {
            Button(MilaStrings.text(.actionDelete), role: .destructive) { workflow.submit(.delete, machine: machine) }
            Button(MilaStrings.text(.cancel), role: .cancel) {}
        }
        .sheet(isPresented: $showTerminal) {
            MilaTerminalView(transport: (adapter as? LinkedMilaFFIAdapter)?.terminalTransport(machine: machine.id) ?? MilaNoopTerminalTransport())
        }
        #if canImport(WebKit)
        .sheet(isPresented: $showWeb, onDismiss: { web.end(webGeneration) }) {
            if let endpoint = web.endpoint { MilaWebView(endpoint: endpoint, lifecycle: web, generation: webGeneration) }
        }
        #endif
    }

    private static func roleTitle(_ role: MilaShareRole) -> String {
        switch role {
        case .viewer: return MilaStrings.text(.shareRoleViewer)
        case .operatorRole: return MilaStrings.text(.shareRoleOperator)
        case .manager: return MilaStrings.text(.shareRoleManager)
        }
    }

    private func openWeb() {
        webLoading = true
        webError = false
        Task {
            defer { webLoading = false }
            do {
                let projection = try await adapter.webEndpointProjection(machine: machine.id)
                let endpoint = try projection.endpoint(for: machine.id)
                guard let generation = web.begin(endpoint, sessionActive: true) else { webError = true; return }
                webGeneration = generation
                showWeb = true
            } catch { webError = true }
        }
    }

    private var shareStatus: String {
        switch sharing.state {
        case .signedOut: return MilaStrings.text(.runtimeUnavailable)
        case .idle: return ""
        case .submitting: return MilaStrings.text(.connecting)
        case .applied(_, _, let remove): return remove ? MilaStrings.text(.shareRemoved) : MilaStrings.text(.shareAdded)
        case .failed: return MilaStrings.text(.actionNotSubmitted)
        }
    }

    private var mutationStatus: String {
        switch workflow.state {
        case .idle: return ""
        case .submitting: return MilaStrings.text(.connecting)
        case .applied: return MilaStrings.text(.actionSubmitted)
        case .failed: return MilaStrings.text(.actionNotSubmitted)
        }
    }

    private func resize() {
        guard let cpu = UInt32(resizeCPU), let memory = UInt64(resizeMemory), let disk = UInt64(resizeDisk), cpu > 0, memory > 0, disk > 0 else { resizeStatus = MilaStrings.text(.actionNotSubmitted); return }
        resizeStatus = MilaStrings.text(.connecting)
        Task {
            do { try await adapter.resize(machine: machine, cpu: cpu, memory: memory, disk: disk, requestID: UUID()); resizeStatus = MilaStrings.text(.actionSubmitted); refresh() }
            catch { resizeStatus = MilaStrings.text(.actionNotSubmitted) }
        }
    }
}

private struct ThreadsView: View {
    @ObservedObject var controller: MilaThreadsController
    let select: (UUID) -> Void
    var body: some View {
        List {
            switch controller.state {
            case .signedOut:
                ContentUnavailableView(MilaStrings.text(.noThreads), systemImage: "bubble.left", description: Text(MilaStrings.text(.threadsHint)))
            case .failed:
                Text(MilaStrings.text(.threadsFailed))
                Button(MilaStrings.text(.retry)) { Task { await controller.list() } }
            case .idle, .loading, .loaded:
                if controller.threads.isEmpty, controller.state == .loaded {
                    ContentUnavailableView(MilaStrings.text(.noThreads), systemImage: "bubble.left", description: Text(MilaStrings.text(.threadsHint)))
                }
                ForEach(controller.threads) { thread in
                    Button { select(thread.id) } label: {
                        VStack(alignment: .leading) {
                            Text(thread.title ?? MilaStrings.text(.threadUntitled))
                            Text(thread.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .overlay { if controller.state == .loading { ProgressView() } }
        .navigationTitle(MilaStrings.text(.threads))
        .toolbar { ToolbarItem { Button(MilaStrings.text(.refresh)) { Task { await controller.list() } }.disabled(controller.state == .signedOut) } }
        .task { if controller.state == .idle { await controller.list() } }
    }
}

private struct ThreadDetailView: View {
    let id: UUID
    @ObservedObject var controller: MilaThreadsController
    @State private var prompt = ""
    @State private var answer = ""
    @State private var revision = ""
    var body: some View {
        Form {
            if let detail = controller.detail, detail.id == id {
                Section {
                    Text(detail.title ?? MilaStrings.text(.threadUntitled)).font(.title2)
                    Text(detail.busy == true ? MilaStrings.text(.threadWorking) : detail.status).font(.caption).foregroundStyle(.secondary)
                }
                if let question = detail.pendingQuestion {
                    Section(MilaStrings.text(.threadQuestionTitle)) {
                        TextField(MilaStrings.text(.input), text: $answer, axis: .vertical)
                        Button(MilaStrings.text(.threadAnswerSend)) { submit(.answer(thread: id, question: question.id, text: answer)) { answer = "" } }
                            .disabled(!MilaThreadAction.answer(thread: id, question: question.id, text: answer).isWellFormed || busy)
                    }
                }
                if let plan = detail.latestPlan, plan.implemented != true {
                    Section(MilaStrings.text(.threadPlanTitle)) {
                        Button(MilaStrings.text(.threadPlanApprove)) { submit(.planApprove(thread: id, plan: plan.id)) {} }.disabled(busy)
                        TextField(MilaStrings.text(.threadPlanRevisionHint), text: $revision, axis: .vertical)
                        Button(MilaStrings.text(.threadPlanRevise)) { submit(.planRevise(thread: id, plan: plan.id, text: revision)) { revision = "" } }
                            .disabled(!MilaThreadAction.planRevise(thread: id, plan: plan.id, text: revision).isWellFormed || busy)
                    }
                }
                Section {
                    TextField(MilaStrings.text(.threadComposerHint), text: $prompt, axis: .vertical)
                    Button(MilaStrings.text(.send)) { submit(.prompt(thread: id, text: prompt)) { prompt = "" } }
                        .disabled(!MilaThreadAction.prompt(thread: id, text: prompt).isWellFormed || busy)
                }
                if case .failed = controller.mutation { Text(MilaStrings.text(.actionNotSubmitted)).font(.caption).foregroundStyle(.secondary) }
            } else if controller.state == .failed {
                Text(MilaStrings.text(.threadFailed))
            } else {
                ProgressView()
            }
        }
        .task(id: id) { await controller.show(id) }
    }
    private var busy: Bool { if case .submitting = controller.mutation { return true }; return false }
    private func submit(_ action: MilaThreadAction, clear: @escaping () -> Void) {
        Task {
            await controller.perform(action)
            if case .applied = controller.mutation { clear() }
        }
    }
}

private struct SettingsView: View {
    let model: MilaAppModel
    @ObservedObject var lockController: MilaAppLockController
    @ObservedObject var session: MilaDeploymentSessionController
    @ObservedObject var signIn: MilaSignInController
    @Environment(\.openURL) private var openURL
    @AppStorage("mila.appearance") private var appearance = "system"
    @AppStorage("mila.locale") private var locale = "en"
    @AppStorage("mila.appLockEnabled") private var appLockEnabled = false
    @State private var notificationToken = ""
    @State private var notificationEndpoint = ""
    @State private var notificationStatus = ""
    @State private var notificationsEnabled = false
    @State private var notificationDevices: [MilaNotificationDevice] = []
    @State private var deploymentHost = ""
    @State private var deploymentPort = "22"
    @State private var deploymentTrust = ""
    @State private var deploymentStatus = ""
    var body: some View {
        Form {
            Section(MilaStrings.text(.signInTitle)) {
                Picker(MilaStrings.text(.signInTitle), selection: Binding(get: { session.selectedDeployment?.id }, set: { id in if let id, let value = session.deployments.first(where: { $0.id == id }) { session.select(value) } })) {
                    Text("—").tag(Optional<UUID>.none)
                    ForEach(session.deployments) { deployment in Text("\(deployment.host):\(deployment.port)").tag(Optional(deployment.id)) }
                }
                signInStatus
                HStack {
                    Button(MilaStrings.text(.signInStart)) { if let value = session.selectedDeployment { signIn.signIn(value) } }
                        .disabled(session.selectedDeployment == nil || isConnecting)
                    Button(MilaStrings.text(.reconnect)) { signIn.reconnect() }.disabled(session.selectedDeployment == nil || isConnecting)
                    Button(MilaStrings.text(.signInSignOut)) { signIn.signOut() }.disabled(signIn.phase == .signedOut)
                }
            }
            Section("Deployment") {
                TextField("Host", text: $deploymentHost)
                TextField("Port", text: $deploymentPort)
                TextField("Pinned trust", text: $deploymentTrust)
                Button("Save deployment") {
                    guard let port = UInt16(deploymentPort), let trust = Data(base64Encoded: deploymentTrust), session.upsert(MilaDeployment(host: deploymentHost, port: port, trust: trust)) else { deploymentStatus = "Invalid deployment"; return }
                    deploymentStatus = "Deployment saved"
                }
                ForEach(session.deployments) { deployment in
                    HStack {
                        Button { session.select(deployment) } label: {
                            VStack(alignment: .leading) { Text("\(deployment.host):\(deployment.port)"); Text(deployment.id == session.selectedDeployment?.id ? "Selected" : "") .font(.caption).foregroundStyle(.secondary) }
                        }.buttonStyle(.plain)
                        Spacer()
                        Button("Remove") { _ = session.remove(deployment.id) }
                    }
                }
                Text(deploymentStatus).font(.caption)
            }
            Section(MilaStrings.text(.appearance)) {
                Picker(MilaStrings.text(.appearance), selection: $appearance) {
                    Text(MilaStrings.text(.appearanceSystem)).tag("system")
                    Text(MilaStrings.text(.appearanceLight)).tag("light")
                    Text(MilaStrings.text(.appearanceDark)).tag("dark")
                }
                .pickerStyle(.segmented)
            }
            Section("Language") {
                Picker("Language", selection: $locale) {
                    ForEach(MilaStrings.supportedLocales, id: \.self) { candidate in
                        Text(MilaStrings.localeDisplayName(candidate)).tag(candidate)
                    }
                }
                .onChange(of: locale) { _, value in
                    let canonical = MilaStrings.canonicalLocale(value)
                    if canonical != value { locale = canonical }
                }
            }
            Section(MilaStrings.text(.lockTitle)) {
                Toggle(MilaStrings.text(.lockTitle), isOn: Binding(get: { appLockEnabled }, set: { value in
                    appLockEnabled = value
                    Task { await lockController.setEnabled(value) }
                }))
                    .disabled(!lockController.canEnable)
                if appLockEnabled {
                    Button("Lock now", systemImage: "lock.fill") {
                        lockController.lock()
                    }
                    .disabled(lockController.state == .locked || lockController.state == .unavailable)
                }
                Text(lockController.canEnable ? MilaStrings.text(.lockExplain) : MilaStrings.text(.lockUnavailable)).font(.caption).foregroundStyle(.secondary)
            }
            Section(MilaStrings.text(.notificationsTitle)) {
                Text(MilaStrings.text(.notificationsExplain)).font(.caption)
                SecureField("Device token", text: $notificationToken)
                    .textContentType(.oneTimeCode)
                TextField("https://deployment.example/push", text: $notificationEndpoint)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                HStack {
                    Button(notificationsEnabled ? MilaStrings.text(.notificationsTurnOff) : MilaStrings.text(.notificationsTurnOn)) {
                        if notificationsEnabled {
                            notificationsEnabled = false
                            notificationStatus = MilaStrings.text(.notificationsTurnOff)
                        } else {
                            let controller = MilaNotificationController(adapter: model.adapter ?? UnavailableMilaFFIAdapter(), appID: "com.overalls.mila", deployment: "current")
                            controller.register(token: notificationToken, endpoint: notificationEndpoint)
                            notificationsEnabled = controller.state == .on
                            notificationStatus = notificationsEnabled ? MilaStrings.text(.notificationsTurnOn) : MilaStrings.text(.runtimeUnavailable)
                            notificationToken = ""
                        }
                    }
                    Text(notificationsEnabled ? "[on]" : "[off]").font(.caption)
                }
                Text(notificationStatus).font(.caption).foregroundStyle(.secondary)
                if signIn.isSignedIn {
                    ForEach(notificationDevices) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.deployment)
                                Text(device.enabled ? "Enabled" : "Disabled").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") {
                                let store = MilaUserDefaultsNotificationStore()
                                _ = store.remove(id: device.id)
                                notificationDevices = store.list()
                            }
                        }
                    }
                    Button("Refresh devices") { notificationDevices = MilaUserDefaultsNotificationStore().list() }
                }
            }
            NavigationLink(MilaStrings.text(.sshKeysTitle)) {
                let adapter = model.adapter
                MilaSSHKeysView(
                    controller: MilaSSHKeysController(
                        loader: { try await (adapter ?? UnavailableMilaFFIAdapter()).listSSHKeys() },
                        revoker: { keyID in
                            let key = MilaSSHKey(id: keyID, fingerprint: "", algorithm: "")
                            try await (adapter ?? UnavailableMilaFFIAdapter()).revokeSSHKey(key, requestID: UUID())
                        }
                    ),
                    signedIn: adapter != nil
                )
            }
        }
        .navigationTitle(MilaStrings.text(.settings))
        .onAppear {
            notificationDevices = signIn.isSignedIn ? MilaUserDefaultsNotificationStore().list() : []
            // Defaults may contain values written by an older build. Normalize
            // them at the read boundary before they reach SwiftUI.
            let canonicalLocale = MilaStrings.canonicalLocale(locale)
            if canonicalLocale != locale { locale = canonicalLocale }
            if !["system", "light", "dark"].contains(appearance) { appearance = "system" }
        }
    }

    private var isConnecting: Bool { if case .connecting = signIn.phase { return true }; return false }

    @ViewBuilder private var signInStatus: some View {
        switch signIn.phase {
        case .signedOut:
            EmptyView()
        case .connecting:
            Text(MilaStrings.text(.signInConnectingHost, ["host": session.selectedDeployment?.host ?? ""])).font(.caption)
        case .awaitingApproval(_, let info):
            Text(MilaStrings.text(.signInApprove)).font(.caption)
            Button(MilaStrings.text(.signInOpenBrowser)) { openURL(info.url) }
            Text("\(MilaStrings.text(.signInFingerprint)): \(info.fingerprint)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        case .signedIn:
            Text(MilaStrings.text(.signedIn)).font(.caption)
        case .expired:
            Text(MilaStrings.text(.signInExpired)).font(.caption)
        case .failed(_, let failure):
            switch failure {
            case .unreachable: Text(MilaStrings.text(.signInFailedUnreachable)).font(.caption)
            case .refused: Text(MilaStrings.text(.signInFailedRefused)).font(.caption)
            case .protocolError: Text(MilaStrings.text(.signInFailedProtocol)).font(.caption)
            }
        }
    }
}

public struct MilaSSHKeysView: View {
    @StateObject private var controller: MilaSSHKeysController
    private let signedIn: Bool
    public init(controller: MilaSSHKeysController, signedIn: Bool = false) {
        _controller = StateObject(wrappedValue: controller)
        self.signedIn = signedIn
    }
    public var body: some View {
        List {
            Text(MilaStrings.text(.sshKeysExplain)).font(.caption)
            switch controller.state {
            case .signedOut: Text(MilaStrings.text(.sshKeysEmpty))
            case .loading: ProgressView()
            case .failed: Text(MilaStrings.text(.runtimeUnavailable))
            case .loaded(let keys):
                if keys.isEmpty { Text(MilaStrings.text(.sshKeysEmpty)) }
                ForEach(keys) { key in
                    HStack {
                        VStack(alignment: .leading) { Text(key.label ?? MilaStrings.text(.sshKeysTitle)); Text(key.fingerprint).font(.caption); Text("\(MilaStrings.text(.sshKeyAlgorithm)): \(key.algorithm)").font(.caption) }
                        Spacer()
                        if key.isCurrentDevice { Text(MilaStrings.text(.sshKeyThisDevice)).font(.caption) }
                        Button(MilaStrings.text(.sshKeyRevoke)) { Task { await controller.revoke(key) } }.disabled(key.isCurrentDevice)
                    }
                }
            }
        }.navigationTitle(MilaStrings.text(.sshKeysTitle)).task { await controller.load(signedIn: signedIn) }
    }
}

@MainActor public struct MilaNativeApp: App {
    public init() {}
    public init(adapter: any MilaFFIAdapter) { _ = adapter }
    public var body: some Scene { WindowGroup { MilaNativeRootView() } }
}

private struct MilaTerminalView: View {
    @StateObject private var terminal: MilaTerminalController
    @State private var command = ""
    init(transport: any MilaTerminalTransport) {
        _terminal = StateObject(wrappedValue: MilaTerminalController(transport: transport))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(MilaStrings.text(.terminal)).font(.title2)
            ScrollView { Text(String(decoding: terminal.output, as: UTF8.self)).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: .infinity).background(.black).foregroundStyle(.green)
            HStack { TextField(MilaStrings.text(.input), text: $command).onSubmit { send() }; Button(MilaStrings.text(.send)) { send() }; Button(MilaStrings.text(.reconnect)) { Task { await terminal.reconnect() } } }
            Text(stateText).font(.caption).foregroundStyle(.secondary)
        }.padding().task { await terminal.attach() }.onDisappear { Task { await terminal.close() } }
    }
    private var stateText: String {
        switch terminal.state {
        case .detached, .failed: return MilaStrings.text(.terminalEnded)
        case .attaching: return MilaStrings.text(.terminalAttaching)
        case .attached: return "\(MilaStrings.text(.terminalLive)) · \(terminal.columns)x\(terminal.rows)"
        case .reconnecting: return MilaStrings.text(.terminalReconnecting)
        }
    }
    private func send() { let data = Data((command + "\n").utf8); command = ""; Task { await terminal.sendInput(data) } }
}
