mod agent_cli;
mod config;
mod guest_host;
use lyra::http;
mod log;
mod open_cli;
mod proxy;
mod ssh_config;
mod telemetry;
mod trust;
mod update;

use clap::{Parser, Subcommand};
use std::process::ExitCode;

#[derive(Parser)]
#[command(name = "overalls", version, about = "Connect to Overalls machines")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Agent {
        #[arg(long)]
        machine: String,
        #[arg(long)]
        thread: Option<String>,
    },
    #[command(hide = true)]
    AgentExecutor,
    #[command(hide = true)]
    AgentSupervisor,
    ConfigSsh {
        #[arg(long)]
        origin: String,
        #[arg(long)]
        zone: String,
        #[arg(long, hide = true)]
        staged_installer: bool,
        /// Absolute path of the OpenSSH client to use (Windows installers pass
        /// a client newer than the in-box one).
        #[arg(long)]
        ssh: Option<std::path::PathBuf>,
    },
    /// SSH to a machine with the OpenSSH client recorded by `config-ssh`.
    Ssh {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true, required = true)]
        args: Vec<std::ffi::OsString>,
    },
    Proxy {
        #[arg(long)]
        host: String,
        #[arg(long)]
        identity: String,
    },
    #[command(hide = true)]
    HostKey {
        #[arg(long)]
        url: String,
        #[arg(long)]
        host: String,
        #[arg(long)]
        allow_multiple: bool,
    },
    Update {
        #[command(subcommand)]
        command: Option<UpdateCommand>,
    },
    Version,
    Logs {
        #[command(subcommand)]
        command: LogsCommand,
    },
    /// Create a machine that clones a public GitHub, GitLab, Codeberg or Bitbucket repository, then SSH into it.
    Open {
        /// <https://github.com/OWNER/REPO>[/tree/BRANCH|/commit/SHA|/pull/N]
        url: String,
        /// Command to run in the checkout instead of a login shell.
        #[arg(last = true)]
        command: Vec<String>,
    },
    #[command(hide = true)]
    UpdateWorker,
}

#[derive(Subcommand)]
enum UpdateCommand {
    Status,
}

#[derive(Subcommand)]
enum LogsCommand {
    Path,
}

#[expect(
    clippy::too_many_lines,
    reason = "flat top-level command dispatch; each arm delegates to a module"
)]
fn run() -> Result<i32, &'static str> {
    if let Some(code) = lyra::agent::maintenance::run_tool() {
        return Ok(code);
    }
    if let Some(code) = lyra::agent::maintenance::bootstrap_invocation() {
        return Ok(code);
    }
    if std::env::args_os()
        .nth(1)
        .is_some_and(|arg| arg == "__update-worker")
    {
        update::worker();
        return Ok(0);
    }
    let cli = Cli::parse();
    if matches!(&cli.command, Command::AgentExecutor) {
        return lyra::agent::run(&guest_host::Guest).map_err(|_| "agent executor unavailable");
    }
    if matches!(&cli.command, Command::AgentSupervisor) {
        return update::supervise().map_err(|_| "agent supervisor unavailable");
    }
    if let Command::HostKey {
        url,
        host,
        allow_multiple,
    } = &cli.command
    {
        proxy::print_host_key(url, host, *allow_multiple)
            .map_err(|_| "SSH host key unavailable")?;
        return Ok(0);
    }
    // @cc [owner:ghuntley,label:security] lyra-staged-installer-authority
    // Staged installer setup MUST execute this downloaded binary's configuration
    // without delegating to or updating an installed binary. Only successful
    // setup permits the outer installer to replace the managed executable.
    if !matches!(
        &cli.command,
        Command::ConfigSsh {
            staged_installer: true,
            ..
        }
    ) {
        update::startup().map_err(|_| "CLI startup failed")?;
        if !config::guest_root() || matches!(&cli.command, Command::Update { command: None }) {
            let _ = update::spawn_check();
        }
    }
    match cli.command {
        Command::Agent { machine, thread } => agent_cli::run(&machine, thread.as_deref()),
        Command::AgentExecutor => {
            lyra::agent::run(&guest_host::Guest).map_err(|_| "agent executor unavailable")
        }
        Command::AgentSupervisor => update::supervise().map_err(|_| "agent supervisor unavailable"),
        Command::ConfigSsh {
            origin, zone, ssh, ..
        } => {
            ssh_config::install(origin, zone, ssh).map_err(|_| "SSH configuration failed")?;
            println!("SSH configuration installed");
            Ok(0)
        }
        Command::Ssh { args } => {
            let program = config::ssh_program(config::load().ok().as_ref());
            let status = std::process::Command::new(program)
                .args(args)
                .status()
                .map_err(|_| "OpenSSH client unavailable")?;
            Ok(status.code().unwrap_or(1))
        }
        Command::Proxy { host, identity } => {
            proxy::run(&host, &identity).map_err(|_| "SSH proxy unavailable")
        }
        Command::HostKey { .. } => unreachable!("handled before update startup"),
        Command::Update {
            command: Some(UpdateCommand::Status),
        } => {
            let status = update::status().map_err(|_| "Update status unavailable")?;
            println!(
                "installed: {}\nstaged: {}\nlast check: {}",
                status.installed,
                status.staged.as_deref().unwrap_or("none"),
                status.last_check.as_deref().unwrap_or("pending")
            );
            Ok(0)
        }
        Command::Update { command: None } => {
            println!("Checking for updates in the background. Run `overalls update status` for the result.");
            Ok(0)
        }
        Command::Version => {
            println!("{}", env!("CARGO_PKG_VERSION"));
            Ok(0)
        }
        Command::Logs {
            command: LogsCommand::Path,
        } => {
            println!(
                "{}",
                log::path().map_err(|_| "Log path unavailable")?.display()
            );
            Ok(0)
        }
        Command::UpdateWorker => {
            update::worker();
            Ok(0)
        }
        Command::Open { url, command } => open_cli::run(&url, &command),
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(code) => ExitCode::from(u8::try_from(code).unwrap_or(1)),
        Err(message) => {
            eprintln!("overalls: {message}");
            ExitCode::FAILURE
        }
    }
}
