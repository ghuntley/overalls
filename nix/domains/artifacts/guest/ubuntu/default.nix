{ pkgs, terminald, lyraLinux, vscodeWeb ? null, vscodeWebBroker ? null,
  codingClis ? import ../coding-clis.nix { inherit pkgs; },
  githubTools ? import ../github { inherit pkgs; } }:
{ imageName ? "lilly-ubuntu-26.04-x86_64"
, packages ? [ ]
, packageLock ? ./packages.lock.json
, files ? { }
, caCertificates ? [ ]
, privateServiceRoots ? [ ]
, minimumMemoryBytes ? (if vscodeWeb == null then 536870912 else 2147483648)
}:
let
  inherit (pkgs) lib;
  nixCache = import ../../../../platform/nix-cache.nix;
  nixConfig = pkgs.writeText "overalls-ubuntu-nix.conf" ''
    experimental-features = nix-command flakes
    substituters = https://cache.nixos.org/ ${nixCache.substituter}
    trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= ${nixCache.publicKey}
    require-sigs = true
    fallback = true
  '';
  workspaceSourceEnabled = privateServiceRoots != [ ];
  base = builtins.fromJSON (builtins.readFile ./base.json);
  # @cc [owner:ghuntley,label:security] ubuntu-personal-account-sudo
  # The locked guest package set MUST provide sudo and its sudoers.d policy
  # include, so reconciled writers can use the shared passwordless sudo policy.
  required = builtins.fromJSON (builtins.readFile ./required-packages.json);
  requested = lib.sort builtins.lessThan (lib.unique (required ++ packages));
  lock = builtins.fromJSON (builtins.readFile packageLock);
  # @cc [owner:ghuntley,label:build] ubuntu-lock-matches-request
  # Ordinary builds MUST require the exact base and requested package set in the
  # lock. All archive downloads MUST have pinned SHA256 hashes; no APT networking
  # is permitted during rootfs assembly.
  validLock = lock.version == 1 && lock.base == base && lock.requested == requested
    && lock.packages != [ ]
    && lib.all (entry: builtins.match "[0-9a-f]{64}" entry.sha256 != null
      && entry.bytes > 0 && builtins.elem entry.architecture [ "amd64" "all" ]
      && lib.hasPrefix "https://snapshot.ubuntu.com/ubuntu/" entry.url) lock.packages
    && lib.all (name: builtins.match "[a-z0-9][a-z0-9+.-]+" name != null) requested;
  # @cc [owner:ghuntley,label:security] ubuntu-customization-paths
  # File destinations MUST be canonical absolute paths under /etc, /opt, /usr/local
  # or /root, without traversal or platform-service overrides. CA inputs MUST be
  # certificates, never private keys. Overlays MUST NOT replace the builder-owned
  # boot, access and networking files.
  validFile = path: value:
    let parts = lib.splitString "/" path;
    in lib.any (prefix: lib.hasPrefix prefix path) [ "/etc/" "/opt/" "/usr/local/" "/root/" ]
      && !(lib.any (part: part == "." || part == ".." || part == "") (lib.tail parts))
      && !(lib.any (prefix: lib.hasPrefix prefix path) [
        "/etc/systemd" "/etc/udev" "/etc/init" "/etc/network" "/etc/netplan"
        "/etc/ssh" "/etc/pam" "/etc/security" "/etc/sysctl" "/etc/modprobe"
        "/etc/modules" "/etc/ld.so" "/etc/profile" "/etc/bash" "/etc/environment"
        "/etc/passwd" "/etc/shadow" "/etc/group" "/etc/gshadow" "/etc/fstab"
        "/etc/machine-id" "/etc/resolv.conf" "/usr/local/lib/lilly"
      ])
      && builtins.match "0[0-7][0-7][0-7]" (value.mode or "0644") != null;
  source = pkgs.fetchurl { inherit (base) url sha256; };
  debs = map (entry: pkgs.fetchurl { inherit (entry) url sha256; }) lock.packages;
  archives = pkgs.linkFarm "ubuntu-locked-debs" (lib.imap0 (i: deb: {
    name = "${toString i}.deb"; path = deb;
  }) debs);
  ubuntuDevelopmentTools = pkgs.buildEnv {
    name = "ubuntu-guest-development-tools";
    paths = [ pkgs.devenv ] ++ codingClis.packages ++ githubTools.packages "linux-amd64";
    pathsToLink = [ "/bin" ];
  };
  editorConfiguration = pkgs.writeText "ubuntu-overalls-vscode-web-broker.json" (builtins.toJSON {
    descriptor = if vscodeWeb == null then null else {
      protocol = vscodeWeb.editorProtocol;
      commit = vscodeWeb.sourceCommit;
      release = vscodeWeb.releaseId;
    };
    editor_executable = if vscodeWeb == null then "" else "${vscodeWeb}/bin/overalls-code";
    systemd_run = "/usr/bin/systemd-run";
    systemctl = "/usr/bin/systemctl";
    account_authorizer = "/usr/local/bin/overalls-ssh-authorize";
    worker_path = "/usr/local/bin:/usr/bin:/bin";
  });
  editorUnit = pkgs.writeText "overalls-vscode-web.service" ''
    [Unit]
    Description=Overalls account-bound browser editor broker
    Requires=lilly-network.service lilly-private-dns.service
    Wants=overalls-ssh-sync.service
    After=lilly-network.service lilly-private-dns.service overalls-ssh-sync.service
    ConditionKernelCommandLine=lilly.ipv4
    ConditionKernelCommandLine=lilly.placement
    ConditionKernelCommandLine=lilly.execution_epoch

    [Service]
    ExecStart=${if vscodeWebBroker == null then "" else "${vscodeWebBroker}/bin/overalls-vscode-web-broker ${editorConfiguration}"}
    Environment=OVERALLS_SSH_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
    Environment=PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    Restart=on-failure
    RestartSec=2
    RuntimeDirectory=overalls-vscode
    RuntimeDirectoryMode=0711
    RuntimeDirectoryPreserve=yes
    StateDirectory=overalls-ssh
    StateDirectoryMode=0700
    UMask=0077
    TasksMax=256
    StandardOutput=null

    [Install]
    WantedBy=multi-user.target
  '';
  developmentToolsClosure = pkgs.closureInfo {
    rootPaths = [ ubuntuDevelopmentTools ] ++ lib.optionals (vscodeWeb != null) [
      vscodeWeb vscodeWebBroker editorConfiguration editorUnit
    ];
  };
  kernel = pkgs.linuxPackages_6_12.kernel;
  bootKernel = import ../kernel.nix { inherit pkgs kernel; };
  # @cc [owner:ghuntley,label:build] ubuntu-guest-kernel-module-set
  # The shipped module closure MUST include the platform boot modules and the
  # namespaces, overlay and netfilter modules Podman and Nix need at runtime;
  # modules absent from this list cannot be loaded inside the guest.
  modules = pkgs.makeModulesClosure {
    kernel = lib.getOutput "modules" kernel;
    rootModules = [
      "virtio_mmio" "virtio_blk" "virtio_net" "ext4" "vmw_vsock_virtio_transport"
      "overlay" "bridge" "veth" "br_netfilter" "tun"
      "nf_tables" "nft_compat" "nft_chain_nat" "nft_nat"
      "nf_conntrack" "nf_nat" "nf_defrag_ipv4"
      "ip_tables" "iptable_filter" "iptable_nat" "xt_addrtype" "xt_comment"
    ];
    firmware = kernel;
  };
  init = pkgs.writeScript "ubuntu-init" ''
    #!${pkgs.busybox}/bin/sh
    export PATH=${pkgs.busybox}/bin:${pkgs.kmod}/bin
    set -eu
    mkdir -p /proc /sys /dev /root
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t devtmpfs devtmpfs /dev
    for module in $(cat ${modules}/insmod-list); do
      ${pkgs.kmod}/bin/insmod "$module"
    done
    for attempt in $(seq 1 100); do
      test ! -b /dev/vda || break
      sleep 0.1
    done
    mount -t ext4 -o rw /dev/vda /root
    mkdir -p /root/dev /root/proc /root/sys
    mount --move /dev /root/dev
    mount --move /proc /root/proc
    mount --move /sys /root/sys
    exec switch_root /root /sbin/init
  '';
  initrd = pkgs.makeInitrd { contents = [{ object = init; symlink = "/init"; }]; };
  customization = lib.concatStringsSep "\n" (lib.mapAttrsToList (path: value: ''
    install -D -m ${lib.escapeShellArg (value.mode or "0644")} ${lib.escapeShellArg "${value.source}"} "$root"${lib.escapeShellArg path}
  '') files);
  certificates = lib.concatStringsSep "\n" (lib.imap0 (i: cert: ''
    ${pkgs.openssl}/bin/openssl x509 -in ${lib.escapeShellArg "${cert}"} -noout
    if grep -q 'PRIVATE KEY' ${lib.escapeShellArg "${cert}"}; then exit 1; fi
    install -D -m 0644 ${lib.escapeShellArg "${cert}"} "$root/usr/local/share/ca-certificates/overalls-${toString i}.crt"
  '') caCertificates);
  # @cc [owner:ghuntley,label:security;build] ubuntu-prebuilt-platform-trust
  # The image MUST stage its public platform roots exactly as overalls-trustd
  # installs them (overalls-platform/overalls-I.crt in order, then
  # update-ca-certificates) and write the installed marker only after that
  # rebuild, with Lilly's bundle digest of those exact bytes. A boot whose
  # delivered set matches is then a verified no-op in the receiver; any other
  # set still replaces the roots and rebuilds the store before networking.
  platformRoots = lib.optionalString (privateServiceRoots != [ ]) (''
    install -d -m 0755 "$root/usr/local/share/ca-certificates/overalls-platform" "$root/var/lib/overalls-trust"
  '' + lib.concatStringsSep "\n" (lib.imap0 (i: cert: ''
    ${pkgs.openssl}/bin/openssl x509 -in ${lib.escapeShellArg "${cert}"} -noout
    if grep -q 'PRIVATE KEY' ${lib.escapeShellArg "${cert}"}; then exit 1; fi
    install -m 0644 ${lib.escapeShellArg "${cert}"} "$root/usr/local/share/ca-certificates/overalls-platform/overalls-${toString i}.crt"
  '') privateServiceRoots));
  platformMarker = lib.optionalString (privateServiceRoots != [ ]) ''
    python3 ${./platform_digest.py} ${lib.escapeShellArgs (map (cert: "${cert}") privateServiceRoots)} > "$root/var/lib/overalls-trust/installed"
  '';
  # @cc [owner:ghuntley,label:security] ubuntu-private-dns-readiness
  # Platform roots MUST enter the Ubuntu trust store from Lilly before guest
  # networking. Internal DNS MUST route only to Audi, without public fallback,
  # before readiness succeeds.
  # Host profile policy remains authoritative for whether egress is allowed.
  rootfs = pkgs.vmTools.runInLinuxVM (pkgs.runCommand "${imageName}-rootfs" {
    memSize = 12288;
    nativeBuildInputs = [ pkgs.e2fsprogs pkgs.gnutar pkgs.gzip pkgs.coreutils pkgs.util-linux pkgs.libfaketime pkgs.python3 ];
  } ''
    export LC_ALL=C SOURCE_DATE_EPOCH=1
    root=$TMPDIR/ubuntu
    mkdir -p "$root"
    tar --numeric-owner -xpf ${source} -C "$root"
    mkdir -p "$root/dev" "$root/proc" "$root/sys" "$root/run" "$root/packages"
    mount --bind /dev "$root/dev"
    mount -t proc proc "$root/proc"
    mount -t sysfs sysfs "$root/sys"
    trap 'umount "$root/sys" "$root/proc" "$root/dev" || true' EXIT
    cp -L ${archives}/*.deb "$root/packages/"
    rm -rf "$root/var/lib/apt/lists"
    mkdir -p "$root/run/apt-empty"
    touch "$root/run/apt-empty.list"
    printf '#!/bin/sh\nexit 101\n' > "$root/usr/sbin/policy-rc.d"
    chmod 0755 "$root/usr/sbin/policy-rc.d"
    # All dependencies are local .deb inputs; APT has no package lists or network.
    # The transcript lands in the build VM's host-visible exchange directory so
    # an offline refusal stays observable even though a failed build script tears
    # the VM down before its console bytes are guaranteed to reach the log.
    mkdir -p /tmp/xchg
    set -o pipefail
    unshare --net chroot "$root" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive \
      /bin/sh -c 'apt-get -o Dpkg::Use-Pty=0 -o Dir::Etc::sourcelist=/run/apt-empty.list -o Dir::Etc::sourceparts=/run/apt-empty --no-install-recommends -y install /packages/*.deb ${lib.concatStringsSep " " requested}' \
      2>&1 | tee /tmp/xchg/apt.log
    set +o pipefail
    rm "$root/usr/sbin/policy-rc.d"
    rm -rf "$root/packages"
    # @cc [owner:ghuntley,label:product] ubuntu-default-interactive-prompt
    # Ordinary users MUST default to Bash. Both login and non-login interactive
    # Bash shells MUST load the same guarded Starship initializer globally;
    # image assembly MUST NOT rewrite personal shell startup files.
    chroot "$root" /usr/sbin/useradd --defaults --shell /bin/bash
    install -D -m 0644 ${./starship.sh} "$root/etc/profile.d/overalls-starship.sh"
    printf '\n. /etc/profile.d/overalls-starship.sh\n' >> "$root/etc/bash.bashrc"

    # @cc [owner:ghuntley,label:build] ubuntu-nix-development-tools
    # Devenv, Codex, Claude Code and their runtime closures MUST come from the
    # supplied pinned Nixpkgs, be registered in the guest's Nix database and
    # retain a GC root. Assembly
    # MUST NOT fetch Nix packages over the network. Direnv remains an Ubuntu
    # package from the authenticated archive lock.

    # @cc [owner:ghuntley,label:build;security] ubuntu-closure-path-and-root-custody
    # Every copied closure path MUST retain its complete hashed store basename,
    # immutable modes and root ownership. Build-user ownership MUST NOT enter
    # the guest, including the broker's root-custodied configuration.
    mkdir -p "$root/nix/store"
    while IFS= read -r path; do
      cp -a --no-preserve=ownership "$path" "$root/nix/store/"
      test -e "$root$path"
      test "$(stat -c %u:%g "$root$path")" = 0:0
    done < ${developmentToolsClosure}/store-paths
    ${lib.optionalString (vscodeWeb != null) ''
      test -x "$root${vscodeWebBroker}/bin/overalls-vscode-web-broker"
      test -x "$root${vscodeWeb}/bin/overalls-code"
      test -f "$root${editorConfiguration}"
      test ! -L "$root${editorConfiguration}"
      test "$(stat -c %u:%g:%a "$root${editorConfiguration}")" = 0:0:444
    ''}
    chroot "$root" /usr/bin/nix-store --load-db < ${developmentToolsClosure}/registration
    install -D -m 0644 ${nixConfig} "$root/etc/nix/nix.conf"
    # @cc [owner:ghuntley,label:build;security] ubuntu-rootfs-same-derivation-same-image
    # Registering identical closure paths on different hosts MUST NOT embed
    # wall-clock registrationTime or transient SQLite WAL/SHM bytes into the
    # immutable rootfs. Preserve the actual path/reference rows and fail closed
    # if canonicalization cannot checkpoint/verify the Nix guest database.
    python3 ${./normalize_nix_db.py} "$root/nix/var/nix/db/db.sqlite"
    mkdir -p "$root/nix/var/nix/gcroots" "$root/usr/local/bin"
    ln -s ${ubuntuDevelopmentTools} "$root/nix/var/nix/gcroots/ubuntu-guest-development-tools"
    for command in devenv codex claude gh git-lfs; do
      ln -s ${ubuntuDevelopmentTools}/bin/$command "$root/usr/local/bin/$command"
    done
    install -D -m 0644 ${githubTools.configuration} "$root/etc/overalls/github.gitconfig"
    # @cc [owner:ghuntley,label:security] ubuntu-coding-cli-native-settings
    # Native system configuration MUST keep Ziggy and verified guest CA trust
    # available to login, interactive Bash and PAM sessions, without rewriting
    # personal homes or adding a client launcher.
    install -D -m 0644 ${codingClis.codexConfiguration} "$root/etc/codex/config.toml"
    install -D -m 0644 ${codingClis.claudeConfiguration} "$root/etc/claude-code/managed-settings.json"
    install -D -m 0644 ${codingClis.loginEnvironment} "$root/etc/profile.d/overalls-coding-clis.sh"
    printf '\n. /etc/profile.d/overalls-coding-clis.sh\n' >> "$root/etc/bash.bashrc"
    printf '\n' >> "$root/etc/environment"
    cat ${codingClis.pamEnvironment} >> "$root/etc/environment"
    # @cc [owner:ghuntley,label:build;security] ubuntu-editor-registered-closure
    # The editor, broker and immutable configuration MUST enter the guest Nix
    # database and retain GC roots. Workers MUST use the normal Ubuntu account,
    # shell, CA store and systemd; the broker MUST NOT use a root editor process.
    ${lib.optionalString (vscodeWeb != null) ''
      ln -s ${vscodeWeb} "$root/nix/var/nix/gcroots/overalls-vscode-web"
      ln -s ${vscodeWebBroker} "$root/nix/var/nix/gcroots/overalls-vscode-web-broker"
      ln -s ${editorUnit} "$root/nix/var/nix/gcroots/overalls-vscode-web-unit"
      ln -s ${vscodeWeb}/bin/overalls-code "$root/usr/local/bin/overalls-code"
      install -D -m 0644 ${editorUnit} "$root/etc/systemd/system/overalls-vscode-web.service"
    ''}
    install -D -m 0755 ${lyraLinux}/bin/overalls "$root/usr/local/bin/overalls"
    install -D -m 0755 ${lyraLinux}/bin/overalls-ssh-authorize "$root/usr/local/bin/overalls-ssh-authorize"
    install -D -m 0755 ${lyraLinux}/bin/overalls-host-certificate "$root/usr/local/bin/overalls-host-certificate"
    install -D -m 0755 ${lyraLinux}/bin/overalls-trustd "$root/usr/local/bin/overalls-trustd"
    install -D -m 0755 ${lyraLinux}/bin/overalls-workspaced "$root/usr/local/bin/overalls-workspaced"
    ${customization}
    ${certificates}
    ${platformRoots}
    chroot "$root" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin update-ca-certificates
    ${platformMarker}
    mkdir -p "$root/usr/local/lib" "$root/usr/lib/modules"
    cp -rL ${modules}/lib/modules/. "$root/usr/lib/modules/"
    cp ${../network.py} "$root/usr/local/lib/lilly-network.py"
    cp ${../readiness.py} "$root/usr/local/lib/lilly-readiness.py"
    cp ${../flush.py} "$root/usr/local/lib/lilly-flush.py"
    cp ${../boot_report.py} "$root/usr/local/lib/lilly-boot-report.py"
    install -D -m 0755 ${terminald}/bin/lilly-terminald "$root/usr/local/lib/lilly/lilly-terminald"
    cp -r ${./units}/. "$root/etc/systemd/system/"
    mkdir -p "$root/etc/systemd/system/multi-user.target.wants" "$root/etc/systemd/system/getty.target.wants" "$root/etc/systemd/system/timers.target.wants"
    for unit in lilly-network lilly-grow-root lilly-readiness lilly-flush lilly-terminals lilly-console-ready lilly-boot-report; do
      ln -sf ../$unit.service "$root/etc/systemd/system/multi-user.target.wants/$unit.service"
    done
    # no-serial-login-shell: no getty may offer a login on the serial console.
    ln -sf /dev/null "$root/etc/systemd/system/serial-getty@.service"
    ln -sf /dev/null "$root/etc/systemd/system/console-getty.service"
    ${lib.optionalString (privateServiceRoots != [ ]) ''
      ${lib.optionalString (vscodeWeb != null) ''
        ln -sf ../overalls-vscode-web.service "$root/etc/systemd/system/multi-user.target.wants/overalls-vscode-web.service"
      ''}
      ln -sf ../overalls-guest-trust.service "$root/etc/systemd/system/multi-user.target.wants/overalls-guest-trust.service"
      # Repository launch (ADR-0128): not a readiness dependency. Checkouts are
      # root-owned and shared by every sudo-capable login account.
      ln -sf ../overalls-workspace.service "$root/etc/systemd/system/multi-user.target.wants/overalls-workspace.service"
      install -d -m 0755 "$root/workspace"
      printf '[safe]\n\tdirectory = /workspace/*\n[include]\n\tpath = /run/overalls-workspace/git-identity/gitconfig\n\tpath = /etc/overalls/github.gitconfig\n' > "$root/etc/gitconfig"
      mkdir -p "$root/etc/systemd/system/lilly-network.service.d"
      cat > "$root/etc/systemd/system/lilly-network.service.d/trust.conf" <<'EOF'
    [Unit]
    Requires=overalls-guest-trust.service
    After=overalls-guest-trust.service
    EOF
      ln -sf ../overalls-ssh-sync.service "$root/etc/systemd/system/multi-user.target.wants/overalls-ssh-sync.service"
      ln -sf ../overalls-ssh-sync.timer "$root/etc/systemd/system/timers.target.wants/overalls-ssh-sync.timer"
      ln -sf ../overalls-ssh-certificate.path "$root/etc/systemd/system/multi-user.target.wants/overalls-ssh-certificate.path"
    ''}
    chroot "$root" /usr/sbin/useradd --system --no-create-home --shell /usr/sbin/nologin overalls-ssh
    # @cc [owner:ghuntley,label:isolation] ubuntu-guest-container-runtime
    # Podman MUST activate through its root-owned system socket with a Docker
    # compatibility alias, and the Nix daemon MUST be enabled explicitly because
    # policy-rc.d blocks service activation during offline image assembly.
    # Neither unit may listen beyond the guest's own root-owned sockets.
    ln -sf /usr/lib/systemd/system/nix-daemon.service "$root/etc/systemd/system/multi-user.target.wants/nix-daemon.service"
    mkdir -p "$root/etc/systemd/system/sockets.target.wants" "$root/etc/systemd/system/podman.socket.d"
    ln -sf /usr/lib/systemd/system/podman.socket "$root/etc/systemd/system/sockets.target.wants/podman.socket"
    printf '[Socket]\nSymlinks=/run/docker.sock\n' > "$root/etc/systemd/system/podman.socket.d/docker-compat.conf"
    ln -sf /usr/lib/systemd/system/multi-user.target "$root/etc/systemd/system/default.target"
    # Enable SSH only after a verified private roster has been reconciled.
    mkdir -p "$root/etc/systemd/system/ssh.service.d" "$root/etc/ssh/sshd_config.d"
    cat > "$root/etc/systemd/system/ssh.service.d/lilly.conf" <<'EOF'
    [Unit]
    After=overalls-ssh-sync.service
    ConditionPathExists=/run/overalls-ssh-ready
    EOF
    ${lib.optionalString (privateServiceRoots != [ ]) ''
      ln -sf /usr/lib/systemd/system/ssh.service "$root/etc/systemd/system/multi-user.target.wants/ssh.service"
    ''}
    cat > "$root/etc/ssh/sshd_config.d/lilly.conf" <<'EOF'
    HostKey /run/overalls-ssh-host/ssh_host_ed25519_key
    HostCertificate /run/overalls-ssh-host/ssh_host_ed25519_key-cert.pub
    HostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com
    PermitRootLogin no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthenticationMethods publickey
    AllowAgentForwarding no
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
    GatewayPorts no
    PermitUserEnvironment no
    AuthorizedKeysFile none
    AuthorizedKeysCommand /usr/local/bin/overalls-ssh-authorize authorize %u %t %k
    AuthorizedKeysCommandUser overalls-ssh
    EOF
    printf '%s\n' 'session requisite pam_exec.so quiet quiet_log type=open_session /usr/local/bin/overalls-ssh-authorize login' >> "$root/etc/pam.d/sshd"
    rm -f "$root/etc/ssh/ssh_host_"*
    # Disable standard alternate network configurators and SSH socket activation.
    # Ubuntu ships sshd.service as an alias of the intended ssh.service. Masking
    # that alias masks the server itself, so disable only socket activation and
    # alternate daemons here.
    for unit in ssh.socket sshd.socket dropbear.service dropbear.socket \
      systemd-networkd.service systemd-networkd.socket systemd-resolved.service \
      networking.service NetworkManager.service dhcpcd.service; do
      ln -sf /dev/null "$root/etc/systemd/system/$unit"
    done
    # openssh-server's package activation materializes ssh.socket's
    # RequiredBy=ssh.service edge. Retaining it while masking the socket makes
    # every explicit service start fail; the hardened service owns port 22.
    rm -f "$root/etc/systemd/system/ssh.service.requires/ssh.socket"
    rmdir "$root/etc/systemd/system/ssh.service.requires" 2>/dev/null || true
    rm -f "$root/etc/resolv.conf"
    printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$root/etc/resolv.conf"
    # Route the internal suffix only to Audi; never use public fallback for it.
    ${lib.optionalString (privateServiceRoots != [ ]) ''
      rm "$root/etc/systemd/system/systemd-resolved.service" "$root/etc/resolv.conf"
      ln -s /run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
      ln -sf /usr/lib/systemd/system/systemd-resolved.service "$root/etc/systemd/system/multi-user.target.wants/systemd-resolved.service"
      mkdir -p "$root/etc/systemd/resolved.conf.d" "$root/etc/systemd/system/lilly-readiness.service.d"
      cat > "$root/etc/systemd/resolved.conf.d/lilly.conf" <<'EOF'
    [Resolve]
    DNS=1.1.1.1 9.9.9.9
    Domains=~.
    FallbackDNS=
    DNSSEC=no
    DNSOverTLS=no
    EOF
      cp ${./private-dns.service} "$root/etc/systemd/system/lilly-private-dns.service"
      cp ${./agent-executor.service} "$root/etc/systemd/system/overalls-agent-executor.service"
      install -D -m 0644 ${pkgs.writeText "overalls-guest-agent" "enabled\n"} "$root/etc/overalls/guest-agent"
      ln -sf ../overalls-agent-executor.service "$root/etc/systemd/system/multi-user.target.wants/overalls-agent-executor.service"
      cat > "$root/etc/systemd/system/lilly-readiness.service.d/private-dns.conf" <<'EOF'
    [Unit]
    Requires=lilly-private-dns.service
    After=lilly-private-dns.service
    [Service]
    Environment="LILLY_REQUIRED_UNITS=lilly-grow-root.service lilly-private-dns.service"
    Environment=LILLY_SSH_UNIT=ssh.service
    EOF
    ''}
    printf 'lilly-guest\n' > "$root/etc/hostname"
    printf '127.0.0.1 localhost lilly-guest\n' > "$root/etc/hosts"
    printf '/dev/vda / ext4 defaults 0 0\n' > "$root/etc/fstab"
    chroot "$root" /usr/bin/passwd -l root
    mkdir -p "$root/etc/systemd/journald.conf.d"
    printf '[Journal]\nStorage=volatile\n' > "$root/etc/systemd/journald.conf.d/lilly.conf"
    # Prevent clone-shared entropy, logs and machine IDs in immutable templates.
    rm -f "$root/etc/machine-id" "$root/var/lib/dbus/machine-id" "$root/var/lib/systemd/random-seed"
    touch "$root/etc/machine-id"
    find "$root/var/log" -type f -delete
    rm -rf "$root/var/cache/apt" "$root/var/lib/apt/lists" "$root/var/cache/ldconfig/aux-cache"
    rm -rf "$root/run/apt-empty" "$root/run/apt-empty.list"
    umount "$root/sys" "$root/proc" "$root/dev"
    trap - EXIT
    # A sorted source tree, fixed UUID/hash seed and tool time make ext4 stable.
    export E2FSPROGS_FAKE_TIME=1
    size_mib=$(( ( $(du -sm "$root" | cut -f1) + 383 ) / 128 * 128 ))
    find "$root" -print0 | xargs -0 touch -h -d @1
    truncate -s "''${size_mib}M" "$out"
    export FAKETIME_DONT_FAKE_STAT=1
    faketime -f "1970-01-01 00:00:01" mkfs.ext4 -F -q -L lilly-root -U 44444444-4444-4444-8888-888888888888 \
      -E hash_seed=44444444-4444-4444-8888-888888888888,lazy_itable_init=0,lazy_journal_init=0 \
      -d "$root" "$out"
  '');
in
assert lib.assertMsg validLock "Ubuntu package lock is stale; run ubuntu-lock for this package list";
assert lib.assertMsg (lib.all (path: validFile path files.${path}) (builtins.attrNames files)) "Invalid or protected Ubuntu file destination/mode";
assert lib.assertMsg (builtins.isInt minimumMemoryBytes && minimumMemoryBytes >= 536870912) "Ubuntu requires an integer memory size of at least 512 MiB";
assert lib.assertMsg ((vscodeWeb == null) == (vscodeWebBroker == null)) "Ubuntu editor and broker packages must be supplied together";
assert lib.assertMsg (vscodeWeb == null || minimumMemoryBytes >= 2147483648) "Browser editor guests require at least 2 GiB RAM";
# @cc [owner:ghuntley,label:protocol] ubuntu-exact-artifacts
# Ubuntu MUST use the same capability manifest and exact descriptors as NixOS.
# Distribution selection MUST NOT introduce a second image-identity algorithm.
# Boot arguments keep the console quiet (guest-quiet-serial-console, ADR-0154):
# printk.time=1, quiet, loglevel=3 and systemd.show_status=error.
pkgs.runCommand imageName {
  nativeBuildInputs = [ pkgs.jq ];
  passthru = { inherit rootfs initrd nixConfig ubuntuDevelopmentTools bootKernel workspaceSourceEnabled; editorEnabled = vscodeWeb != null; };
} ''
  mkdir -p $out
  ln -s ${bootKernel}/vmlinux $out/kernel
  ln -s ${initrd}/initrd $out/initrd
  ln -s ${rootfs} $out/rootfs.ext4
  rootfs_bytes=$(stat -Lc %s $out/rootfs.ext4)
  minimum_disk_bytes=$rootfs_bytes
  ${lib.optionalString (vscodeWeb != null) ''
    minimum_disk_bytes=$(( (rootfs_bytes + 2147483648 + 1073741823) / 1073741824 * 1073741824 ))
  ''}
  jq -n \
    --arg boot_args 'console=ttyS0 reboot=k panic=1 pci=off net.ifnames=0 ipv6.disable=1 systemd.getty_auto=0 printk.time=1 quiet loglevel=3 systemd.show_status=error root=/dev/vda rw' \
    --argjson memory ${toString minimumMemoryBytes} \
    --argjson kernel_bytes "$(stat -Lc %s $out/kernel)" --arg kernel_hash "$(sha256sum $out/kernel | cut -d' ' -f1)" \
    --argjson initrd_bytes "$(stat -Lc %s $out/initrd)" --arg initrd_hash "$(sha256sum $out/initrd | cut -d' ' -f1)" \
    --argjson rootfs_bytes "$rootfs_bytes" --arg rootfs_hash "$(sha256sum $out/rootfs.ext4 | cut -d' ' -f1)" \
    --argjson minimum_disk_bytes "$minimum_disk_bytes" \
    --argjson workspace_source_version '${if workspaceSourceEnabled then "2" else "null"}' \
    --argjson editor '${builtins.toJSON (if vscodeWeb == null then null else { protocol = vscodeWeb.editorProtocol; commit = vscodeWeb.sourceCommit; release = vscodeWeb.releaseId; })}' \
    '{version:4, architecture:"x86_64", boot_args:$boot_args, minimum_memory_bytes:$memory, minimum_disk_bytes:$minimum_disk_bytes, workspace_source_version:$workspace_source_version,
      kernel:{bytes:$kernel_bytes,sha256:$kernel_hash}, initrd:{bytes:$initrd_bytes,sha256:$initrd_hash}, rootfs:{bytes:$rootfs_bytes,sha256:$rootfs_hash}} + (if $workspace_source_version == 2 then {git_identity_version:1} else {} end) + (if $editor == null then {} else {editor:$editor} end)' > $out/manifest.json
''
