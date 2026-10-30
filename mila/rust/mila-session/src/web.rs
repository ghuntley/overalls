use crate::{ApplicationSession, SessionError};
use mila_model::Identifier;

impl ApplicationSession {
    /// Execute authenticated web endpoint inspection and return bounded JSON.
    pub async fn web_show(&mut self, machine: &str) -> Result<Vec<u8>, SessionError> {
        let machine = Identifier::parse(machine).map_err(|_| SessionError::InvalidListing)?;
        let line = format!("web show {machine} --json");
        let output = self.exec(&line, &[]).await?;
        if output.exit_status != 0 || output.stdout.len() > 256 * 1024 {
            Err(SessionError::MutationRefused)
        } else {
            serde_json::from_slice::<serde_json::Value>(&output.stdout)
                .map_err(|_| SessionError::Refused)?;
            Ok(output.stdout)
        }
    }

    /// Execute authenticated web endpoint mutation with optimistic revision.
    pub async fn web_set(
        &mut self,
        machine: &str,
        port: u16,
        public: bool,
        revision: u64,
        request_id: &str,
    ) -> Result<(), SessionError> {
        let machine = Identifier::parse(machine).map_err(|_| SessionError::InvalidListing)?;
        let request_id =
            mila_model::RequestId::parse(request_id).map_err(|_| SessionError::MutationRefused)?;
        let visibility = if public { "--public" } else { "--private" };
        let line = format!("web set {machine} --json --port={port} {visibility} --revision={revision} --request-id={request_id}");
        let output = self.exec(&line, &[]).await?;
        if output.exit_status == 0 {
            Ok(())
        } else {
            Err(SessionError::MutationRefused)
        }
    }
}
