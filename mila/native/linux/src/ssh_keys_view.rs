//! GTK-independent SSH-key settings presentation.
//!
//! The settings page renders [`SshKeysView::rows`] and [`SshKeysView::status`]
//! and forwards Refresh/Revoke to this module. Listing and revocation run
//! through the authenticated session; GTK never formats Porsche commands or
//! chooses request identifiers.

use crate::adapter::{SshKey, SshKeyProjection};
use crate::session::{LiveSession, SessionError};
use std::collections::HashMap;

/// Authenticated SSH-key operations; implemented by [`LiveSession`].
pub trait SshKeySource {
    fn list_keys(&mut self) -> Result<Vec<u8>, SessionError>;
    fn revoke_key(&mut self, key_id: &str, request_id: &str) -> Result<(), SessionError>;
}

impl SshKeySource for LiveSession {
    fn list_keys(&mut self) -> Result<Vec<u8>, SessionError> {
        self.ssh_keys()
    }

    fn revoke_key(&mut self, key_id: &str, request_id: &str) -> Result<(), SessionError> {
        self.ssh_key_revoke(key_id, request_id)
    }
}

/// What the settings page shows above (or instead of) the key rows.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SshKeysStatus {
    SignInRequired,
    Loading,
    Failed,
    Empty,
    Loaded,
}

/// One displayed key. `label` is `None` when the server label is blank, so
/// the UI shows its localized "unnamed key" text.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SshKeyRow {
    pub id: String,
    pub label: Option<String>,
    pub fingerprint: String,
    pub added_at: u64,
    /// The key is this device's signing key.
    pub this_device: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RevokeOutcome {
    /// The refreshed listing no longer contains the key.
    Revoked,
    /// The deployment refused the request; nothing changed.
    Refused,
    /// The outcome is unknown. The request is never resubmitted; the listing
    /// was refreshed and a later refresh resolves it.
    Uncertain,
    /// The key is not in the current listing or no session is bound.
    Unavailable,
    /// The key belongs to this device; it cannot be revoked from here.
    ThisDevice,
}

/// @cc [owner:ghuntley,label:security;desktop] linux-ssh-key-this-device
/// When the device fingerprint is known, its row MUST be marked and revoking
/// it MUST be refused before any submission, so a user cannot lock this
/// device out of the session it is using.

/// @cc [owner:ghuntley,label:security;protocol] linux-ssh-key-revoke-once
/// Revocation MUST target only a key in the current authenticated listing,
/// MUST reuse the pending request identifier for that key until the outcome
/// is known so a retry is never a second submission, and MUST clear rows and
/// pending requests whenever the session generation changes.
#[expect(
    clippy::empty_line_after_doc_comments,
    reason = "code-contracts requires a blank line between the two @cc notes on this type"
)]
#[derive(Default)]
pub struct SshKeysView {
    projection: SshKeyProjection,
    generation: u64,
    status: Option<SshKeysStatus>,
    pending: HashMap<String, String>,
    device_fingerprint: Option<String>,
}

/// Opaque: fields may hold credentials, key material or terminal bytes.
impl std::fmt::Debug for SshKeysView {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SshKeysView")
            .finish_non_exhaustive()
    }
}

impl SshKeysView {
    /// A new authenticated session: clear rows and pending requests.
    pub fn begin_session(&mut self) {
        self.generation = self.projection.begin_generation();
        self.pending.clear();
        self.status = Some(SshKeysStatus::Loading);
    }

    /// Sign-out or deployment switch: no rows survive.
    /// The `SHA256:` fingerprint of this device's key, if known.
    pub fn set_device_fingerprint(&mut self, fingerprint: Option<String>) {
        self.device_fingerprint = fingerprint.map(|value| normalize(&value).to_owned());
    }

    pub fn sign_out(&mut self) {
        self.generation = self.projection.begin_generation();
        self.pending.clear();
        self.status = Some(SshKeysStatus::SignInRequired);
    }

    pub fn status(&self) -> SshKeysStatus {
        self.status.unwrap_or(SshKeysStatus::SignInRequired)
    }

    pub fn rows(&self) -> Vec<SshKeyRow> {
        self.projection
            .keys()
            .iter()
            .map(|key| row(key, self.device_fingerprint.as_deref()))
            .collect()
    }

    /// The fingerprint shown in the revoke confirmation, if the key is listed.
    pub fn confirmation_fingerprint(&self, key_id: &str) -> Option<String> {
        self.key(key_id).map(|key| key.fingerprint.clone())
    }

    pub fn refresh(&mut self, source: Option<&mut dyn SshKeySource>) -> SshKeysStatus {
        let Some(source) = source else {
            self.sign_out();
            return self.status();
        };
        if self.status() == SshKeysStatus::SignInRequired {
            self.begin_session();
        }
        let status = match source
            .list_keys()
            .ok()
            .and_then(|bytes| self.projection.refresh(self.generation, &bytes).ok())
        {
            Some(()) if self.projection.keys().is_empty() => SshKeysStatus::Empty,
            Some(()) => SshKeysStatus::Loaded,
            None => SshKeysStatus::Failed,
        };
        let listed = self
            .projection
            .keys()
            .iter()
            .map(|key| key.id.as_str())
            .collect::<std::collections::HashSet<_>>();
        if status != SshKeysStatus::Failed {
            self.pending.retain(|key, _| listed.contains(key.as_str()));
        }
        self.status = Some(status);
        status
    }

    /// Revokes one listed key. `new_request_id` is called only when no request
    /// for this key is pending.
    pub fn revoke(
        &mut self,
        source: Option<&mut dyn SshKeySource>,
        key_id: &str,
        new_request_id: impl FnOnce() -> Option<String>,
    ) -> RevokeOutcome {
        let Some(source) = source else {
            self.sign_out();
            return RevokeOutcome::Unavailable;
        };
        let Some(key) = self.key(key_id) else {
            return RevokeOutcome::Unavailable;
        };
        if self.device_fingerprint.as_deref() == Some(normalize(&key.fingerprint)) {
            return RevokeOutcome::ThisDevice;
        }
        let request_id = if let Some(existing) = self.pending.get(key_id) {
            existing.clone()
        } else {
            let Some(created) = new_request_id() else {
                return RevokeOutcome::Unavailable;
            };
            self.pending.insert(key_id.to_owned(), created.clone());
            created
        };
        let result = source.revoke_key(key_id, &request_id);
        self.refresh(Some(source));
        let still_listed = self.key(key_id).is_some();
        match result {
            Ok(()) | Err(SessionError::Transport | SessionError::Busy) if !still_listed => {
                self.pending.remove(key_id);
                RevokeOutcome::Revoked
            }
            Ok(())
            | Err(
                SessionError::Transport
                | SessionError::Busy
                | SessionError::StaleHandle
                | SessionError::Unavailable,
            ) => RevokeOutcome::Uncertain,
            Err(SessionError::InvalidInput) => {
                self.pending.remove(key_id);
                RevokeOutcome::Refused
            }
        }
    }

    fn key(&self, key_id: &str) -> Option<&SshKey> {
        self.projection.keys().iter().find(|key| key.id == key_id)
    }
}

fn normalize(fingerprint: &str) -> &str {
    fingerprint.strip_prefix("SHA256:").unwrap_or(fingerprint)
}

fn row(key: &SshKey, device: Option<&str>) -> SshKeyRow {
    SshKeyRow {
        id: key.id.clone(),
        label: (!key.label.trim().is_empty()).then(|| key.label.clone()),
        fingerprint: key.fingerprint.clone(),
        added_at: key.added_at,
        this_device: device == Some(normalize(&key.fingerprint)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const REQUEST_A: &str = "porsche-0123456789abcdef0123456789abcdef";
    const REQUEST_B: &str = "porsche-fedcba9876543210fedcba9876543210";

    #[derive(Default)]
    struct Server {
        keys: Vec<(String, String)>,
        revokes: Vec<(String, String)>,
        fail_list: bool,
        revoke_result: Option<Result<(), SessionError>>,
        apply_revoke: bool,
    }

    impl Server {
        fn with(keys: &[(&str, &str)]) -> Self {
            Self {
                keys: keys
                    .iter()
                    .map(|(id, label)| ((*id).to_owned(), (*label).to_owned()))
                    .collect(),
                apply_revoke: true,
                ..Self::default()
            }
        }
    }

    impl SshKeySource for Server {
        fn list_keys(&mut self) -> Result<Vec<u8>, SessionError> {
            if self.fail_list {
                return Err(SessionError::Transport);
            }
            let keys = self
                .keys
                .iter()
                .map(|(id, label)| {
                    serde_json::json!({
                        "id": id, "label": label,
                        "fingerprint": format!("SHA256:{id}"), "added_at": 1
                    })
                })
                .collect::<Vec<_>>();
            Ok(serde_json::to_vec(&serde_json::json!({ "keys": keys })).unwrap())
        }

        fn revoke_key(&mut self, key_id: &str, request_id: &str) -> Result<(), SessionError> {
            self.revokes
                .push((key_id.to_owned(), request_id.to_owned()));
            if self.apply_revoke {
                self.keys.retain(|(id, _)| id != key_id);
            }
            self.revoke_result.unwrap_or(Ok(()))
        }
    }

    #[test]
    fn listing_projects_rows_and_states() {
        let mut view = SshKeysView::default();
        assert_eq!(view.status(), SshKeysStatus::SignInRequired);
        assert_eq!(view.refresh(None), SshKeysStatus::SignInRequired);
        let mut server = Server::with(&[("k1", "laptop"), ("k2", "  ")]);
        assert_eq!(view.refresh(Some(&mut server)), SshKeysStatus::Loaded);
        let rows = view.rows();
        assert_eq!(rows[0].label.as_deref(), Some("laptop"));
        assert_eq!(rows[1].label, None);
        assert_eq!(
            view.confirmation_fingerprint("k2").as_deref(),
            Some("SHA256:k2")
        );
        let mut empty = Server::with(&[]);
        assert_eq!(view.refresh(Some(&mut empty)), SshKeysStatus::Empty);
        let mut failing = Server {
            fail_list: true,
            ..Server::default()
        };
        assert_eq!(view.refresh(Some(&mut failing)), SshKeysStatus::Failed);
    }

    #[test]
    fn revoke_targets_only_listed_keys_and_refreshes() {
        let mut view = SshKeysView::default();
        let mut server = Server::with(&[("k1", "laptop")]);
        view.refresh(Some(&mut server));
        assert_eq!(
            view.revoke(Some(&mut server), "other", || Some(REQUEST_A.into())),
            RevokeOutcome::Unavailable
        );
        assert_eq!(server.revokes, []);
        assert_eq!(
            view.revoke(Some(&mut server), "k1", || Some(REQUEST_A.into())),
            RevokeOutcome::Revoked
        );
        assert_eq!(server.revokes, vec![("k1".into(), REQUEST_A.into())]);
        assert_eq!(view.status(), SshKeysStatus::Empty);
    }

    #[test]
    fn uncertain_revoke_reuses_request_id_never_a_new_submission() {
        let mut view = SshKeysView::default();
        let mut server = Server::with(&[("k1", "laptop")]);
        server.apply_revoke = false;
        server.revoke_result = Some(Err(SessionError::Transport));
        view.refresh(Some(&mut server));
        assert_eq!(
            view.revoke(Some(&mut server), "k1", || Some(REQUEST_A.into())),
            RevokeOutcome::Uncertain
        );
        let mut generated = false;
        assert_eq!(
            view.revoke(Some(&mut server), "k1", || {
                generated = true;
                Some(REQUEST_B.into())
            }),
            RevokeOutcome::Uncertain
        );
        assert!(!generated, "a pending request id must be reused");
        assert!(server.revokes.iter().all(|(_, id)| id == REQUEST_A));
        // The server eventually applied the first request.
        server.keys.clear();
        view.refresh(Some(&mut server));
        assert_eq!(view.status(), SshKeysStatus::Empty);
    }

    #[test]
    fn refusal_clears_pending_and_sign_out_clears_rows() {
        let mut view = SshKeysView::default();
        let mut server = Server::with(&[("k1", "laptop")]);
        server.apply_revoke = false;
        server.revoke_result = Some(Err(SessionError::InvalidInput));
        view.refresh(Some(&mut server));
        assert_eq!(
            view.revoke(Some(&mut server), "k1", || Some(REQUEST_A.into())),
            RevokeOutcome::Refused
        );
        assert_eq!(
            view.revoke(Some(&mut server), "k1", || Some(REQUEST_B.into())),
            RevokeOutcome::Refused
        );
        assert_eq!(server.revokes[1].1, REQUEST_B);
        view.sign_out();
        assert_eq!(view.rows(), []);
        assert_eq!(view.status(), SshKeysStatus::SignInRequired);
        assert_eq!(
            view.revoke(Some(&mut server), "k1", || Some(REQUEST_A.into())),
            RevokeOutcome::Unavailable
        );
    }

    #[test]
    fn this_device_key_is_marked_and_never_submitted() {
        let mut view = SshKeysView::default();
        view.set_device_fingerprint(Some("k1".into()));
        let mut server = Server::with(&[("k1", "laptop"), ("k2", "phone")]);
        view.refresh(Some(&mut server));
        let rows = view.rows();
        assert!(rows[0].this_device && !rows[1].this_device);
        assert_eq!(
            view.revoke(Some(&mut server), "k1", || Some(REQUEST_A.into())),
            RevokeOutcome::ThisDevice
        );
        assert_eq!(server.revokes, []);
        assert_eq!(
            view.revoke(Some(&mut server), "k2", || Some(REQUEST_A.into())),
            RevokeOutcome::Revoked
        );
    }

    #[test]
    fn revoke_without_session_signs_out() {
        let mut view = SshKeysView::default();
        let mut server = Server::with(&[("k1", "laptop")]);
        view.refresh(Some(&mut server));
        assert_eq!(
            view.revoke(None, "k1", || Some(REQUEST_A.into())),
            RevokeOutcome::Unavailable
        );
        assert_eq!(view.rows(), []);
    }
}
