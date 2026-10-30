//! Windows worker identity and recovery policy. This grants no image capability.

use crate::{Binding, Boot, Descriptor, Preface, Refusal, validate};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fmt::Write as _;
use std::sync::atomic::{AtomicUsize, Ordering};

pub const CUSTODIAN_ACCOUNT_LIMIT: usize = 64;

/// A bounded account registry retains ownership independent of individual streams.
/// Entries are never evicted implicitly, including empty or quarantined slots.
#[derive(Debug)]
pub struct CustodianAccounts<T> {
    entries: std::sync::Mutex<std::collections::BTreeMap<u32, std::sync::Arc<std::sync::Mutex<T>>>>,
}

impl<T> Default for CustodianAccounts<T> {
    fn default() -> Self {
        Self {
            entries: std::sync::Mutex::new(std::collections::BTreeMap::new()),
        }
    }
}

impl<T> CustodianAccounts<T> {
    /// @cc [owner:ghuntley,label:security;capacity] windows-custodian-capacity-ownership
    /// Admission MUST charge one of at most 64 stable account slots before
    /// launching. Concurrent admissions for one UID MUST share the same lock
    /// and retained state. Full or poisoned registries MUST refuse; dropping a
    /// connection reference MUST NOT evict or release its worker's ownership.
    #[expect(
        rustdoc::broken_intra_doc_links,
        reason = "the @cc contract tag is bracketed metadata, not an intra-doc link"
    )]
    pub fn slot(
        &self,
        uid: u32,
        initial: impl FnOnce() -> T,
    ) -> Result<std::sync::Arc<std::sync::Mutex<T>>, Refusal> {
        let mut entries = self.entries.lock().map_err(|_| Refusal::Custody)?;
        if !entries.contains_key(&uid) && entries.len() >= CUSTODIAN_ACCOUNT_LIMIT {
            return Err(Refusal::Capacity);
        }
        Ok(entries
            .entry(uid)
            .or_insert_with(|| std::sync::Arc::new(std::sync::Mutex::new(initial())))
            .clone())
    }
}

pub const PIPE_LIMIT: usize = 128;

/// Broker-wide custody budget shared by live pipes and cancelled operations.
#[derive(Debug)]
pub struct PipeSlots {
    used: AtomicUsize,
}

impl Default for PipeSlots {
    fn default() -> Self {
        Self::new()
    }
}

impl PipeSlots {
    pub const fn new() -> Self {
        Self {
            used: AtomicUsize::new(0),
        }
    }

    /// @cc [owner:ghuntley,label:security;capacity] windows-editor-pipe-slots
    /// Live pipes and undrained cancelled operations MUST share at most 128
    /// reservations. A reservation MUST remain owned until its operation's
    /// buffer, completion storage and handles may safely be released. Exhaustion
    /// MUST refuse new pipes without evicting an outstanding operation.
    #[expect(
        rustdoc::broken_intra_doc_links,
        reason = "the @cc contract tag is bracketed metadata, not an intra-doc link"
    )]
    pub fn reserve(&self) -> Option<PipeSlot<'_>> {
        let mut used = self.used.load(Ordering::Acquire);
        loop {
            if used >= PIPE_LIMIT {
                return None;
            }
            match self.used.compare_exchange_weak(
                used,
                used + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => return Some(PipeSlot { slots: self }),
                Err(current) => used = current,
            }
        }
    }
}

/// Moving a reservation transfers its capacity; only releasing it returns a slot.
#[derive(Debug)]
pub struct PipeSlot<'a> {
    slots: &'a PipeSlots,
}

impl Drop for PipeSlot<'_> {
    fn drop(&mut self) {
        self.slots.used.fetch_sub(1, Ordering::AcqRel);
    }
}

/// Complete S-1-5-21 account SID syntax; native SAM lookup establishes locality.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct AccountSid(Vec<u8>);

impl AccountSid {
    /// @cc [owner:ghuntley,label:security] windows-editor-local-account-sid
    /// Account custody MUST use a complete S-1-5-21 SID with an ordinary
    /// account RID. SYSTEM, built-in groups and partial SIDs MUST NOT become
    /// editor account identities. Only native SAM lookup establishes locality.
    #[expect(
        rustdoc::broken_intra_doc_links,
        reason = "the @cc contract tag is bracketed metadata, not an intra-doc link"
    )]
    pub fn parse(bytes: &[u8]) -> Result<Self, Refusal> {
        if bytes.len() != 28
            || bytes[..8] != [1, 5, 0, 0, 0, 0, 0, 5]
            || u32::from_le_bytes(bytes[8..12].try_into().map_err(|_| Refusal::Account)?) != 21
            || u32::from_le_bytes(bytes[24..28].try_into().map_err(|_| Refusal::Account)?) < 1000
        {
            return Err(Refusal::Account);
        }
        Ok(Self(bytes.to_vec()))
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

/// Exact account, physical execution, package and browser-origin launch identity.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct WorkerIdentity {
    uid: u32,
    username: String,
    guest_account_id: String,
    placement_id: String,
    execution_epoch: u64,
    sid: AccountSid,
    descriptor: Descriptor,
    origin: String,
    webview_template: String,
}

impl WorkerIdentity {
    /// @cc [owner:ghuntley,label:security] windows-editor-identity-closed-admission
    /// A Windows worker identity MUST pass the existing exact boot/package/
    /// origin admission and use the canonical `u<uid>` roster name. A caller
    /// hint or a valid SID alone MUST NOT create a worker identity.
    #[expect(
        rustdoc::broken_intra_doc_links,
        reason = "the @cc contract tag is bracketed metadata, not an intra-doc link"
    )]
    pub fn admitted(
        preface: &Preface,
        boot: &Boot,
        descriptor: &Descriptor,
        sid: AccountSid,
    ) -> Result<Self, Refusal> {
        validate(preface, boot, descriptor)?;
        let Binding {
            uid,
            username,
            guest_account_id,
            placement_id,
            execution_epoch,
            editor_origin,
            ..
        } = &preface.binding;
        if username != &format!("u{uid}") {
            return Err(Refusal::Account);
        }
        Ok(Self {
            uid: *uid,
            username: username.clone(),
            guest_account_id: guest_account_id.clone(),
            placement_id: placement_id.clone(),
            execution_epoch: *execution_epoch,
            sid,
            descriptor: descriptor.clone(),
            origin: editor_origin.clone(),
            webview_template: crate::webview_template(&preface.binding)?,
        })
    }

    pub fn username(&self) -> &str {
        &self.username
    }
    pub fn uid(&self) -> u32 {
        self.uid
    }
    pub fn guest_account_id(&self) -> &str {
        &self.guest_account_id
    }
    pub fn placement_id(&self) -> &str {
        &self.placement_id
    }
    pub fn execution_epoch(&self) -> u64 {
        self.execution_epoch
    }
    pub fn sid(&self) -> &AccountSid {
        &self.sid
    }
    pub fn origin(&self) -> &str {
        &self.origin
    }
    pub fn descriptor(&self) -> &Descriptor {
        &self.descriptor
    }
    pub fn webview_template(&self) -> &str {
        &self.webview_template
    }

    /// @cc [owner:ghuntley,label:security;recovery] windows-editor-stable-receipt
    /// A receipt in the current physical-boot namespace MAY survive session
    /// and generation rotation only when its validated stable worker identity
    /// equals the current account, SID, placement/epoch, package and origins.
    /// This comparison MUST NOT authorize receipts from another boot namespace.
    #[expect(
        rustdoc::broken_intra_doc_links,
        reason = "the @cc contract tag is bracketed metadata, not an intra-doc link"
    )]
    pub fn matches_retained_binding(
        &self,
        binding: &Binding,
        boot: &Boot,
        descriptor: &Descriptor,
    ) -> bool {
        Self::admitted(
            &Preface {
                version: 1,
                binding: binding.clone(),
            },
            boot,
            descriptor,
            self.sid.clone(),
        )
        .is_ok_and(|retained| retained == *self)
    }

    pub fn key(&self) -> String {
        // Struct fields have a fixed serialization order and no unchecked values.
        let mut hash = Sha256::new();
        hash.update(b"overalls-windows-editor-worker-v1\0");
        #[expect(
            clippy::expect_used,
            reason = "derived Serialize of string and integer fields into a Vec cannot fail"
        )]
        let serialized = serde_json::to_vec(self).expect("closed identity serialization");
        hash.update(serialized);
        hash.finalize()
            .iter()
            .fold(String::with_capacity(64), |mut out, byte| {
                let _ = write!(out, "{byte:02x}");
                out
            })
    }

    /// Kernel names include the owning custodian generation, so a job or pipe
    /// of one custodian lifetime can never be confused with its successor's.
    pub fn pipe_name(&self, generation: CustodianGeneration) -> String {
        format!(
            r"\\.\pipe\overalls-editor-{}-g{}-{}",
            self.uid,
            generation.get(),
            self.key()
        )
    }

    pub fn job_name(&self, generation: CustodianGeneration) -> String {
        format!(
            r"Global\overalls-editor-{}-g{}-{}",
            self.uid,
            generation.get(),
            self.key()
        )
    }
}

/// One custodian process lifetime inside a physical-boot receipt namespace.
/// Zero never names a lifetime; successors strictly increase and never wrap.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "u64", into = "u64")]
pub struct CustodianGeneration(u64);

impl CustodianGeneration {
    pub fn new(value: u64) -> Result<Self, Refusal> {
        (value != 0).then_some(Self(value)).ok_or(Refusal::Custody)
    }

    pub fn get(self) -> u64 {
        self.0
    }

    /// @cc [owner:ghuntley,label:security;recovery] windows-custodian-generation-successor
    /// A starting custodian MUST take a generation strictly greater than every
    /// generation previously recorded in its boot namespace. Absence starts at
    /// one; overflow MUST refuse rather than wrap or reuse an earlier lifetime.
    #[expect(
        rustdoc::broken_intra_doc_links,
        reason = "the @cc contract tag is bracketed metadata, not an intra-doc link"
    )]
    pub fn successor(previous: Option<Self>) -> Result<Self, Refusal> {
        match previous {
            None => Ok(Self(1)),
            Some(previous) => previous.0.checked_add(1).map(Self).ok_or(Refusal::Custody),
        }
    }
}

impl TryFrom<u64> for CustodianGeneration {
    type Error = &'static str;
    fn try_from(value: u64) -> Result<Self, Self::Error> {
        Self::new(value).map_err(|_| "custodian generation must be nonzero")
    }
}

impl From<CustodianGeneration> for u64 {
    fn from(value: CustodianGeneration) -> Self {
        value.0
    }
}

/// The LSA logon-session LUID of one worker's S4U token. Every process created
/// from that token inherits it, and it is unique within one physical boot.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "u64", into = "u64")]
pub struct LogonSession(u64);

impl LogonSession {
    pub fn new(value: u64) -> Result<Self, Refusal> {
        (value != 0).then_some(Self(value)).ok_or(Refusal::Custody)
    }

    /// Combine a Win32 LUID without sign extension of its high part.
    pub fn from_luid(low: u32, high: i32) -> Result<Self, Refusal> {
        Self::new((u64::from(high.cast_unsigned()) << 32) | u64::from(low))
    }
}

impl TryFrom<u64> for LogonSession {
    type Error = &'static str;
    fn try_from(value: u64) -> Result<Self, Self::Error> {
        Self::new(value).map_err(|_| "logon session must be nonzero")
    }
}

impl From<LogonSession> for u64 {
    fn from(value: LogonSession) -> Self {
        value.0
    }
}

/// Exact account and logon session of a live process's primary token.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TokenOwner {
    pub sid: AccountSid,
    pub logon: LogonSession,
}

/// What a SYSTEM observer could establish about one process-list entry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TokenObservation {
    /// The token user is a complete ordinary local account SID.
    Account(TokenOwner),
    /// The token user is a valid non-account principal such as SYSTEM.
    NonAccount,
    /// The token could not be opened or read.
    Unreadable,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProcessObservation {
    /// The process exited between enumeration and observation.
    Exited,
    /// An unopenable entry whose creator is the kernel (Idle/System parent).
    /// User-mode tokens cannot create processes with those parents.
    KernelCreated,
    /// An unopenable or untimed entry with a user-mode creator.
    Unobservable,
    Opened {
        process: ProcessIdentity,
        token: TokenObservation,
    },
}

/// Exact recorded custody of a worker launched by an earlier custodian
/// generation in the current boot namespace.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PriorWorker {
    pub generation: CustodianGeneration,
    pub sid: AccountSid,
    pub logon: LogonSession,
    pub root: ProcessIdentity,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProcessClass {
    Unrelated,
    Straggler(ProcessIdentity),
    Ambiguous,
}

/// @cc [owner:ghuntley,label:security;recovery] windows-custodian-straggler-classification
/// Only a live process created no earlier than the recorded prior root whose
/// primary token has the exact recorded account SID and logon session MAY be a
/// straggler. Earlier processes, other accounts, other sessions of the same
/// account and kernel-created entries are unrelated and MUST NOT be touched.
/// A possibly-descendant process whose token or creation is unobservable MUST
/// be ambiguous, never unrelated.
#[expect(
    rustdoc::broken_intra_doc_links,
    reason = "the @cc contract tag is bracketed metadata, not an intra-doc link"
)]
pub fn classify_process(prior: &PriorWorker, observation: &ProcessObservation) -> ProcessClass {
    match observation {
        ProcessObservation::Exited | ProcessObservation::KernelCreated => ProcessClass::Unrelated,
        ProcessObservation::Unobservable => ProcessClass::Ambiguous,
        ProcessObservation::Opened { process, token } => {
            // A descendant cannot predate the suspended root it descends from.
            if process.created < prior.root.created {
                return ProcessClass::Unrelated;
            }
            match token {
                TokenObservation::Account(owner)
                    if owner.sid == prior.sid && owner.logon == prior.logon =>
                {
                    ProcessClass::Straggler(*process)
                }
                TokenObservation::Account(_) | TokenObservation::NonAccount => {
                    ProcessClass::Unrelated
                }
                TokenObservation::Unreadable => ProcessClass::Ambiguous,
            }
        }
    }
}

/// @cc [owner:ghuntley,label:security;recovery] windows-custodian-prior-receipt-admission
/// A cold same-boot receipt MAY enter recovery only when it was written by a
/// strictly earlier custodian generation, its stable identity exactly matches
/// the current admitted worker, and its generation-scoped named job no longer
/// exists. Current/future generations, identity drift, a surviving job and
/// observation errors MUST refuse without adoption, termination or deletion.
#[expect(
    rustdoc::broken_intra_doc_links,
    reason = "the @cc contract tag is bracketed metadata, not an intra-doc link"
)]
pub fn prior_receipt_admission(
    current: CustodianGeneration,
    recorded: CustodianGeneration,
    exact_identity: bool,
    prior_job_present: impl FnOnce() -> Result<bool, Refusal>,
) -> Result<(), Refusal> {
    if recorded >= current || !exact_identity {
        return Err(Refusal::Custody);
    }
    if prior_job_present()? {
        return Err(Refusal::Custody);
    }
    Ok(())
}

/// Plan one bounded pass. Any ambiguous entry refuses the whole pass.
pub fn straggler_plan(
    prior: &PriorWorker,
    observations: &[ProcessObservation],
) -> Result<Vec<ProcessIdentity>, Refusal> {
    let mut stragglers = Vec::new();
    for observation in observations {
        match classify_process(prior, observation) {
            ProcessClass::Unrelated => {}
            ProcessClass::Straggler(process) => stragglers.push(process),
            ProcessClass::Ambiguous => return Err(Refusal::Custody),
        }
    }
    Ok(stragglers)
}

pub const PRIOR_SESSION_ROUNDS: usize = 8;

/// @cc [owner:ghuntley,label:security;recovery] windows-custodian-prior-session-quiescence
/// Same-boot replacement after custodian loss MUST observe a complete process
/// list containing zero processes of the prior worker's exact account logon
/// session. Each pass MAY terminate only planned stragglers; any ambiguous
/// observation, scan error or termination error MUST refuse. Exhausting the
/// bounded passes without an empty observation MUST refuse replacement.
#[expect(
    rustdoc::broken_intra_doc_links,
    reason = "the @cc contract tag is bracketed metadata, not an intra-doc link"
)]
pub fn drain_prior_session(
    prior: &PriorWorker,
    rounds: usize,
    mut scan: impl FnMut() -> Result<Vec<ProcessObservation>, Refusal>,
    mut terminate: impl FnMut(&PriorWorker, ProcessIdentity) -> Result<(), Refusal>,
) -> Result<(), Refusal> {
    for _ in 0..rounds {
        let stragglers = straggler_plan(prior, &scan()?)?;
        if stragglers.is_empty() {
            return Ok(());
        }
        for process in stragglers {
            terminate(prior, process)?;
        }
    }
    Err(Refusal::Custody)
}

/// Process creation time disambiguates a retained kernel process from PID reuse.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ProcessIdentity {
    pub pid: u32,
    pub created: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PipePeer {
    pub process: ProcessIdentity,
    pub sid: AccountSid,
    pub in_expected_job: bool,
    pub exact_executable: bool,
}

/// @cc [owner:ghuntley,label:security] windows-editor-pipe-kernel-custody
/// A pipe MUST be reusable only when its server has the exact retained PID and
/// creation time, account SID, named-job membership and configured executable.
/// Matching a name, PID alone or same-account SID alone MUST NOT authorize it.
#[expect(
    rustdoc::broken_intra_doc_links,
    reason = "the @cc contract tag is bracketed metadata, not an intra-doc link"
)]
pub fn verify_peer(
    identity: &WorkerIdentity,
    expected: ProcessIdentity,
    peer: &PipePeer,
) -> Result<(), Refusal> {
    if expected.pid == 0
        || expected.created == 0
        || peer.process != expected
        || peer.sid != identity.sid
        || !peer.in_expected_job
        || !peer.exact_executable
    {
        Err(Refusal::Custody)
    } else {
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HeldWorkerDecision {
    Reuse,
    DrainDeadJob,
}

/// @cc [owner:ghuntley,label:security;recovery] windows-custodian-live-probe-refusal
/// A retained live root's failed readiness or pipe-custody probe MUST refuse
/// without authorizing termination. Only a conclusively dead root whose exact
/// job handle is still held MAY authorize whole-job drainage before replacement.
/// Process-observation errors MUST propagate without probing or cleanup.
#[expect(
    rustdoc::broken_intra_doc_links,
    reason = "the @cc contract tag is bracketed metadata, not an intra-doc link"
)]
pub fn held_worker_decision(
    root_running: Result<bool, Refusal>,
    probe: impl FnOnce() -> Result<(), Refusal>,
) -> Result<HeldWorkerDecision, Refusal> {
    if root_running? {
        probe()?;
        Ok(HeldWorkerDecision::Reuse)
    } else {
        Ok(HeldWorkerDecision::DrainDeadJob)
    }
}

/// Missing metadata never authorizes destructive cleanup of a possible worker.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecoveryDecision {
    Start,
    Reuse,
    StopOwnedThenStart,
    Refuse,
}

/// @cc [owner:ghuntley,label:recovery] windows-editor-recovery-no-foreign-cleanup
/// Recovery MUST reuse only exact identities with proven pipe custody. A
/// mismatched owned worker may be stopped only after root-owned job/process
/// custody is established. Incomplete or foreign metadata MUST refuse without
/// terminating a process, removing a pipe or deleting personal data.
#[expect(
    rustdoc::broken_intra_doc_links,
    reason = "the @cc contract tag is bracketed metadata, not an intra-doc link"
)]
#[expect(
    clippy::fn_params_excessive_bools,
    reason = "four independent custody observations form the decision truth table"
)]
pub fn recovery_decision(
    exists: bool,
    system_owned_job: bool,
    exact_identity: bool,
    proven_peer: bool,
) -> RecoveryDecision {
    match (exists, system_owned_job, exact_identity, proven_peer) {
        (false, _, _, _) => RecoveryDecision::Start,
        (true, true, true, true) => RecoveryDecision::Reuse,
        (true, true, false, true) => RecoveryDecision::StopOwnedThenStart,
        _ => RecoveryDecision::Refuse,
    }
}

/// A configured local drive path; UNC, device and alternate-stream paths refuse.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LocalPath(String);

impl LocalPath {
    pub fn parse(value: &str) -> Result<Self, Refusal> {
        let bytes = value.as_bytes();
        if bytes.len() == 3 && bytes[0].is_ascii_alphabetic() && &bytes[1..] == b":\\" {
            return Ok(Self(value.to_owned()));
        }
        if bytes.len() < 4
            || bytes.len() > 4096
            || !bytes[0].is_ascii_alphabetic()
            || &bytes[1..3] != b":\\"
            || value
                .get(3..)
                .is_none_or(|tail| tail.contains([':', '/', '"', '\0', '\r', '\n']))
            || value.get(3..).is_none_or(|tail| {
                tail.split('\\').any(|part| {
                    part.is_empty()
                        || part == "."
                        || part == ".."
                        || part.ends_with(['.', ' '])
                        || dos_device(part)
                })
            })
        {
            return Err(Refusal::Package);
        }
        Ok(Self(value.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

fn dos_device(component: &str) -> bool {
    let base = component
        .split('.')
        .next()
        .unwrap_or_default()
        .to_ascii_uppercase();
    matches!(
        base.as_str(),
        "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
    ) || base
        .strip_prefix("COM")
        .or_else(|| base.strip_prefix("LPT"))
        .is_some_and(|suffix| {
            matches!(
                suffix,
                "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"
            )
        })
}

/// A closed deployment PATH; every entry still requires native directory custody.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkerPath {
    value: String,
    directories: Vec<LocalPath>,
}

impl WorkerPath {
    /// @cc [owner:ghuntley,label:security] windows-editor-worker-path-closed-list
    /// Worker PATH MUST contain at most 32 explicit ASCII absolute local
    /// directories within 4096 bytes. Empty, relative, case-insensitive duplicate,
    /// environment-expanded, device and ambiguous entries MUST refuse;
    /// configuration authority alone MUST NOT bypass the native directory
    /// ownership and write-ACL checks.
    #[expect(
        rustdoc::broken_intra_doc_links,
        reason = "the @cc contract tag is bracketed metadata, not an intra-doc link"
    )]
    pub fn parse(value: &str) -> Result<Self, Refusal> {
        if value.is_empty() || value.len() > 4096 || !value.is_ascii() {
            return Err(Refusal::Package);
        }
        let mut directories: Vec<LocalPath> = Vec::new();
        for entry in value.split(';') {
            if directories.len() >= 32
                || entry
                    .chars()
                    .any(|character| character.is_control() || "<>|?*%".contains(character))
            {
                return Err(Refusal::Package);
            }
            let path = LocalPath::parse(entry)?;
            if directories
                .iter()
                .any(|previous| previous.as_str().eq_ignore_ascii_case(path.as_str()))
            {
                return Err(Refusal::Package);
            }
            directories.push(path);
        }
        Ok(Self {
            value: value.to_owned(),
            directories,
        })
    }

    pub fn as_str(&self) -> &str {
        &self.value
    }

    pub fn directories(&self) -> &[LocalPath] {
        &self.directories
    }
}

/// Windows C-runtime quoting; the process is created directly, without a shell.
pub fn command_line(arguments: &[String]) -> Result<Vec<u16>, Refusal> {
    let mut command = String::new();
    for argument in arguments {
        if argument.contains('\0') {
            return Err(Refusal::Package);
        }
        if !command.is_empty() {
            command.push(' ');
        }
        command.push('"');
        let mut slashes = 0;
        for character in argument.chars() {
            if character == '\\' {
                slashes += 1;
                continue;
            }
            if character == '"' {
                command.extend(std::iter::repeat_n('\\', slashes * 2 + 1));
            } else {
                command.extend(std::iter::repeat_n('\\', slashes));
            }
            slashes = 0;
            command.push(character);
        }
        command.extend(std::iter::repeat_n('\\', slashes * 2));
        command.push('"');
    }
    let mut wide: Vec<u16> = command.encode_utf16().collect();
    if wide.is_empty() || wide.len() >= 32767 {
        return Err(Refusal::Package);
    }
    wide.push(0);
    Ok(wide)
}

#[cfg(test)]
mod tests {
    use super::*;
    use hegel::{TestCase, generators as gs};

    #[test]
    fn custody_map_retains_owner_after_stream_references_drop() {
        struct Owner(std::sync::Arc<AtomicUsize>);
        impl Drop for Owner {
            fn drop(&mut self) {
                self.0.fetch_add(1, Ordering::SeqCst);
            }
        }
        let dropped = std::sync::Arc::new(AtomicUsize::new(0));
        let registry = CustodianAccounts::default();
        let stream = registry.slot(200_000, || Owner(dropped.clone())).unwrap();
        drop(stream);
        assert_eq!(dropped.load(Ordering::SeqCst), 0);
        let retained = registry
            .slot(200_000, || panic!("must reuse retained owner"))
            .unwrap();
        drop(retained);
        assert_eq!(dropped.load(Ordering::SeqCst), 0);
        drop(registry);
        assert_eq!(dropped.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn concurrent_account_admission_shares_one_serialized_owner() {
        let registry = CustodianAccounts::default();
        let initialized = AtomicUsize::new(0);
        std::thread::scope(|scope| {
            for _ in 0..32 {
                scope.spawn(|| {
                    let slot = registry
                        .slot(200_000, || {
                            initialized.fetch_add(1, Ordering::SeqCst);
                            0_u32
                        })
                        .unwrap();
                    *slot.lock().unwrap() += 1;
                });
            }
        });
        assert_eq!(initialized.load(Ordering::SeqCst), 1);
        assert_eq!(*registry.slot(200_000, || 0).unwrap().lock().unwrap(), 32);
    }

    /// @cc [owner:ghuntley,label:verification;capacity] broker-custodian-registry-retention
    /// Every admission sequence MUST retain each accepted account's original
    /// state and refuse new accounts with Capacity once 64 are retained.
    #[hegel::test(test_cases = 64)]
    fn full_custodian_registry_never_evicts_retained_accounts(tc: TestCase) {
        let uids = tc.draw(
            gs::vecs(gs::integers::<u32>().max_value(127))
                .min_size(1)
                .max_size(255),
        );
        let registry = CustodianAccounts::default();
        let mut accepted = std::collections::BTreeSet::new();
        for uid in uids {
            let result = registry.slot(uid, || uid);
            if accepted.contains(&uid) || accepted.len() < CUSTODIAN_ACCOUNT_LIMIT {
                let slot = result.unwrap();
                assert_eq!(*slot.lock().unwrap(), uid);
                accepted.insert(uid);
            } else {
                assert!(matches!(result, Err(Refusal::Capacity)));
            }
        }
        for uid in accepted {
            assert_eq!(
                *registry.slot(uid, || u32::MAX).unwrap().lock().unwrap(),
                uid
            );
        }
    }

    /// @cc [owner:ghuntley,label:verification;capacity] broker-custodian-slot-limit
    /// `CustodianAccounts::slot` MUST never hold more than 64 accounts, MUST
    /// hold exactly the first 64 distinct admitted UIDs, and MUST accept a
    /// request exactly when its UID is retained or capacity remains.
    #[hegel::test(test_cases = 64)]
    fn custodian_slots_stay_within_limit(tc: TestCase) {
        let uids = tc.draw(gs::vecs(gs::integers::<u32>().max_value(199)).max_size(300));
        let registry = CustodianAccounts::default();
        let mut model = std::collections::BTreeSet::new();
        for uid in uids {
            let admit = model.contains(&uid) || model.len() < CUSTODIAN_ACCOUNT_LIMIT;
            assert_eq!(registry.slot(uid, || ()).is_ok(), admit);
            if admit {
                model.insert(uid);
            }
            let held = registry.entries.lock().unwrap().len();
            assert!(held <= CUSTODIAN_ACCOUNT_LIMIT);
            assert_eq!(held, model.len());
        }
    }

    /// @cc [owner:ghuntley,label:verification;capacity] broker-pipe-slot-limit
    /// `PipeSlots::reserve` MUST succeed exactly while fewer than 128
    /// reservations are held, and the shared count MUST equal the held
    /// reservations after every reserve and release.
    #[hegel::test(test_cases = 64)]
    fn pipe_slots_stay_within_limit(tc: TestCase) {
        let operations = tc.draw(gs::vecs(gs::integers::<u8>().max_value(9)).max_size(400));
        let slots = PipeSlots::new();
        let mut held = Vec::new();
        for operation in operations {
            if operation < 8 {
                let reservation = slots.reserve();
                assert_eq!(reservation.is_some(), held.len() < PIPE_LIMIT);
                held.extend(reservation);
            } else {
                held.pop();
            }
            let used = slots.used.load(Ordering::Acquire);
            assert!(used <= PIPE_LIMIT);
            assert_eq!(used, held.len());
        }
    }

    #[test]
    fn live_root_probe_errors_never_authorize_destructive_recovery() {
        for reason in [
            Refusal::Custody,
            Refusal::Account,
            Refusal::Package,
            Refusal::Readiness,
            Refusal::Capacity,
            Refusal::Transport,
        ] {
            assert_eq!(held_worker_decision(Ok(true), || Err(reason)), Err(reason));
            assert_eq!(
                held_worker_decision(Err(reason), || panic!("ambiguous root must not probe")),
                Err(reason)
            );
        }
        assert_eq!(
            held_worker_decision(Ok(false), || panic!("dead root has no pipe authority")),
            Ok(HeldWorkerDecision::DrainDeadJob)
        );
        assert_eq!(
            held_worker_decision(Ok(true), || Ok(())),
            Ok(HeldWorkerDecision::Reuse)
        );
    }

    fn sid(rid: u32) -> AccountSid {
        let mut bytes = vec![1, 5, 0, 0, 0, 0, 0, 5];
        for value in [21_u32, 1, 2, 3, rid] {
            bytes.extend(value.to_le_bytes());
        }
        AccountSid::parse(&bytes).unwrap()
    }

    fn admission_fixture() -> (Preface, Boot, Descriptor, AccountSid) {
        let id = "11111111-1111-4111-8111-111111111111".to_owned();
        let descriptor = Descriptor {
            protocol: 1,
            commit: "a".repeat(40),
            release: "b".repeat(64),
        };
        let boot = Boot {
            placement_id: "22222222-2222-4222-8222-222222222222".to_owned(),
            execution_epoch: 1,
            address: "10.10.0.2".parse().unwrap(),
            gateway: "10.10.0.1".parse().unwrap(),
        };
        let preface = Preface {
            version: 1,
            binding: Binding {
                vm_id: id.clone(),
                host_id: id.clone(),
                placement_id: boot.placement_id.clone(),
                session_id: id.clone(),
                execution_epoch: boot.execution_epoch,
                generation: 1,
                label: "e-ceirceircfardairceirceirce-ceirceircfardairceirceirce".to_owned(),
                service: "editor".to_owned(),
                port: crate::PORT,
                user_id: id.clone(),
                guest_account_id: id,
                uid: 200_001,
                username: "u200001".to_owned(),
                editor_protocol: descriptor.protocol,
                editor_commit: descriptor.commit.clone(),
                editor_release: descriptor.release.clone(),
                editor_origin:
                    "https://e-ceirceircfardairceirceirce-ceirceircfardairceirceirce.apps.test"
                        .to_owned(),
            },
        };
        (preface, boot, descriptor, sid(1001))
    }

    fn identity() -> WorkerIdentity {
        let (preface, boot, descriptor, sid) = admission_fixture();
        WorkerIdentity::admitted(&preface, &boot, &descriptor, sid).unwrap()
    }

    /// @cc [owner:ghuntley,label:verification;security] broker-pipe-peer-exact-process
    /// A pipe peer MUST verify only with the exact expected PID and creation
    /// time; any other PID or creation time MUST refuse with Custody.
    #[hegel::test(test_cases = 64)]
    fn any_foreign_pid_or_creation_time_refuses(tc: TestCase) {
        let pid = tc.draw(gs::integers::<u32>().min_value(1).max_value(u32::MAX - 1));
        let created = tc.draw(gs::integers::<u64>().min_value(1).max_value(u64::MAX - 1));
        let identity = identity();
        let expected = ProcessIdentity { pid, created };
        let mut peer = PipePeer {
            process: expected,
            sid: identity.sid.clone(),
            in_expected_job: true,
            exact_executable: true,
        };
        assert_eq!(verify_peer(&identity, expected, &peer), Ok(()));
        peer.process.pid = pid.wrapping_add(1);
        assert_eq!(
            verify_peer(&identity, expected, &peer),
            Err(Refusal::Custody)
        );
        peer.process = ProcessIdentity {
            pid,
            created: created.wrapping_add(1),
        };
        assert_eq!(
            verify_peer(&identity, expected, &peer),
            Err(Refusal::Custody)
        );
    }

    /// @cc [owner:ghuntley,label:verification;security] broker-identity-kernel-names
    /// A changed execution epoch MUST change pipe and job names, and a changed
    /// account SID MUST change the identity key.
    #[hegel::test(test_cases = 64)]
    fn identity_changes_never_reuse_old_pipe_or_job(tc: TestCase) {
        let epoch = tc.draw(gs::integers::<u64>().min_value(2).max_value(u64::MAX - 1));
        let rid = tc.draw(
            gs::integers::<u32>()
                .min_value(1002)
                .max_value(u32::MAX - 1),
        );
        let first = identity();
        let generation = CustodianGeneration::new(1).unwrap();
        let mut next = first.clone();
        next.execution_epoch = epoch;
        assert_ne!(first.pipe_name(generation), next.pipe_name(generation));
        assert_ne!(first.job_name(generation), next.job_name(generation));
        next = first.clone();
        next.sid = sid(rid);
        assert_ne!(first.key(), next.key());
    }

    /// @cc [owner:ghuntley,label:verification;recovery] broker-incomplete-recovery-refusal
    /// An existing worker without SYSTEM job custody or without a proven peer
    /// MUST refuse recovery regardless of the other facts.
    #[hegel::test(test_cases = 16)]
    fn incomplete_recovery_custody_never_stops_workers(tc: TestCase) {
        let exact = tc.draw(gs::booleans());
        let peer = tc.draw(gs::booleans());
        assert_eq!(
            recovery_decision(true, false, exact, peer),
            RecoveryDecision::Refuse
        );
        assert_eq!(
            recovery_decision(true, exact, peer, false),
            RecoveryDecision::Refuse
        );
    }

    /// @cc [owner:ghuntley,label:verification;security] broker-truncated-sid-refusal
    /// Every proper prefix of a valid local account SID MUST refuse.
    #[hegel::test(test_cases = 32)]
    fn every_truncated_local_sid_refuses(tc: TestCase) {
        let length = tc.draw(gs::integers::<usize>().max_value(27));
        assert_eq!(
            AccountSid::parse(&sid(1001).as_bytes()[..length]),
            Err(Refusal::Account)
        );
    }

    /// @cc [owner:ghuntley,label:verification;security] broker-renewed-identity-stability
    /// A renewed session or generation MUST yield the same stable identity,
    /// while a foreign epoch, account or origin MUST NOT match it.
    #[hegel::test(test_cases = 64)]
    fn renewed_sessions_and_generations_retain_only_exact_stable_identity(tc: TestCase) {
        let generation = tc.draw(
            gs::integers::<u64>()
                .min_value(1)
                .max_value(i64::MAX.unsigned_abs() - 1),
        );
        let (preface, boot, descriptor, sid) = admission_fixture();
        let identity = WorkerIdentity::admitted(&preface, &boot, &descriptor, sid.clone()).unwrap();
        let mut renewed = preface.clone();
        renewed.binding.generation = generation;
        renewed.binding.session_id = "33333333-3333-4333-8333-333333333333".to_owned();
        let current = WorkerIdentity::admitted(&renewed, &boot, &descriptor, sid).unwrap();
        assert_eq!(&current, &identity);
        assert!(current.matches_retained_binding(&preface.binding, &boot, &descriptor));
        let mut foreign = preface.binding.clone();
        foreign.execution_epoch += 1;
        assert!(!current.matches_retained_binding(&foreign, &boot, &descriptor));
        foreign = preface.binding.clone();
        foreign.guest_account_id = renewed.binding.session_id;
        assert!(!current.matches_retained_binding(&foreign, &boot, &descriptor));
        foreign = preface.binding;
        foreign.editor_origin = foreign.editor_origin.replace("apps.test", "other.test");
        assert!(!current.matches_retained_binding(&foreign, &boot, &descriptor));
    }

    fn prior(generation: u64) -> PriorWorker {
        PriorWorker {
            generation: CustodianGeneration::new(generation).unwrap(),
            sid: sid(1001),
            logon: LogonSession::new(0x1_0000_0042).unwrap(),
            root: ProcessIdentity {
                pid: 900,
                created: 1_000,
            },
        }
    }

    /// One simulated process-list entry for the recovery state machine.
    #[derive(Clone, Debug)]
    struct Simulated {
        pid: u32,
        created: u64,
        rid: u32,
        logon: u64,
        observable: bool,
        token_readable: bool,
        stubborn: bool,
        respawns: u8,
    }

    impl Simulated {
        fn matches(&self, prior: &PriorWorker) -> bool {
            self.created >= prior.root.created
                && sid(self.rid) == prior.sid
                && LogonSession::new(self.logon).unwrap() == prior.logon
        }

        fn observation(&self) -> ProcessObservation {
            if !self.observable {
                return ProcessObservation::Unobservable;
            }
            ProcessObservation::Opened {
                process: ProcessIdentity {
                    pid: self.pid,
                    created: self.created,
                },
                token: if self.token_readable {
                    TokenObservation::Account(TokenOwner {
                        sid: sid(self.rid),
                        logon: LogonSession::new(self.logon).unwrap(),
                    })
                } else {
                    TokenObservation::Unreadable
                },
            }
        }
    }

    fn simulated(tc: &TestCase) -> Simulated {
        Simulated {
            pid: tc.draw(gs::integers::<u32>().min_value(1).max_value(63)),
            created: tc.draw(hegel::one_of!(
                gs::integers::<u64>().min_value(500).max_value(999),
                gs::integers::<u64>().min_value(1_000).max_value(1_999),
            )),
            rid: tc.draw(gs::sampled_from(vec![1001_u32, 1002])),
            logon: tc.draw(gs::sampled_from(vec![0x1_0000_0042_u64, 0x1_0000_0043])),
            observable: tc.draw(gs::integers::<u8>().max_value(99)) < 95,
            token_readable: tc.draw(gs::integers::<u8>().max_value(99)) < 95,
            stubborn: tc.draw(gs::integers::<u8>().max_value(99)) < 10,
            respawns: tc.draw(gs::integers::<u8>().max_value(2)),
        }
    }

    /// @cc [owner:ghuntley,label:verification;recovery] broker-generation-successor
    /// Every custodian generation successor MUST be strictly greater, name a
    /// distinct job and pipe, and round-trip through its serialized form.
    #[hegel::test(test_cases = 64)]
    fn custodian_generations_strictly_increase_and_never_reuse(tc: TestCase) {
        let value = tc.draw(gs::integers::<u64>().min_value(1).max_value(u64::MAX - 1));
        let previous = CustodianGeneration::new(value).unwrap();
        let next = CustodianGeneration::successor(Some(previous)).unwrap();
        assert!(next > previous);
        let identity = identity();
        assert_ne!(identity.job_name(previous), identity.job_name(next));
        assert_ne!(identity.pipe_name(previous), identity.pipe_name(next));
        let encoded = serde_json::to_vec(&next).unwrap();
        assert_eq!(
            serde_json::from_slice::<CustodianGeneration>(&encoded).unwrap(),
            next
        );
    }

    /// @cc [owner:ghuntley,label:verification;recovery] broker-prior-receipt-admission
    /// A prior receipt MUST be admitted exactly when it is from a strictly
    /// earlier generation, matches the identity and its job is absent; stale,
    /// current or drifted receipts MUST refuse before probing the job.
    #[hegel::test(test_cases = 128)]
    fn stale_or_current_generation_receipts_never_reach_recovery(tc: TestCase) {
        let current = tc.draw(gs::integers::<u64>().min_value(1).max_value(999));
        let recorded = tc.draw(gs::integers::<u64>().min_value(1).max_value(999));
        let exact = tc.draw(gs::booleans());
        let present = tc.draw(gs::booleans());
        let current = CustodianGeneration::new(current).unwrap();
        let recorded = CustodianGeneration::new(recorded).unwrap();
        let mut probed = false;
        let decision = prior_receipt_admission(current, recorded, exact, || {
            probed = true;
            Ok(present)
        });
        if recorded < current && exact && !present {
            assert_eq!(decision, Ok(()));
        } else {
            assert_eq!(decision, Err(Refusal::Custody));
        }
        // Stale/current generations and identity drift refuse before any
        // kernel observation of the prior job namespace.
        assert_eq!(probed, recorded < current && exact);
    }

    /// @cc [owner:ghuntley,label:verification;recovery] broker-prior-session-drain
    /// Draining a simulated process table MUST terminate only exact account
    /// and logon-session stragglers, leave every unrelated entry, and succeed
    /// only when no ambiguous or stubborn straggler remains.
    #[hegel::test(test_cases = 128)]
    fn prior_session_drain_never_touches_other_accounts_or_sessions(tc: TestCase) {
        let count = tc.draw(gs::integers::<usize>().max_value(23));
        let mut table = (0..count).map(|_| simulated(&tc)).collect::<Vec<_>>();
        // A PID and creation time name at most one live process.
        let mut seen = std::collections::BTreeSet::new();
        table.retain(|entry| seen.insert((entry.pid, entry.created)));
        let prior = prior(1);
        let mut live = table.clone();
        let mut next_pid = 10_000;
        let mut terminated = Vec::new();
        let result = {
            let live = std::cell::RefCell::new(&mut live);
            drain_prior_session(
                &prior,
                PRIOR_SESSION_ROUNDS,
                || Ok(live.borrow().iter().map(Simulated::observation).collect()),
                |_, target| {
                    let mut live = live.borrow_mut();
                    let index = live
                        .iter()
                        .position(|entry| {
                            entry.pid == target.pid && entry.created == target.created
                        })
                        .ok_or(Refusal::Custody)?;
                    terminated.push(live[index].clone());
                    if live[index].stubborn {
                        return Ok(());
                    }
                    let entry = live.remove(index);
                    if entry.respawns > 0 {
                        // A dying straggler may spawn a same-session child.
                        next_pid += 1;
                        live.push(Simulated {
                            pid: next_pid,
                            created: 3_000,
                            respawns: entry.respawns - 1,
                            stubborn: false,
                            observable: true,
                            token_readable: true,
                            ..entry
                        });
                    }
                    Ok(())
                },
            )
        };
        // Only exact account and logon-session stragglers are ever terminated.
        for entry in &terminated {
            assert!(entry.matches(&prior));
        }
        // Every unrelated original entry survives untouched.
        for entry in table.iter().filter(|entry| {
            !entry.matches(&prior)
                && (entry.observable && entry.token_readable || entry.created < prior.root.created)
        }) {
            assert!(
                live.iter()
                    .any(|survivor| survivor.pid == entry.pid && survivor.created == entry.created)
            );
        }
        let ambiguous = table.iter().any(|entry| {
            (!entry.observable) || (!entry.token_readable && entry.created >= prior.root.created)
        });
        let stubborn = table
            .iter()
            .any(|entry| entry.stubborn && entry.matches(&prior));
        match result {
            Ok(()) => {
                assert!(!ambiguous && !stubborn);
                assert!(live.iter().all(|entry| !entry.matches(&prior)));
            }
            Err(reason) => {
                assert_eq!(reason, Refusal::Custody);
                assert!(ambiguous || stubborn);
            }
        }
    }

    /// @cc [owner:ghuntley,label:verification;recovery] broker-drain-error-propagation
    /// Scan and termination errors MUST propagate unchanged and refuse
    /// replacement.
    #[hegel::test(test_cases = 16)]
    fn scan_and_termination_errors_refuse_replacement(tc: TestCase) {
        let reason = tc.draw(gs::sampled_from(vec![
            Refusal::Custody,
            Refusal::Startup,
            Refusal::Capacity,
        ]));
        let prior = prior(2);
        assert_eq!(
            drain_prior_session(
                &prior,
                PRIOR_SESSION_ROUNDS,
                || Err(reason),
                |_, _| panic!("no plan")
            ),
            Err(reason)
        );
        let straggler = ProcessObservation::Opened {
            process: ProcessIdentity {
                pid: 7,
                created: 2_000,
            },
            token: TokenObservation::Account(TokenOwner {
                sid: prior.sid.clone(),
                logon: prior.logon,
            }),
        };
        assert_eq!(
            drain_prior_session(
                &prior,
                PRIOR_SESSION_ROUNDS,
                || Ok(vec![straggler.clone()]),
                |_, _| Err(reason)
            ),
            Err(reason)
        );
    }

    /// @cc [owner:ghuntley,label:verification;recovery] broker-logon-session-luid
    /// `LogonSession` MUST refuse zero, and every nonzero LUID MUST combine
    /// without sign extension into the little-endian (low, high) value that
    /// round-trips through new, u64 and serialization.
    #[hegel::test(test_cases = 128)]
    fn logon_sessions_refuse_zero_and_round_trip(tc: TestCase) {
        let low = tc.draw(hegel::one_of!(gs::just(0_u32), gs::integers::<u32>()));
        let high = tc.draw(hegel::one_of!(
            gs::sampled_from(vec![0_i32, -1, i32::MIN]),
            gs::integers::<i32>(),
        ));
        let mut bytes = [0_u8; 8];
        bytes[..4].copy_from_slice(&low.to_le_bytes());
        bytes[4..].copy_from_slice(&high.to_le_bytes());
        let combined = u64::from_le_bytes(bytes);
        let session = LogonSession::from_luid(low, high);
        assert_eq!(session, LogonSession::new(combined));
        if combined == 0 {
            assert_eq!(session, Err(Refusal::Custody));
            assert!(LogonSession::try_from(0_u64).is_err());
            assert!(serde_json::from_slice::<LogonSession>(b"0").is_err());
        } else {
            let session = session.unwrap();
            assert_eq!(u64::from(session), combined);
            assert_eq!(LogonSession::try_from(combined), Ok(session));
            let encoded = serde_json::to_vec(&session).unwrap();
            assert_eq!(
                serde_json::from_slice::<LogonSession>(&encoded).unwrap(),
                session
            );
        }
    }

    const DEVICES: [&str; 12] = [
        "CON", "prn", "Aux", "nul", "COM1", "com9", "LPT5", "lpt²", "COM¹", "Lpt³", "CONIN$",
        "conout$",
    ];

    /// @cc [owner:ghuntley,label:verification;security] broker-dos-device-lattice
    /// `dos_device` MUST recognize every reserved DOS device name in any ASCII
    /// case and with any extension, and MUST NOT recognize a device name with
    /// any extra or missing base character.
    #[hegel::test(test_cases = 128)]
    fn dos_device_names_follow_the_reserved_lattice(tc: TestCase) {
        let device = tc.draw(gs::sampled_from(DEVICES.as_slice()));
        let extension = tc.draw(gs::sampled_from(vec!["", ".txt", ".a.b", "."]));
        assert!(dos_device(&format!("{device}{extension}")));
        assert!(dos_device(&format!(
            "{}{extension}",
            device.to_ascii_lowercase()
        )));
        let extra = tc.draw(gs::sampled_from(vec!["0", "x", "$", "1"]));
        assert!(!dos_device(&format!("{device}{extra}{extension}")));
        assert!(!dos_device(&format!("x{device}{extension}")));
        let mut shortened = device.chars().collect::<Vec<_>>();
        shortened.pop();
        assert!(!dos_device(&format!(
            "{}{extension}",
            shortened.into_iter().collect::<String>()
        )));
    }

    const POISON_COMPONENTS: [&str; 19] = [
        "",
        ".",
        "..",
        "a.",
        "a ",
        "NUL",
        "con.txt",
        "Com1",
        "lpt²",
        "CONIN$",
        "conout$.log",
        "aux",
        "a:b",
        "a/b",
        "a\"b",
        "a\rb",
        "a\nb",
        "a\0b",
        "prn.x.y",
    ];

    /// A component that is never a device, dot form or forbidden character.
    fn safe_component(tc: &TestCase) -> String {
        let first = tc.draw(gs::sampled_from(vec![
            'b', 'w', 'x', 'y', 'z', '0', '1', '9', '_',
        ]));
        let rest = tc.draw(gs::text().alphabet("abwxyz019_- ").max_size(7));
        let rest = rest.trim_end_matches(' ');
        format!("{first}{rest}")
    }

    /// @cc [owner:ghuntley,label:verification;security] broker-local-path-lattice
    /// `LocalPath::parse` MUST accept a drive root or a drive-absolute path of at
    /// most 4096 bytes exactly when every component is safe; any empty, dot,
    /// trailing dot or space, device, stream, separator, quote or control
    /// component, or a non-letter drive, MUST refuse.
    #[hegel::test(test_cases = 192)]
    fn local_paths_follow_the_component_lattice(tc: TestCase) {
        let drive = tc.draw(gs::sampled_from(vec!['C', 'z', '1', ':', '\\', 'é']));
        let count = tc.draw(gs::integers::<usize>().max_value(5));
        let mut poisoned = false;
        let mut components = Vec::new();
        for _ in 0..count {
            if tc.draw(gs::integers::<u8>().max_value(4)) == 0 {
                poisoned = true;
                components.push(
                    tc.draw(gs::sampled_from(POISON_COMPONENTS.as_slice()))
                        .to_owned(),
                );
            } else {
                components.push(safe_component(&tc));
            }
        }
        if tc.draw(gs::booleans()) {
            components.push("x".repeat(tc.draw(gs::integers::<usize>().max_value(4200))));
            poisoned |= components.last().is_some_and(String::is_empty);
        }
        let rest = components.join("\\");
        let value = format!("{drive}:\\{rest}");
        let expected =
            drive.is_ascii_alphabetic() && (rest.is_empty() || !poisoned && value.len() <= 4096);
        assert_eq!(LocalPath::parse(&value).is_ok(), expected);
        if expected {
            assert_eq!(LocalPath::parse(&value).unwrap().as_str(), value);
        } else {
            assert_eq!(LocalPath::parse(&value), Err(Refusal::Package));
        }
    }

    const POISON_ENTRIES: [&str; 13] = [
        "",
        "relative",
        "C:",
        r"C:\a\..\b",
        r"%SystemRoot%\x",
        r"C:\a*",
        r"C:\a?",
        r"C:\a<b",
        r"C:\a|b",
        r"C:\Ö",
        "C:\\a\tb",
        r"\\server\share",
        r"C:\NUL",
    ];

    /// @cc [owner:ghuntley,label:verification;security] broker-worker-path-lattice
    /// `WorkerPath::parse` MUST accept exactly 1..=32 distinct safe local
    /// directories; a poisoned entry, a case-insensitive duplicate or a 33rd
    /// entry MUST refuse, and accepted paths MUST preserve value and order.
    #[hegel::test(test_cases = 192)]
    fn worker_paths_follow_the_entry_lattice(tc: TestCase) {
        let count = tc.draw(gs::integers::<usize>().min_value(1).max_value(36));
        let mut refused = count > 32;
        let mut entries: Vec<String> = Vec::new();
        for index in 0..count {
            match tc.draw(gs::integers::<u8>().max_value(9)) {
                0 => {
                    refused = true;
                    entries.push(
                        tc.draw(gs::sampled_from(POISON_ENTRIES.as_slice()))
                            .to_owned(),
                    );
                }
                1 if index > 0 => {
                    refused = true;
                    let previous = tc.draw(gs::integers::<usize>().max_value(index - 1));
                    entries.push(format!(r"C:\D{previous}"));
                }
                _ => entries.push(format!(r"C:\d{index}")),
            }
        }
        let value = entries.join(";");
        match WorkerPath::parse(&value) {
            Ok(path) => {
                assert!(!refused);
                assert_eq!(path.as_str(), value);
                assert!(
                    path.directories()
                        .iter()
                        .map(LocalPath::as_str)
                        .eq(entries.iter().map(String::as_str))
                );
            }
            Err(reason) => {
                assert!(refused);
                assert_eq!(reason, Refusal::Package);
            }
        }
    }

    /// CommandLineToArgvW/msvcrt argument splitting: 2n backslashes and a
    /// quote yield n backslashes and toggle quoting; 2n+1 yield n and a
    /// literal quote; other backslashes are literal; unquoted blanks split.
    fn argv_oracle(line: &str) -> Vec<String> {
        let characters = line.chars().collect::<Vec<_>>();
        let mut arguments = Vec::new();
        let mut index = 0;
        loop {
            while characters
                .get(index)
                .is_some_and(|c| *c == ' ' || *c == '\t')
            {
                index += 1;
            }
            if index >= characters.len() {
                return arguments;
            }
            let mut argument = String::new();
            let mut quoted = false;
            while let Some(&character) = characters.get(index) {
                if !quoted && (character == ' ' || character == '\t') {
                    break;
                }
                if character == '\\' {
                    let mut slashes = 0;
                    while characters.get(index) == Some(&'\\') {
                        slashes += 1;
                        index += 1;
                    }
                    if characters.get(index) == Some(&'"') {
                        argument.extend(std::iter::repeat_n('\\', slashes / 2));
                        if slashes % 2 == 1 {
                            argument.push('"');
                        } else {
                            quoted = !quoted;
                        }
                        index += 1;
                    } else {
                        argument.extend(std::iter::repeat_n('\\', slashes));
                    }
                } else if character == '"' {
                    quoted = !quoted;
                    index += 1;
                } else {
                    argument.push(character);
                    index += 1;
                }
            }
            arguments.push(argument);
        }
    }

    /// @cc [owner:ghuntley,label:verification;security] broker-command-line-roundtrip
    /// `command_line` MUST refuse NUL-bearing or empty argument lists and lines
    /// of 32767 or more UTF-16 units, and every accepted line MUST be
    /// NUL-terminated and split back into exactly the original arguments by
    /// an independent CommandLineToArgvW-style parser.
    #[hegel::test(test_cases = 192)]
    fn command_lines_round_trip_through_argv_oracle(tc: TestCase) {
        let mut arguments = tc.draw(
            gs::vecs(hegel::one_of!(
                gs::text().alphabet("ab \\\"\té😀").max_size(12),
                gs::text().alphabet("a\\\"\0").max_size(4),
            ))
            .max_size(5),
        );
        if tc.draw(gs::booleans()) {
            let length = tc.draw(gs::integers::<usize>().max_value(40_000));
            arguments.push("x\\".repeat(length / 2));
        }
        let nul = arguments.iter().any(|argument| argument.contains('\0'));
        let raw: usize = arguments
            .iter()
            .map(|argument| argument.encode_utf16().count())
            .sum();
        let bound: usize = arguments
            .iter()
            .map(|argument| 2 * argument.encode_utf16().count() + 3)
            .sum();
        match command_line(&arguments) {
            Ok(wide) => {
                assert!(!nul && !arguments.is_empty() && raw < 32767);
                assert_eq!(wide.last(), Some(&0));
                assert!(wide.len() <= 32767);
                let line = String::from_utf16(&wide[..wide.len() - 1]).unwrap();
                assert!(!line.contains('\0'));
                assert_eq!(argv_oracle(&line), arguments);
            }
            Err(reason) => {
                assert_eq!(reason, Refusal::Package);
                assert!(nul || arguments.is_empty() || bound >= 32767);
            }
        }
    }

    #[test]
    fn prior_session_classification_is_exact() {
        let prior = prior(1);
        let opened = |created, token| ProcessObservation::Opened {
            process: ProcessIdentity { pid: 5, created },
            token,
        };
        let own = TokenObservation::Account(TokenOwner {
            sid: prior.sid.clone(),
            logon: prior.logon,
        });
        assert_eq!(
            classify_process(&prior, &opened(1_000, own.clone())),
            ProcessClass::Straggler(ProcessIdentity {
                pid: 5,
                created: 1_000
            })
        );
        // Created before the root: unrelated even with a matching session.
        assert_eq!(
            classify_process(&prior, &opened(999, own)),
            ProcessClass::Unrelated
        );
        assert_eq!(
            classify_process(&prior, &opened(999, TokenObservation::Unreadable)),
            ProcessClass::Unrelated
        );
        // Another logon session of the same account is never a straggler.
        assert_eq!(
            classify_process(
                &prior,
                &opened(
                    2_000,
                    TokenObservation::Account(TokenOwner {
                        sid: prior.sid.clone(),
                        logon: LogonSession::new(0x1_0000_0043).unwrap()
                    })
                )
            ),
            ProcessClass::Unrelated
        );
        // The same session LUID under another account SID is unrelated.
        assert_eq!(
            classify_process(
                &prior,
                &opened(
                    2_000,
                    TokenObservation::Account(TokenOwner {
                        sid: sid(1002),
                        logon: prior.logon
                    })
                )
            ),
            ProcessClass::Unrelated
        );
        assert_eq!(
            classify_process(&prior, &opened(2_000, TokenObservation::NonAccount)),
            ProcessClass::Unrelated
        );
        assert_eq!(
            classify_process(&prior, &opened(2_000, TokenObservation::Unreadable)),
            ProcessClass::Ambiguous
        );
        assert_eq!(
            classify_process(&prior, &ProcessObservation::Unobservable),
            ProcessClass::Ambiguous
        );
        assert_eq!(
            classify_process(&prior, &ProcessObservation::KernelCreated),
            ProcessClass::Unrelated
        );
        assert_eq!(
            classify_process(&prior, &ProcessObservation::Exited),
            ProcessClass::Unrelated
        );
        assert_eq!(
            CustodianGeneration::successor(None),
            CustodianGeneration::new(1)
        );
        assert_eq!(
            CustodianGeneration::successor(Some(CustodianGeneration::new(u64::MAX).unwrap())),
            Err(Refusal::Custody)
        );
        assert!(serde_json::from_slice::<CustodianGeneration>(b"0").is_err());
        assert!(serde_json::from_slice::<LogonSession>(b"0").is_err());
        assert_eq!(
            LogonSession::from_luid(0x42, -1).map(u64::from),
            Ok(0xffff_ffff_0000_0042)
        );
    }

    #[test]
    fn same_account_pipe_requires_job_and_executable_custody() {
        let identity = identity();
        let expected = ProcessIdentity {
            pid: 7,
            created: 99,
        };
        let peer = PipePeer {
            process: expected,
            sid: identity.sid.clone(),
            in_expected_job: true,
            exact_executable: true,
        };
        assert_eq!(
            verify_peer(
                &identity,
                expected,
                &PipePeer {
                    sid: sid(1002),
                    ..peer.clone()
                }
            ),
            Err(Refusal::Custody)
        );
        assert_eq!(
            verify_peer(
                &identity,
                expected,
                &PipePeer {
                    in_expected_job: false,
                    ..peer.clone()
                }
            ),
            Err(Refusal::Custody)
        );
        assert_eq!(
            verify_peer(
                &identity,
                expected,
                &PipePeer {
                    exact_executable: false,
                    ..peer
                }
            ),
            Err(Refusal::Custody)
        );
        assert_eq!(
            recovery_decision(true, true, false, true),
            RecoveryDecision::StopOwnedThenStart
        );
    }

    #[test]
    fn device_relative_alternate_stream_and_ambiguous_paths_refuse() {
        assert!(LocalPath::parse(r"C:\Program Files\Overalls\node.exe").is_ok());
        for value in [
            r"node.exe",
            r"C:node.exe",
            r"\\host\share\node.exe",
            r"\\?\C:\node.exe",
            r"C:\node.exe:stream",
            r"C:\a\..\node.exe",
            r"C:\a.\node.exe",
            r"C:\a \node.exe",
            r"C:\a\\node.exe",
            r"C:\NUL",
            r"C:\CON.exe",
            r"C:\COM¹.exe",
        ] {
            assert_eq!(LocalPath::parse(value), Err(Refusal::Package));
        }
    }

    #[test]
    fn quoted_paths_and_trailing_slashes_have_exact_windows_escaping() {
        let command = command_line(&[
            r"C:\Program Files\node.exe".to_owned(),
            "a\"b".to_owned(),
            "x\\".to_owned(),
            String::new(),
        ])
        .unwrap();
        assert_eq!(
            String::from_utf16(&command[..command.len() - 1]).unwrap(),
            "\"C:\\Program Files\\node.exe\" \"a\\\"b\" \"x\\\\\" \"\""
        );
        assert_eq!(command_line(&["x\0y".to_owned()]), Err(Refusal::Package));
    }

    #[test]
    fn worker_path_requires_explicit_distinct_local_directories() {
        let value = r"C:\overalls\editor;C:\Windows\System32;C:\Program Files\Git\cmd";
        let path = WorkerPath::parse(value).unwrap();
        assert_eq!(path.as_str(), value);
        assert_eq!(path.directories().len(), 3);
        for value in [
            "",
            r"C:\Windows\System32;",
            r";C:\Windows\System32",
            r"C:\Windows\System32;;C:\overalls",
            r"C:\Windows\System32;c:\windows\system32",
            r"C:\overalls;.",
            r"C:\overalls;relative",
            r"C:\overalls;%SystemRoot%\System32",
            r"C:\overalls;\\server\share",
            r"C:\overalls;C:\Windows\*",
            r"C:\overalls;C:\Windows\?",
            r"C:\overalls;C:\Överalls",
            "C:\\overalls;C:\\a\tb",
        ] {
            assert_eq!(WorkerPath::parse(value), Err(Refusal::Package));
        }
        let too_many = (0..33)
            .map(|index| format!(r"C:\path{index}"))
            .collect::<Vec<_>>()
            .join(";");
        assert_eq!(WorkerPath::parse(&too_many), Err(Refusal::Package));
        assert_eq!(
            WorkerPath::parse(&format!(r"C:\{}", "x".repeat(4094))),
            Err(Refusal::Package)
        );
    }

    #[test]
    fn pipe_slots_remain_reserved_until_retained_operation_is_released() {
        let slots = PipeSlots::new();
        let mut live = (0..PIPE_LIMIT)
            .map(|_| slots.reserve().unwrap())
            .collect::<Vec<_>>();
        assert!(slots.reserve().is_none());
        let retained = live.pop().unwrap();
        assert!(slots.reserve().is_none());
        drop(retained);
        let replacement = slots.reserve().unwrap();
        assert!(slots.reserve().is_none());
        drop(replacement);
        drop(live);
        for _ in 0..PIPE_LIMIT * 2 {
            assert!(slots.reserve().is_some());
        }
    }
}
