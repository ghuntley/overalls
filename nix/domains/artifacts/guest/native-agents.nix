{ pkgs, lyra, terminald, githubTools ? import ./github { inherit pkgs; } }:
let
  bootstrap = import ./native-bootstrap.nix { inherit pkgs lyra; };
  nativeGit = import ./native-git.nix { inherit pkgs; };
  # @cc [owner:ghuntley,label:security] native-agent-set-complete
  # Every binary listed here MUST be cross-built for the selected native OS;
  # the image builder MUST never copy the Linux Lyra closure into a native
  # root. Probe and trust listeners MUST start before roster/certificate
  # bootstrap; readiness MUST remain false until the complete live service set,
  # including sshd, exists on the host-only vsock channel.
  binaries = [
    "overalls-native-bootstrap"
    "overalls-native-grow-root"
    "overalls-native-kernel-probed"
    "overalls-native-agentd"
    "overalls-native-flushd"
    "overalls-native-readinessd"
    "overalls-native-trustd"
    "overalls-native-workspaced"
    "overalls-ssh-authorize"
    "overalls-host-certificate"
  ];
  # @cc [owner:ghuntley,label:verification;recovery] native-supervisor-process-markers
  # Each supervised daemon MUST atomically publish its child PID as decimal
  # digits and one newline under /var/run/overalls, remove the marker when
  # reaping that child, and restart unexpected exits. A new supervisor MUST
  # remove markers left by an abruptly terminated predecessor before launching
  # children. Readiness MUST also check that the PID lives; marker presence
  # alone is insufficient. Supervisor shutdown MUST terminate its watchers and
  # their daemon children.
  supervised = [
    "overalls-native-kernel-probed"
    "overalls-native-agentd"
    "overalls-native-flushd"
    "overalls-native-readinessd"
    "overalls-native-trustd"
    "overalls-native-workspaced"
    "lilly-terminald"
  ];
  copy = os: assert builtins.elem os [ "freebsd" "illumos" ]; pkgs.runCommand "overalls-${os}-guest-agent-binaries" { } ''
    mkdir -p "$out/bin"
    ${pkgs.lib.concatMapStringsSep "\n" (binary: ''
      install -D -m 0755 ${lyra.native}/bin/x86_64-unknown-${if os == "freebsd" then "freebsd" else "illumos"}-${binary} "$out/bin/${binary}"
    '') binaries}
    install -D -m 0755 ${terminald.native}/bin/x86_64-unknown-${os}-lilly-terminald "$out/bin/lilly-terminald"
  '';
  freebsdBinaries = copy "freebsd";
  illumosBinaries = copy "illumos";
  # @cc [owner:ghuntley,label:security] native-sshd-current-authority-only
  # Native SSH MUST use certified volatile host keys, deny root/password/file
  # key access, authorize each offered key through the current private
  # authority and obtain a login receipt before launching a user shell/command.
  # System PAM remains enabled for native account/expiry checks.
  # Unavailable reverse DNS MUST NOT delay the SSH handshake; hostnames do not
  # participate in managed-key or login-receipt authority.
  sshdConfiguration = os: let
    binariesPath = if os == "freebsd" then "/usr/local/libexec" else "/opt/overalls/libexec";
  in pkgs.writeText "overalls-${os}-sshd-config" ''
    Port 22
    AddressFamily inet
    PidFile /var/run/overalls/sshd-native.pid
    HostKey /var/run/overalls/ssh-host/ssh_host_ed25519_key
    HostCertificate /var/run/overalls/ssh-host/ssh_host_ed25519_key-cert.pub
    HostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com
    PermitRootLogin no
    PubkeyAuthentication yes
    PasswordAuthentication no
    PermitEmptyPasswords no
    KbdInteractiveAuthentication no
    AuthenticationMethods publickey
    ${pkgs.lib.optionalString (os == "freebsd") "UsePAM yes"}
    UseDNS no
    AllowAgentForwarding no
    AllowTcpForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTunnel no
    GatewayPorts no
    PermitUserEnvironment no
    PermitUserRC no
    # sshd invokes ForceCommand through the account's Bash -c. Prevent Bash
    # from reading user startup files until the helper obtains a login receipt.
    # OpenSSH applies SetEnv after client/PAM environment variables.
    SetEnv SHLVL=2 BASH_ENV=/dev/null ENV=/dev/null
    AuthorizedKeysFile none
    AuthorizedKeysCommand ${binariesPath}/overalls-ssh-authorize authorize %u %t %k
    AuthorizedKeysCommandUser overalls-ssh
    ExposeAuthInfo yes
    ForceCommand ${binariesPath}/overalls-ssh-authorize session
    LogLevel QUIET
  '';
  sshRefresh = os: let
    binariesPath = if os == "freebsd" then "/usr/local/libexec" else "/opt/overalls/libexec";
  in pkgs.writeTextFile {
    name = "overalls-${os}-ssh-refresh";
    executable = true;
    text = ''
      #!/bin/sh
      set -eu
      export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      while :; do
        if ${binariesPath}/overalls-ssh-authorize sync >/dev/null 2>&1 &&
           ${binariesPath}/overalls-host-certificate >/dev/null 2>&1; then
          : > /var/run/overalls/ssh-ready
        else
          rm -f /var/run/overalls/ssh-ready
        fi
        sleep 2
      done
    '';
  };
  sudoConfiguration = os: pkgs.writeText "overalls-${os}-sudoers" ''
    Defaults env_reset
    root ALL=(ALL:ALL) ALL
    @includedir ${if os == "freebsd" then "/usr/local/etc/sudoers.d" else "/etc/sudoers.d"}
  '';
  freebsdRc = pkgs.writeText "overalls-native-agents-freebsd.rc" ''
    # The rc.d supervisor is enabled only after the image's network bootstrap.
    overalls_native_agents_enable="YES"
  '';
  # @cc [owner:ghuntley,label:recovery] illumos-native-service-signal-boundary
  # SMF MUST retain its contract service model while allowing the shell
  # supervisor to restart an individually signalled daemon. Only signal errors
  # may be ignored; core dumps, hardware errors and an empty service contract
  # MUST retain the outer service restart boundary.
  illumosManifest = pkgs.writeText "overalls-native-agents-illumos.xml" ''
    <?xml version="1.0"?>
    <!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
    <service_bundle type="manifest" name="overalls-native-agents">
      <service name="site/overalls-native-agents" type="service" version="1">
        <create_default_instance enabled="true"/>
        <single_instance/>
        <dependency name="network" grouping="require_all" restart_on="error" type="service">
          <service_fmri value="svc:/network/physical:default"/>
        </dependency>
        <dependency name="bootstrap" grouping="require_all" restart_on="error" type="service">
          <service_fmri value="svc:/site/overalls-native-bootstrap:default"/>
        </dependency>
        <dependency name="multi-user" grouping="require_all" restart_on="error" type="service">
          <service_fmri value="svc:/milestone/multi-user:default"/>
        </dependency>
        <exec_method type="method" name="start" exec="/opt/overalls/libexec/native-agents-start" timeout_seconds="30"/>
        <exec_method type="method" name="stop" exec=":kill" timeout_seconds="30"/>
        <property_group name="startd" type="framework">
          <propval name="duration" type="astring" value="contract"/>
          <propval name="ignore_error" type="astring" value="signal"/>
        </property_group>
        <stability value="Unstable"/>
        <template>
          <common_name><loctext xml:lang="C">Overalls native guest agents</loctext></common_name>
        </template>
      </service>
    </service_bundle>
  '';
  # The shell is intentionally a small supervisor rather than a collection of
  # background jobs. Each child has a volatile PID marker consumed by the
  # readiness probe, is restarted after an unexpected exit, and is terminated
  # together with the supervisor. SSH is part of the declared capability set;
  # roster/certificate or sshd failure therefore fails service startup and
  # withholds readiness instead of being hidden by an ignored exit status.

  # @cc [owner:ghuntley,label:security] native-callback-home-safe-preservation
  # An existing /var/empty MUST be a root-owned real directory without group
  # or other write permission. Safe existing permissions and native immutable
  # flags MUST remain unchanged; only a missing directory may be initialized.
  supervisor = os: let
    # Native roots do not contain the Linux builder's Nix store or shell.
    binariesPath = if os == "freebsd" then "/usr/local/libexec" else "/opt/overalls/libexec";
    sshd = "/usr/sbin/sshd";
    sshdConfig = "-f /etc/overalls/sshd_config";
  in pkgs.writeTextFile {
    name = "overalls-native-agents-${os}-supervisor";
    executable = true;
    text = ''
    #!/bin/sh
    set -eu
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    # Public trust must remain readable by the unprivileged SSH callback.
    # Private keys/state set their own 0600 modes in root-only runtime dirs.
    umask 022
    run_dir=/var/run/overalls
    # The bootstrap publishes this volatile receipt only after validated MMDS
    # identity and exact routes are installed. rc ordering alone cannot prove
    # that its start method succeeded.
    [ -f "$run_dir/bootstrap.json" ] || exit 1
    stop_file="$run_dir/agents.stop"
    mkdir -p "$run_dir"
    stale_markers="$run_dir/ssh-ready ${pkgs.lib.concatStringsSep " " (map (service: "$run_dir/${service}.pid") (supervised ++ [ "sshd" "sshd-native" "overalls-native-ssh-refresh" ]))}"
    stale_temporary_markers="${pkgs.lib.concatStringsSep " " (map (service: "$run_dir/${service}.pid.tmp.*") (supervised ++ [ "sshd" "overalls-native-ssh-refresh" ]))}"
    rm -f "$stop_file" $stale_markers $stale_temporary_markers
    supervisor_pids=""
    cleaned=0

    cleanup() {
      if [ "$cleaned" -eq 1 ]; then
        return
      fi
      cleaned=1
      : > "$stop_file"
      for child in $supervisor_pids; do
        if kill "$child" 2>/dev/null; then
          :
        fi
      done
      for child in $supervisor_pids; do
        if wait "$child" 2>/dev/null; then
          :
        fi
      done
      rm -f "$stop_file" $stale_markers $stale_temporary_markers
    }
    trap cleanup EXIT
    trap 'exit 0' HUP INT TERM

    # sshd's public-key callback is unprivileged. Account reconciliation and
    # per-boot certificate installation remain privileged supervisor work.
    if [ ! -e /var/empty ] && [ ! -L /var/empty ]; then
      mkdir /var/empty
      chown 0:0 /var/empty
      chmod 0755 /var/empty
    fi
    test -d /var/empty
    test ! -L /var/empty
    # POSIX numeric ls keeps these owner/mode fields portable across both native
    # utilities. /var and this fixed path are root controlled throughout startup.
    empty_metadata=$(LC_ALL=C /bin/ls -ldn /var/empty)
    set -- $empty_metadata
    [ "$3" = 0 ]
    case "$1" in
      d????-??-?) ;;
      *) exit 1 ;;
    esac
    ${if os == "freebsd" then ''
    if ! /usr/sbin/pw groupshow overalls-ssh >/dev/null 2>&1; then
      /usr/sbin/pw groupadd overalls-ssh
    fi
    if ! /usr/sbin/pw usershow overalls-ssh >/dev/null 2>&1; then
      /usr/sbin/pw useradd overalls-ssh -g overalls-ssh -d /var/empty -s /usr/sbin/nologin -w no
    fi
    '' else ''
    if ! /usr/bin/getent group overalls-ssh >/dev/null 2>&1; then
      /usr/sbin/groupadd overalls-ssh
    fi
    if ! /usr/bin/getent passwd overalls-ssh >/dev/null 2>&1; then
      /usr/sbin/useradd -g overalls-ssh -d /var/empty -s /usr/bin/false overalls-ssh
    fi
    ''}

    supervise() {
      service_name="$1"
      shift
      command_path="$1"
      child=""
      marker="$run_dir/$service_name.pid"
      marker_prefix="$marker.tmp"
      stop_child() {
        if [ -n "$child" ]; then
          if kill "$child" 2>/dev/null; then :; fi
          if wait "$child" 2>/dev/null; then :; fi
        fi
        rm -f "$marker" "$marker_prefix".*
      }
      trap stop_child EXIT
      trap 'exit 0' HUP INT TERM
      while [ ! -e "$stop_file" ]; do
        if [ ! -x "$command_path" ]; then
          rm -f "$marker" "$marker_prefix".*
          sleep 1
          continue
        fi
        "$@" &
        child=$!
        marker_tmp="$marker_prefix.$child"
        # Write to a same-directory temporary and rename so readiness never
        # observes a partially written PID marker.
        printf '%s\n' "$child" > "$marker_tmp"
        mv -f "$marker_tmp" "$marker"
        if wait "$child"; then
          :
        fi
        rm -f "$marker" "$marker_prefix".*
        if [ ! -e "$stop_file" ]; then
          sleep 1
        fi
      done
    }

    # Probe and trust listeners must exist before SSH bootstrap: the host
    # delivers the CA through trustd, and the roster fetch depends on that CA.
    # Readiness remains false because its complete live-process set includes
    # sshd, whose marker does not exist until these prerequisites pass.
    ${pkgs.lib.concatMapStringsSep "\n" (binary: ''
    supervise ${binary} ${binariesPath}/${binary} &
    supervisor_pids="$supervisor_pids $!"
    '') supervised}

    ssh_bootstrap_ready=0
    ssh_attempt=0
    while [ "$ssh_attempt" -lt 30 ] && [ ! -e "$stop_file" ]; do
      if ${binariesPath}/overalls-ssh-authorize sync >/dev/null 2>&1 &&
         ${binariesPath}/overalls-host-certificate >/dev/null 2>&1 &&
         ${sshd} -t ${sshdConfig} >/dev/null 2>&1; then
        ssh_bootstrap_ready=1
        break
      fi
      ssh_attempt=$((ssh_attempt + 1))
      sleep 1
    done
    if [ "$ssh_bootstrap_ready" -ne 1 ]; then
      # EXIT cleanup stops every listener. rc.d/SMF may then retry the entire
      # bounded attempt without claiming readiness from a partial service set.
      exit 1
    fi

    supervise sshd ${sshd} -D ${sshdConfig} &
    supervisor_pids="$supervisor_pids $!"
    : > "$run_dir/ssh-ready"
    supervise overalls-native-ssh-refresh ${binariesPath}/native-ssh-refresh &
    supervisor_pids="$supervisor_pids $!"

    # Keep the parent in the foreground for rc.d and svc.startd. The process
    # markers are health evidence, not readiness by themselves; the native
    # readiness daemon checks that every marker still names a live process.
    while [ ! -e "$stop_file" ]; do
      sleep 1
    done
    '';
  };
  freebsdSupervisor = supervisor "freebsd";
  illumosSupervisor = supervisor "illumos";
  # @cc [owner:ghuntley,label:security] native-workspace-system-git-ownership
  # Native Git MUST permit managed accounts to use the root-owned shared
  # checkout through the receiver's root-controlled exact-path configuration.
  # The pinned OmniOS Git does not support /workspace/* ownership exceptions.
  # Repository-owned configuration MUST NOT supply this exception and
  # unrelated paths MUST remain protected.
  gitConfiguration = pkgs.writeText "overalls-native-shared-workspace-gitconfig" ''
    [include]
      path = /run/overalls-workspace/gitconfig
      path = /run/overalls-workspace/git-identity/gitconfig
      path = /etc/overalls/github.gitconfig
  '';
  freebsdService = pkgs.writeTextFile {
    name = "overalls-native-agents-freebsd";
    executable = true;
    text = ''
    #!/bin/sh
    # PROVIDE: overalls_native_agents
    # REQUIRE: NETWORKING netif routing overalls_native_bootstrap
    # KEYWORD: shutdown
    . /etc/rc.subr
    name=overalls_native_agents
    rcvar=overalls_native_agents_enable
    load_rc_config "$name"
    : ''${overalls_native_agents_enable:=NO}
    pidfile=/var/run/overalls/native-agents-supervisor.pid
    command=/usr/sbin/daemon
    command_args="-p $pidfile -r -R 2 -- /usr/local/libexec/native-agents-supervisor"
    run_rc_command "$1"
    '';
  };
  illumosService = pkgs.writeTextFile {
    name = "overalls-native-agents-start";
    executable = true;
    text = ''
    #!/bin/sh
    # SMF retains the child in its service contract after the start method exits.
    /opt/overalls/libexec/native-agents-supervisor &
    exit 0
    '';
  };
  # @cc [owner:ghuntley,label:security;build] native-freebsd-vendor-trust-snapshot
  # The immutable native trust base MUST be copied from the pinned official
  # Git runtime bundle, independently of the mutable system CA destination.
  freebsd = pkgs.runCommand "overalls-freebsd-guest-agents" {} ''
    mkdir -p "$out/bin" "$out/usr/local/libexec" "$out/usr/local/etc/rc.d" "$out/etc/rc.conf.d" "$out/etc/overalls"
    cp -a ${freebsdBinaries}/bin/. "$out/bin/"
    cp -a ${freebsdBinaries}/bin/. "$out/usr/local/libexec/"
    chmod u+w "$out/bin" "$out/usr/local/libexec"
    install -m 0755 ${freebsdSupervisor} "$out/usr/local/libexec/native-agents-supervisor"
    install -m 0755 ${freebsdService} "$out/usr/local/etc/rc.d/overalls-native-agents"
    install -m 0644 ${freebsdRc} "$out/etc/rc.conf.d/overalls_native_agents"
    install -m 0644 ${sshdConfiguration "freebsd"} "$out/etc/overalls/sshd_config"
    install -m 0644 ${nativeGit.freebsd}/etc/ssl/cert.pem "$out/etc/overalls/system-ca.pem"
    install -m 0644 ${gitConfiguration} "$out/usr/local/etc/gitconfig"
    install -D -m 0755 ${githubTools.gh.freebsd-amd64}/bin/gh "$out/usr/local/bin/gh"
    install -D -m 0755 ${githubTools.lfs.freebsd-amd64}/bin/git-lfs "$out/usr/local/bin/git-lfs"
    install -m 0644 ${githubTools.configuration} "$out/etc/overalls/github.gitconfig"
    install -m 0755 ${sshRefresh "freebsd"} "$out/usr/local/libexec/native-ssh-refresh"
    install -D -m 0440 ${sudoConfiguration "freebsd"} "$out/usr/local/etc/sudoers"
    mkdir -p "$out/usr/local/etc/sudoers.d"
    chmod -R u+w "$out"
    cp -a ${bootstrap.freebsd}/. "$out/"
  '';
  # @cc [owner:ghuntley,label:security;build] native-illumos-vendor-trust-snapshot
  # The immutable native trust base MUST be copied from the pinned official
  # Git runtime bundle, independently of the mutable system CA destination.
  illumos = pkgs.runCommand "overalls-illumos-guest-agents" {} ''
    mkdir -p "$out/bin" "$out/lib/svc/manifest/site" "$out/opt/overalls/libexec" "$out/etc/overalls"
    cp -a ${illumosBinaries}/bin/. "$out/bin/"
    cp -a ${illumosBinaries}/bin/. "$out/opt/overalls/libexec/"
    chmod u+w "$out/bin" "$out/opt/overalls/libexec"
    install -m 0755 ${illumosSupervisor} "$out/opt/overalls/libexec/native-agents-supervisor"
    install -m 0644 ${illumosManifest} "$out/lib/svc/manifest/site/overalls-native-agents.xml"
    install -m 0755 ${illumosService} "$out/opt/overalls/libexec/native-agents-start"
    install -m 0644 ${sshdConfiguration "illumos"} "$out/etc/overalls/sshd_config"
    install -m 0644 ${nativeGit.illumos}/etc/ssl/cacert.pem "$out/etc/overalls/system-ca.pem"
    install -m 0644 ${gitConfiguration} "$out/etc/gitconfig"
    install -D -m 0755 ${githubTools.gh.illumos-amd64}/bin/gh "$out/usr/local/bin/gh"
    install -D -m 0755 ${githubTools.lfs.illumos-amd64}/bin/git-lfs "$out/usr/local/bin/git-lfs"
    install -m 0644 ${githubTools.configuration} "$out/etc/overalls/github.gitconfig"
    install -m 0755 ${sshRefresh "illumos"} "$out/opt/overalls/libexec/native-ssh-refresh"
    install -m 0440 ${sudoConfiguration "illumos"} "$out/etc/sudoers"
    mkdir -p "$out/etc/sudoers.d"
    chmod -R u+w "$out"
    cp -a ${bootstrap.illumos}/. "$out/"
  '';
in
{
  inherit freebsd illumos freebsdRc freebsdService illumosManifest illumosService freebsdSupervisor illumosSupervisor;
  manifest = {
    version = 1;
    agents = binaries ++ [ "lilly-terminald" ];
    # This is the installed service set. Runtime acceptance remains separate
    # from cross-building a native ELF or declaring an rc.d/SMF supervisor.
    native_admission = false;
    capabilities = [ "readiness" "trust" "workspace" "flush" "ssh" "agents" "terminal" ];
  };
}
