use crate::{ApplicationSession, SessionError};
use mila_model::Identifier;

impl ApplicationSession {
    /// Read the caller's push notification devices through Porsche.
    pub async fn device_ls(&mut self) -> Result<Vec<u8>, SessionError> {
        let output = self.exec("device ls --json", &[]).await?;
        if output.exit_status != 0 || output.stdout.len() > 256 * 1024 {
            Err(SessionError::MutationRefused)
        } else {
            serde_json::from_slice::<serde_json::Value>(&output.stdout)
                .map_err(|_| SessionError::Refused)?;
            Ok(output.stdout)
        }
    }

    /// @cc [owner:ghuntley,label:security;privacy] mila-session-device-register
    /// The Susan push key MUST travel only on stdin, never on the command line;
    /// the platform, X25519 public key and optional label MUST satisfy the shared
    /// command grammar before any channel is opened. The bounded JSON reply is
    /// returned only on a zero exit status. Registers this device for push
    /// notifications through Porsche.
    pub async fn device_register(
        &mut self,
        platform: mila_model::DevicePlatform,
        push_key: &str,
        enc_pubkey: &str,
        label: Option<&str>,
    ) -> Result<Vec<u8>, SessionError> {
        if !(16..=700).contains(&push_key.len())
            || !push_key
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            return Err(SessionError::MutationRefused);
        }
        let platform = platform.as_str();
        let mut options = std::collections::BTreeMap::new();
        options.insert(
            "platform".to_owned(),
            mila_protocol::OptionValue::String(platform.into()),
        );
        options.insert(
            "push-key".to_owned(),
            mila_protocol::OptionValue::String("-".into()),
        );
        options.insert(
            "enc-pubkey".to_owned(),
            mila_protocol::OptionValue::String(enc_pubkey.into()),
        );
        if let Some(label) = label {
            options.insert(
                "label".to_owned(),
                mila_protocol::OptionValue::String(label.into()),
            );
        }
        options.insert("json".to_owned(), mila_protocol::OptionValue::Bool(true));
        let line = mila_protocol::Command {
            command: "device register".into(),
            arguments: Vec::new(),
            options,
        }
        .format()
        .map_err(|_| SessionError::MutationRefused)?;
        let output = self.exec(&line, push_key.as_bytes()).await?;
        if output.exit_status != 0 || output.stdout.len() > 64 * 1024 {
            return Err(SessionError::MutationRefused);
        }
        serde_json::from_slice::<serde_json::Value>(&output.stdout)
            .map_err(|_| SessionError::Refused)?;
        Ok(output.stdout)
    }

    /// Revoke one caller-owned push notification device.
    pub async fn device_rm(
        &mut self,
        device_id: &str,
        request_id: &str,
    ) -> Result<(), SessionError> {
        let device_id = Identifier::parse(device_id).map_err(|_| SessionError::MutationRefused)?;
        let request_id =
            mila_model::RequestId::parse(request_id).map_err(|_| SessionError::MutationRefused)?;
        let output = self
            .exec(
                &format!("device rm {device_id} --json --request-id={request_id}"),
                &[],
            )
            .await?;
        if output.exit_status == 0 {
            Ok(())
        } else {
            Err(SessionError::MutationRefused)
        }
    }

    /// Enable or disable one caller-owned push notification device.
    pub async fn device_prefs(
        &mut self,
        device_id: &str,
        enabled: bool,
        request_id: &str,
    ) -> Result<(), SessionError> {
        let device_id = Identifier::parse(device_id).map_err(|_| SessionError::MutationRefused)?;
        let request_id =
            mila_model::RequestId::parse(request_id).map_err(|_| SessionError::MutationRefused)?;
        let output = self
            .exec(
                &format!(
                    "device prefs {device_id} --enabled={enabled} --json --request-id={request_id}"
                ),
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
