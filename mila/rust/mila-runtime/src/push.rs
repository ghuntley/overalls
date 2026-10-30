use crate::{validate_host, RuntimeError};
use serde::{Deserialize, Serialize};

/// Push registration data kept in memory while a platform token is exchanged.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PushRegistration {
    pub platform: mila_model::DevicePlatform,
    pub push_key: String,
    pub key_id: String,
    pub expires_at: u64,
}

/// Push provider accepted by Susan's closed registration API.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PushProvider {
    Apns,
    Fcm,
    Wns,
}

impl PushProvider {
    pub const fn origin(self) -> &'static str {
        match self {
            Self::Apns => "https://api.push.apple.com",
            Self::Fcm => "https://fcm.googleapis.com",
            Self::Wns => "https://notify.windows.com",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PushEnvironment {
    Production,
    Development,
}

/// Secret provider token. Formatting deliberately never exposes its contents.
#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
pub struct ProviderToken(String);
impl std::fmt::Debug for ProviderToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ProviderToken(REDACTED)")
    }
}
impl ProviderToken {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Closed request sent from a native client to Susan for key issuance.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PushRegistrationRequest {
    pub provider: PushProvider,
    pub token: ProviderToken,
    pub app_id: String,
    pub environment: PushEnvironment,
    pub deployment: String,
    /// WNS channel URI; absent for APNs and FCM, whose origins are fixed.
    pub endpoint: Option<String>,
}

impl PushRegistrationRequest {
    pub fn new(
        provider: PushProvider,
        token: String,
        app_id: String,
        environment: PushEnvironment,
        deployment: String,
        endpoint: Option<String>,
    ) -> Result<Self, RuntimeError> {
        if app_id.is_empty()
            || app_id.len() > 256
            || !app_id.bytes().all(|b| b.is_ascii_graphic() && b != b'"')
        {
            return Err(RuntimeError::InvalidPushRegistration);
        }
        validate_host(&deployment).map_err(|_| RuntimeError::InvalidPushRegistration)?;
        if provider != PushProvider::Apns && environment == PushEnvironment::Development {
            return Err(RuntimeError::InvalidPushRegistration);
        }
        if !provider_token_valid(provider, &token) {
            return Err(RuntimeError::InvalidPushRegistration);
        }
        match provider {
            PushProvider::Wns => {
                let value = endpoint
                    .as_deref()
                    .ok_or(RuntimeError::InvalidPushRegistration)?;
                if value != token || !wns_channel_valid(value) {
                    return Err(RuntimeError::InvalidPushRegistration);
                }
            }
            PushProvider::Apns | PushProvider::Fcm if endpoint.is_some() => {
                return Err(RuntimeError::InvalidPushRegistration)
            }
            _ => {}
        }
        Ok(Self {
            provider,
            token: ProviderToken(token),
            app_id,
            environment,
            deployment,
            endpoint,
        })
    }
}

impl PushRegistrationRequest {
    /// @cc [owner:ghuntley,label:protocol;privacy] mila-susan-key-request-body
    /// The Susan key-issuance body MUST contain exactly Susan's closed members
    /// `provider`, `token`, `app_id`, `environment` and `deployment`; the WNS
    /// `endpoint` duplicate is a client-side check and MUST NOT be sent.
    pub fn susan_body(&self) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "provider": self.provider,
            "token": self.token.as_str(),
            "app_id": self.app_id,
            "environment": self.environment,
            "deployment": self.deployment,
        }))
        .unwrap_or_default()
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PushRegistrationReply {
    pub push_key: String,
    pub key_id: String,
    pub expires_at: u64,
}

impl PushRegistrationReply {
    pub fn new(
        push_key: String,
        key_id: String,
        expires_at: u64,
        now: u64,
    ) -> Result<Self, RuntimeError> {
        if !(16..=700).contains(&push_key.len())
            || !base64url(&push_key)
            || key_id.is_empty()
            || key_id.len() > 128
            || expires_at <= now
        {
            return Err(RuntimeError::InvalidPushRegistration);
        }
        Ok(Self {
            push_key,
            key_id,
            expires_at,
        })
    }
}

impl PushRegistrationReply {
    /// Decodes Susan's `201` key-issuance reply
    /// `{"push_key","key_id","expires_at"}` where `expires_at` is an ISO-8601
    /// UTC timestamp. Unknown members, non-UTC offsets and expired keys refuse.
    pub fn decode_susan(bytes: &[u8], now: u64) -> Result<Self, RuntimeError> {
        if bytes.len() > 4096 {
            return Err(RuntimeError::InvalidPushRegistration);
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Wire {
            push_key: String,
            key_id: String,
            expires_at: String,
        }
        let wire: Wire =
            serde_json::from_slice(bytes).map_err(|_| RuntimeError::InvalidPushRegistration)?;
        let expires_at =
            parse_utc_timestamp(&wire.expires_at).ok_or(RuntimeError::InvalidPushRegistration)?;
        if wire.key_id.chars().any(char::is_control) {
            return Err(RuntimeError::InvalidPushRegistration);
        }
        Self::new(wire.push_key, wire.key_id, expires_at, now)
    }
}

/// Parses `YYYY-MM-DDTHH:MM:SS[.fraction]Z` into Unix seconds.
fn parse_utc_timestamp(value: &str) -> Option<u64> {
    let bytes = value.as_bytes();
    if !value.is_ascii() || bytes.len() < 20 || bytes.len() > 32 || *bytes.last()? != b'Z' {
        return None;
    }
    let digits = |range: std::ops::Range<usize>| -> Option<u64> {
        let part = value.get(range)?;
        if part.bytes().all(|b| b.is_ascii_digit()) {
            part.parse().ok()
        } else {
            None
        }
    };
    if bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
    {
        return None;
    }
    let fraction = &value[19..value.len() - 1];
    if !(fraction.is_empty()
        || (fraction.len() >= 2
            && fraction.starts_with('.')
            && fraction[1..].bytes().all(|b| b.is_ascii_digit())))
    {
        return None;
    }
    let (year, month, day) = (digits(0..4)?, digits(5..7)?, digits(8..10)?);
    let (hour, minute, second) = (digits(11..13)?, digits(14..16)?, digits(17..19)?);
    let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    let month_days = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    if !(1970..=9999).contains(&year)
        || !(1..=12).contains(&month)
        || day == 0
        || day > month_days[(month - 1) as usize]
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }
    // Days from civil (Howard Hinnant), restricted to post-epoch dates.
    let (y, m) = if month <= 2 {
        (year - 1, month + 9)
    } else {
        (year, month - 3)
    };
    let era = y / 400;
    let yoe = y - era * 400;
    let doy = (153 * m + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(days * 86_400 + hour * 3600 + minute * 60 + second)
}

fn provider_token_valid(provider: PushProvider, token: &str) -> bool {
    match provider {
        PushProvider::Apns => {
            (32..=200).contains(&token.len())
                && token
                    .bytes()
                    .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        }
        PushProvider::Fcm => {
            (32..=512).contains(&token.len())
                && token
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"_:-".contains(&b))
        }
        PushProvider::Wns => wns_channel_valid(token),
    }
}

/// @cc [owner:ghuntley,label:security;privacy] mila-wns-channel-shape
/// A WNS channel MUST match Susan's `susan-wns-channel-shape`: HTTPS with the
/// implicit default port, a lower-case DNS host under `.notify.windows.com`, a
/// non-empty path, no userinfo or fragment, no backslash, space or `%00`, and
/// at most 1024 bytes. Percent escapes in the channel token are permitted.
fn wns_channel_valid(value: &str) -> bool {
    if value.len() > 1024
        || !value.starts_with("https://")
        || value.contains([' ', '\\', '#', '@'])
        || value.contains("%00")
        || value.bytes().any(|b| b.is_ascii_control() || !b.is_ascii())
    {
        return false;
    }
    let Some((host, path)) = value[8..].split_once('/') else {
        return false;
    };
    let Some(prefix) = host.strip_suffix(".notify.windows.com") else {
        return false;
    };
    !path.is_empty()
        && !prefix.is_empty()
        && host.split('.').all(|label| {
            (1..=63).contains(&label.len())
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        })
}
impl PushRegistration {
    pub fn new(
        platform: mila_model::DevicePlatform,
        push_key: String,
        key_id: String,
        expires_at: u64,
        now: u64,
    ) -> Result<Self, RuntimeError> {
        if !(16..=700).contains(&push_key.len())
            || !push_key
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            || key_id.is_empty()
            || key_id.len() > 128
            || expires_at <= now
        {
            return Err(RuntimeError::InvalidPushRegistration);
        }
        Ok(Self {
            platform,
            push_key,
            key_id,
            expires_at,
        })
    }
}

/// Metadata for a Susan poke; ciphertext remains opaque to the core.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PokeEnvelope {
    pub deployment: String,
    pub push_key: String,
    pub delivery_id: String,
    pub collapse_id: String,
    pub kind: String,
    pub issued_at: u64,
    pub nonce: String,
    pub ciphertext: String,
}
impl PokeEnvelope {
    pub fn validate(&self, now: u64) -> Result<(), RuntimeError> {
        validate_host(&self.deployment)?;
        if self.push_key.is_empty()
            || self.push_key.len() > 700
            || !base64url(&self.push_key)
            || self.delivery_id.is_empty()
            || self.delivery_id.len() > 128
            || self.collapse_id.is_empty()
            || self.collapse_id.len() > 128
            || self.kind.is_empty()
            || self.kind.len() > 64
            || self.nonce.is_empty()
            || self.nonce.len() > 128
            || self.ciphertext.is_empty()
            || self.ciphertext.len() > 4096
            || !base64url(&self.ciphertext)
            || self.issued_at > now.saturating_add(300)
            || now.saturating_sub(self.issued_at) > 86_400
        {
            return Err(RuntimeError::InvalidPoke);
        }
        Ok(())
    }
}
fn base64url(value: &str) -> bool {
    value
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
