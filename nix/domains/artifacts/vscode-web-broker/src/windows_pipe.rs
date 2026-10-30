//! Bounded overlapped I/O for the retained Windows named pipe.
//!
//! Kernel operations use owned completion storage and copied buffers. A timed
//! out pipe is retired into one bounded process-wide drain queue; a single
//! reaper retains every resource until the kernel reports completion.

use crate::windows_model::{PipeSlot, PipeSlots};
use std::cell::UnsafeCell;
use std::fs::File;
use std::io::{self, Read, Write};
use std::mem::zeroed;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{
    ERROR_IO_INCOMPLETE, ERROR_IO_PENDING, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::Storage::FileSystem::{ReadFile, WriteFile};
use windows_sys::Win32::System::IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED};
use windows_sys::Win32::System::Threading::{CreateEventW, ResetEvent, WaitForSingleObject};

const OPERATION_TIMEOUT: Duration = Duration::from_secs(30);
const BUFFER_LIMIT: usize = 64 * 1024;
static SLOTS: PipeSlots = PipeSlots::new();
static RETIRED: Mutex<Vec<Pending>> = Mutex::new(Vec::new());
static REAPER: OnceLock<io::Result<()>> = OnceLock::new();

#[derive(Debug)]
struct Resources {
    file: File,
    event: OwnedHandle,
    _reservation: PipeSlot<'static>,
}

struct Operation {
    overlapped: Box<UnsafeCell<OVERLAPPED>>,
    buffer: Box<UnsafeCell<[u8; BUFFER_LIMIT]>>,
    length: usize,
}

struct Pending {
    resources: Resources,
    operation: Operation,
}

// SAFETY: all pointers in OVERLAPPED refer to its owned event or kernel state.
// The Box and buffer allocations never move or resize, and no other thread
// accesses these resources after transfer to the exclusively locked queue.
unsafe impl Send for Pending {}

impl Pending {
    fn completed(&self) -> bool {
        !matches!(self.operation.result(&self.resources), Ok(None))
    }
}

impl Operation {
    fn result(&self, resources: &Resources) -> io::Result<Option<usize>> {
        let mut transferred = 0;
        // SAFETY: the file handle is open, `overlapped` is this operation's owned boxed OVERLAPPED, and `transferred` is a live local; bWait is 0 so the call never blocks.
        if unsafe {
            GetOverlappedResult(
                resources.file.as_raw_handle(),
                self.overlapped.get(),
                &raw mut transferred,
                0,
            )
        } != 0
        {
            if transferred as usize > self.length {
                return Err(io::Error::other("invalid pipe completion length"));
            }
            Ok(Some(transferred as usize))
        } else {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(ERROR_IO_INCOMPLETE.cast_signed()) {
                Ok(None)
            } else {
                // Every error other than IO_INCOMPLETE describes a completed
                // operation, including OPERATION_ABORTED after cancellation.
                Err(error)
            }
        }
    }
}

fn drain() {
    let mut retired = RETIRED
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    retired.retain(|pending| !pending.completed());
}

fn ensure_reaper() -> io::Result<()> {
    match REAPER.get_or_init(|| {
        thread::Builder::new()
            .name("editor-pipe-drain".to_owned())
            .spawn(|| {
                loop {
                    drain();
                    thread::sleep(Duration::from_millis(10));
                }
            })
            .map(|_| ())
    }) {
        Ok(()) => Ok(()),
        Err(_) => Err(io::Error::other("pipe completion reaper unavailable")),
    }
}

enum Direction<'a> {
    Read(&'a mut [u8]),
    Write(&'a [u8]),
}

#[derive(Clone, Copy)]
enum CompletionWait<'a> {
    Deadline(Instant),
    Relay(&'a AtomicBool),
}

impl CompletionWait<'_> {
    fn interval(&self) -> io::Result<Duration> {
        match self {
            Self::Deadline(deadline) => {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "pipe operation deadline elapsed",
                    ))
                } else {
                    Ok(remaining)
                }
            }
            Self::Relay(cancelled) if cancelled.load(Ordering::Acquire) => Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "pipe relay stopped",
            )),
            Self::Relay(_) => Ok(Duration::from_millis(100)),
        }
    }
}

/// A connected pipe. A timed-out instance is closed to further operations.
#[derive(Debug)]
pub struct Pipe {
    resources: Option<Resources>,
}

impl Pipe {
    /// Reserve bounded kernel-resource custody before opening or duplicating a
    /// pipe. Cancelled operations retain this reservation until completion.
    pub fn reserve() -> io::Result<PipeSlot<'static>> {
        ensure_reaper()?;
        drain();
        SLOTS
            .reserve()
            .ok_or_else(|| io::Error::other("pipe capacity exhausted"))
    }

    pub fn from_file(file: File, reservation: PipeSlot<'static>) -> io::Result<Self> {
        // SAFETY: null security attributes and name request an unnamed, non-inheritable manual-reset event.
        let event = unsafe { CreateEventW(null(), 1, 0, null()) };
        if event.is_null() || event == windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: CreateEventW returned a newly owned event handle.
        let event = unsafe { OwnedHandle::from_raw_handle(event) };
        Ok(Self {
            resources: Some(Resources {
                file,
                event,
                _reservation: reservation,
            }),
        })
    }

    pub fn raw_handle(&self) -> io::Result<std::os::windows::io::RawHandle> {
        Ok(self.resources()?.file.as_raw_handle())
    }

    /// The listener owns bounded OVERLAPPED storage until local connect completes.
    /// A failed wait retires the exact operation before returning.
    pub fn accept(&mut self) -> io::Result<()> {
        use windows_sys::Win32::Foundation::ERROR_PIPE_CONNECTED;
        use windows_sys::Win32::System::Pipes::ConnectNamedPipe;
        let resources = self.resources()?;
        // SAFETY: OVERLAPPED is a plain C struct for which all-zero bytes are a valid value.
        let mut overlapped: OVERLAPPED = unsafe { zeroed() };
        overlapped.hEvent = resources.event.as_raw_handle();
        #[expect(
            clippy::large_stack_arrays,
            reason = "the 64 KiB buffer is a temporary before boxing on a 1 MiB or larger thread stack"
        )]
        let operation = Operation {
            overlapped: Box::new(UnsafeCell::new(overlapped)),
            buffer: Box::new(UnsafeCell::new([0; BUFFER_LIMIT])),
            length: 0,
        };
        // SAFETY: the listener handle is open and the boxed OVERLAPPED stays owned until completion or retirement.
        if unsafe { ConnectNamedPipe(resources.file.as_raw_handle(), operation.overlapped.get()) }
            != 0
        {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(ERROR_PIPE_CONNECTED.cast_signed()) {
            return Ok(());
        }
        if error.raw_os_error() != Some(ERROR_IO_PENDING.cast_signed()) {
            return Err(error);
        }
        loop {
            // SAFETY: the event handle is owned by `resources` and remains open for the wait.
            match unsafe { WaitForSingleObject(resources.event.as_raw_handle(), 100) } {
                WAIT_TIMEOUT => {}
                WAIT_OBJECT_0 => match operation.result(resources) {
                    Ok(Some(_)) => return Ok(()),
                    Err(error) => return Err(error),
                    Ok(None) => {}
                },
                _ => {
                    let error = io::Error::last_os_error();
                    self.cancel_and_retire(operation);
                    return Err(error);
                }
            }
        }
    }

    fn resources(&self) -> io::Result<&Resources> {
        self.resources
            .as_ref()
            .ok_or_else(|| io::Error::new(io::ErrorKind::BrokenPipe, "pipe operation was retired"))
    }

    /// Each relay direction has a distinct completion event and reservation.
    pub fn try_clone(&self) -> io::Result<Self> {
        let reservation = Self::reserve()?;
        Self::from_file(self.resources()?.file.try_clone()?, reservation)
    }

    /// @cc [owner:ghuntley,label:security;recovery] windows-editor-pipe-owned-completion
    /// Kernel I/O MUST reference only owned stable completion storage and at
    /// most 64 KiB of owned buffer, never caller storage. A timeout MUST cancel
    /// and retire the pipe without an unbounded wait. Pending storage, buffer,
    /// event, file handle and capacity reservation MUST remain owned until a
    /// nonblocking completion check reports success or a terminal I/O error.
    fn operation(
        &mut self,
        direction: Direction<'_>,
        wait: CompletionWait<'_>,
    ) -> io::Result<usize> {
        let length = match &direction {
            Direction::Read(buffer) => buffer.len(),
            Direction::Write(buffer) => buffer.len(),
        }
        .min(BUFFER_LIMIT);
        #[expect(
            clippy::cast_possible_truncation,
            reason = "length is at most BUFFER_LIMIT (64 KiB)"
        )]
        let kernel_length = length as u32;
        if length == 0 {
            return Ok(0);
        }
        wait.interval()?;
        let resources = self.resources()?;
        // SAFETY: the event handle is owned by `resources` and remains open.
        if unsafe { ResetEvent(resources.event.as_raw_handle()) } == 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: OVERLAPPED is a plain C struct for which all-zero bytes are a valid value.
        let mut overlapped: OVERLAPPED = unsafe { zeroed() };
        overlapped.hEvent = resources.event.as_raw_handle();
        #[expect(
            clippy::large_stack_arrays,
            reason = "the 64 KiB buffer is a temporary before boxing on a 1 MiB or larger thread stack"
        )]
        let operation = Operation {
            overlapped: Box::new(UnsafeCell::new(overlapped)),
            buffer: Box::new(UnsafeCell::new([0; BUFFER_LIMIT])),
            length,
        };
        let started = match &direction {
            Direction::Write(buffer) => {
                // SAFETY: no I/O has started; this operation exclusively owns
                // the allocation and writes only its bounded prefix.
                unsafe {
                    (&mut *operation.buffer.get())[..length].copy_from_slice(&buffer[..length]);
                }
                // SAFETY: the stable buffer and OVERLAPPED are retained through
                // completion, including after cancellation and caller return.
                unsafe {
                    WriteFile(
                        resources.file.as_raw_handle(),
                        operation.buffer.get().cast(),
                        kernel_length,
                        null_mut(),
                        operation.overlapped.get(),
                    )
                }
            }
            // SAFETY: the stable boxed buffer and OVERLAPPED are retained through completion, including after cancellation and caller return; `length` is at most the buffer size.
            Direction::Read(_) => unsafe {
                ReadFile(
                    resources.file.as_raw_handle(),
                    operation.buffer.get().cast(),
                    kernel_length,
                    null_mut(),
                    operation.overlapped.get(),
                )
            },
        };
        if started == 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(ERROR_IO_PENDING.cast_signed()) {
                return Err(error);
            }
            loop {
                let interval = match wait.interval() {
                    Ok(interval) => interval,
                    Err(error) => {
                        self.cancel_and_retire(operation);
                        return Err(error);
                    }
                };
                #[expect(
                    clippy::cast_possible_truncation,
                    reason = "clamped to at most u32::MAX - 1"
                )]
                let milliseconds = interval.as_millis().clamp(1, u128::from(u32::MAX - 1)) as u32;
                // SAFETY: the event handle is owned by `resources` and remains open for the wait.
                match unsafe { WaitForSingleObject(resources.event.as_raw_handle(), milliseconds) }
                {
                    WAIT_OBJECT_0 => break,
                    WAIT_TIMEOUT => {}
                    _ => {
                        let error = io::Error::last_os_error();
                        self.cancel_and_retire(operation);
                        return Err(error);
                    }
                }
            }
        }
        match operation.result(resources) {
            Ok(Some(transferred)) => {
                if let Direction::Read(buffer) = direction {
                    // SAFETY: the kernel reported completion, so it no longer
                    // writes the owned buffer. Only the completed prefix is read.
                    buffer[..transferred]
                        .copy_from_slice(unsafe { &(&*operation.buffer.get())[..transferred] });
                }
                Ok(transferred)
            }
            Ok(None) => {
                // A stale/spurious signal cannot release an incomplete request.
                self.cancel_and_retire(operation);
                Err(io::Error::other("pipe completion unavailable"))
            }
            Err(error) => Err(error),
        }
    }

    fn cancel_and_retire(&mut self, operation: Operation) {
        let Some(resources) = self.resources.take() else {
            return;
        };
        // SAFETY: cancellation names the exact retained operation. Cancellation
        // failure does not prove completion and cannot release its resources.
        unsafe {
            let _ = CancelIoEx(resources.file.as_raw_handle(), operation.overlapped.get());
        }
        let pending = Pending {
            resources,
            operation,
        };
        if !pending.completed() {
            // Every entry retains one of the 128 reservations acquired before
            // opening its handle. No operation starts without that reservation,
            // so this queue and its one reaper cannot grow per request.
            RETIRED
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push(pending);
        }
    }

    pub fn read_deadline(&mut self, buffer: &mut [u8], deadline: Instant) -> io::Result<usize> {
        self.operation(
            Direction::Read(buffer),
            CompletionWait::Deadline(deadline.min(Instant::now() + OPERATION_TIMEOUT)),
        )
    }

    pub fn write_deadline(&mut self, buffer: &[u8], deadline: Instant) -> io::Result<usize> {
        self.operation(
            Direction::Write(buffer),
            CompletionWait::Deadline(deadline.min(Instant::now() + OPERATION_TIMEOUT)),
        )
    }

    /// @cc [owner:ghuntley,label:recovery] windows-editor-idle-relay-lifetime
    /// A healthy silent browser relay MUST remain connected without an idle
    /// read timeout. Its overlapped read MUST poll shutdown at most every 100ms
    /// and retire/cancel owned kernel storage when either relay direction ends.
    /// Worker pipe loss MUST still complete or fail the retained operation.
    pub fn read_until_cancelled(
        &mut self,
        buffer: &mut [u8],
        cancelled: &AtomicBool,
    ) -> io::Result<usize> {
        self.operation(Direction::Read(buffer), CompletionWait::Relay(cancelled))
    }
}

impl Read for Pipe {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        self.read_deadline(buffer, Instant::now() + OPERATION_TIMEOUT)
    }
}

impl Write for Pipe {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.write_deadline(buffer, Instant::now() + OPERATION_TIMEOUT)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::OpenOptions;
    use std::os::windows::fs::OpenOptionsExt;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use windows_sys::Win32::Foundation::{
        ERROR_PIPE_CONNECTED, GetLastError, INVALID_HANDLE_VALUE,
    };
    use windows_sys::Win32::Storage::FileSystem::{FILE_FLAG_OVERLAPPED, PIPE_ACCESS_DUPLEX};
    use windows_sys::Win32::System::Pipes::{
        ConnectNamedPipe, CreateNamedPipeW, PIPE_READMODE_BYTE, PIPE_TYPE_BYTE, PIPE_WAIT,
    };

    fn connected() -> (Pipe, File) {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let reservation = Pipe::reserve().unwrap();
        let name = format!(
            r"\\.\pipe\overalls-editor-io-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        let wide: Vec<u16> = name.encode_utf16().chain([0]).collect();
        // SAFETY: the name is a live NUL-terminated UTF-16 string and null security attributes are permitted.
        let server = unsafe {
            CreateNamedPipeW(
                wide.as_ptr(),
                PIPE_ACCESS_DUPLEX,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                1,
                u32::try_from(BUFFER_LIMIT).unwrap(),
                u32::try_from(BUFFER_LIMIT).unwrap(),
                0,
                null(),
            )
        };
        assert_ne!(server, INVALID_HANDLE_VALUE);
        assert!(!server.is_null());
        // SAFETY: CreateNamedPipeW returned the newly owned synchronous handle.
        let server = unsafe { File::from_raw_handle(server) };
        let client = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(FILE_FLAG_OVERLAPPED)
            .open(name)
            .unwrap();
        assert!(
            // SAFETY: the server handle is a live synchronous pipe, so a null OVERLAPPED is permitted.
            unsafe { ConnectNamedPipe(server.as_raw_handle(), null_mut()) } != 0
                // SAFETY: GetLastError only reads this thread's last-error value.
                || unsafe { GetLastError() } == ERROR_PIPE_CONNECTED
        );
        (Pipe::from_file(client, reservation).unwrap(), server)
    }

    #[test]
    fn native_pipe_copies_completed_bytes_and_retires_timeout_without_caller_storage() {
        let (mut pipe, mut server) = connected();
        server.write_all(b"worker").unwrap();
        let mut received = [0_u8; 6];
        pipe.read_exact(&mut received).unwrap();
        assert_eq!(&received, b"worker");
        pipe.write_all(b"client").unwrap();
        server.read_exact(&mut received).unwrap();
        assert_eq!(&received, b"client");

        let mut caller = [17_u8; 8];
        let started = Instant::now();
        assert_eq!(
            pipe.read_deadline(&mut caller, started + Duration::from_millis(30))
                .unwrap_err()
                .kind(),
            io::ErrorKind::TimedOut
        );
        assert!(started.elapsed() < Duration::from_secs(2));
        assert_eq!(caller, [17_u8; 8]);
        assert_eq!(
            pipe.read(&mut caller).unwrap_err().kind(),
            io::ErrorKind::BrokenPipe
        );
        drop(server);
        drain();
    }

    #[test]
    fn native_idle_relay_read_waits_for_bytes_or_explicit_shutdown() {
        let (mut pipe, mut server) = connected();
        let cancelled = AtomicBool::new(false);
        let mut received = [0_u8; 6];
        thread::scope(|scope| {
            scope.spawn(|| {
                thread::sleep(Duration::from_millis(150));
                server.write_all(b"worker").unwrap();
            });
            assert_eq!(
                pipe.read_until_cancelled(&mut received, &cancelled)
                    .unwrap(),
                6
            );
        });
        assert_eq!(&received, b"worker");
        let mut caller = [17_u8; 8];
        let started = Instant::now();
        thread::scope(|scope| {
            scope.spawn(|| {
                thread::sleep(Duration::from_millis(150));
                cancelled.store(true, Ordering::Release);
            });
            assert_eq!(
                pipe.read_until_cancelled(&mut caller, &cancelled)
                    .unwrap_err()
                    .kind(),
                io::ErrorKind::Interrupted
            );
        });
        assert!(started.elapsed() < Duration::from_secs(2));
        assert_eq!(caller, [17_u8; 8]);
        assert_eq!(
            pipe.read(&mut caller).unwrap_err().kind(),
            io::ErrorKind::BrokenPipe
        );
        drop(server);
        drain();
    }
}
