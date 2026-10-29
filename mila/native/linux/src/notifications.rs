//! Linux notification capability reporting.
//!
//! Mila's platform profile does not currently provide a Linux push provider.
//! Keep that absence explicit at the native boundary so the UI cannot claim
//! registration succeeded or retain a misleading enabled state.

/// Why notification delivery is unavailable on this platform.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NotificationUnavailable {
    NoPushProvider,
}

/// Capability exposed by the platform profile.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NotificationCapability {
    Unsupported(NotificationUnavailable),
    /// Desktop notifications are available through the freedesktop portal,
    /// even though Linux has no Susan push registration provider.
    LocalDesktop,
}

/// Native notification state owned by the Linux presentation host.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NotificationState {
    capability: NotificationCapability,
    enabled: bool,
    devices: Vec<String>,
}

impl NotificationState {
    /// Constructs the Linux capability from the platform profile.
    pub const fn linux() -> Self {
        Self {
            capability: NotificationCapability::Unsupported(
                NotificationUnavailable::NoPushProvider,
            ),
            enabled: false,
            devices: Vec::new(),
        }
    }

    pub const fn desktop() -> Self {
        Self {
            capability: NotificationCapability::LocalDesktop,
            enabled: false,
            devices: Vec::new(),
        }
    }

    pub const fn capability(&self) -> NotificationCapability {
        self.capability
    }

    pub const fn enabled(&self) -> bool {
        self.enabled
    }

    /// Restores bounded local device identifiers from a JSON array.
    pub fn load_devices(&mut self, bytes: &[u8]) -> Result<(), NotificationUnavailable> {
        let values: Vec<String> =
            serde_json::from_slice(bytes).map_err(|_| NotificationUnavailable::NoPushProvider)?;
        if values.len() > 32
            || values.iter().any(|id| !Self::valid_device_id(id))
            || values
                .iter()
                .enumerate()
                .any(|(index, id)| values[..index].iter().any(|existing| existing == id))
        {
            return Err(NotificationUnavailable::NoPushProvider);
        }
        self.devices = values;
        Ok(())
    }

    pub fn devices(&self) -> &[String] {
        &self.devices
    }

    pub fn persist_devices(&self) -> Result<Vec<u8>, NotificationUnavailable> {
        serde_json::to_vec(&self.devices).map_err(|_| NotificationUnavailable::NoPushProvider)
    }

    pub fn register_device(&mut self, id: &str) -> Result<(), NotificationUnavailable> {
        if !Self::valid_device_id(id) {
            return Err(NotificationUnavailable::NoPushProvider);
        }
        if self.devices.iter().any(|existing| existing == id) {
            return Ok(());
        }
        if self.devices.len() >= 32 {
            return Err(NotificationUnavailable::NoPushProvider);
        }
        if !self.devices.iter().any(|existing| existing == id) {
            self.devices.push(id.to_owned());
        }
        Ok(())
    }

    fn valid_device_id(id: &str) -> bool {
        !id.is_empty()
            && id.len() <= 128
            && !id.chars().any(char::is_control)
            && !id.chars().any(char::is_whitespace)
    }

    pub fn remove_device(&mut self, id: &str) {
        self.devices.retain(|existing| existing != id);
    }

    /// Removes a provider-invalidated device from the local projection.
    /// Returns whether an entry was removed, allowing callers to distinguish
    /// idempotent invalidation from an unknown device.
    pub fn invalidate_device(&mut self, id: &str) -> bool {
        let before = self.devices.len();
        self.remove_device(id);
        self.devices.len() != before
    }

    /// @cc [owner:ghuntley,label:security;desktop] linux-notifications-registration
    /// Registration MUST fail closed when the platform has no push provider,
    /// and a failed attempt MUST leave the state disabled.
    ///
    /// Attempts to register this host with the platform push provider.
    ///
    /// Linux has no provider in the shared Susan protocol. Keeping a distinct
    /// registration operation prevents the GTK host from treating a local
    /// toggle as a completed server registration.
    pub fn register(&mut self) -> Result<(), NotificationUnavailable> {
        self.enabled = false;
        Err(NotificationUnavailable::NoPushProvider)
    }

    /// @cc [owner:ghuntley,label:security;desktop] linux-notifications-no-provider
    /// Linux MUST refuse notification enablement while no push provider exists;
    /// the native state MUST remain disabled after every refusal.
    pub fn enable(&mut self) -> Result<(), NotificationUnavailable> {
        match self.capability {
            NotificationCapability::Unsupported(reason) => {
                self.enabled = false;
                Err(reason)
            }
            NotificationCapability::LocalDesktop => {
                self.enabled = true;
                Ok(())
            }
        }
    }

    /// Disables local notification presentation without changing capability.
    pub const fn disable(&mut self) {
        self.enabled = false;
    }

    /// Returns whether this host can display a local desktop notification.
    pub const fn can_display_locally(&self) -> bool {
        matches!(self.capability, NotificationCapability::LocalDesktop)
    }
}

#[cfg(test)]
mod tests {
    use super::{NotificationCapability, NotificationState, NotificationUnavailable};

    #[test]
    fn linux_reports_unsupported_without_enabling() {
        let mut state = NotificationState::linux();
        assert_eq!(
            state.capability(),
            NotificationCapability::Unsupported(NotificationUnavailable::NoPushProvider)
        );
        assert!(!state.enabled());
        assert_eq!(state.enable(), Err(NotificationUnavailable::NoPushProvider));
        assert!(!state.enabled());
        assert_eq!(
            state.register(),
            Err(NotificationUnavailable::NoPushProvider)
        );
        assert!(!state.enabled());
    }

    #[test]
    fn desktop_capability_can_be_enabled_without_push_registration() {
        let mut state = NotificationState::desktop();
        assert!(state.can_display_locally());
        assert_eq!(state.enable(), Ok(()));
        assert!(state.enabled());
        state.disable();
        assert!(!state.enabled());
        assert_eq!(
            state.register(),
            Err(NotificationUnavailable::NoPushProvider)
        );
        assert!(!state.enabled());
    }

    #[test]
    fn desktop_devices_round_trip_with_bounds() {
        let mut state = NotificationState::desktop();
        state.register_device("desktop-a").expect("register");
        state.register_device("desktop-a").expect("idempotent");
        let bytes = state.persist_devices().expect("persist");
        let mut restored = NotificationState::desktop();
        restored.load_devices(&bytes).expect("load");
        assert_eq!(restored.devices(), &["desktop-a"]);
        restored.remove_device("desktop-a");
        assert!(restored.devices().is_empty());
    }

    #[test]
    fn invalidation_is_idempotent_and_identifiers_are_bounded() {
        let mut state = NotificationState::desktop();
        assert!(state.register_device("desktop-a").is_ok());
        assert!(state.invalidate_device("desktop-a"));
        assert!(!state.invalidate_device("desktop-a"));
        assert!(state.register_device("bad id").is_err());
        assert!(state.register_device("bad\nvalue").is_err());
        let invalid = serde_json::to_vec(&["bad id"]).expect("json");
        assert!(state.load_devices(&invalid).is_err());
        let duplicate = serde_json::to_vec(&["desktop-a", "desktop-a"]).expect("json");
        assert!(state.load_devices(&duplicate).is_err());
        let mut full = NotificationState::desktop();
        for index in 0..32 {
            full.register_device(&format!("desktop-{index}"))
                .expect("register");
        }
        full.register_device("desktop-0")
            .expect("duplicate is idempotent");
        assert!(full.register_device("desktop-new").is_err());
        let multibyte = "é".repeat(65);
        assert!(state.register_device(&multibyte).is_err());
    }
}
