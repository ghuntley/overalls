use crate::{ApplicationSession, SessionError};
use mila_model::Identifier;

impl ApplicationSession {
    /// Execute an authenticated machine sharing mutation. The command is parsed by
    /// the shared protocol grammar before it is sent, and request IDs provide the
    /// same at-most-once boundary as lifecycle mutations.
    pub async fn share_mutation(
        &mut self,
        machine: &str,
        email: &str,
        role: Option<&str>,
        add: bool,
        request_id: &str,
    ) -> Result<(), SessionError> {
        let machine = Identifier::parse(machine).map_err(|_| SessionError::InvalidListing)?;
        let request_id =
            mila_model::RequestId::parse(request_id).map_err(|_| SessionError::MutationRefused)?;
        if email.is_empty()
            || email.len() > 320
            || email
                .bytes()
                .any(|byte| byte.is_ascii_whitespace() || byte == 0)
        {
            return Err(SessionError::MutationRefused);
        }
        let line = if add {
            let role = role
                .filter(|value| matches!(*value, "viewer" | "operator" | "manager"))
                .ok_or(SessionError::MutationRefused)?;
            format!("share add {machine} {email} {role} --json --request-id={request_id}")
        } else {
            if role.is_some() {
                return Err(SessionError::MutationRefused);
            }
            format!("share remove {machine} {email} --json --request-id={request_id}")
        };
        let line = mila_protocol::Command::parse(&line)
            .and_then(|command| command.format())
            .map_err(|_| SessionError::MutationRefused)?;
        let output = self.exec(&line, &[]).await?;
        if output.exit_status == 0 {
            Ok(())
        } else {
            Err(SessionError::MutationRefused)
        }
    }
}
