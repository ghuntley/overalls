//! Reviewed native account utility dialects and private SSH runtime locations.

use std::path::PathBuf;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Platform {
    Linux,
    FreeBsd,
    Illumos,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Invocation {
    pub program: &'static str,
    pub arguments: Vec<String>,
}

fn command(program: &'static str, arguments: &[&str]) -> Invocation {
    Invocation {
        program,
        arguments: arguments
            .iter()
            .map(|argument| (*argument).to_owned())
            .collect(),
    }
}

impl Platform {
    pub const fn current() -> Self {
        if cfg!(target_os = "freebsd") {
            Self::FreeBsd
        } else if cfg!(any(target_os = "illumos", target_os = "solaris")) {
            Self::Illumos
        } else {
            Self::Linux
        }
    }

    pub const fn shell(self) -> &'static str {
        if matches!(self, Self::FreeBsd) {
            "usr/local/bin/bash"
        } else {
            "bin/bash"
        }
    }

    pub const fn home_root(self) -> &'static str {
        if matches!(self, Self::Illumos) {
            "/export/home"
        } else {
            "/home"
        }
    }

    pub const fn sudoers(self) -> &'static str {
        if matches!(self, Self::FreeBsd) {
            "/usr/local/etc/sudoers.d"
        } else {
            "/etc/sudoers.d"
        }
    }

    pub const fn lock(self) -> &'static str {
        if matches!(self, Self::Linux) {
            "/run/overalls-accounts.lock"
        } else {
            "/var/run/overalls/overalls-accounts.lock"
        }
    }

    pub const fn host_keys(self) -> &'static str {
        if matches!(self, Self::Linux) {
            "/run/overalls-ssh-host"
        } else {
            "/var/run/overalls/ssh-host"
        }
    }

    pub fn home(self, username: &str) -> PathBuf {
        PathBuf::from(self.home_root()).join(username)
    }

    pub fn create_group(self, username: &str, uid: u32) -> Invocation {
        let uid = uid.to_string();
        match self {
            Self::Linux => command("groupadd", &["--gid", &uid, "--", username]),
            Self::FreeBsd => command("/usr/sbin/pw", &["groupadd", username, "-g", &uid]),
            Self::Illumos => command("/usr/sbin/groupadd", &["-g", &uid, username]),
        }
    }

    /// @cc [owner:ghuntley,label:security] native-account-passwordless-key-only
    /// Native account creation and activation MUST use the selected OS's own
    /// utility dialect and keep password login unusable. Managed usernames,
    /// UIDs, home and executable Bash MUST be validated before these commands
    /// run; native arguments MUST NOT use GNU long options or option delimiters.
    pub fn create_user(self, username: &str, uid: u32, home: &str, shell: &str) -> Invocation {
        let uid = uid.to_string();
        match self {
            Self::Linux => command(
                "useradd",
                &[
                    "--create-home",
                    "--home-dir",
                    home,
                    "--uid",
                    &uid,
                    "--gid",
                    username,
                    "--shell",
                    shell,
                    "--",
                    username,
                ],
            ),
            Self::FreeBsd => command(
                "/usr/sbin/pw",
                &[
                    "useradd", username, "-u", &uid, "-g", &uid, "-d", home, "-m", "-s", shell,
                    "-w", "no",
                ],
            ),
            Self::Illumos => command(
                "/usr/sbin/useradd",
                &[
                    // Homes belong to the guest disk lifecycle. Never let the
                    // host's MANAGE_ZFS default create a separate user dataset.
                    "-m", "-Z", "-d", home, "-u", &uid, "-g", &uid, "-s", shell, username,
                ],
            ),
        }
    }

    pub fn activate(self, username: &str, shell: &str) -> Vec<Invocation> {
        match self {
            Self::Linux => vec![command(
                "usermod",
                &["--expiredate", "", "--shell", shell, "--", username],
            )],
            Self::FreeBsd => vec![command(
                "/usr/sbin/pw",
                &["usermod", username, "-e", "0", "-s", shell, "-w", "no"],
            )],
            Self::Illumos => vec![
                command("/usr/sbin/usermod", &["-e", "", "-s", shell, username]),
                // Local passwd -N leaves a non-password account usable for
                // key auth. Never use -d, which would permit an empty password.
                command("/usr/bin/passwd", &["-r", "files", "-N", username]),
            ],
        }
    }

    /// @cc [owner:ghuntley,label:security;recovery] native-account-retirement-preserves-home
    /// Native retirement MUST expire or lock the account and set a noninteractive shell;
    /// it MUST NOT delete the account or home. Reactivation MUST clear expiry
    /// and restore the validated Bash without enabling password authentication.
    pub fn deactivate(self, username: &str, linux_nologin: &str) -> Vec<Invocation> {
        match self {
            Self::Linux => vec![command(
                "usermod",
                &[
                    "--expiredate",
                    "1",
                    "--shell",
                    linux_nologin,
                    "--",
                    username,
                ],
            )],
            Self::FreeBsd => vec![command(
                "/usr/sbin/pw",
                &["usermod", username, "-e", "1", "-s", "/usr/sbin/nologin"],
            )],
            // illumos forbids past expiry, and passwd -l deliberately leaves
            // its NP no-password marker unchanged. The reviewed local-file
            // account utility atomically sets the fixed lock marker and shell.
            Self::Illumos => vec![command(
                "/usr/lib/passmgmt",
                &["-m", "-p", "*LK*", "-s", "/usr/bin/false", username],
            )],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_dialects_preserve_identity_and_never_delete_homes() {
        for os in [Platform::FreeBsd, Platform::Illumos] {
            let home = os.home("u200001");
            let home = home.to_str().unwrap();
            let shell = format!("/{}", os.shell());
            let create = os.create_user("u200001", 200_001, home, &shell);
            assert!(create.arguments.contains(&"200001".to_owned()));
            assert!(create.arguments.contains(&home.to_owned()));
            assert!(create.arguments.contains(&shell));
            let retired = os.deactivate("u200001", "/unused");
            for invocation in &retired {
                assert!(!invocation.program.contains("del"));
                assert!(!invocation.arguments.contains(&"-r".to_owned()));
            }
            for action in std::iter::once(create)
                .chain(os.activate("u200001", &shell))
                .chain(retired)
                .chain([os.create_group("u200001", 200_001)])
            {
                assert!(action.program.starts_with('/'));
                assert!(action
                    .arguments
                    .iter()
                    .all(|argument| !argument.starts_with("--")));
            }
        }
    }

    #[test]
    fn native_paths_are_volatile_or_native_package_locations() {
        assert_eq!(Platform::FreeBsd.shell(), "usr/local/bin/bash");
        assert_eq!(Platform::FreeBsd.sudoers(), "/usr/local/etc/sudoers.d");
        assert_eq!(
            Platform::Illumos.home("u200001"),
            PathBuf::from("/export/home/u200001")
        );
        for os in [Platform::FreeBsd, Platform::Illumos] {
            assert!(os.lock().starts_with("/var/run/overalls/"));
            assert!(os.host_keys().starts_with("/var/run/overalls/"));
        }
    }

    #[test]
    fn native_reactivation_does_not_use_password_unlock_or_empty_password() {
        assert!(Platform::Illumos
            .create_user("u200001", 200_001, "/export/home/u200001", "/bin/bash")
            .arguments
            .windows(2)
            .any(|pair| pair == ["-m", "-Z"]));
        let actions = Platform::Illumos.activate("u200001", "/bin/bash");
        assert_eq!(
            actions[0].arguments,
            ["-e", "", "-s", "/bin/bash", "u200001"]
        );
        assert_eq!(
            actions[1],
            command("/usr/bin/passwd", &["-r", "files", "-N", "u200001"])
        );
        let retired = Platform::Illumos.deactivate("u200001", "/unused");
        assert_eq!(
            retired[0],
            command(
                "/usr/lib/passmgmt",
                &["-m", "-p", "*LK*", "-s", "/usr/bin/false", "u200001"]
            )
        );
        let actions = Platform::FreeBsd.activate("u200001", "/usr/local/bin/bash");
        assert!(actions[0]
            .arguments
            .windows(2)
            .any(|pair| pair == ["-w", "no"]));
    }
}
