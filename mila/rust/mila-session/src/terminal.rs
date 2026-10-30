use crate::{ApplicationSession, SessionError};
use mila_model::Identifier;
use mila_transport::ssh::PtySession;

impl ApplicationSession {
    /// Opens a bounded interactive terminal on this authenticated deployment.
    /// The returned channel remains owned by the caller while the underlying
    /// certificate-pinned session is borrowed by the transport.
    pub async fn open_pty(&self, columns: u32, rows: u32) -> Result<PtySession, SessionError> {
        Ok(PtySession::open(&self.ssh, columns, rows).await?)
    }

    /// Attaches a bounded PTY to one named terminal session of one machine.
    pub async fn attach_terminal(
        &self,
        machine: &str,
        terminal: &str,
        columns: u32,
        rows: u32,
    ) -> Result<PtySession, SessionError> {
        let machine = Identifier::parse(machine).map_err(|_| SessionError::InvalidListing)?;
        let terminal = Identifier::parse(terminal).map_err(|_| SessionError::MutationRefused)?;
        Ok(PtySession::attach(
            &self.ssh,
            &machine.to_string(),
            &terminal.to_string(),
            columns,
            rows,
        )
        .await?)
    }

    /// Opens (or rejoins) the caller's personal terminal session on a machine and
    /// returns Porsche's bounded JSON receipt naming the session.
    pub async fn terminal_new(
        &mut self,
        machine: &str,
        request_id: &str,
    ) -> Result<Vec<u8>, SessionError> {
        let machine = Identifier::parse(machine).map_err(|_| SessionError::InvalidListing)?;
        let request_id =
            mila_model::RequestId::parse(request_id).map_err(|_| SessionError::MutationRefused)?;
        self.json_mutation(&format!(
            "terminal new {machine} --json --request-id={request_id}"
        ))
        .await
    }

    /// Closes one of the caller's terminal sessions on the server.
    pub async fn terminal_kill(
        &mut self,
        machine: &str,
        terminal: &str,
        request_id: &str,
    ) -> Result<Vec<u8>, SessionError> {
        let machine = Identifier::parse(machine).map_err(|_| SessionError::InvalidListing)?;
        let terminal = Identifier::parse(terminal).map_err(|_| SessionError::MutationRefused)?;
        let request_id =
            mila_model::RequestId::parse(request_id).map_err(|_| SessionError::MutationRefused)?;
        self.json_mutation(&format!(
            "terminal kill {machine} {terminal} --json --request-id={request_id}"
        ))
        .await
    }

    async fn json_mutation(&mut self, line: &str) -> Result<Vec<u8>, SessionError> {
        let output = self.exec(line, &[]).await?;
        if output.exit_status != 0 || output.stdout.len() > 256 * 1024 {
            return Err(SessionError::MutationRefused);
        }
        serde_json::from_slice::<serde_json::Value>(&output.stdout)
            .map_err(|_| SessionError::Refused)?;
        Ok(output.stdout)
    }
}
