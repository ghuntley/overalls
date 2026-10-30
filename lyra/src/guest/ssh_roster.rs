//! Guest account roster reconciliation shared by the SSH agents (ADR-0171).
//!
//! Audi serves each guest's roster, authorizes offered keys and records logins
//! over the private TLS route (`/ssh/v1/roster`, `/authorize`, `/login`). The
//! rules below are the platform-neutral half of the Linux
//! `overalls-ssh-authorize` reconciler: what a valid roster is, when it is
//! stale, which accounts to activate or deactivate and how the durable state
//! records progress. Creating, disabling and inspecting accounts is the
//! `Accounts` implementation's job (`useradd` on Linux, the Net API on
//! Windows).

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::io;

/// Rosters larger than this are refused before parsing.
pub const MAX_ROSTER: usize = 64 * 1024;
/// Marshall allocates guest UIDs in this band only.
pub const UID_RANGE: std::ops::RangeInclusive<u32> = 200_000..=999_999;
pub const ORIGIN: &str = "https://ssh.integration.internal/ssh/v1/";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Route {
    Roster,
    /// The roster writers' registered keys, for guests whose sshd cannot ask
    /// per connection (Windows).
    AuthorizedKeys,
    Authorize,
    Login,
}

impl Route {
    pub fn path(self) -> &'static str {
        match self {
            Self::Roster => "roster",
            Self::AuthorizedKeys => "authorized-keys",
            Self::Authorize => "authorize",
            Self::Login => "login",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Account {
    pub username: String,
    pub uid: u32,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Roster {
    pub version: u64,
    pub accounts: Vec<Account>,
}

/// Durable record of the last roster applied and every account ever managed.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct State {
    pub version: u64,
    pub digest: String,
    pub accounts: Vec<Account>,
}

impl State {
    pub fn empty() -> Self {
        Self {
            version: 0,
            digest: String::new(),
            accounts: Vec::new(),
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Authorization {
    pub public_key: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LoginReceipt {
    pub login_id: String,
}

/// Account operations an operating system provides.
pub trait Accounts {
    /// Create the account when missing and leave it enabled with the managed
    /// shell, group membership and home; refuse a conflicting existing account.
    fn activate(&mut self, account: &Account) -> io::Result<()>;
    /// Disable (never delete) a managed account that left the roster.
    fn deactivate(&mut self, account: &Account) -> io::Result<()>;
}

/// Where the durable state lives.
pub trait StateStore {
    fn load(&self) -> io::Result<Option<State>>;
    fn store(&mut self, state: &State) -> io::Result<()>;
}

pub fn roster_digest(roster: &Roster) -> io::Result<String> {
    let mut accounts = roster.accounts.clone();
    accounts.sort_by(|left, right| left.username.cmp(&right.username));
    let bytes = serde_json::to_vec(&(roster.version, accounts)).map_err(io::Error::other)?;
    Ok(hex::encode(Sha256::digest(bytes)))
}

/// @cc [owner:ghuntley,label:security] ssh-roster-safe-name
/// A managed username MUST be 1 to 20 lowercase ASCII letters, digits, `_`,
/// `.` or `-`, start with a letter or `_`, end with a letter, digit or `_`,
/// and MUST NOT be a well-known system or built-in account on either
/// platform. The 20-character bound is the Windows SAM account limit;
/// Marshall's `u<uid>` names fit both.
pub fn valid_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 20
        && (bytes[0].is_ascii_lowercase() || bytes[0] == b'_')
        && (bytes[bytes.len() - 1].is_ascii_lowercase()
            || bytes[bytes.len() - 1].is_ascii_digit()
            || bytes[bytes.len() - 1] == b'_')
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || b"_.-".contains(byte))
        && ![
            "root",
            "daemon",
            "bin",
            "sys",
            "sync",
            "games",
            "man",
            "lp",
            "mail",
            "news",
            "uucp",
            "proxy",
            "www-data",
            "backup",
            "list",
            "irc",
            "gnats",
            "nobody",
            "ubuntu",
            "sshd",
            "sudo",
            "postgres",
            "administrator",
            "guest",
            "defaultaccount",
            "wdagutilityaccount",
            "system",
            "overalls",
        ]
        .contains(&name)
        && !name.starts_with("systemd-")
        && !name.starts_with("nixbld")
}

/// @cc [owner:ghuntley,label:security] ssh-roster-unique-identity-shared
/// A roster MUST have a positive version, at most 512 accounts, safe unique
/// names and unique UIDs in Marshall's band. Invalid data MUST cause no
/// account mutation.
pub fn validate(roster: &Roster) -> io::Result<()> {
    let mut names = HashSet::new();
    let mut ids = HashSet::new();
    if roster.version == 0 || roster.accounts.len() > 512 {
        return Err(io::Error::other("invalid roster"));
    }
    for account in &roster.accounts {
        if !valid_name(&account.username)
            || !UID_RANGE.contains(&account.uid)
            || !names.insert(&account.username)
            || !ids.insert(account.uid)
        {
            return Err(io::Error::other("invalid roster"));
        }
    }
    Ok(())
}

/// Whether `required_user` (if any) is in the validated roster.
pub fn require_account(roster: &Roster, required_user: Option<&str>) -> io::Result<()> {
    validate(roster)?;
    if required_user.is_some_and(|user| {
        !roster
            .accounts
            .iter()
            .any(|account| account.username == user)
    }) {
        return Err(io::Error::other("account not authorized"));
    }
    Ok(())
}

/// @cc [owner:ghuntley,label:security] editor-account-exact-roster-identity
/// On-demand editor reconciliation MUST require both the exact name and UID in
/// a valid current roster. A name-only or UID-only match, an unsafe account or
/// an invalid roster MUST refuse before any local account mutation.
pub fn require_identity(roster: &Roster, username: &str, uid: u32) -> io::Result<()> {
    validate(roster)?;
    if !valid_name(username)
        || !UID_RANGE.contains(&uid)
        || !roster
            .accounts
            .iter()
            .any(|account| account.username == username && account.uid == uid)
    {
        return Err(io::Error::other("account not authorized"));
    }
    Ok(())
}

/// @cc [owner:ghuntley,label:security;recovery] ssh-roster-reconcile-order
/// reconcile MUST refuse an older roster version, or the same version with a
/// different digest, without touching accounts; MUST stage the union of old
/// and new accounts in the state before changing anything so an interrupted
/// run still knows every managed account; MUST deactivate accounts that left
/// before activating the roster's accounts; and MUST commit the roster as the
/// new state only after every operation succeeded.
pub fn reconcile(
    roster: Roster,
    store: &mut impl StateStore,
    accounts: &mut impl Accounts,
) -> io::Result<State> {
    validate(&roster)?;
    let digest = roster_digest(&roster)?;
    let previous = store.load()?.unwrap_or_else(State::empty);
    if roster.version < previous.version
        || (roster.version == previous.version && digest != previous.digest)
    {
        return Err(io::Error::other("stale roster"));
    }
    let mut journal = previous.accounts.clone();
    for account in &roster.accounts {
        if !journal.iter().any(|old| old.username == account.username) {
            journal.push(account.clone());
        }
    }
    store.store(&State {
        version: roster.version,
        digest: digest.clone(),
        accounts: journal,
    })?;
    let desired: HashSet<&str> = roster
        .accounts
        .iter()
        .map(|account| account.username.as_str())
        .collect();
    for account in &previous.accounts {
        if !desired.contains(account.username.as_str()) {
            accounts.deactivate(account)?;
        }
    }
    for account in &roster.accounts {
        accounts.activate(account)?;
    }
    let committed = State {
        version: roster.version,
        digest,
        accounts: roster.accounts,
    };
    store.store(&committed)?;
    Ok(committed)
}

/// The key an SSH client offered, as sshd hands it to the authorized keys
/// command (`%t %k`), re-joined for the authority.
pub fn offered_key(algorithm: &str, encoded: &str) -> io::Result<String> {
    if !matches!(
        algorithm,
        "ssh-ed25519"
            | "ssh-rsa"
            | "ecdsa-sha2-nistp256"
            | "ecdsa-sha2-nistp384"
            | "ecdsa-sha2-nistp521"
    ) || encoded.is_empty()
        || encoded.len() > 4096
        || !encoded
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'/' | b'='))
    {
        return Err(io::Error::other("invalid offered key"));
    }
    Ok(format!("{algorithm} {encoded}"))
}

/// @cc [owner:ghuntley,label:security] ssh-authorization-exact-key
/// An authority answer MUST name exactly the offered key or nothing is
/// printed for sshd.
pub fn authorized_key(offered: &str, response: &[u8]) -> io::Result<String> {
    let authorized: Authorization =
        serde_json::from_slice(response).map_err(|_| io::Error::other("invalid authorization"))?;
    if authorized.public_key != offered {
        return Err(io::Error::other("key mismatch"));
    }
    Ok(authorized.public_key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Fake {
        state: Option<State>,
        active: Vec<String>,
        disabled: Vec<String>,
        fail_on: Option<String>,
    }

    impl StateStore for Fake {
        fn load(&self) -> io::Result<Option<State>> {
            Ok(self.state.clone())
        }
        fn store(&mut self, state: &State) -> io::Result<()> {
            self.state = Some(state.clone());
            Ok(())
        }
    }

    impl Accounts for Fake {
        fn activate(&mut self, account: &Account) -> io::Result<()> {
            if self.fail_on.as_deref() == Some(account.username.as_str()) {
                return Err(io::Error::other("refused"));
            }
            self.active.push(account.username.clone());
            Ok(())
        }
        fn deactivate(&mut self, account: &Account) -> io::Result<()> {
            self.disabled.push(account.username.clone());
            Ok(())
        }
    }

    fn roster(version: u64, uids: &[u32]) -> Roster {
        Roster {
            version,
            accounts: uids
                .iter()
                .map(|uid| Account {
                    username: format!("u{uid}"),
                    uid: *uid,
                })
                .collect(),
        }
    }

    #[test]
    fn names_follow_both_platforms_rules() {
        assert!(valid_name("u200000"));
        assert!(valid_name("_x"));
        assert!(!valid_name("Administrator") && !valid_name("administrator"));
        assert!(!valid_name("u".repeat(21).as_str()) && valid_name("u".repeat(20).as_str()));
        assert!(!valid_name("1abc") && !valid_name("abc-") && !valid_name("root"));
    }

    #[test]
    fn reconcile_activates_deactivates_and_journals() {
        let mut fake = Fake::default();
        let mut store = Fake::default();
        let committed = reconcile(roster(1, &[200_000, 200_001]), &mut store, &mut fake).unwrap();
        assert_eq!(fake.active, vec!["u200000", "u200001"]);
        assert_eq!(committed.accounts.len(), 2);
        let committed = reconcile(roster(2, &[200_001]), &mut store, &mut fake).unwrap();
        assert_eq!(fake.disabled, vec!["u200000"]);
        assert_eq!(committed.accounts.len(), 1);
        // Older or diverging same-version rosters are refused without mutation.
        assert!(reconcile(roster(1, &[200_000]), &mut store, &mut fake).is_err());
        assert!(reconcile(roster(2, &[200_002]), &mut store, &mut fake).is_err());
        assert_eq!(fake.active.len(), 3);
        // A failed activation leaves the staged union in the state.
        fake.fail_on = Some("u200003".into());
        assert!(reconcile(roster(3, &[200_001, 200_003]), &mut store, &mut fake).is_err());
        let staged = store.load().unwrap().unwrap();
        assert_eq!(staged.version, 3);
        assert!(staged.accounts.iter().any(|a| a.username == "u200003"));
    }

    #[test]
    fn rosters_and_keys_are_validated() {
        assert!(validate(&roster(0, &[200_000])).is_err());
        assert!(validate(&roster(1, &[199_999])).is_err());
        assert!(validate(&roster(1, &[200_000, 200_000])).is_err());
        assert!(require_account(&roster(1, &[200_000]), Some("u200001")).is_err());
        assert!(require_account(&roster(1, &[200_000]), Some("u200000")).is_ok());
        assert_eq!(
            offered_key("ssh-ed25519", "AAAA").unwrap(),
            "ssh-ed25519 AAAA"
        );
        assert!(offered_key("ssh-dss", "AAAA").is_err());
        assert!(offered_key("ssh-ed25519", "AA AA").is_err());
        assert_eq!(
            authorized_key("ssh-ed25519 AAAA", br#"{"public_key":"ssh-ed25519 AAAA"}"#).unwrap(),
            "ssh-ed25519 AAAA"
        );
        assert!(
            authorized_key("ssh-ed25519 AAAA", br#"{"public_key":"ssh-ed25519 BBBB"}"#).is_err()
        );
    }

    #[test]
    fn invalid_share_roster_refuses_before_authenticated_mutation_boundary() {
        // The HTTPS roster is the authenticated machine-sharing input.  A
        // malformed or conflicting share update must stop before either the
        // durable journal or the native account adapter is touched.
        let mut fake = Fake::default();
        let mut store = Fake::default();
        let invalid = Roster {
            version: 1,
            accounts: vec![
                Account {
                    username: "u200000".into(),
                    uid: 200_000,
                },
                Account {
                    username: "u200000".into(),
                    uid: 200_001,
                },
            ],
        };

        assert!(reconcile(invalid, &mut store, &mut fake).is_err());
        assert!(store.state.is_none());
        assert_eq!(fake.active.len(), 0);
        assert_eq!(fake.disabled.len(), 0);
    }

    #[test]
    fn editor_identity_requires_the_exact_roster_pair() {
        let current = roster(7, &[200_001, 200_002]);
        assert!(require_identity(&current, "u200001", 200_001).is_ok());
        for (name, uid) in [
            ("u200001", 200_002),
            ("u200002", 200_001),
            ("u200003", 200_003),
            ("administrator", 200_001),
            ("u200001", 199_999),
        ] {
            assert!(require_identity(&current, name, uid).is_err());
        }
        assert!(require_identity(&roster(0, &[200_001]), "u200001", 200_001).is_err());
        assert!(require_identity(&roster(7, &[200_001, 200_001]), "u200001", 200_001).is_err());
    }
}
