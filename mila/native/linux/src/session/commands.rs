//! Machine, sharing, thread, request, web and device commands on a live session.

use super::{
    copy_output, valid_request_id, validate_session_identifier, LiveSession, SessionError,
};

impl LiveSession {
    /// Read the authenticated account SSH-key inventory. The FFI layer keeps
    /// the response bounded; callers must decode it with `decode_ssh_keys`.
    pub fn ssh_keys(&self) -> Result<Vec<u8>, SessionError> {
        let handle = self.handle()?;
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_ssh_keys(handle, out, capacity, written)
        })
    }

    /// Revoke one server-managed SSH key, once per request identifier.
    pub fn ssh_key_revoke(&mut self, key_id: &str, request_id: &str) -> Result<(), SessionError> {
        let command = crate::adapter::format_ssh_key_revoke(key_id, request_id)
            .map_err(|_| SessionError::InvalidInput)?;
        if !self.submitted_mutations.insert(request_id.to_owned()) {
            return Err(SessionError::Busy);
        }
        let handle = self.handle()?;
        // SAFETY: every pointer/length pair borrows a live Rust slice for this
        // synchronous call, and the C ABI copies its inputs without retaining them.
        let status = unsafe {
            mila_ffi::session::mila_session_ssh_key_revoke(
                handle,
                key_id.as_bytes().as_ptr(),
                key_id.len(),
                request_id.as_bytes().as_ptr(),
                request_id.len(),
            )
        };
        let _ = command;
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }

    /// Execute one authenticated machine mutation through Porsche's closed
    /// command vocabulary. The request id is validated before crossing FFI.
    pub fn machine_action(
        &mut self,
        machine_id: &str,
        action: &str,
        request_id: &str,
    ) -> Result<(), SessionError> {
        validate_session_identifier(machine_id)?;
        if !matches!(action, "start" | "stop" | "pause" | "resume" | "rm")
            || request_id.len() != 40
            || !request_id.starts_with("porsche-")
            || !request_id.as_bytes()[8..].iter().all(u8::is_ascii_hexdigit)
        {
            return Err(SessionError::InvalidInput);
        }
        if !self.submitted_mutations.insert(request_id.to_owned()) {
            return Err(SessionError::Busy);
        }
        let handle = self.handle()?;
        // SAFETY: every pointer/length pair borrows a live Rust slice for this
        // synchronous call, and the C ABI copies its inputs without retaining them.
        let status = unsafe {
            mila_ffi::session::mila_session_machine_action(
                handle,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                action.as_bytes().as_ptr(),
                action.len(),
                request_id.as_bytes().as_ptr(),
                request_id.len(),
            )
        };
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }

    /// Create a machine using the authenticated Porsche session.
    pub fn machine_create(
        &mut self,
        name: &str,
        cpu: u32,
        memory: u64,
        disk: u64,
        request_id: &str,
    ) -> Result<(), SessionError> {
        if name.is_empty()
            || name.len() > 128
            || name
                .bytes()
                .any(|b| b.is_ascii_control() || b.is_ascii_whitespace())
            || !(1..=256).contains(&cpu)
            || !(128..=4_194_304).contains(&memory)
            || !(1..=16_777_216).contains(&disk)
            || !valid_request_id(request_id)
        {
            return Err(SessionError::InvalidInput);
        }
        // SAFETY: every pointer/length pair borrows a live Rust slice for this
        // synchronous call, and the C ABI copies its inputs without retaining them.
        let status = unsafe {
            mila_ffi::session::mila_session_machine_create(
                self.handle()?,
                name.as_bytes().as_ptr(),
                name.len(),
                cpu,
                memory,
                disk,
                request_id.as_bytes().as_ptr(),
                request_id.len(),
            )
        };
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }

    /// Resize a machine using the authenticated Porsche session.
    pub fn machine_resize(
        &mut self,
        machine_id: &str,
        cpu: u32,
        memory: u64,
        disk: u64,
        request_id: &str,
    ) -> Result<(), SessionError> {
        validate_session_identifier(machine_id)?;
        if !(1..=256).contains(&cpu)
            || !(128..=4_194_304).contains(&memory)
            || !(1..=16_777_216).contains(&disk)
            || !valid_request_id(request_id)
        {
            return Err(SessionError::InvalidInput);
        }
        // SAFETY: every pointer/length pair borrows a live Rust slice for this
        // synchronous call, and the C ABI copies its inputs without retaining them.
        let status = unsafe {
            mila_ffi::session::mila_session_machine_resize(
                self.handle()?,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                cpu,
                memory,
                disk,
                request_id.as_bytes().as_ptr(),
                request_id.len(),
            )
        };
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }

    /// Execute an authenticated sharing add/remove mutation with typed role and
    /// request-id validation before crossing the native boundary.
    pub fn share_mutation(
        &mut self,
        machine_id: &str,
        email: &str,
        role: Option<&str>,
        add: bool,
        request_id: &str,
    ) -> Result<(), SessionError> {
        validate_session_identifier(machine_id)?;
        if email.is_empty()
            || email.len() > 320
            || email
                .bytes()
                .any(|byte| byte.is_ascii_control() || byte.is_ascii_whitespace())
            || (add && !matches!(role, Some("viewer" | "operator" | "manager")))
            || (!add && role.is_some())
            || request_id.len() != 40
            || !request_id.starts_with("porsche-")
            || !request_id.as_bytes()[8..].iter().all(u8::is_ascii_hexdigit)
        {
            return Err(SessionError::InvalidInput);
        }
        let handle = self.handle()?;
        let role_bytes = role.map(str::as_bytes).unwrap_or_default();
        // SAFETY: every pointer/length pair borrows a live Rust slice for this
        // synchronous call, and the C ABI copies its inputs without retaining them.
        let status = unsafe {
            mila_ffi::session::mila_session_share_mutation(
                handle,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                email.as_bytes().as_ptr(),
                email.len(),
                role_bytes.as_ptr(),
                role_bytes.len(),
                u8::from(add),
                request_id.as_bytes().as_ptr(),
                request_id.len(),
            )
        };
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }

    /// Read or mutate a thread through the authenticated, closed command set.
    /// Response bytes remain bounded inside the Rust session boundary.
    pub fn thread_action(
        &mut self,
        thread: Option<&str>,
        command: &str,
        secondary: Option<&str>,
        input: Option<&str>,
        request_id: Option<&str>,
    ) -> Result<Vec<u8>, SessionError> {
        const ALLOWED_THREAD_COMMANDS: &[&str] = &[
            "thread ls",
            "thread show",
            "thread turns",
            "thread prompt",
            "thread answer",
            "thread plan approve",
            "thread plan revise",
        ];
        if !ALLOWED_THREAD_COMMANDS.contains(&command) {
            return Err(SessionError::InvalidInput);
        }
        for value in [thread, secondary].into_iter().flatten() {
            validate_session_identifier(value)?;
        }
        if let Some(input) = input {
            if input.len() > 64 * 1024 || input.bytes().any(|byte| byte == 0) {
                return Err(SessionError::InvalidInput);
            }
        }
        Self::validate_thread_plan_input(command, input)?;
        if matches!(
            command,
            "thread prompt" | "thread answer" | "thread plan approve" | "thread plan revise"
        ) && thread.is_none()
        {
            return Err(SessionError::InvalidInput);
        }
        if matches!(command, "thread answer") && secondary.is_none() {
            return Err(SessionError::InvalidInput);
        }
        if let Some(request_id) = request_id {
            if request_id.len() != 40
                || !request_id.starts_with("porsche-")
                || !request_id.as_bytes()[8..].iter().all(u8::is_ascii_hexdigit)
            {
                return Err(SessionError::InvalidInput);
            }
        }
        if matches!(
            command,
            "thread prompt" | "thread answer" | "thread plan approve" | "thread plan revise"
        ) && request_id.is_none()
        {
            return Err(SessionError::InvalidInput);
        }
        let handle = self.handle()?;
        let empty = std::ptr::null();
        let (thread_ptr, thread_len) =
            thread.map_or((empty, 0), |value| (value.as_bytes().as_ptr(), value.len()));
        let (secondary_ptr, secondary_len) =
            secondary.map_or((empty, 0), |value| (value.as_bytes().as_ptr(), value.len()));
        let (input_ptr, input_len) =
            input.map_or((empty, 0), |value| (value.as_bytes().as_ptr(), value.len()));
        let (request_ptr, request_len) =
            request_id.map_or((empty, 0), |value| (value.as_bytes().as_ptr(), value.len()));
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_thread_action(
                handle,
                thread_ptr,
                thread_len,
                command.as_bytes().as_ptr(),
                command.len(),
                secondary_ptr,
                secondary_len,
                input_ptr,
                input_len,
                request_ptr,
                request_len,
                out,
                capacity,
                written,
            )
        })
    }

    /// Enforce the closed input contract for plan approval commands before FFI.
    pub(super) fn validate_thread_plan_input(
        command: &str,
        input: Option<&str>,
    ) -> Result<(), SessionError> {
        match command {
            "thread plan approve" if input.is_some() => Err(SessionError::InvalidInput),
            "thread plan revise" if input.is_none_or(str::is_empty) => {
                Err(SessionError::InvalidInput)
            }
            _ => Ok(()),
        }
    }

    /// Read one machine (`show MACHINE --json`) as bounded JSON.
    pub fn machine_show(&mut self, machine_id: &str) -> Result<Vec<u8>, SessionError> {
        self.machine_read(machine_id, mila_ffi::session::mila_session_machine_show)
    }

    /// Read a machine's owner and grants (`share show MACHINE --json`).
    pub fn share_show(&mut self, machine_id: &str) -> Result<Vec<u8>, SessionError> {
        self.machine_read(machine_id, mila_ffi::session::mila_session_share_show)
    }

    fn machine_read(
        &mut self,
        machine_id: &str,
        read: unsafe extern "C" fn(
            u64,
            *const u8,
            usize,
            *mut u8,
            usize,
            *mut usize,
        ) -> mila_ffi::session::SessionStatus,
    ) -> Result<Vec<u8>, SessionError> {
        validate_session_identifier(machine_id)?;
        let handle = self.handle()?;
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        copy_output(|out, capacity, written| unsafe {
            read(
                handle,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                out,
                capacity,
                written,
            )
        })
    }

    /// Read one mutation receipt by its request id (`request show`).
    pub fn request_show(&mut self, request_id: &str) -> Result<Vec<u8>, SessionError> {
        if !valid_request_id(request_id) {
            return Err(SessionError::InvalidInput);
        }
        let handle = self.handle()?;
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_request_show(
                handle,
                request_id.as_bytes().as_ptr(),
                request_id.len(),
                out,
                capacity,
                written,
            )
        })
    }

    /// Read a machine-bound web endpoint through the authenticated session.
    /// The response remains bounded and owned by the Rust adapter.
    pub fn web_show(&mut self, machine_id: &str) -> Result<Vec<u8>, SessionError> {
        validate_session_identifier(machine_id)?;
        let handle = self.handle()?;
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_web_show(
                handle,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                out,
                capacity,
                written,
            )
        })
    }

    /// Change a machine web endpoint using its optimistic policy revision.
    pub fn web_set(
        &mut self,
        machine_id: &str,
        port: u16,
        public: bool,
        revision: u64,
        request_id: &str,
    ) -> Result<(), SessionError> {
        validate_session_identifier(machine_id)?;
        if port == 0
            || revision == 0
            || request_id.len() != 40
            || !request_id.starts_with("porsche-")
            || !request_id.as_bytes()[8..].iter().all(u8::is_ascii_hexdigit)
        {
            return Err(SessionError::InvalidInput);
        }
        let handle = self.handle()?;
        // SAFETY: every pointer/length pair borrows a live Rust slice for this
        // synchronous call, and the C ABI copies its inputs without retaining them.
        let status = unsafe {
            mila_ffi::session::mila_session_web_set(
                handle,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                port,
                u8::from(public),
                revision,
                request_id.as_bytes().as_ptr(),
                request_id.len(),
            )
        };
        if status == mila_ffi::session::SessionStatus::Ok {
            Ok(())
        } else {
            Err(status.into())
        }
    }

    /// Read authenticated push notification devices. Provider registration is
    /// intentionally host-owned; this method covers list and preference CRUD.
    pub fn device_list(&mut self) -> Result<Vec<u8>, SessionError> {
        let handle = self.handle()?;
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_device_ls(handle, out, capacity, written)
        })
    }

    pub fn device_remove(&mut self, device_id: &str) -> Result<(), SessionError> {
        validate_session_identifier(device_id)?;
        let handle = self.handle()?;
        // SAFETY: every pointer/length pair borrows a live Rust slice for this
        // synchronous call, and the C ABI copies its inputs without retaining them.
        let status = unsafe {
            mila_ffi::session::mila_session_device_rm(
                handle,
                device_id.as_bytes().as_ptr(),
                device_id.len(),
            )
        };
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }

    pub fn device_preference(
        &mut self,
        device_id: &str,
        enabled: bool,
    ) -> Result<(), SessionError> {
        validate_session_identifier(device_id)?;
        let handle = self.handle()?;
        // SAFETY: every pointer/length pair borrows a live Rust slice for this
        // synchronous call, and the C ABI copies its inputs without retaining them.
        let status = unsafe {
            mila_ffi::session::mila_session_device_prefs(
                handle,
                device_id.as_bytes().as_ptr(),
                device_id.len(),
                u8::from(enabled),
            )
        };
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }
}
