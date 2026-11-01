//! The SYSTEM peer, deployment package and custodian-owned worker.

use super::account::{account_token, privilege, profile_directory, token_logon};
use super::files::{package_directory, package_file};
use super::job::{JobAttributes, new_job, stop_owned_job, system_job};
use super::processes::{peer, process_identity};
use super::{owned, raw, system_sid, wide};
use crate::Refusal;
use crate::windows_model::{
    CustodianGeneration, LocalPath, LogonSession, ProcessIdentity, WorkerIdentity, WorkerPath,
    command_line, verify_peer,
};
use crate::windows_pipe::Pipe;
use std::fs::OpenOptions;
use std::mem::{size_of, zeroed};
use std::os::windows::fs::OpenOptionsExt;
use std::os::windows::io::{AsRawHandle, OwnedHandle};
use std::ptr::{null, null_mut};
use windows_sys::Win32::Foundation::{WAIT_OBJECT_0, WAIT_TIMEOUT};
use windows_sys::Win32::Security::{
    EqualSid, GetTokenInformation, SE_ASSIGNPRIMARYTOKEN_NAME, SE_INCREASE_QUOTA_NAME, SE_TCB_NAME,
    TOKEN_QUERY, TOKEN_USER, TokenUser,
};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_FLAG_OVERLAPPED, SECURITY_IDENTIFICATION, SECURITY_SQOS_PRESENT,
};
use windows_sys::Win32::System::Pipes::{GetNamedPipeServerProcessId, WaitNamedPipeW};
use windows_sys::Win32::System::Threading::{
    CREATE_BREAKAWAY_FROM_JOB, CREATE_NO_WINDOW, CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT,
    CreateProcessAsUserW, EXTENDED_STARTUPINFO_PRESENT, OpenProcess, OpenProcessToken,
    PROCESS_INFORMATION, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE,
    QueryFullProcessImageNameW, ResumeThread, STARTUPINFOEXW, WaitForSingleObject,
};

/// A SYSTEM peer handle pins PID/creation and the exact installed executable.
#[derive(Debug)]
pub struct SystemPeer {
    process: OwnedHandle,
    identity: ProcessIdentity,
}

impl SystemPeer {
    pub fn open(pid: u32, executable: &LocalPath) -> Result<Self, Refusal> {
        package_file(executable)?;
        let process = owned(
            // SAFETY: OpenProcess takes only integer arguments and returns a new handle or null.
            unsafe {
                OpenProcess(
                    PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
                    0,
                    pid,
                )
            },
            Refusal::Custody,
        )?;
        let identity = process_identity(&process)?;
        let peer = Self { process, identity };
        peer.verify(executable)?;
        Ok(peer)
    }

    pub fn identity(&self) -> ProcessIdentity {
        self.identity
    }

    pub fn verify(&self, executable: &LocalPath) -> Result<(), Refusal> {
        if process_identity(&self.process)? != self.identity
            // SAFETY: the process handle is owned and open; a zero timeout never blocks.
            || unsafe { WaitForSingleObject(raw(&self.process), 0) } != WAIT_TIMEOUT
        {
            return Err(Refusal::Custody);
        }
        let mut token = null_mut();
        // SAFETY: the process handle is owned and open, and `token` is a writable out-pointer.
        if unsafe { OpenProcessToken(raw(&self.process), TOKEN_QUERY, &raw mut token) } == 0 {
            return Err(Refusal::Custody);
        }
        let token = owned(token, Refusal::Custody)?;
        let mut length = 0;
        // SAFETY: a null buffer with zero length only queries the required size into the live `length` local.
        unsafe { GetTokenInformation(raw(&token), TokenUser, null_mut(), 0, &raw mut length) };
        if length == 0 || length > 65536 {
            return Err(Refusal::Custody);
        }
        let mut buffer = vec![0_usize; (length as usize).div_ceil(size_of::<usize>())];
        // SAFETY: `buffer` is a live pointer-aligned writable allocation of at least `length` bytes, and the token handle is owned and open.
        if unsafe {
            GetTokenInformation(
                raw(&token),
                TokenUser,
                buffer.as_mut_ptr().cast(),
                length,
                &raw mut length,
            )
        } == 0
        {
            return Err(Refusal::Custody);
        }
        // SAFETY: GetTokenInformation succeeded into the pointer-aligned `buffer` sized as the kernel requested, so it holds an initialized TOKEN_USER.
        let user = unsafe { &*buffer.as_ptr().cast::<TOKEN_USER>() };
        // SAFETY: the SID points into the live `buffer`, and the temporary SYSTEM SID array lives until the end of this statement.
        if unsafe { EqualSid(user.User.Sid, system_sid().as_ptr().cast_mut().cast()) } == 0 {
            return Err(Refusal::Custody);
        }
        let mut path = [0_u16; 4096];
        let mut length = u32::try_from(path.len()).map_err(|_| Refusal::Custody)?;
        // SAFETY: the process handle is owned and open, and `path` is a live writable buffer whose UTF-16 length is passed in `length`.
        if unsafe {
            QueryFullProcessImageNameW(raw(&self.process), 0, path.as_mut_ptr(), &raw mut length)
        } == 0
            || length as usize >= path.len()
        {
            return Err(Refusal::Custody);
        }
        let path = String::from_utf16(&path[..length as usize]).map_err(|_| Refusal::Custody)?;
        if !path.eq_ignore_ascii_case(executable.as_str()) {
            return Err(Refusal::Custody);
        }
        Ok(())
    }
}

/// Trusted deployment paths, never selected from an incoming editor preface.
#[derive(Debug)]
pub struct Package {
    pub node: LocalPath,
    pub server: LocalPath,
    pub system_root: LocalPath,
    pub worker_path: WorkerPath,
    pub extra_ca_certs: LocalPath,
}

/// Failed drain retains the exact job and its capacity charge until shutdown.
#[derive(Debug)]
pub struct QuarantinedJob {
    _job: OwnedHandle,
}

#[derive(Debug)]
pub struct LaunchFailure {
    pub reason: Refusal,
    pub quarantine: Option<QuarantinedJob>,
}

impl From<Refusal> for LaunchFailure {
    fn from(reason: Refusal) -> Self {
        Self {
            reason,
            quarantine: None,
        }
    }
}

/// A custodian-owned worker. Closing its last job handle kills every descendant.
#[derive(Debug)]
pub struct Worker {
    process: OwnedHandle,
    job: OwnedHandle,
    identity: WorkerIdentity,
    generation: CustodianGeneration,
    logon: LogonSession,
    executable: LocalPath,
    process_identity: ProcessIdentity,
    suspended_thread: Option<OwnedHandle>,
}

impl Worker {
    /// @cc [owner:ghuntley,label:security;recovery] windows-editor-suspended-account-launch
    /// Launch MUST verify the current local and S4U token SID, create the exact
    /// configured executable directly with no inherited handles, and assign its
    /// process atomically to a SYSTEM-only kill-on-close job through `JOB_LIST`.
    /// It MUST return suspended, without inherited handles, until the custodian
    /// publishes the receipt. Custodian loss at every intermediate point MUST
    /// kill the child; the TCP gateway MUST never hold a worker job handle.
    #[expect(
        clippy::too_many_lines,
        reason = "one atomic launch sequence whose job and handles must be stopped on every failure path"
    )]
    pub fn launch(
        identity: WorkerIdentity,
        generation: CustodianGeneration,
        package: &Package,
    ) -> Result<Self, LaunchFailure> {
        package_file(&package.node)?;
        package_file(&package.server)?;
        package_file(&package.extra_ca_certs)?;
        for directory in package.worker_path.directories() {
            package_directory(directory)?;
        }
        privilege(SE_ASSIGNPRIMARYTOKEN_NAME)?;
        privilege(SE_INCREASE_QUOTA_NAME)?;
        privilege(SE_TCB_NAME)?;
        let token = account_token(&identity)?;
        // Recorded before launch so a later custodian can prove quiescence of
        // exactly this worker's processes without its job handle.
        let logon = token_logon(raw(&token))?;
        let home = profile_directory(raw(&token))?;
        let mut command = command_line(&[
            package.node.as_str().to_owned(),
            package.server.as_str().to_owned(),
            "--without-connection-token".to_owned(),
            "--socket-path".to_owned(),
            identity.pipe_name(generation),
            "--server-data-dir".to_owned(),
            format!(r"{}\.overalls-code-server", home.as_str()),
            "--enable-remote-auto-shutdown".to_owned(),
            "--reconnection-grace-time".to_owned(),
            "1500".to_owned(),
            "--disable-telemetry".to_owned(),
            "--disable-workspace-trust".to_owned(),
            "--default-folder".to_owned(),
            r"C:\workspace".to_owned(),
        ])?;
        let mut pairs = vec![
            ("HOME", home.as_str().to_owned()),
            ("USERPROFILE", home.as_str().to_owned()),
            ("USERNAME", identity.username().to_owned()),
            ("SystemRoot", package.system_root.as_str().to_owned()),
            ("WINDIR", package.system_root.as_str().to_owned()),
            ("PATH", package.worker_path.as_str().to_owned()),
            ("APPDATA", format!(r"{}\AppData\Roaming", home.as_str())),
            ("LOCALAPPDATA", format!(r"{}\AppData\Local", home.as_str())),
            (
                "COMSPEC",
                format!(r"{}\System32\cmd.exe", package.system_root.as_str()),
            ),
            ("PATHEXT", ".COM;.EXE;.BAT;.CMD".to_owned()),
            (
                "NODE_EXTRA_CA_CERTS",
                package.extra_ca_certs.as_str().to_owned(),
            ),
            ("TEMP", format!(r"{}\AppData\Local\Temp", home.as_str())),
            ("TMP", format!(r"{}\AppData\Local\Temp", home.as_str())),
            ("OVERALLS_EDITOR_ORIGIN", identity.origin().to_owned()),
            (
                "OVERALLS_WEBVIEW_ENDPOINT_TEMPLATE",
                identity.webview_template().to_owned(),
            ),
        ];
        pairs.sort_by_key(|(key, _)| key.to_ascii_uppercase());
        let environment: Vec<u16> = pairs
            .into_iter()
            .flat_map(|(key, value)| wide(&format!("{key}={value}")))
            .chain([0])
            .collect();
        let job = new_job(&identity, generation)?;
        let attributes = JobAttributes::new(&job)?;
        // SAFETY: STARTUPINFOEXW is a plain C struct for which all-zero bytes are a valid value.
        let mut startup: STARTUPINFOEXW = unsafe { zeroed() };
        startup.StartupInfo.cb =
            u32::try_from(size_of::<STARTUPINFOEXW>()).map_err(|_| Refusal::Startup)?;
        startup.lpAttributeList = attributes.pointer();
        let mut desktop = wide("");
        startup.StartupInfo.lpDesktop = desktop.as_mut_ptr();
        let application = wide(package.node.as_str());
        let directory = wide(home.as_str());
        // SAFETY: PROCESS_INFORMATION is a plain C struct for which all-zero bytes are a valid value.
        let mut information: PROCESS_INFORMATION = unsafe { zeroed() };
        // SAFETY: the token is an owned primary token; application, command, environment, directory and desktop are live NUL-terminated UTF-16 buffers; `startup` and its attribute list outlive the call, and `information` is a live writable local.
        if unsafe {
            CreateProcessAsUserW(
                raw(&token),
                application.as_ptr(),
                command.as_mut_ptr(),
                null(),
                null(),
                0,
                CREATE_SUSPENDED
                    | CREATE_UNICODE_ENVIRONMENT
                    | CREATE_NO_WINDOW
                    | CREATE_BREAKAWAY_FROM_JOB
                    | EXTENDED_STARTUPINFO_PRESENT,
                environment.as_ptr().cast(),
                directory.as_ptr(),
                &raw const startup.StartupInfo,
                &raw mut information,
            )
        } == 0
        {
            return Err(Refusal::Startup.into());
        }
        let process = owned(information.hProcess, Refusal::Startup);
        let thread = owned(information.hThread, Refusal::Startup);
        let (process, thread) = match (process, thread) {
            (Ok(process), Ok(thread)) => (process, thread),
            partial => {
                // Any opened handle stays open until the owned job is stopped.
                let stopped = stop_owned_job(&job);
                drop(partial);
                if let Err(reason) = stopped {
                    return Err(LaunchFailure {
                        reason,
                        quarantine: Some(QuarantinedJob { _job: job }),
                    });
                }
                return Err(Refusal::Startup.into());
            }
        };
        let launched: Result<ProcessIdentity, Refusal> = (|| {
            let process_identity = process_identity(&process)?;
            verify_peer(
                &identity,
                process_identity,
                &peer(&process, &job, &package.node)?,
            )?;
            Ok(process_identity)
        })();
        match launched {
            Ok(process_identity) => Ok(Self {
                process,
                job,
                identity,
                generation,
                logon,
                executable: package.node.clone(),
                process_identity,
                suspended_thread: Some(thread),
            }),
            Err(error) => {
                if let Err(reason) = stop_owned_job(&job) {
                    return Err(LaunchFailure {
                        reason,
                        quarantine: Some(QuarantinedJob { _job: job }),
                    });
                }
                Err(error.into())
            }
        }
    }

    pub fn process_identity(&self) -> ProcessIdentity {
        self.process_identity
    }

    pub fn matches(&self, identity: &WorkerIdentity, generation: CustodianGeneration) -> bool {
        &self.identity == identity && self.generation == generation
    }

    pub fn logon_session(&self) -> LogonSession {
        self.logon
    }

    /// Resume only after the complete private receipt has been published.
    pub fn resume(&mut self) -> Result<(), Refusal> {
        let thread = self.suspended_thread.as_ref().ok_or(Refusal::Custody)?;
        // SAFETY: the suspended thread handle is owned and open.
        if unsafe { ResumeThread(raw(thread)) } != 1 {
            return Err(Refusal::Startup);
        }
        self.suspended_thread = None;
        Ok(())
    }

    /// A retained process is live only when its PID and creation time remain
    /// exact and the process is still in the verified named job.
    pub fn is_running(&self) -> Result<bool, Refusal> {
        let observed = process_identity(&self.process)?;
        if observed != self.process_identity {
            return Err(Refusal::Custody);
        }
        // SAFETY: the process handle is owned and open; a zero timeout never blocks.
        match unsafe { WaitForSingleObject(raw(&self.process), 0) } {
            WAIT_OBJECT_0 => return Ok(false),
            WAIT_TIMEOUT => {}
            _ => return Err(Refusal::Custody),
        }
        verify_peer(
            &self.identity,
            self.process_identity,
            &peer(&self.process, &self.job, &self.executable)?,
        )?;
        Ok(true)
    }

    /// @cc [owner:ghuntley,label:security] windows-editor-connected-pipe-custody
    /// A returned pipe MUST be connected to the exact retained worker process
    /// after kernel PID, creation-time, token-SID, executable and job checks.
    /// The open MUST permit identification only, so a foreign pipe
    /// server cannot impersonate the `LocalSystem` broker. Failure closes the
    /// connection without killing or deleting the possible server.
    pub fn connect(&self) -> Result<Pipe, Refusal> {
        let reservation = Pipe::reserve().map_err(|_| Refusal::Capacity)?;
        let pipe_name = wide(&self.identity.pipe_name(self.generation));
        // SAFETY: `pipe_name` is a live NUL-terminated UTF-16 pipe name.
        if unsafe { WaitNamedPipeW(pipe_name.as_ptr(), 2_000) } == 0 {
            return Err(Refusal::Readiness);
        }
        let pipe = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION | FILE_FLAG_OVERLAPPED)
            .open(self.identity.pipe_name(self.generation))
            .map_err(|_| Refusal::Readiness)?;
        let mut pid = 0;
        // SAFETY: the pipe handle is open for the borrow of `pipe` and `pid` is a live writable local.
        if unsafe { GetNamedPipeServerProcessId(pipe.as_raw_handle(), &raw mut pid) } == 0
            || pid != self.process_identity.pid
        {
            return Err(Refusal::Custody);
        }
        verify_peer(
            &self.identity,
            self.process_identity,
            &peer(&self.process, &self.job, &self.executable)?,
        )?;
        Pipe::from_file(pipe, reservation).map_err(|_| Refusal::Readiness)
    }

    /// End only the verified job; personal profile/workspace files are untouched.
    pub fn terminate(&self) -> Result<(), Refusal> {
        system_job(&self.job)?;
        if process_identity(&self.process)? != self.process_identity {
            return Err(Refusal::Custody);
        }
        // SAFETY: the process handle is owned and open; a zero timeout never blocks.
        match unsafe { WaitForSingleObject(raw(&self.process), 0) } {
            WAIT_TIMEOUT => {
                verify_peer(
                    &self.identity,
                    self.process_identity,
                    &peer(&self.process, &self.job, &self.executable)?,
                )?;
            }
            // Both retained handles were verified when this Worker was built;
            // a dead root cannot erase custody of its remaining descendants.
            WAIT_OBJECT_0 => {}
            _ => return Err(Refusal::Custody),
        }
        stop_owned_job(&self.job)
    }
}
