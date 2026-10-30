//! Rolling per-VM and host-wide guest telemetry intake budgets.

use crate::binding::Binding;
use std::collections::HashMap;
use std::time::{Duration, Instant};

pub(crate) const VM_BYTES_PER_MINUTE: usize = 1_048_576;
pub(crate) const HOST_BYTES_PER_MINUTE: usize = 2_097_152;
pub(crate) const VM_REQUESTS_PER_MINUTE: usize = 60;
pub(crate) const HOST_REQUESTS_PER_MINUTE: usize = 120;
const MAX_ACTIVE_VMS: usize = 4096;

#[derive(Debug)]
struct Window {
    since: Instant,
    bytes: usize,
    requests: usize,
}

impl Window {
    fn new(now: Instant) -> Self {
        Self {
            since: now,
            bytes: 0,
            requests: 0,
        }
    }

    fn refresh(&mut self, now: Instant) {
        if now.duration_since(self.since) >= Duration::from_secs(60) {
            *self = Self::new(now);
        }
    }

    fn fits(&self, bytes: usize, byte_limit: usize, request_limit: usize) -> bool {
        self.requests < request_limit && bytes <= byte_limit.saturating_sub(self.bytes)
    }

    fn record(&mut self, bytes: usize) {
        self.bytes += bytes;
        self.requests += 1;
    }
}

#[derive(Debug)]
pub struct IntakeLimit {
    host: Window,
    vms: HashMap<String, Window>,
}

impl IntakeLimit {
    pub fn new(now: Instant) -> Self {
        Self {
            host: Window::new(now),
            vms: HashMap::new(),
        }
    }

    // @cc [owner:ghuntley,label:capacity] guest-telemetry-bounded
    // Each VM and host MUST stay within fixed rolling-window byte/request
    // limits, and the number of tracked VM windows MUST remain bounded.
    pub fn admit(&mut self, binding: &Binding, bytes: usize, now: Instant) -> bool {
        self.host.refresh(now);
        if !self
            .host
            .fits(bytes, HOST_BYTES_PER_MINUTE, HOST_REQUESTS_PER_MINUTE)
        {
            return false;
        }
        if !self.vms.contains_key(&binding.vm_id) && self.vms.len() >= MAX_ACTIVE_VMS {
            self.vms
                .retain(|_, window| now.duration_since(window.since) < Duration::from_secs(60));
            if self.vms.len() >= MAX_ACTIVE_VMS {
                return false;
            }
        }
        let vm = self
            .vms
            .entry(binding.vm_id.clone())
            .or_insert_with(|| Window::new(now));
        vm.refresh(now);
        if !vm.fits(bytes, VM_BYTES_PER_MINUTE, VM_REQUESTS_PER_MINUTE) {
            return false;
        }
        self.host.record(bytes);
        vm.record(bytes);
        true
    }
}
