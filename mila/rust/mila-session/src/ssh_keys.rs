use crate::{validate_ssh_keys, ApplicationSession, SessionError};
use mila_model::Identifier;

impl ApplicationSession {
    /// Execute authenticated approved-key listing and return bounded validated JSON.
    pub async fn ssh_keys(&mut self) -> Result<Vec<u8>, SessionError> {
        let output = self.exec("ssh-key list --json", &[]).await?;
        if output.exit_status != 0 || output.stdout.len() > 256 * 1024 {
            return Err(SessionError::Refused);
        }
        validate_ssh_keys(&output.stdout)?;
        Ok(output.stdout)
    }

    /// Execute the bounded identity check used by browser approval. Porsche returns
    /// an `approval_required` JSON envelope with a link while the device key is
    /// pending; callers must be able to inspect that envelope even on a non-zero
    /// command exit status.
    pub async fn whoami(&self) -> Result<Vec<u8>, SessionError> {
        let output = self.exec("whoami --json", &[]).await?;
        if output.stdout.len() > 64 * 1024 {
            return Err(SessionError::Bounds);
        }
        let value: serde_json::Value =
            serde_json::from_slice(&output.stdout).map_err(|_| SessionError::Refused)?;
        if !value.is_object()
            || value.get("version").and_then(serde_json::Value::as_u64) != Some(1)
            || value
                .get("status")
                .and_then(serde_json::Value::as_str)
                .is_none()
        {
            return Err(SessionError::Refused);
        }
        Ok(output.stdout)
    }

    /// Revoke one opaque approved-key identity with an at-most-once request id.
    pub async fn ssh_key_revoke(
        &mut self,
        key_id: &str,
        request_id: &str,
    ) -> Result<(), SessionError> {
        let key_id = Identifier::parse(key_id).map_err(|_| SessionError::MutationRefused)?;
        let request_id =
            mila_model::RequestId::parse(request_id).map_err(|_| SessionError::MutationRefused)?;
        let output = self
            .exec(
                &format!("ssh-key remove --json --request-id={request_id} {key_id}"),
                &[],
            )
            .await?;
        if output.exit_status == 0 {
            Ok(())
        } else {
            Err(SessionError::MutationRefused)
        }
    }
}
