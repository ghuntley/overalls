use crate::ModelError;
use serde::{Deserialize, Serialize};

/// A trusted repository source used by the launch route.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
pub struct WorkspaceSource {
    pub owner: String,
    pub repository: String,
    pub pull_request: Option<u32>,
}

impl WorkspaceSource {
    /// Parses the public GitHub URL forms shared by Marshall and Mila.
    pub fn parse(value: &str) -> Result<Self, ModelError> {
        let prefix = "https://github.com/";
        let rest = value
            .strip_prefix(prefix)
            .ok_or(ModelError::InvalidSource)?;
        if rest.contains(['?', '#', '%', '@', '\\']) {
            return Err(ModelError::InvalidSource);
        }
        let parts: Vec<&str> = rest.trim_end_matches(".git").split('/').collect();
        if parts.len() != 2 && parts.len() != 4 {
            return Err(ModelError::InvalidSource);
        }
        if parts.iter().take(2).any(|part| !valid_label(part)) {
            return Err(ModelError::InvalidSource);
        }
        let pull_request = if parts.len() == 4 && parts[2] == "pull" {
            let number = parts[3]
                .parse::<u32>()
                .map_err(|_| ModelError::InvalidSource)?;
            if number == 0 || parts[3].starts_with('0') {
                return Err(ModelError::InvalidSource);
            }
            Some(number)
        } else if parts.len() == 4 {
            return Err(ModelError::InvalidSource);
        } else {
            None
        };
        Ok(Self {
            owner: parts[0].to_owned(),
            repository: parts[1].to_owned(),
            pull_request,
        })
    }

    /// Returns the canonical source URL.
    pub fn to_url(&self) -> String {
        match self.pull_request {
            Some(number) => format!(
                "https://github.com/{}/{}/pull/{number}",
                self.owner, self.repository
            ),
            None => format!("https://github.com/{}/{}", self.owner, self.repository),
        }
    }
}

fn valid_label(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 100
        && value
            .as_bytes()
            .first()
            .is_some_and(|byte| byte.is_ascii_alphanumeric())
        && value
            .as_bytes()
            .last()
            .is_some_and(|byte| byte.is_ascii_alphanumeric())
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_' || byte == b'.'
        })
        && value != "."
        && value != ".."
}
