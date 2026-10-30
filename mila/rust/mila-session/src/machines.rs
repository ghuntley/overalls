use crate::{ApplicationSession, SessionError};
use mila_model::Identifier;

impl ApplicationSession {
    /// Execute one authenticated machine mutation on this connection. The command is
    /// constructed from closed vocabulary values and a validated request id; callers
    /// cannot inject shell text or reuse an untyped operation.
    pub async fn machine_action(
        &mut self,
        machine: &str,
        action: &str,
        request_id: &str,
    ) -> Result<(), SessionError> {
        let machine = Identifier::parse(machine).map_err(|_| SessionError::InvalidListing)?;
        let request_id =
            mila_model::RequestId::parse(request_id).map_err(|_| SessionError::MutationRefused)?;
        let action = match action {
            "start" | "stop" | "pause" | "resume" | "rm" => action,
            _ => return Err(SessionError::MutationRefused),
        };
        // Physical receipts are resolved with `request show`, never by waiting on
        // or resubmitting the mutation (mila-mutation-once).
        let line = format!("{action} {machine} --json --no-wait --request-id={request_id}");
        let output = self.exec(&line, &[]).await?;
        if output.exit_status == 0 {
            Ok(())
        } else {
            Err(SessionError::MutationRefused)
        }
    }

    /// Execute an authenticated machine creation with bounded resource values.
    pub async fn machine_create(
        &mut self,
        name: &str,
        cpu: u32,
        memory: u64,
        disk: u64,
        request_id: &str,
    ) -> Result<(), SessionError> {
        let request_id =
            mila_model::RequestId::parse(request_id).map_err(|_| SessionError::MutationRefused)?;
        if name.is_empty()
            || name.len() > 128
            || !name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            || !(1..=256).contains(&cpu)
            || !(256..=4_194_304).contains(&memory)
            || !(1..=500).contains(&disk)
        {
            return Err(SessionError::MutationRefused);
        }
        let line = format!("new --name={name} --cpu={cpu} --memory={memory} --disk={disk} --no-wait --json --request-id={request_id}");
        let output = self.exec(&line, &[]).await?;
        if output.exit_status == 0 {
            Ok(())
        } else {
            Err(SessionError::MutationRefused)
        }
    }

    /// Execute an authenticated machine resize with bounded resource values.
    pub async fn machine_resize(
        &mut self,
        machine: &str,
        cpu: u32,
        memory: u64,
        disk: u64,
        request_id: &str,
    ) -> Result<(), SessionError> {
        let machine = Identifier::parse(machine).map_err(|_| SessionError::InvalidListing)?;
        let request_id =
            mila_model::RequestId::parse(request_id).map_err(|_| SessionError::MutationRefused)?;
        if !(1..=256).contains(&cpu)
            || !(256..=4_194_304).contains(&memory)
            || !(1..=500).contains(&disk)
        {
            return Err(SessionError::MutationRefused);
        }
        let line = format!(
            "resize {machine} --cpu={cpu} --memory={memory} --disk={disk} --json --no-wait --request-id={request_id}"
        );
        let output = self.exec(&line, &[]).await?;
        if output.exit_status == 0 {
            Ok(())
        } else {
            Err(SessionError::MutationRefused)
        }
    }

    /// @cc [owner:ghuntley,label:protocol;security] mila-session-machine-reads
    /// `machine_show` and `share_show` MUST send only the grammar-checked
    /// `show MACHINE --json` / `share show MACHINE --json` read for a canonical
    /// machine identifier, MUST refuse a non-zero exit, oversized or non-JSON
    /// output, and MUST NOT carry a request id or mutate state.
    pub async fn machine_show(&mut self, machine: &str) -> Result<Vec<u8>, SessionError> {
        self.machine_read("show", machine).await
    }

    /// Read a machine's owner and access grants (`share show`).
    pub async fn share_show(&mut self, machine: &str) -> Result<Vec<u8>, SessionError> {
        self.machine_read("share show", machine).await
    }

    async fn machine_read(
        &mut self,
        command: &str,
        machine: &str,
    ) -> Result<Vec<u8>, SessionError> {
        let machine = Identifier::parse(machine).map_err(|_| SessionError::InvalidListing)?;
        let line = mila_protocol::Command::parse(&format!("{command} {machine} --json"))
            .and_then(|command| command.format())
            .map_err(|_| SessionError::Refused)?;
        let output = self.ssh.exec(&line, &[]).await?;
        if output.exit_status != 0 || output.stdout.len() > 256 * 1024 {
            return Err(SessionError::Refused);
        }
        serde_json::from_slice::<serde_json::Value>(&output.stdout)
            .map_err(|_| SessionError::Refused)?;
        Ok(output.stdout)
    }
}
