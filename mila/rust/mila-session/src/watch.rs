use crate::{ApplicationSession, SessionError};
use mila_transport::{ssh::SshError, WatchRequest, WatchSession};

impl ApplicationSession {
    /// Subscribe on this deployment's existing certificate-pinned connection.
    /// Identifier hints require ordinary authorized reads; callers invalidate
    /// authority on `WatchRead::AuthorityLost`, and refresh after reconnect.
    pub async fn watch(&self, request: WatchRequest) -> Result<WatchSession, SessionError> {
        if !self.authority {
            return Err(SshError::Authentication.into());
        }
        Ok(WatchSession::open(&self.ssh, request).await?)
    }
}
