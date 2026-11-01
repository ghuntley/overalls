use super::files::{FileAuthority, descriptor_acl};
use super::job::{JobAttributes, new_job_named};
use super::processes::{job_name_present, process_identity};
use super::*;
use crate::Refusal;
use crate::windows_model::{ProcessObservation, TokenObservation, command_line};
use std::mem::{size_of, zeroed};
use std::ptr::{null, null_mut};
use windows_sys::Win32::Foundation::{LocalFree, WAIT_OBJECT_0, WAIT_TIMEOUT};
use windows_sys::Win32::Security::Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW;
use windows_sys::Win32::System::JobObjects::IsProcessInJob;
use windows_sys::Win32::System::Threading::{
    CREATE_BREAKAWAY_FROM_JOB, CREATE_NO_WINDOW, CREATE_SUSPENDED, EXTENDED_STARTUPINFO_PRESENT,
    PROCESS_INFORMATION, STARTUPINFOEXW, WaitForSingleObject,
};

/// SYSTEM-only native check of the two recovery observations. It does not
/// launch a personal worker, kill a straggler or crash a custodian.
#[test]
fn native_closed_job_name_vanishes_and_snapshot_reports_system_tokens() {
    require_system().expect("native custody tests require SYSTEM");
    let name = format!(r"Global\overalls-editor-prior-test-{}", std::process::id());
    assert_eq!(job_name_present(&name), Ok(false));
    let job = new_job_named(&name).unwrap();
    assert_eq!(job_name_present(&name), Ok(true));
    drop(job);
    assert_eq!(job_name_present(&name), Ok(false));
    let observations = observe_processes().unwrap();
    let own = std::process::id();
    assert!(observations.iter().any(|observation| matches!(
        observation,
        ProcessObservation::Opened {
            process,
            token: TokenObservation::NonAccount,
        } if process.pid == own
    )));
}

/// This requires an explicitly SYSTEM-run native test executable. Cross
/// compilation does not exercise atomic launch or kill-on-close timing.
#[test]
fn native_atomic_job_assignment_closes_suspended_orphan_window() {
    use windows_sys::Win32::System::Threading::CreateProcessW;
    require_system().expect("native custody tests require SYSTEM");
    let name = format!(r"Global\overalls-editor-atomic-test-{}", std::process::id());
    let job = new_job_named(&name).unwrap();
    let attributes = JobAttributes::new(&job).unwrap();
    // SAFETY: STARTUPINFOEXW is a plain C struct for which all-zero bytes are a valid value.
    let mut startup: STARTUPINFOEXW = unsafe { zeroed() };
    startup.StartupInfo.cb = u32::try_from(size_of::<STARTUPINFOEXW>()).unwrap();
    startup.lpAttributeList = attributes.pointer();
    let application = wide(r"C:\Windows\System32\cmd.exe");
    let mut command = command_line(&[
        r"C:\Windows\System32\cmd.exe".to_owned(),
        "/c".to_owned(),
        "exit 0".to_owned(),
    ])
    .unwrap();
    // SAFETY: PROCESS_INFORMATION is a plain C struct for which all-zero bytes are a valid value.
    let mut information: PROCESS_INFORMATION = unsafe { zeroed() };
    assert_ne!(
        // SAFETY: application and command are live NUL-terminated UTF-16 buffers, `startup` and its attribute list outlive the call, and `information` is a live writable local.
        unsafe {
            CreateProcessW(
                application.as_ptr(),
                command.as_mut_ptr(),
                null(),
                null(),
                0,
                CREATE_SUSPENDED
                    | CREATE_NO_WINDOW
                    | CREATE_BREAKAWAY_FROM_JOB
                    | EXTENDED_STARTUPINFO_PRESENT,
                null(),
                null(),
                &raw const startup.StartupInfo,
                &raw mut information,
            )
        },
        0
    );
    let process = owned(information.hProcess, Refusal::Startup).unwrap();
    let _thread = owned(information.hThread, Refusal::Startup).unwrap();
    let identity = process_identity(&process).unwrap();
    let mut member = 0;
    assert_ne!(
        // SAFETY: both handles are owned and open, and `member` is a live writable local.
        unsafe { IsProcessInJob(raw(&process), raw(&job), &raw mut member) },
        0
    );
    assert_ne!(member, 0);
    assert_eq!(
        // SAFETY: the process handle is owned and open; a zero timeout never blocks.
        unsafe { WaitForSingleObject(raw(&process), 0) },
        WAIT_TIMEOUT
    );
    drop(attributes);
    drop(job);
    assert_eq!(
        // SAFETY: the process handle is owned and open, and the wait is bounded to five seconds.
        unsafe { WaitForSingleObject(raw(&process), 5000) },
        WAIT_OBJECT_0
    );
    assert_eq!(process_identity(&process).unwrap(), identity);
}

const TRUSTED_INSTALLER: &str = "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";

fn check_descriptor(sddl: &str, authority: FileAuthority) -> Result<(), Refusal> {
    let mut descriptor = null_mut();
    assert_ne!(
        // SAFETY: the temporary SDDL is a NUL-terminated UTF-16 string that lives until the end of the statement, and `descriptor` is a writable out-pointer.
        unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                wide(sddl).as_ptr(),
                1,
                &raw mut descriptor,
                null_mut(),
            )
        },
        0
    );
    // SAFETY: this descriptor is owned by this fixture and retained until
    // the same production validator has finished reading its owner/DACL.
    let result = unsafe { descriptor_acl(descriptor, authority) };
    // SAFETY: `descriptor` was allocated by ConvertStringSecurityDescriptorToSecurityDescriptorW and is freed exactly once after its last use.
    unsafe {
        LocalFree(descriptor);
    }
    result
}

#[test]
fn native_platform_authority_is_scoped_to_directories_and_ancestors() {
    let platform = format!(
        "O:{TRUSTED_INSTALLER}G:SYD:P(A;;FA;;;SY)(A;;FA;;;{TRUSTED_INSTALLER})(A;;GR;;;BU)"
    );
    for authority in [FileAuthority::Ancestor, FileAuthority::WorkerDirectory] {
        assert_eq!(check_descriptor(&platform, authority), Ok(()));
    }
    for authority in [FileAuthority::Package, FileAuthority::SystemOnly] {
        assert_eq!(
            check_descriptor(&platform, authority),
            Err(Refusal::Custody)
        );
    }
    let inherited_platform =
        format!("O:BAG:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;{TRUSTED_INSTALLER})(A;;GR;;;BU)");
    assert_eq!(
        check_descriptor(&inherited_platform, FileAuthority::WorkerDirectory),
        Ok(())
    );
    assert_eq!(
        check_descriptor(&inherited_platform, FileAuthority::Package),
        Err(Refusal::Custody)
    );
    let foreign_service = platform.replace("-2271478464", "-2271478465");
    for authority in [FileAuthority::Ancestor, FileAuthority::WorkerDirectory] {
        assert_eq!(
            check_descriptor(&foreign_service, authority),
            Err(Refusal::Custody)
        );
    }
}

#[test]
fn native_directory_custody_refuses_foreign_owners_and_write_authority() {
    for authority in [FileAuthority::Ancestor, FileAuthority::WorkerDirectory] {
        for descriptor in [
            "O:LSG:SYD:P(A;;FA;;;SY)",
            "O:SYG:SYD:P(A;;FA;;;SY)(A;;GW;;;BU)",
            "O:SYG:SYD:P(A;;FA;;;SY)(A;;WD;;;BU)",
            "O:SYG:SYD:P(A;;FA;;;SY)(A;;0x00000040;;;BU)",
            "O:SYG:SY",
            "O:SYG:SYD:P",
        ] {
            assert_eq!(
                check_descriptor(descriptor, authority),
                Err(Refusal::Custody),
                "{descriptor}"
            );
        }
    }
    let unrelated_children = "O:SYG:SYD:P(A;;FA;;;SY)(A;;0x00000006;;;BU)";
    assert_eq!(
        check_descriptor(unrelated_children, FileAuthority::Ancestor),
        Ok(())
    );
    assert_eq!(
        check_descriptor(unrelated_children, FileAuthority::WorkerDirectory),
        Err(Refusal::Custody)
    );
    assert_eq!(
        check_descriptor("O:SYG:SYD:P(A;;FA;;;SY)", FileAuthority::SystemOnly),
        Ok(())
    );
}
