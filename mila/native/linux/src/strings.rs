//! Stable message identities for the GTK client.

use std::{collections::HashMap, fs, sync::OnceLock};

#[derive(Clone, Copy)]
pub(crate) enum Message {
    AppName,
    Machines,
    Threads,
    Settings,
    Ready,
    LockTitle,
    LockUnavailable,
    LockExplain,
    DeploymentSelect,
    ThreadList,
    ThreadShow,
    ThreadPrompt,
    ThreadAnswer,
    ThreadPlanApprove,
    ThreadPlanRevise,
    DeploymentForgotten,
    DeploymentForgetFailed,
    AttachTerminal,
    MachineUuid,
    ThreadId,
    WebShow,
    WebPublic,
    WebPrivate,
    ShareEmail,
    ShareRole,
    ShareAdd,
    ShareRemove,
    ShareLoad,
    Appearance,
    AppearanceSystem,
    AppearanceLight,
    AppearanceDark,
    Locale,
    SaveSettings,
    SignInStart,
    SignInDeploymentRequired,
    SignInConnecting,
    SignInApprove,
    SignInOpenBrowser,
    SignInSignOut,
    SignInReconnect,
    SignInFingerprint,
    SignInAccount,
    SignInDisconnected,
    SignInExpired,
    SignInFailedHost,
    SignInFailedRefused,
    SignInFailedUnreachable,
    SignInFailedProtocol,
    SignInFailedDeviceKey,
    SignInProfileInvalid,
    NotificationsTitle,
    NotificationsExplain,
    PushUnsupported,
    NotificationDevices,
    NotificationDeviceId,
    NotificationRefresh,
    NotificationRemove,
    NotificationEnable,
    NotificationDisable,
    NotificationRequireSignIn,
    NotificationAccepted,
    NotificationRejected,
    DeploymentsTitle,
    DeploymentAddAndSelect,
    DeploymentOpen,
    DeploymentRemove,
    DeploymentSelected,
    DeploymentsEmpty,
    DeploymentRemoveConfirm,
    Cancel,
    Refresh,
    SignInTitle,
    LinkRefused,
    LinkUnknownDeployment,
    LinkSignInRequired,
    LinkCopy,
    LinkCopied,
    TerminalsTitle,
    TerminalSend,
    TerminalReconnect,
    TerminalResize,
    TerminalClose,
    TerminalLive,
    TerminalEnded,
    TerminalSignedOut,
    TerminalInvalid,
    TerminalUnreachable,
    SshKeysTitle,
    SshKeysExplain,
    SshKeysSignInFirst,
    SshKeysFailed,
    SshKeysLoading,
    SshKeysEmpty,
    SshKeyUnlabelled,
    SshKeyRevoke,
    SshKeyThisDevice,
    SshKeyRevokeConfirm,
    RequestWaiting,
    RequestSucceeded,
    RequestRefused,
}
fn id(message: Message) -> &'static str {
    match message {
        Message::AppName => "appTitle",
        Message::Machines => "machinesTitle",
        Message::Threads => "tabThreads",
        Message::Settings => "settingsTitle",
        Message::Ready => "ready",
        Message::LockTitle => "lockTitle",
        Message::LockUnavailable => "lockUnavailable",
        Message::LockExplain => "lockExplain",
        Message::DeploymentSelect => "deploymentHostLabel",
        Message::ThreadList => "tabThreads",
        Message::ThreadShow => "threadTitle",
        Message::ThreadPrompt => "threadPrompt",
        Message::ThreadAnswer => "threadAnswer",
        Message::ThreadPlanApprove => "threadPlanApprove",
        Message::ThreadPlanRevise => "threadPlanRevise",
        Message::DeploymentForgotten => "deploymentForgotten",
        Message::DeploymentForgetFailed => "deploymentForgetFailed",
        Message::AttachTerminal => "terminalAttach",
        Message::MachineUuid => "machineIdLabel",
        Message::ThreadId => "threadIdLabel",
        Message::WebShow => "webOpen",
        Message::WebPublic => "webPublic",
        Message::WebPrivate => "webPrivate",
        Message::ShareEmail => "sharingEmail",
        Message::ShareRole => "sharingRole",
        Message::ShareAdd => "sharingAdd",
        Message::ShareRemove => "sharingRemove",
        Message::ShareLoad => "sharingLoad",
        Message::Appearance => "appearance",
        Message::AppearanceSystem => "appearanceSystem",
        Message::AppearanceLight => "appearanceLight",
        Message::AppearanceDark => "appearanceDark",
        Message::Locale => "locale",
        Message::SaveSettings => "settingsSave",
        Message::SignInStart => "signInStart",
        Message::SignInDeploymentRequired => "signInDeploymentRequired",
        Message::SignInConnecting => "signInConnecting",
        Message::SignInApprove => "signInApprove",
        Message::SignInOpenBrowser => "signInOpenBrowser",
        Message::SignInSignOut => "signInSignOut",
        Message::SignInReconnect => "signInReconnect",
        Message::SignInFingerprint => "signInFingerprint",
        Message::SignInAccount => "signInAccount",
        Message::SignInDisconnected => "signInDisconnected",
        Message::SignInExpired => "signInExpired",
        Message::SignInFailedHost => "signInFailedHost",
        Message::SignInFailedRefused => "signInFailedRefused",
        Message::SignInFailedUnreachable => "signInFailedUnreachable",
        Message::SignInFailedProtocol => "signInFailedProtocol",
        Message::SignInFailedDeviceKey => "signInFailedDeviceKey",
        Message::SignInProfileInvalid => "signInProfileInvalid",
        Message::NotificationsTitle => "notificationsTitle",
        Message::NotificationsExplain => "notificationsExplain",
        Message::PushUnsupported => "pushUnsupported",
        Message::NotificationDevices => "notificationDevices",
        Message::NotificationDeviceId => "notificationDeviceId",
        Message::NotificationRefresh => "notificationRefresh",
        Message::NotificationRemove => "notificationRemove",
        Message::NotificationEnable => "notificationEnable",
        Message::NotificationDisable => "notificationDisable",
        Message::NotificationRequireSignIn => "notificationRequireSignIn",
        Message::NotificationAccepted => "notificationAccepted",
        Message::NotificationRejected => "notificationRejected",
        Message::DeploymentsTitle => "deploymentsTitle",
        Message::DeploymentAddAndSelect => "addDeployment",
        Message::DeploymentOpen => "deploymentOpen",
        Message::DeploymentRemove => "deploymentRemove",
        Message::DeploymentSelected => "deploymentSelected",
        Message::DeploymentsEmpty => "deploymentsEmpty",
        Message::DeploymentRemoveConfirm => "deploymentRemoveConfirm",
        Message::Cancel => "cancel",
        Message::Refresh => "refresh",
        Message::SignInTitle => "signInTitle",
        Message::LinkRefused => "linkRefused",
        Message::LinkUnknownDeployment => "linkUnknownDeployment",
        Message::LinkSignInRequired => "linkSignInRequired",
        Message::LinkCopy => "linkCopy",
        Message::LinkCopied => "linkCopied",
        Message::TerminalsTitle => "tabTerminals",
        Message::TerminalSend => "terminalSend",
        Message::TerminalReconnect => "terminalReconnect",
        Message::TerminalResize => "terminalResize",
        Message::TerminalClose => "terminalClose",
        Message::TerminalLive => "terminalLive",
        Message::TerminalEnded => "terminalEnded",
        Message::TerminalSignedOut => "terminalSignedOut",
        Message::TerminalInvalid => "terminalInvalid",
        Message::TerminalUnreachable => "terminalUnreachable",
        Message::SshKeysTitle => "sshKeysTitle",
        Message::SshKeysExplain => "sshKeysExplain",
        Message::SshKeysSignInFirst => "sshKeysSignInFirst",
        Message::SshKeysFailed => "sshKeysFailed",
        Message::SshKeysLoading => "sshKeysLoading",
        Message::SshKeysEmpty => "sshKeysEmpty",
        Message::SshKeyUnlabelled => "sshKeyUnlabelled",
        Message::SshKeyRevoke => "sshKeyRevoke",
        Message::SshKeyThisDevice => "sshKeyThisDevice",
        Message::SshKeyRevokeConfirm => "sshKeyRevokeConfirm",
        Message::RequestWaiting => "requestWaiting",
        Message::RequestSucceeded => "requestSucceeded",
        Message::RequestRefused => "requestRefused",
    }
}

pub(crate) fn text(message: Message) -> String {
    catalog()
        .get(id(message))
        .cloned()
        .unwrap_or_else(|| fallback(message).to_owned())
}

/// First strong isolate / pop directional isolate around interpolated values,
/// so a host or fingerprint keeps its own direction inside RTL sentences.
const FSI: char = '\u{2068}';
const PDI: char = '\u{2069}';

/// Substitutes `{name}` placeholders. Values are isolated with FSI/PDI and
/// stripped of control and bidi formatting characters; unknown placeholders
/// stay literal.
pub(crate) fn format(message: Message, values: &[(&str, &str)]) -> String {
    interpolate(&text(message), values)
}

fn interpolate(form: &str, values: &[(&str, &str)]) -> String {
    let mut output = form.to_owned();
    for (name, value) in values {
        let clean = value
            .chars()
            .filter(|character| {
                !character.is_control()
                    && !matches!(character, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
            })
            .collect::<String>();
        output = output.replace(&format!("{{{name}}}"), &format!("{FSI}{clean}{PDI}"));
    }
    output
}

fn fallback(message: Message) -> &'static str {
    match message {
        Message::AppName => "Mila",
        Message::Machines => "Machines",
        Message::Threads => "Threads",
        Message::Settings => "Settings",
        Message::Ready => "Ready",
        Message::LockTitle => "App lock",
        Message::LockUnavailable => "App lock is unavailable on Linux.",
        Message::LockExplain => "This device does not provide a native app-lock authenticator.",
        Message::DeploymentSelect => "Deployment host",
        Message::ThreadList => "Threads",
        Message::ThreadShow => "Show thread",
        Message::ThreadPrompt => "Prompt",
        Message::ThreadAnswer => "Answer",
        Message::ThreadPlanApprove => "Approve plan",
        Message::ThreadPlanRevise => "Revise plan",
        Message::DeploymentForgotten => "Deployment forgotten.",
        Message::DeploymentForgetFailed => "Deployment could not be forgotten.",
        Message::AttachTerminal => "Attach terminal",
        Message::MachineUuid => "Machine UUID",
        Message::ThreadId => "Thread ID",
        Message::WebShow => "Web show",
        Message::WebPublic => "Web set public",
        Message::WebPrivate => "Web set private",
        Message::ShareEmail => "Share email",
        Message::ShareRole => "Role: viewer, operator, or manager",
        Message::ShareAdd => "Share machine",
        Message::ShareRemove => "Remove share",
        Message::ShareLoad => "Load sharing",
        Message::Appearance => "Appearance",
        Message::AppearanceSystem => "System",
        Message::AppearanceLight => "Light",
        Message::AppearanceDark => "Dark",
        Message::Locale => "Locale",
        Message::SaveSettings => "Save settings",
        Message::SignInStart => "Sign in with browser",
        Message::SignInDeploymentRequired => "Select a deployment before signing in.",
        Message::SignInConnecting => "Connecting to {host}…",
        Message::SignInApprove => "Approve this device in your browser, then return here. Keep Mila open until you have approved it.",
        Message::SignInOpenBrowser => "Open approval page",
        Message::SignInSignOut => "Sign out",
        Message::SignInReconnect => "Reconnect",
        Message::SignInFingerprint => "Key fingerprint",
        Message::SignInAccount => "Account",
        Message::SignInDisconnected => "The connection to this deployment closed.",
        Message::SignInExpired => "The approval link is no longer valid. Start again to get a new one.",
        Message::SignInFailedHost => "This host did not present a certificate from its published authority, so Mila did not connect.",
        Message::SignInFailedRefused => "The deployment refused this device.",
        Message::SignInFailedUnreachable => "The deployment cannot be reached.",
        Message::SignInFailedProtocol => "The deployment sent a reply Mila does not understand.",
        Message::SignInFailedDeviceKey => "Mila could not open this device's key, so it did not connect.",
        Message::SignInProfileInvalid => "This deployment's connection settings are invalid, so Mila did not connect.",
        Message::NotificationsTitle => "Notifications",
        Message::NotificationsExplain => "Notifications are unavailable on Linux.",
        Message::PushUnsupported => "Notifications are not available on this platform.",
        Message::NotificationDevices => "Notification devices",
        Message::NotificationDeviceId => "Device ID",
        Message::NotificationRefresh => "Refresh devices",
        Message::NotificationRemove => "Remove device",
        Message::NotificationEnable => "Enable device",
        Message::NotificationDisable => "Disable device",
        Message::NotificationRequireSignIn => "Notification device controls require sign-in.",
        Message::NotificationAccepted => "Notification device request accepted.",
        Message::NotificationRejected => "Notification device request rejected.",
        Message::DeploymentsTitle => "Deployments",
        Message::DeploymentAddAndSelect => "Add deployment",
        Message::DeploymentOpen => "Open",
        Message::DeploymentRemove => "Remove",
        Message::DeploymentSelected => "Selected",
        Message::DeploymentsEmpty => "No deployments yet.",
        Message::DeploymentRemoveConfirm => "Remove {host} from Mila? Its saved machine list and this device's notifications are removed. Your account and machines are not changed.",
        Message::Cancel => "Cancel",
        Message::Refresh => "Refresh",
        Message::SignInTitle => "Sign in",
        Message::LinkRefused => "Mila cannot open this link.",
        Message::LinkUnknownDeployment => "Add {host} as a deployment to open this link.",
        Message::LinkSignInRequired => "Sign in to {host} to open this link.",
        Message::LinkCopy => "Copy link",
        Message::LinkCopied => "Link copied.",
        Message::TerminalsTitle => "Terminals",
        Message::TerminalSend => "Send",
        Message::TerminalReconnect => "Reconnect",
        Message::TerminalResize => "Resize",
        Message::TerminalClose => "Close",
        Message::TerminalLive => "live",
        Message::TerminalEnded => "The terminal session ended.",
        Message::TerminalSignedOut => "This device is no longer authorized. Sign in again to attach.",
        Message::TerminalInvalid => "Mila could not attach to this terminal session.",
        Message::TerminalUnreachable => "The deployment cannot be reached.",
        Message::SshKeysTitle => "SSH keys",
        Message::SshKeysExplain => "Keys approved to sign in to your account on this deployment. A revoked key must be approved again before it can sign in.",
        Message::SshKeysSignInFirst => "Sign in to see this account's keys.",
        Message::SshKeysFailed => "The keys could not be loaded.",
        Message::SshKeysLoading => "Loading keys…",
        Message::SshKeysEmpty => "No approved keys.",
        Message::SshKeyUnlabelled => "Unnamed key",
        Message::SshKeyRevoke => "Revoke",
        Message::SshKeyThisDevice => "This device",
        Message::SshKeyRevokeConfirm => "Revoke the key {fingerprint}? A device using it must be approved again to sign in.",
        Message::RequestWaiting => "Waiting for the request to finish…",
        Message::RequestSucceeded => "Done.",
        Message::RequestRefused => "The deployment refused the request.",
    }
}

fn catalog() -> &'static HashMap<String, String> {
    static CATALOG: OnceLock<HashMap<String, String>> = OnceLock::new();
    CATALOG.get_or_init(|| {
        let root = std::env::var_os("MILA_LOCALE_DIR")
            .map(std::path::PathBuf::from)
            .or_else(|| option_env!("MILA_BUILT_LOCALE_DIR").map(std::path::PathBuf::from));
        let Some(root) = root else {
            return HashMap::new();
        };
        let locale = std::env::var("LANG")
            .unwrap_or_else(|_| "en".to_owned())
            .split('.')
            .next()
            .unwrap_or("en")
            .replace('_', "-");
        for candidate in [locale, "en".into()] {
            let path = root.join(format!("{candidate}.json"));
            let Ok(raw) = fs::read_to_string(path) else {
                continue;
            };
            let Ok(value) = serde_json::from_str::<serde_json::Value>(&raw) else {
                continue;
            };
            let Some(messages) = value
                .pointer("/domains/mila/messages")
                .and_then(|v| v.as_array())
            else {
                continue;
            };
            return messages
                .iter()
                .filter_map(|message| {
                    Some((
                        message.get("id")?.as_str()?.to_owned(),
                        message
                            .get("forms")?
                            .as_array()?
                            .first()?
                            .as_str()?
                            .to_owned(),
                    ))
                })
                .collect();
        }
        HashMap::new()
    })
}
#[cfg(test)]
mod tests {
    use super::*;

    const NEW_MESSAGES: &[Message] = &[
        Message::DeploymentsTitle,
        Message::DeploymentAddAndSelect,
        Message::DeploymentOpen,
        Message::DeploymentRemove,
        Message::DeploymentSelected,
        Message::DeploymentsEmpty,
        Message::DeploymentRemoveConfirm,
        Message::Cancel,
        Message::Refresh,
        Message::SignInTitle,
        Message::SignInConnecting,
        Message::SignInApprove,
        Message::SignInFingerprint,
        Message::SignInAccount,
        Message::SignInDisconnected,
        Message::SignInExpired,
        Message::SignInFailedHost,
        Message::SignInFailedRefused,
        Message::SignInFailedUnreachable,
        Message::SignInFailedProtocol,
        Message::SignInFailedDeviceKey,
        Message::SignInProfileInvalid,
        Message::LinkRefused,
        Message::LinkUnknownDeployment,
        Message::LinkSignInRequired,
        Message::LinkCopy,
        Message::LinkCopied,
        Message::TerminalsTitle,
        Message::TerminalSend,
        Message::TerminalReconnect,
        Message::TerminalResize,
        Message::TerminalClose,
        Message::TerminalLive,
        Message::TerminalEnded,
        Message::TerminalSignedOut,
        Message::TerminalInvalid,
        Message::TerminalUnreachable,
        Message::SshKeysTitle,
        Message::SshKeysExplain,
        Message::SshKeysSignInFirst,
        Message::SshKeysFailed,
        Message::SshKeysLoading,
        Message::SshKeysEmpty,
        Message::SshKeyUnlabelled,
        Message::SshKeyRevoke,
        Message::SshKeyThisDevice,
        Message::SshKeyRevokeConfirm,
        Message::RequestWaiting,
        Message::RequestSucceeded,
        Message::RequestRefused,
    ];
    #[test]
    fn fallback_is_present() {
        assert_eq!(text(Message::AppName), "Mila");
        assert!(!text(Message::LockUnavailable).is_empty());
    }

    #[test]
    fn interpolation_isolates_and_sanitizes_values() {
        assert_eq!(
            interpolate("Remove {host}?", &[("host", "mila.example")]),
            "Remove \u{2068}mila.example\u{2069}?"
        );
        assert_eq!(
            interpolate("{host}", &[("host", "a\u{202e}b\nc")]),
            "\u{2068}abc\u{2069}"
        );
        assert_eq!(interpolate("{other}", &[("host", "x")]), "{other}");
    }

    /// Every message added for the deployment list, terminal surface,
    /// SSH-key settings and deep-link pages resolves to a shared catalog id
    /// whose English source equals the compiled fallback.
    #[test]
    fn new_message_ids_exist_in_shared_catalog() {
        let raw = include_str!("../../../localization/catalogs/app_en.arb");
        let catalog: serde_json::Value = serde_json::from_str(raw).unwrap();
        for message in NEW_MESSAGES {
            let source = catalog
                .get(id(*message))
                .and_then(serde_json::Value::as_str)
                .unwrap_or_else(|| panic!("missing catalog id {}", id(*message)));
            assert_eq!(
                source,
                fallback(*message),
                "fallback drift for {}",
                id(*message)
            );
        }
    }
}
