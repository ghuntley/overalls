import Foundation

/// Stable message identities shared with the Rust localization catalog.
public enum MilaMessage: String, Sendable { case appName, sharePrincipal, shareAdd, shareRemove, shareAdded, shareRemoved, machines, threads, settings, ready, refresh, connecting, connected, runtimeUnavailable, noAction, snapshotLoaded, noSnapshotLoaded, machinesEmpty, machinesHint, openTerminal, actionSubmitted, actionNotSubmitted, rejectedByRust, machineUnavailable, commandsRust, noThreads, threadsHint, unavailable, terminal, input, send, reconnect, appearance, appearanceSystem, appearanceLight, appearanceDark, lockTitle, lockExplain, lockUnavailable, lockUnlock, lockFailed, notificationsTitle, notificationsExplain, notificationsTurnOn, notificationsTurnOff, pushUnsupported, sshKeysTitle, sshKeysExplain, sshKeysEmpty, sshKeyRevoke, sshKeyAlgorithm, sshKeyThisDevice, webOpen, webInvalid, webPlaceholder, actionStart, actionStop, actionPause, actionResume, actionPin, actionUnpin, actionDelete, confirmDelete, cancel, retry, machineMore, signInStart, signInApprove, signInOpenBrowser, signInFingerprint, signInExpired, signInFailedRefused, signInFailedUnreachable, signInFailedProtocol, signInSignOut, signedIn, signInConnectingHost, threadsFailed, threadFailed, threadUntitled, threadPlanTitle, threadPlanApprove, threadPlanRevise, threadPlanRevisionHint, threadQuestionTitle, threadAnswerSend, threadComposerHint, threadWorking, webFailed, terminalEnded, terminalSignedOut, terminalLive, terminalAttaching, terminalReconnecting, signInTitle, shareRoleViewer, shareRoleOperator, shareRoleManager, actionCreate, actionResize }

public enum MilaStrings {
    /// The deterministic ordering emitted by the shared Rust locale policy.
    public static let supportedLocales = [
        "en", "zh-Hans", "hi", "es", "ar", "fr", "bn", "pt-BR", "pt-PT",
        "ru", "ur", "id", "de", "ja", "pcm", "mr", "te", "tr", "ta", "vi",
        "ko", "fil", "et", "fi", "sv", "arz", "sw", "ha",
    ]
    /// Canonicalize a user-selected BCP-47 locale to one of the bundled catalogs.
    public static func canonicalLocale(_ raw: String) -> String {
        let normalized = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64)).replacingOccurrences(of: "_", with: "-")
        let parts = normalized.split(separator: "-").map(String.init)
        guard let language = parts.first?.lowercased(), !language.isEmpty else { return "en" }
        let script = parts.dropFirst().first(where: { $0.count == 4 })?.capitalized
        let region = parts.dropFirst().first(where: { $0.count == 2 || $0.count == 3 && $0.allSatisfy(\.isNumber) })?.uppercased()
        let candidate = [language, script, region].compactMap { $0 }.joined(separator: "-")
        let supported = supportedLocales
        if supported.contains(candidate) { return candidate }
        // Region/script-qualified requests should fall back to the bundled
        // language catalog when no qualified catalog exists.
        return script == nil && supported.contains(language) ? language : "en"
    }
    /// Stable display names for the locale picker, independent of the host locale.
    public static func localeDisplayName(_ raw: String) -> String {
        switch canonicalLocale(raw) {
        case "zh-Hans": return "简体中文"; case "hi": return "हिन्दी"; case "es": return "Español"
        case "ar": return "العربية"; case "fr": return "Français"; case "bn": return "বাংলা"
        case "pt-BR": return "Português (Brasil)"; case "pt-PT": return "Português (Portugal)"
        case "ru": return "Русский"; case "ur": return "اردو"; case "id": return "Bahasa Indonesia"
        case "de": return "Deutsch"; case "ja": return "日本語"; case "pcm": return "Naijá"
        case "mr": return "मराठी"; case "te": return "తెలుగు"; case "tr": return "Türkçe"
        case "ta": return "தமிழ்"; case "vi": return "Tiếng Việt"; case "ko": return "한국어"
        case "fil": return "Filipino"; case "et": return "Eesti"; case "fi": return "Suomi"
        case "sv": return "Svenska"; case "arz": return "العربية (مصر)"; case "sw": return "Kiswahili"
        case "ha": return "Hausa"; default: return "English"
        }
    }

    private static let ids: [MilaMessage: String] = [
        .appName: "appTitle", .sharePrincipal: "sharePrincipal", .shareAdd: "shareAdd", .shareRemove: "shareRemove", .shareAdded: "shareAdded", .shareRemoved: "shareRemoved", .machines: "machinesTitle", .threads: "tabThreads", .settings: "settingsTitle",
        .ready: "ready", .refresh: "refresh", .connecting: "signInConnecting", .connected: "connected",
        .runtimeUnavailable: "runtimeUnavailable", .noAction: "noAction", .snapshotLoaded: "snapshotLoaded", .noSnapshotLoaded: "noSnapshotLoaded", .machinesEmpty: "machinesEmpty", .machinesHint: "machinesEmptyHint", .openTerminal: "terminalAttach", .actionSubmitted: "requestSucceeded", .actionNotSubmitted: "requestFailed", .rejectedByRust: "linkRefused", .machineUnavailable: "machineNotFound", .commandsRust: "threadEventTool", .noThreads: "threadsEmpty", .threadsHint: "threadsEmptyHint", .unavailable: "runtimeUnavailable", .terminal: "tabTerminals", .input: "threadAnswerHint", .send: "threadSend", .reconnect: "signInReconnect", .appearance: "appearance", .appearanceSystem: "appearanceSystem", .appearanceLight: "appearanceLight", .appearanceDark: "appearanceDark", .lockTitle: "lockTitle", .lockExplain: "lockExplain", .lockUnavailable: "lockUnavailable", .lockUnlock: "lockUnlock", .lockFailed: "lockFailed", .notificationsTitle: "notificationsTitle", .notificationsExplain: "notificationsExplain", .notificationsTurnOn: "notificationsTurnOn", .notificationsTurnOff: "notificationsTurnOff", .pushUnsupported: "pushUnsupported", .sshKeysTitle: "sshKeysTitle", .sshKeysExplain: "sshKeysExplain", .sshKeysEmpty: "sshKeysEmpty", .sshKeyRevoke: "sshKeyRevoke", .sshKeyAlgorithm: "sshKeyAlgorithm", .sshKeyThisDevice: "sshKeyThisDevice", .webOpen: "webOpen", .webInvalid: "webInvalid", .webPlaceholder: "webPlaceholder",
        .actionStart: "actionStart", .actionStop: "actionStop", .actionPause: "actionPause", .actionResume: "actionResume", .actionPin: "actionPin", .actionUnpin: "actionUnpin", .actionDelete: "actionDelete", .confirmDelete: "confirmDelete", .cancel: "cancel", .retry: "retry", .machineMore: "machineMore", .signInStart: "signInStart", .signInApprove: "signInApprove", .signInOpenBrowser: "signInOpenBrowser", .signInFingerprint: "signInFingerprint", .signInExpired: "signInExpired", .signInFailedRefused: "signInFailedRefused", .signInFailedUnreachable: "signInFailedUnreachable", .signInFailedProtocol: "signInFailedProtocol", .signInSignOut: "signInSignOut", .signedIn: "settingsSignedIn", .signInConnectingHost: "signInConnecting", .threadsFailed: "threadsFailed", .threadFailed: "threadFailed", .threadUntitled: "threadUntitled", .threadPlanTitle: "threadPlanTitle", .threadPlanApprove: "threadPlanApprove", .threadPlanRevise: "threadPlanRevise", .threadPlanRevisionHint: "threadPlanRevisionHint", .threadQuestionTitle: "threadQuestionTitle", .threadAnswerSend: "threadAnswerSend", .threadComposerHint: "threadComposerHint", .threadWorking: "threadWorking", .webFailed: "webFailed", .terminalEnded: "terminalEnded", .terminalSignedOut: "terminalSignedOut", .terminalLive: "terminalLive", .terminalAttaching: "terminalAttaching", .terminalReconnecting: "terminalReconnecting", .signInTitle: "signInTitle", .shareRoleViewer: "shareRoleViewer", .shareRoleOperator: "shareRoleOperator", .shareRoleManager: "shareRoleManager", .actionCreate: "actionCreate", .actionResize: "actionResize"
    ]

    /// Resolves a catalog message and substitutes named ICU-style `{placeholder}`
    /// arguments. A catalog form that still has an unresolved placeholder falls
    /// back to the English source so raw markup never reaches the UI.
    public static func text(_ message: MilaMessage, _ arguments: [String: String], locale: Locale = .current) -> String {
        func fill(_ template: String) -> String {
            arguments.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
        }
        let value = fill(text(message, locale: locale))
        return hasPlaceholder(value) ? fill(fallback(message)) : value
    }

    static func hasPlaceholder(_ value: String) -> Bool {
        value.range(of: "\\{[A-Za-z_][A-Za-z0-9_]*\\}", options: .regularExpression) != nil
    }

    public static func text(_ message: MilaMessage, locale: Locale = .current) -> String {
        let candidates: [String] = [
            locale.identifier.replacingOccurrences(of: "_", with: "-"),
            locale.language.languageCode?.identifier ?? "en",
            "en",
        ]
        for candidate in candidates {
            if let value = resourceValue(message, locale: candidate) {
                // Argument-free callers of a templated catalog form (for example the
                // generic connecting status) use the placeholder-free fallback.
                return hasPlaceholder(value) && !hasPlaceholder(fallback(message)) ? fallback(message) : value
            }
        }
        return fallback(message)
    }

    static func fallback(_ message: MilaMessage) -> String {
        switch message {
        case .appName: return "Mila"; case .sharePrincipal: return "Share principal"; case .shareAdd: return "Share"; case .shareRemove: return "Remove share"; case .shareAdded: return "Share added"; case .shareRemoved: return "Share removed"; case .machines: return "Machines"; case .threads: return "Threads"; case .settings: return "Settings"
        case .ready: return "Ready"; case .refresh: return "Refresh"; case .connecting: return "Connecting…"; case .connected: return "Connected"
        case .runtimeUnavailable: return "Native runtime unavailable"; case .appearance: return "Appearance"; case .appearanceSystem: return "System"; case .appearanceLight: return "Light"; case .appearanceDark: return "Dark"; case .lockTitle: return "App lock"; case .lockExplain: return "Ask for your fingerprint, face or device passcode before showing Mila."; case .lockUnavailable: return "App lock is not available on this device."; case .lockUnlock: return "Unlock Mila"; case .lockFailed: return "Authentication failed."; case .noAction: return "No action selected"; case .snapshotLoaded: return "Snapshot loaded"; case .noSnapshotLoaded: return "No snapshot loaded"; case .machinesEmpty: return "No machines"; case .machinesHint: return "Connect to a deployment to load a validated snapshot."; case .openTerminal: return "Open terminal"; case .actionSubmitted: return "Action submitted"; case .actionNotSubmitted: return "Action not submitted"; case .rejectedByRust: return "Rejected by Rust"; case .machineUnavailable: return "Machine unavailable"; case .commandsRust: return "Commands are classified by Rust before execution."; case .noThreads: return "No threads"; case .threadsHint: return "Connect to a deployment to load threads."; case .unavailable: return "Unavailable"; case .terminal: return "Terminal"; case .input: return "Input"; case .send: return "Send"; case .reconnect: return "Reconnect"; case .notificationsTitle: return "Notifications"; case .notificationsExplain: return "Notifications tell you when an agent needs your input."; case .notificationsTurnOn: return "Turn on"; case .notificationsTurnOff: return "Turn off"; case .pushUnsupported: return "Notifications are not available on this platform."; case .webOpen: return "Open web"; case .webInvalid: return "Invalid HTTPS URL"; case .webPlaceholder: return "https://machine.example"; case .sshKeysTitle: return "SSH keys"; case .sshKeysExplain: return "Keys approved to sign in to your account on this deployment."; case .sshKeysEmpty: return "No approved keys."; case .sshKeyRevoke: return "Revoke"; case .sshKeyAlgorithm: return "Type"; case .sshKeyThisDevice: return "This device"
        case .actionStart: return "Start"
        case .actionStop: return "Stop"
        case .actionPause: return "Pause"
        case .actionResume: return "Resume"
        case .actionPin: return "Pin"
        case .actionUnpin: return "Unpin"
        case .actionDelete: return "Delete"
        case .confirmDelete: return "Delete {name} and its disk? This cannot be undone."
        case .cancel: return "Cancel"
        case .retry: return "Try again"
        case .machineMore: return "Show more"
        case .signInStart: return "Sign in with browser"
        case .signInApprove: return "Approve this device in your browser, then return here. Keep Mila open until you have approved it."
        case .signInOpenBrowser: return "Open approval page"
        case .signInFingerprint: return "Key fingerprint"
        case .signInExpired: return "The approval link is no longer valid. Start again to get a new one."
        case .signInFailedRefused: return "The deployment refused this device."
        case .signInFailedUnreachable: return "The deployment cannot be reached."
        case .signInFailedProtocol: return "The deployment sent a reply Mila does not understand."
        case .signInSignOut: return "Sign out"
        case .signedIn: return "Signed in"
        case .signInConnectingHost: return "Connecting to {host}…"
        case .threadsFailed: return "Threads could not be loaded."
        case .threadFailed: return "This thread could not be loaded."
        case .threadUntitled: return "Untitled thread"
        case .threadPlanTitle: return "Proposed plan"
        case .threadPlanApprove: return "Approve"
        case .threadPlanRevise: return "Ask for changes"
        case .threadPlanRevisionHint: return "What should change?"
        case .threadQuestionTitle: return "The agent asks"
        case .threadAnswerSend: return "Send answer"
        case .threadComposerHint: return "Message the agent"
        case .threadWorking: return "working"
        case .webFailed: return "The web address could not be loaded."
        case .terminalEnded: return "The terminal session ended."
        case .terminalSignedOut: return "This device is no longer authorized. Sign in again to attach."
        case .terminalLive: return "live"
        case .terminalAttaching: return "attaching"
        case .terminalReconnecting: return "reconnecting"
        case .signInTitle: return "Sign in"
        case .shareRoleViewer: return "viewer"
        case .shareRoleOperator: return "operator"
        case .shareRoleManager: return "manager"
        case .actionCreate: return "Create"
        case .actionResize: return "Resize"
        }
    }

    /// SwiftPM's `Bundle.module` looks only at the app bundle's root and the
    /// build directory. A signed macOS app cannot hold a bundle at its root, so
    /// the host app places it under `Contents/Resources`; check there first.
    private static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("MilaNativeUI_MilaNativeUI.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    private static func resourceValue(_ message: MilaMessage, locale: String) -> String? {
        guard let url = resources.url(forResource: locale, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let domains = root["domains"] as? [String: Any],
              let mila = domains["mila"] as? [String: Any],
              let messages = mila["messages"] as? [[String: Any]] else { return nil }
        guard let entry = messages.first(where: { $0["id"] as? String == ids[message] }),
              let forms = entry["forms"] as? [Any],
              let first = forms.first as? String else { return nil }
        return first
    }
}
