//! Disposable NixOS control fixture; never installed by the production package.
use overalls_otel_guest_receiver::request_recorder::{
    self, Command, Envelope, Refusal, Reply, Terminal,
};
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::time::{Duration, Instant};

fn command(op: &str, id: Option<&String>) -> Result<Command, ()> {
    match op {
        "hello" => Ok(Command::Hello {}),
        "admit" => Ok(Command::Admit {}),
        "gap" => Ok(Command::Gap {}),
        "success" | "failure" | "exclude" => Ok(Command::Finish {
            id: id.ok_or(())?.parse().map_err(|_| ())?,
            duration_us: 100,
            outcome: match op {
                "success" => Terminal::Success,
                "failure" => Terminal::Failure,
                _ => Terminal::Exclude,
            },
        }),
        _ => Err(()),
    }
}

fn serve(recorder: &Path, control: &Path) -> Result<(), ()> {
    if control.exists() {
        std::fs::remove_file(control).map_err(|_| ())?;
    }
    let listener = UnixListener::bind(control).map_err(|_| ())?;
    listener.set_nonblocking(true).map_err(|_| ())?;
    #[expect(
        clippy::unchecked_time_subtraction,
        reason = "Linux Instant is a signed-seconds CLOCK_MONOTONIC timespec; subtracting one second cannot underflow"
    )]
    let mut heartbeat = Instant::now() - Duration::from_secs(1);
    loop {
        if heartbeat.elapsed() >= Duration::from_secs(1) {
            let _ = request_recorder::request(recorder, Command::Hello {});
            heartbeat = Instant::now();
        }
        match listener.accept() {
            Ok((mut stream, _)) => {
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .map_err(|_| ())?;
                let reply = match request_recorder::read_frame(&mut stream) {
                    Ok(envelope) => request_recorder::request(recorder, envelope.command)
                        .unwrap_or(Reply::Refused {
                            reason: Refusal::Storage,
                        }),
                    Err(reason) => Reply::Refused { reason },
                };
                request_recorder::write_frame(&mut stream, &reply).map_err(|_| ())?;
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(_) => return Err(()),
        }
    }
}

fn run() -> Result<(), ()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [mode, recorder, control] if mode == "serve" => {
            serve(Path::new(recorder), Path::new(control))
        }
        [mode, path, op, rest @ ..] if mode == "call" || mode == "probe" => {
            let command = command(op, rest.first())?;
            let reply = if mode == "probe" {
                request_recorder::request(Path::new(path), command).map_err(|_| ())?
            } else {
                // A fixture control socket carries the production frame schema;
                // the fixture process makes the authenticated recorder connection.
                let mut stream = UnixStream::connect(path).map_err(|_| ())?;
                stream
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .map_err(|_| ())?;
                let bytes = serde_json::to_vec(&Envelope {
                    version: 1,
                    command,
                })
                .map_err(|_| ())?;
                stream
                    .write_all(&u32::try_from(bytes.len()).map_err(|_| ())?.to_be_bytes())
                    .and_then(|()| stream.write_all(&bytes))
                    .map_err(|_| ())?;
                let mut header = [0_u8; 4];
                stream.read_exact(&mut header).map_err(|_| ())?;
                let length = u32::from_be_bytes(header) as usize;
                if length == 0 || length > 512 {
                    return Err(());
                }
                let mut bytes = vec![0_u8; length];
                stream.read_exact(&mut bytes).map_err(|_| ())?;
                serde_json::from_slice::<Reply>(&bytes).map_err(|_| ())?
            };
            println!("{}", serde_json::to_string(&reply).map_err(|_| ())?);
            if mode == "probe" && matches!(reply, Reply::Refused { .. }) {
                Err(())
            } else {
                Ok(())
            }
        }
        _ => Err(()),
    }
}
fn main() {
    if run().is_err() {
        std::process::exit(2);
    }
}
