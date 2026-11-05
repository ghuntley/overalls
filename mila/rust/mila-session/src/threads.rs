use crate::{ApplicationSession, SessionError};
use mila_model::Identifier;

impl ApplicationSession {
    #[expect(
        clippy::too_many_lines,
        reason = "one closed command dispatch table mirrors Porsche's thread catalog"
    )]
    /// Execute one closed-vocabulary thread operation. Response JSON is bounded and
    /// parsed before crossing a native boundary; stdin is accepted only for commands
    /// whose protocol grammar requires it.
    pub async fn thread_action(
        &mut self,
        thread: Option<&str>,
        command: &str,
        secondary: Option<&str>,
        input: Option<&str>,
        request_id: Option<&str>,
    ) -> Result<Vec<u8>, SessionError> {
        let thread_id = thread
            .map(|v| Identifier::parse(v).map_err(|_| SessionError::InvalidThreadAction))
            .transpose()?;
        let arg: Option<String> = match (command, secondary) {
            ("thread read" | "thread mode", Some(value)) => Some(value.to_owned()),
            (_, Some(value)) => Some(
                Identifier::parse(value)
                    .map_err(|_| SessionError::InvalidThreadAction)?
                    .to_string(),
            ),
            (_, None) => None,
        };
        #[expect(
            clippy::expect_used,
            reason = "every arm that unwraps thread_id or arg is guarded by its is_some() check"
        )]
        let (line, stdin) = match command {
            "thread ls" if thread_id.is_none() && secondary.is_none() && input.is_none() => {
                ("thread ls --json".to_string(), Vec::new())
            }
            "thread show" | "thread turns"
                if thread_id.is_some() && secondary.is_none() && input.is_none() =>
            {
                (
                    format!("{command} {} --json", thread_id.as_ref().expect("checked")),
                    Vec::new(),
                )
            }
            "thread prompt" if thread_id.is_some() && secondary.is_none() => (
                format!(
                    "thread prompt {} - --json",
                    thread_id.as_ref().expect("checked")
                ),
                input
                    .ok_or(SessionError::InvalidThreadAction)?
                    .as_bytes()
                    .to_vec(),
            ),
            "thread answer" if thread_id.is_some() && arg.is_some() => (
                format!(
                    "thread answer {} {} - --json",
                    thread_id.as_ref().expect("checked"),
                    arg.as_ref().expect("checked")
                ),
                input
                    .ok_or(SessionError::InvalidThreadAction)?
                    .as_bytes()
                    .to_vec(),
            ),
            "thread plan approve" if thread_id.is_some() && arg.is_some() && input.is_none() => (
                format!(
                    "thread plan approve {} {} --json",
                    thread_id.as_ref().expect("checked"),
                    arg.as_ref().expect("checked")
                ),
                Vec::new(),
            ),
            "thread plan revise" if thread_id.is_some() && arg.is_some() => (
                format!(
                    "thread plan revise {} {} - --json",
                    thread_id.as_ref().expect("checked"),
                    arg.as_ref().expect("checked")
                ),
                input
                    .ok_or(SessionError::InvalidThreadAction)?
                    .as_bytes()
                    .to_vec(),
            ),
            "thread mode"
                if thread_id.is_some()
                    && matches!(arg.as_deref(), Some("plan" | "work"))
                    && input.is_none() =>
            {
                (
                    format!(
                        "thread mode {} {} --json",
                        thread_id.as_ref().expect("checked"),
                        arg.as_deref().expect("checked")
                    ),
                    Vec::new(),
                )
            }
            "thread read"
                if thread_id.is_some()
                    && arg.as_deref().is_some_and(|value| {
                        !value.is_empty()
                            && (value.len() == 1 || !value.starts_with('0'))
                            && value.parse::<u64>().is_ok_and(|sequence| sequence > 0)
                    })
                    && input.is_none() =>
            {
                (
                    format!(
                        "thread read {} {} --json",
                        thread_id.as_ref().expect("checked"),
                        arg.as_deref().expect("checked")
                    ),
                    Vec::new(),
                )
            }
            _ => return Err(SessionError::InvalidThreadAction),
        };
        if matches!(command, "thread mode" | "thread read") && request_id.is_none() {
            return Err(SessionError::MutationRefused);
        }
        if stdin.is_empty()
            && matches!(
                command,
                "thread prompt" | "thread answer" | "thread plan revise"
            )
        {
            return Err(SessionError::InvalidThreadAction);
        }
        if stdin.len() > 64 * 1024 || stdin.contains(&0) {
            return Err(SessionError::Bounds);
        }
        let line = mila_protocol::Command::parse(&line)
            .and_then(|c| c.format())
            .map_err(|_| SessionError::InvalidThreadAction)?;
        let line = if let Some(request) = request_id {
            let request =
                mila_model::RequestId::parse(request).map_err(|_| SessionError::MutationRefused)?;
            format!("{line} --request-id={request}")
        } else {
            line
        };
        let output = self.exec(&line, &stdin).await?;
        if output.exit_status != 0 || output.stdout.len() > 256 * 1024 {
            return Err(SessionError::MutationRefused);
        }
        serde_json::from_slice::<serde_json::Value>(&output.stdout)
            .map_err(|_| SessionError::Refused)?;
        Ok(output.stdout)
    }
}
