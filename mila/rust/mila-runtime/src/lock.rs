use serde::{Deserialize, Serialize};

/// Availability of the platform authentication mechanism used by app lock.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum LockAvailability {
    Unknown,
    Available,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum LockDelay {
    Immediate,
    OneMinute,
    FiveMinutes,
}
impl LockDelay {
    pub const fn millis(self) -> u64 {
        match self {
            Self::Immediate => 0,
            Self::OneMinute => 60_000,
            Self::FiveMinutes => 300_000,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum LockPhase {
    Unlocked,
    Locked,
    Authenticating,
}

/// Events supplied by a native lifecycle/authentication adapter.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LockEvent {
    Availability(LockAvailability),
    Enable,
    Disable,
    Delay(LockDelay),
    Backgrounded(u64),
    Foregrounded(u64),
    UnlockRequested,
    UnlockFinished { attempt: u32, success: bool },
}

/// Pure, fail-closed app lock state machine. It contains no platform handles.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct AppLock {
    pub enabled: bool,
    pub delay: LockDelay,
    pub availability: LockAvailability,
    pub phase: LockPhase,
    pub attempt: u32,
    pub backgrounded_at: Option<u64>,
    pub last_failed: bool,
}
impl AppLock {
    pub const fn start(enabled: bool, delay: LockDelay) -> Self {
        Self {
            enabled,
            delay,
            availability: LockAvailability::Unknown,
            phase: if enabled {
                LockPhase::Locked
            } else {
                LockPhase::Unlocked
            },
            attempt: 0,
            backgrounded_at: None,
            last_failed: false,
        }
    }
    pub const fn effective(self) -> bool {
        self.enabled && !matches!(self.availability, LockAvailability::Unavailable)
    }
    pub const fn obscured(self) -> bool {
        !matches!(self.phase, LockPhase::Unlocked)
    }
    /// Applies one event; stale authentication results never unlock content.
    pub fn apply(mut self, event: LockEvent) -> Self {
        match event {
            LockEvent::Availability(a) => {
                self.availability = a;
                if matches!(a, LockAvailability::Unavailable) {
                    self.phase = LockPhase::Unlocked;
                    self.last_failed = false;
                }
            }
            LockEvent::Enable
                if matches!(self.phase, LockPhase::Unlocked)
                    && matches!(self.availability, LockAvailability::Available) =>
            {
                self.enabled = true
            }
            LockEvent::Disable if matches!(self.phase, LockPhase::Unlocked) => self.enabled = false,
            LockEvent::Delay(d) if matches!(self.phase, LockPhase::Unlocked) => self.delay = d,
            LockEvent::Backgrounded(at) if !matches!(self.phase, LockPhase::Authenticating) => {
                self.backgrounded_at = Some(at);
                if self.effective() && matches!(self.delay, LockDelay::Immediate) {
                    self.phase = LockPhase::Locked;
                }
            }
            LockEvent::Foregrounded(at) if !matches!(self.phase, LockPhase::Authenticating) => {
                if self.effective()
                    && self.backgrounded_at.is_some_and(|from| {
                        at < from || at.saturating_sub(from) >= self.delay.millis()
                    })
                {
                    self.phase = LockPhase::Locked;
                }
                self.backgrounded_at = None;
            }
            LockEvent::UnlockRequested
                if matches!(self.phase, LockPhase::Locked)
                    && matches!(self.availability, LockAvailability::Available) =>
            {
                self.phase = LockPhase::Authenticating;
                self.attempt = self.attempt.saturating_add(1);
            }
            LockEvent::UnlockFinished { attempt, success }
                if attempt == self.attempt && matches!(self.phase, LockPhase::Authenticating) =>
            {
                if success {
                    self.phase = LockPhase::Unlocked;
                    self.backgrounded_at = None;
                    self.last_failed = false;
                } else {
                    self.phase = LockPhase::Locked;
                    self.last_failed = true;
                }
            }
            _ => {}
        }
        self
    }
}
