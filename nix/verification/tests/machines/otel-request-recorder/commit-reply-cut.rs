// Test-only expression inserted at the production apply/reply boundary.
// @cc [owner:ghuntley,label:verification;durability] recorder-cut-after-real-commit
// The cut MUST occur only after production apply accepts a real authenticated
// command and before writing its reply. It MUST NOT modify accounting or peer
// identity. The fixture MUST observe the stopped process before claiming reach.
Ok(envelope) => {
    let operation: &str = match &envelope.command {
        Command::Hello {} => "hello",
        Command::Admit {} => "admit",
        Command::Gap {} => "gap",
        Command::Finish { .. } => "finish",
    };
    let reply: Reply = runtime.apply(producer, envelope.command, now_ns()?);
    let arm: PathBuf = config.socket.with_extension("commit-reply-arm");
    if std::fs::read_to_string(&arm).is_ok_and(|armed| armed == operation)
        && !matches!(reply, Reply::Refused { .. })
    {
        std::fs::remove_file(&arm).map_err(|_| Refusal::Storage)?;
        let reached: PathBuf = config.socket.with_extension("commit-reply-reached");
        let mut witness: File = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(reached)
            .map_err(|_| Refusal::Storage)?;
        witness.write_all(operation.as_bytes()).map_err(|_| Refusal::Storage)?;
        witness.sync_all().map_err(|_| Refusal::Storage)?;
        // SAFETY: raise(3) takes a signal number by value and reads no memory.
        if unsafe { libc::raise(libc::SIGSTOP) } != 0 {
            return Err(Refusal::Storage);
        }
    }
    reply
},
