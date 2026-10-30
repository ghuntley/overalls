import Foundation
import Synchronization

/// Stable message identities shared with the Rust localization catalog.
public enum MilaMessage: String, Sendable, CaseIterable { case appName, sharePrincipal, shareAdd, shareRemove, shareAdded, shareRemoved, machines, threads, settings, ready, refresh, connecting, runtimeUnavailable, noSnapshotLoaded, machinesEmpty, openTerminal, actionSubmitted, actionNotSubmitted, machineUnavailable, noThreads, threadsHint, unavailable, terminal, input, send, reconnect, appearance, appearanceSystem, appearanceLight, appearanceDark, lockTitle, lockExplain, lockUnavailable, lockUnlock, lockFailed, notificationsTitle, notificationsExplain, notificationsTurnOn, notificationsTurnOff, pushUnsupported, sshKeysTitle, sshKeysExplain, sshKeysEmpty, sshKeyRevoke, sshKeyAlgorithm, sshKeyThisDevice, webOpen, actionStart, actionStop, actionPause, actionResume, actionPin, actionUnpin, actionDelete, confirmDelete, cancel, retry, machineMore, signInStart, signInApprove, signInOpenBrowser, signInFingerprint, signInExpired, signInFailedRefused, signInFailedUnreachable, signInFailedProtocol, signInSignOut, signedIn, signInConnectingHost, threadsFailed, threadFailed, threadUntitled, threadPlanTitle, threadPlanApprove, threadPlanRevise, threadPlanRevisionHint, threadQuestionTitle, threadAnswerSend, threadComposerHint, threadWorking, webFailed, terminalEnded, terminalSignedOut, terminalLive, terminalAttaching, terminalReconnecting, signInTitle, shareRoleViewer, shareRoleOperator, shareRoleManager, actionCreate, actionResize, shareRole, sshKeysFailed, lockReason, lockedTitle, notificationsFailed, fieldCpu, fieldMemory, fieldDisk, deployments, deploymentHost, deploymentRemove, notificationsRemoveDevice, settingsLanguage, machineName, deploymentPort, deploymentTrust, deploymentSave, lockNow, pushEndpointHint }

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
    /// Text direction for a bundled catalog tag, matching the Rust policy.
    public static func isRightToLeft(_ tag: String) -> Bool { ["ar", "arz", "ur"].contains(canonicalLocale(tag)) }
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
        .appName: "appTitle", .sharePrincipal: "sharingEmail", .shareAdd: "sharingAdd", .shareRemove: "sharingRemove", .shareAdded: "requestSucceeded", .shareRemoved: "requestSucceeded", .machines: "machinesTitle", .threads: "tabThreads", .settings: "settingsTitle",
        .ready: "signInTitle", .refresh: "refresh", .connecting: "requestWaiting", 
        .runtimeUnavailable: "stateUnavailable",  .noSnapshotLoaded: "requestFailed", .machinesEmpty: "machinesEmpty",  .openTerminal: "terminalAttach", .actionSubmitted: "requestSucceeded", .actionNotSubmitted: "requestFailed",  .machineUnavailable: "machineNotFound",  .noThreads: "threadsEmpty", .threadsHint: "threadsEmptyHint", .unavailable: "stateUnavailable", .terminal: "tabTerminals", .input: "threadAnswerHint", .send: "threadSend", .reconnect: "signInReconnect", .appearance: "appearance", .appearanceSystem: "appearanceSystem", .appearanceLight: "appearanceLight", .appearanceDark: "appearanceDark", .lockTitle: "lockTitle", .lockExplain: "lockExplain", .lockUnavailable: "lockUnavailable", .lockUnlock: "unlock", .lockFailed: "lockFailed", .notificationsTitle: "notificationsTitle", .notificationsExplain: "notificationsExplain", .notificationsTurnOn: "notificationsTurnOn", .notificationsTurnOff: "notificationsTurnOff", .pushUnsupported: "pushUnsupported", .sshKeysTitle: "sshKeysTitle", .sshKeysExplain: "sshKeysExplain", .sshKeysEmpty: "sshKeysEmpty", .sshKeyRevoke: "sshKeyRevoke", .sshKeyAlgorithm: "sshKeyAlgorithm", .sshKeyThisDevice: "sshKeyThisDevice", .webOpen: "webOpen", 
        .actionStart: "actionStart", .actionStop: "actionStop", .actionPause: "actionPause", .actionResume: "actionResume", .actionPin: "actionPin", .actionUnpin: "actionUnpin", .actionDelete: "actionDelete", .confirmDelete: "confirmDelete", .cancel: "cancel", .retry: "retry", .machineMore: "machineMore", .signInStart: "signInStart", .signInApprove: "signInApprove", .signInOpenBrowser: "signInOpenBrowser", .signInFingerprint: "signInFingerprint", .signInExpired: "signInExpired", .signInFailedRefused: "signInFailedRefused", .signInFailedUnreachable: "signInFailedUnreachable", .signInFailedProtocol: "signInFailedProtocol", .signInSignOut: "signInSignOut", .signedIn: "settingsSignedIn", .signInConnectingHost: "signInConnecting", .threadsFailed: "threadsFailed", .threadFailed: "threadFailed", .threadUntitled: "threadUntitled", .threadPlanTitle: "threadPlanTitle", .threadPlanApprove: "threadPlanApprove", .threadPlanRevise: "threadPlanRevise", .threadPlanRevisionHint: "threadPlanRevisionHint", .threadQuestionTitle: "threadQuestionTitle", .threadAnswerSend: "threadAnswerSend", .threadComposerHint: "threadComposerHint", .threadWorking: "threadWorking", .webFailed: "webFailed", .terminalEnded: "terminalEnded", .terminalSignedOut: "terminalSignedOut", .terminalLive: "terminalLive", .terminalAttaching: "terminalAttaching", .terminalReconnecting: "terminalReconnecting", .signInTitle: "signInTitle", .shareRoleViewer: "shareRoleViewer", .shareRoleOperator: "shareRoleOperator", .shareRoleManager: "shareRoleManager", .actionCreate: "actionCreate", .actionResize: "actionResize", .shareRole: "sharingRole", .sshKeysFailed: "sshKeysFailed", .lockReason: "lockReason", .lockedTitle: "lockedTitle", .notificationsFailed: "pushFailedRefused", .fieldCpu: "kvCpu", .fieldMemory: "memoryFieldMib", .fieldDisk: "diskFieldGib", .deployments: "deploymentsTitle", .deploymentHost: "deploymentHostLabel", .deploymentRemove: "deploymentRemove", .notificationsRemoveDevice: "notificationsRemoveDevice", .settingsLanguage: "settingsLanguage", .machineName: "machineName", .deploymentPort: "deploymentPortLabel", .deploymentTrust: "deploymentTrustLabel", .deploymentSave: "deploymentSave", .lockNow: "lockNow", .pushEndpointHint: "pushEndpointHint"
    ]

    /// Resolves a catalog message and substitutes named ICU-style `{placeholder}`
    /// arguments. A catalog form that still has an unresolved placeholder falls
    /// back to the English source so raw markup never reaches the UI.
    public static func text(_ message: MilaMessage, _ arguments: [String: String], locale: Locale? = nil) -> String {
        func fill(_ template: String) -> String {
            arguments.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
        }
        let value = fill(text(message, locale: locale))
        return hasPlaceholder(value) ? fill(fallback(message)) : value
    }

    static func hasPlaceholder(_ value: String) -> Bool {
        value.range(of: "\\{[A-Za-z_][A-Za-z0-9_]*\\}", options: .regularExpression) != nil
    }

    /// The stored per-device language override (`mila.locale`). Empty means
    /// "follow the device language".
    public static let localeOverrideKey = "mila.locale"

    /// @cc [owner:ghuntley,label:localization] mila-apple-locale-precedence
    /// Resolve the bundled catalog tag for an explicit override and the
    /// device's preferred languages: a valid stored override MUST win, then the
    /// first preferred language with a bundled catalog, then English. A
    /// malformed or unsupported override MUST NOT pin the UI to English.
    public static func activeLocale(override: String?, preferredLanguages: [String]) -> String {
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let canonical = canonicalLocale(override)
            if canonical != "en" || override.lowercased().hasPrefix("en") { return canonical }
        }
        for language in preferredLanguages.prefix(16) {
            if let tag = bundledLocale(for: Locale(identifier: language)) { return tag }
        }
        return "en"
    }

    /// The locale the UI renders in now, read from the stored override and the
    /// device language list.
    public static func activeLocale(defaults: UserDefaults = .standard) -> String {
        activeLocale(override: defaults.string(forKey: localeOverrideKey), preferredLanguages: Locale.preferredLanguages)
    }

    /// Map a system locale to a bundled catalog tag. The exact form is tried
    /// first, then the likely script (`zh-CN` resolves to `zh-Hans`), then the
    /// likely region (`pt` resolves to `pt-BR`), then the bare language.
    /// Unlike `canonicalLocale`, which validates a user-entered tag exactly as
    /// the Rust policy does, this expands a device locale with CLDR likely
    /// subtags so a device in a supported language is not shown English.
    public static func bundledLocale(for locale: Locale) -> String? {
        let exact = canonicalLocale(locale.identifier)
        if exact != "en" { return exact }
        let maximal = Locale.Language(identifier: locale.identifier).maximalIdentifier
        let parts = maximal.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let language = parts.first?.lowercased(), !language.isEmpty else { return nil }
        let script = parts.dropFirst().first(where: { $0.count == 4 })?.capitalized
        let region = parts.dropFirst().first(where: { $0.count == 2 })?.uppercased()
        let candidates = [script.map { "\(language)-\($0)" }, region.map { "\(language)-\($0)" }, language].compactMap { $0 }
        return candidates.first { supportedLocales.contains($0) }
    }

    /// Resolve a message in `locale`, or in the active locale when nil.
    public static func text(_ message: MilaMessage, locale: Locale? = nil) -> String {
        let tag = locale.map { bundledLocale(for: $0) ?? "en" } ?? activeLocale()
        for candidate in tag == "en" ? ["en"] : [tag, "en"] {
            if let value = resourceValue(message, locale: candidate) {
                // Argument-free callers of a templated catalog form (for example the
                // generic connecting status) use the placeholder-free fallback.
                return hasPlaceholder(value) && !hasPlaceholder(fallback(message)) ? fallback(message) : value
            }
        }
        return fallback(message)
    }

    /// The catalog id a message resolves through; exposed for catalog tests.
    static func catalogID(_ message: MilaMessage) -> String? { ids[message] }

    static func fallback(_ message: MilaMessage) -> String {
        switch message {
        case .appName: return "Mila"; case .sharePrincipal: return "Email"; case .shareAdd: return "Share"; case .shareRemove: return "Remove"; case .shareAdded: return "Done."; case .shareRemoved: return "Done."; case .machines: return "Machines"; case .threads: return "Threads"; case .settings: return "Settings"
        case .ready: return "Sign in"; case .refresh: return "Refresh"; case .connecting: return "Waiting for the request to finish…";
        case .runtimeUnavailable: return "unavailable"; case .appearance: return "Appearance"; case .appearanceSystem: return "System"; case .appearanceLight: return "Light"; case .appearanceDark: return "Dark"; case .lockTitle: return "App lock"; case .lockExplain: return "Ask for your fingerprint, face or device passcode before showing Mila."; case .lockUnavailable: return "App lock is not available on this device."; case .lockUnlock: return "Unlock"; case .lockFailed: return "Not unlocked. Try again."; case .noSnapshotLoaded: return "The request failed."; case .machinesEmpty: return "No machines"; case .openTerminal: return "Open terminal"; case .actionSubmitted: return "Action submitted"; case .actionNotSubmitted: return "Action not submitted"; case .machineUnavailable: return "Machine unavailable"; case .noThreads: return "No threads"; case .threadsHint: return "Connect to a deployment to load threads."; case .unavailable: return "unavailable"; case .terminal: return "Terminal"; case .input: return "Input"; case .send: return "Send"; case .reconnect: return "Reconnect"; case .notificationsTitle: return "Notifications"; case .notificationsExplain: return "Notifications tell you when an agent needs your input."; case .notificationsTurnOn: return "Turn on"; case .notificationsTurnOff: return "Turn off"; case .pushUnsupported: return "Notifications are not available on this platform."; case .webOpen: return "Open web"; case .sshKeysTitle: return "SSH keys"; case .sshKeysExplain: return "Keys approved to sign in to your account on this deployment."; case .sshKeysEmpty: return "No approved keys."; case .sshKeyRevoke: return "Revoke"; case .sshKeyAlgorithm: return "Type"; case .sshKeyThisDevice: return "This device"
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
        case .shareRole: return "Role"; case .sshKeysFailed: return "The keys could not be loaded."; case .lockReason: return "Unlock Mila"; case .lockedTitle: return "Mila is locked"; case .notificationsFailed: return "The deployment or the notification relay refused this device."
        case .fieldCpu: return "CPU"; case .fieldMemory: return "Memory (MiB)"; case .fieldDisk: return "Disk (GiB)"; case .deployments: return "Deployments"; case .deploymentHost: return "Deployment host"; case .deploymentRemove: return "Remove"; case .notificationsRemoveDevice: return "Remove"
        case .settingsLanguage: return "Language"; case .machineName: return "Name"; case .deploymentPort: return "Port"; case .deploymentTrust: return "Pinned trust"; case .deploymentSave: return "Save deployment"; case .lockNow: return "Lock now"; case .pushEndpointHint: return "https://deployment.example/push"
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

    /// Parsed `id -> first form` tables, loaded once per bundled locale.
    private static let catalogs = Mutex<[String: [String: String]]>([:])

    static func catalog(_ locale: String) -> [String: String]? {
        if let cached = catalogs.withLock({ $0[locale] }) { return cached }
        guard supportedLocales.contains(locale),
              let url = resources.url(forResource: locale, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let domains = root["domains"] as? [String: Any],
              let mila = domains["mila"] as? [String: Any],
              let messages = mila["messages"] as? [[String: Any]] else { return nil }
        var table: [String: String] = [:]
        for entry in messages {
            guard let id = entry["id"] as? String, let forms = entry["forms"] as? [Any],
                  let first = forms.first as? String, !first.isEmpty else { continue }
            table[id] = first
        }
        catalogs.withLock { $0[locale] = table }
        return table
    }

    private static func resourceValue(_ message: MilaMessage, locale: String) -> String? {
        guard let id = ids[message] else { return nil }
        return catalog(locale)?[id]
    }
}
