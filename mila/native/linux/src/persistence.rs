//! Typed, durable appearance and locale settings for the Linux client.
//!
//! The deployment list is persisted by `mila_native_linux::deployments`.
//! Credentials and session material are owned by the runtime.

use serde::{Deserialize, Serialize};
use std::{fs, io, path::PathBuf};

const SETTINGS_FILE_NAME: &str = "settings.json";
const MAX_PERSISTED_BYTES: usize = 64 * 1024;

fn restrict_permissions(path: &std::path::Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

fn require_owner_only(path: &std::path::Path) -> Result<(), PersistenceError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let metadata = fs::metadata(path)?;
        if metadata.permissions().mode() & 0o077 != 0 {
            return Err(PersistenceError::InvalidData);
        }
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(crate) enum Appearance {
    System,
    Light,
    Dark,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(crate) struct Settings {
    pub(crate) appearance: Appearance,
    pub(crate) locale: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            appearance: Appearance::System,
            locale: "en".to_owned(),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum LocaleDirection {
    Ltr,
    Rtl,
}

impl Settings {
    pub(crate) fn direction(&self) -> LocaleDirection {
        let language = self.locale.split('-').next().unwrap_or_default();
        match language {
            "ar" | "fa" | "he" | "ur" => LocaleDirection::Rtl,
            _ => LocaleDirection::Ltr,
        }
    }

    pub(crate) fn validate(appearance: Appearance, locale: &str) -> Result<Self, PersistenceError> {
        let raw = locale.trim().replace('_', "-");
        let mut parts = raw.split('-');
        let Some(language) = parts.next() else {
            return Err(PersistenceError::InvalidLocale);
        };
        let mut canonical = language.to_ascii_lowercase();
        for part in parts {
            if part.len() == 4 && part.bytes().all(|b| b.is_ascii_alphabetic()) {
                let mut chars = part.chars();
                if let Some(first) = chars.next() {
                    canonical.push('-');
                    canonical.push(first.to_ascii_uppercase());
                    canonical.extend(chars.map(|c| c.to_ascii_lowercase()));
                }
            } else {
                canonical.push('-');
                canonical.push_str(&part.to_ascii_uppercase());
            }
        }
        let locale = canonical;
        let valid = locale.len() >= 2
            && locale.len() <= 35
            && locale.split('-').all(|part| {
                !part.is_empty()
                    && part.len() <= 8
                    && part.bytes().all(|b| b.is_ascii_alphanumeric())
            })
            && locale
                .chars()
                .next()
                .is_some_and(|c| c.is_ascii_alphabetic());
        if !valid {
            return Err(PersistenceError::InvalidLocale);
        }
        Ok(Self { appearance, locale })
    }
}

#[derive(Debug)]
pub(crate) enum PersistenceError {
    #[expect(
        dead_code,
        reason = "the I/O cause is kept for the error's Debug output"
    )]
    Io(io::Error),
    InvalidData,
    InvalidLocale,
}

impl From<io::Error> for PersistenceError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

fn settings_path() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("MILA_SETTINGS_PATH") {
        return Some(PathBuf::from(path));
    }
    let root = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))?;
    Some(root.join("mila").join(SETTINGS_FILE_NAME))
}

pub(crate) fn load_settings() -> Result<Settings, PersistenceError> {
    let Some(path) = settings_path() else {
        return Ok(Settings::default());
    };
    let bytes = match fs::read(&path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Settings::default()),
        Err(error) => return Err(error.into()),
    };
    require_owner_only(&path)?;
    if bytes.len() > MAX_PERSISTED_BYTES {
        return Err(PersistenceError::InvalidData);
    }
    let settings: Settings =
        serde_json::from_slice(&bytes).map_err(|_| PersistenceError::InvalidData)?;
    Settings::validate(settings.appearance, &settings.locale)
}

pub(crate) fn save_settings(settings: &Settings) -> Result<(), PersistenceError> {
    let settings = Settings::validate(settings.appearance, &settings.locale)?;
    let Some(path) = settings_path() else {
        return Err(PersistenceError::Io(io::Error::new(
            io::ErrorKind::NotFound,
            "configuration directory unavailable",
        )));
    };
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid configuration path"))?;
    fs::create_dir_all(parent)?;
    let temporary = path.with_extension("json.tmp");
    fs::write(
        &temporary,
        serde_json::to_vec(&settings).map_err(|_| PersistenceError::InvalidData)?,
    )?;
    restrict_permissions(&temporary)?;
    fs::rename(temporary, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings_validate_and_normalize_locale() {
        let settings = Settings::validate(Appearance::Dark, "fr_FR").unwrap();
        assert_eq!(settings.locale, "fr-FR");
        assert_eq!(
            Settings::validate(Appearance::System, "ZH_hant_tw")
                .unwrap()
                .locale,
            "zh-Hant-TW"
        );
        assert_eq!(settings.appearance, Appearance::Dark);
        assert!(Settings::validate(Appearance::System, "not a locale").is_err());
        assert!(Settings::validate(Appearance::System, "").is_err());
        assert_eq!(settings.direction(), LocaleDirection::Ltr);
        assert_eq!(
            Settings::validate(Appearance::System, "ar_SA")
                .unwrap()
                .direction(),
            LocaleDirection::Rtl
        );
    }

    #[cfg(unix)]
    #[test]
    fn settings_load_rejects_group_accessible_file() {
        use std::os::unix::fs::PermissionsExt;
        let path = std::env::temp_dir().join(format!("mila-settings-{}.json", std::process::id()));
        std::env::set_var("MILA_SETTINGS_PATH", &path);
        fs::write(&path, br#"{"appearance":"System","locale":"en"}"#).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
        assert!(matches!(
            load_settings(),
            Err(PersistenceError::InvalidData)
        ));
        let _ = fs::remove_file(&path);
        std::env::remove_var("MILA_SETTINGS_PATH");
    }
}
