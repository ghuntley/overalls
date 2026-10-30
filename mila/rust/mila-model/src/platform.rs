use serde::{Deserialize, Serialize};

/// The client platforms accepted by Porsche's device registration command.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DevicePlatform {
    Ios,
    Android,
    Macos,
    Windows,
}

impl DevicePlatform {
    /// Returns the exact protocol spelling.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Ios => "ios",
            Self::Android => "android",
            Self::Macos => "macos",
            Self::Windows => "windows",
        }
    }
}
