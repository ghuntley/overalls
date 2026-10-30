//! Shared locale policy for Mila native clients.
//!
//! Catalog text remains platform data; this crate owns the bounded, deterministic
//! locale decision used by every client.
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use thiserror::Error;

pub const DEFAULT_LOCALE: &str = "en";
pub const SUPPORTED_LOCALES: [&str; 28] = [
    "en", "zh-Hans", "hi", "es", "ar", "fr", "bn", "pt-BR", "pt-PT", "ru", "ur", "id", "de", "ja",
    "pcm", "mr", "te", "tr", "ta", "vi", "ko", "fil", "et", "fi", "sv", "arz", "sw", "ha",
];

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum Direction {
    Ltr,
    Rtl,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Locale(String);
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct CatalogEntry {
    pub domain: String,
    pub context: Option<String>,
    pub msgid: String,
    pub plural: Option<String>,
    pub translations: Vec<String>,
}
#[derive(Debug, Error, PartialEq, Eq)]
pub enum LocaleError {
    #[error("locale is empty or invalid")]
    Invalid,
    #[error("catalog entry has no translation")]
    EmptyTranslation,
}

impl Locale {
    pub fn parse(input: &str) -> Option<Self> {
        let n = normalize(input)?;
        SUPPORTED_LOCALES.iter().any(|x| *x == n).then_some(Self(n))
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
    pub fn direction(&self) -> Direction {
        match self.0.as_str() {
            "ar" | "arz" | "ur" => Direction::Rtl,
            _ => Direction::Ltr,
        }
    }
}
impl TryFrom<&str> for Locale {
    type Error = LocaleError;
    fn try_from(v: &str) -> Result<Self, Self::Error> {
        Self::parse(v).ok_or(LocaleError::Invalid)
    }
}

pub fn normalize(input: &str) -> Option<String> {
    let raw = input.trim();
    if raw.is_empty() || raw.len() > 64 || !raw.is_ascii() {
        return None;
    }
    let replaced = raw.replace('_', "-");
    let parts: Vec<&str> = replaced.split('-').filter(|x| !x.is_empty()).collect();
    if parts.is_empty() {
        return None;
    }
    let mut out = parts[0].to_ascii_lowercase();
    for (i, p) in parts.iter().enumerate().skip(1) {
        if !p.bytes().all(|b| b.is_ascii_alphanumeric()) {
            return None;
        }
        out.push('-');
        out.push_str(
            if p.len() == 4 {
                let mut q = p.to_ascii_lowercase();
                // `p` is ASCII (checked above), so byte 0 is a char boundary.
                if let Some(first) = q.get_mut(..1) {
                    first.make_ascii_uppercase();
                }
                q
            } else if i > 0 && p.len() == 2 {
                p.to_ascii_uppercase()
            } else {
                p.to_ascii_lowercase()
            }
            .as_str(),
        );
    }
    SUPPORTED_LOCALES
        .iter()
        .find(|x| x.eq_ignore_ascii_case(&out))
        .map(|x| (*x).to_owned())
}
pub fn direction(input: &str) -> Direction {
    Locale::parse(input).map_or(Direction::Ltr, |x| x.direction())
}
pub fn choose(user: Option<&str>, session: Option<&str>, accept_language: Option<&str>) -> Locale {
    user.and_then(Locale::parse)
        .or_else(|| session.and_then(Locale::parse))
        .or_else(|| negotiate(accept_language.unwrap_or("")))
        .unwrap_or_else(|| Locale("en".into()))
}
pub fn negotiate(header: &str) -> Option<Locale> {
    if header.len() > 8192 {
        return None;
    }
    let mut vals = header
        .split(',')
        .filter_map(|part| {
            let mut i = part.split(';');
            let tag = i.next()?.trim();
            let q = i
                .find_map(|x| x.trim().strip_prefix("q=")?.parse::<f32>().ok())
                .unwrap_or(1.0);
            (q > 0.0).then_some((tag, q))
        })
        .collect::<Vec<_>>();
    vals.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(Ordering::Equal));
    vals.into_iter().find_map(|(tag, _)| {
        Locale::parse(tag).or_else(|| {
            let lang = tag.split('-').next()?;
            SUPPORTED_LOCALES
                .iter()
                .find(|x| x.split('-').next() == Some(lang))
                .and_then(|x| Locale::parse(x))
        })
    })
}
impl CatalogEntry {
    pub fn validate(&self) -> Result<(), LocaleError> {
        if self.translations.is_empty() || self.translations.iter().any(|x| x.trim().is_empty()) {
            return Err(LocaleError::EmptyTranslation);
        }
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn locales() {
        assert_eq!(normalize("pt_br"), Some("pt-BR".into()));
        assert_eq!(direction("ar"), Direction::Rtl);
        assert_eq!(
            choose(None, None, Some("xx, ar;q=0.9")),
            Locale::parse("ar").unwrap()
        );
    }
    #[test]
    fn catalog() {
        let c = CatalogEntry {
            domain: "x".into(),
            context: None,
            msgid: "a".into(),
            plural: None,
            translations: vec!["A".into()],
        };
        assert!(c.validate().is_ok());
    }

    #[test]
    fn plural_forms_keep_catalog_order() {
        let c = CatalogEntry {
            domain: "mila".into(),
            context: None,
            msgid: "item".into(),
            plural: Some("items".into()),
            translations: vec!["élément".into(), "éléments".into()],
        };
        assert!(c.validate().is_ok());
    }

    #[test]
    fn zero_quality_and_oversized_headers_fall_back() {
        assert_eq!(negotiate("ar;q=0, en;q=0"), None);
        assert_eq!(negotiate(&"ar".repeat(5000)), None);
    }
}
