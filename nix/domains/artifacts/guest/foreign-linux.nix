{ pkgs, mkUbuntuGuest, terminald, lyraLinux, distribution, defaultImageName, source, sourceFormat,
  vscodeWeb ? null, vscodeWebBroker ? null, githubTools ? import ./github { inherit pkgs; } }:
{ imageName ? defaultImageName
, privateServiceRoots ? [ ]
, files ? { }
, minimumMemoryBytes ? 2147483648
, minimumDiskBytes ? 8589934592
}:
let
  inherit (pkgs) lib;
  # @cc [owner:ghuntley,label:build;security] foreign-linux-fixture-files
  # Custom files MUST use canonical absolute /opt destinations and ordinary
  # read-only or owner-writable file modes. Assembly MUST refuse existing
  # destinations and symlink parents; overlays MUST NOT replace platform files.
  validFile = path: value:
    let parts = lib.splitString "/" path;
    in builtins.match "/opt/[ -~]+" path != null
      && !(lib.any (part: part == "." || part == ".." || part == "") (lib.tail parts))
      && builtins.isAttrs value && value ? source
      && lib.all (name: builtins.elem name [ "source" "mode" ]) (builtins.attrNames value)
      && (builtins.isPath value.source || builtins.isString value.source || lib.isDerivation value.source)
      && builtins.isString (value.mode or "0644")
      && builtins.elem (value.mode or "0644") [ "0444" "0644" "0555" "0755" ];
  customization = lib.concatStringsSep "\n" (lib.mapAttrsToList (path: value: ''
    test -f ${lib.escapeShellArg "${value.source}"}
    test ! -L ${lib.escapeShellArg "${value.source}"}
    destination=./files${lib.escapeShellArg path}
    test ! -e "$destination" && test ! -L "$destination"
    parent=$(dirname "$destination")
    while test "$parent" != ./files; do
      test ! -L "$parent"
      test ! -e "$parent" || test -d "$parent"
      parent=$(dirname "$parent")
    done
    install -D -m ${lib.escapeShellArg (value.mode or "0644")} ${lib.escapeShellArg "${value.source}"} "$destination"
  '') files);
  editorEnabled = vscodeWeb != null;
  editorDescriptor = if editorEnabled then {
    protocol = vscodeWeb.editorProtocol;
    commit = vscodeWeb.sourceCommit;
    release = vscodeWeb.releaseId;
  } else null;
  # @cc [owner:ghuntley,label:security;deployment] foreign-linux-editor-account-broker
  # Editor-enabled roots MUST carry the exact pinned editor/broker descriptor
  # and root-custodied configuration. The broker MUST use the distribution's
  # systemd and current account authorizer; workers MUST retain personal UID
  # custody. Private DNS and roster startup MUST precede the broker, while
  # editor startup MUST NOT become a guest readiness dependency.
  editorConfiguration = if editorEnabled then pkgs.writeText "foreign-linux-overalls-vscode-web-broker.json" (builtins.toJSON {
    descriptor = editorDescriptor;
    editor_executable = "${vscodeWeb}/bin/overalls-code";
    systemd_run = "/usr/bin/systemd-run";
    systemctl = "/usr/bin/systemctl";
    account_authorizer = "/usr/local/bin/overalls-ssh-authorize";
    worker_path = "/usr/local/bin:/usr/bin:/bin";
  }) else null;
  editorUnit = if editorEnabled then pkgs.writeText "foreign-linux-overalls-vscode-web.service" ''
    [Unit]
    Description=Overalls account-bound browser editor broker
    Requires=lilly-network.service lilly-private-dns.service
    Wants=overalls-ssh-sync.service
    After=lilly-network.service lilly-private-dns.service overalls-ssh-sync.service
    ConditionKernelCommandLine=lilly.ipv4
    ConditionKernelCommandLine=lilly.placement
    ConditionKernelCommandLine=lilly.execution_epoch

    [Service]
    Type=notify
    NotifyAccess=main
    ExecStart=${vscodeWebBroker}/bin/overalls-vscode-web-broker ${editorConfiguration}
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
  '' else null;
  # Reuse only the reviewed Firecracker Linux kernel/initrd contract. The
  # distribution rootfs is assembled from its own pinned release input below.
  boot = mkUbuntuGuest {
    imageName = "${imageName}-boot-contract";
    inherit privateServiceRoots minimumMemoryBytes;
  };
  # Keep the upstream archive and image extraction separate from mutation. This
  # lets both source formats receive exactly the same guest runtime setup.
  archiveRoot = pkgs.runCommand "${imageName}-archive-root" {
    nativeBuildInputs = [ pkgs.gnutar pkgs.zstd ];
    preferLocalBuild = true;
  } ''
    mkdir -p "$out"
    tar --use-compress-program=${pkgs.zstd}/bin/zstd --delay-directory-restore \
      --extract --file ${source} --directory "$out" --strip-components=1
    chmod -R u+rwX "$out"
  '';
  rootfsDir = if sourceFormat == "arch-bootstrap" then null else pkgs.runCommand "${imageName}-rootfs" {
    nativeBuildInputs = [ pkgs.coreutils pkgs.jq pkgs.qemu-utils pkgs.util-linux ];
    preferLocalBuild = true;
  } ''
    mkdir -p "$out"
    ${pkgs.qemu-utils}/bin/qemu-img convert -O raw -S 4k ${source} "$out/disk.raw"
    root_start=$(${pkgs.util-linux}/bin/sfdisk --json "$out/disk.raw" | ${pkgs.jq}/bin/jq -r '.partitiontable.partitions[] | select(.name == "root") | .start')
    root_size=$(${pkgs.util-linux}/bin/sfdisk --json "$out/disk.raw" | ${pkgs.jq}/bin/jq -r '.partitiontable.partitions[] | select(.name == "root") | .size')
    test -n "$root_start" -a "$root_start" != null
    test -n "$root_size" -a "$root_size" != null
    ${pkgs.coreutils}/bin/dd if="$out/disk.raw" of="$out/rootfs.ext4" bs=512 skip="$root_start" count="$root_size" iflag=fullblock conv=sparse status=none
    ${pkgs.coreutils}/bin/rm "$out/disk.raw"
  '';
  baseRoot = if sourceFormat == "arch-bootstrap" then archiveRoot else pkgs.vmTools.extractFs {
    file = "${rootfsDir}/rootfs.ext4";
    fs = "ext4";
  };
  # @cc [owner:ghuntley,label:security;deployment] foreign-linux-pam-account-helper
  # Every boot MUST install only the pinned unix_chkpwd as a regular root-owned
  # mode-04755 runtime copy at PAM's compiled helper path. The immutable source
  # MUST remain mode 0555. Unsafe runtime parents or destination nodes MUST fail
  # before copying; callers MUST NOT select paths or supply arguments.
  pamHelperInstaller = pkgs.writeShellScript "overalls-install-pam-helper" ''
    set -eu
    export LC_ALL=C
    test "$#" -eq 0
    test "$(${pkgs.coreutils}/bin/id -u)" -eq 0
    for directory in /run /run/wrappers /run/wrappers/bin; do
      test ! -L "$directory"
      if test ! -e "$directory"; then
        ${pkgs.coreutils}/bin/install -d --owner=0 --group=0 --mode=0755 -- "$directory"
      fi
      test -d "$directory"
      test "$(${pkgs.coreutils}/bin/stat -c '%u:%g:%a' -- "$directory")" = 0:0:755
    done
    helper=/run/wrappers/bin/unix_chkpwd
    if test -e "$helper" || test -L "$helper"; then
      test ! -L "$helper"
      test -f "$helper"
      test "$(${pkgs.coreutils}/bin/stat -c '%u:%g' -- "$helper")" = 0:0
    fi
    test ! -L ${pkgs.pam}/bin/unix_chkpwd
    test -f ${pkgs.pam}/bin/unix_chkpwd
    test "$(${pkgs.coreutils}/bin/stat -c '%u:%g:%a' ${pkgs.pam}/bin/unix_chkpwd)" = 0:0:555
    ${pkgs.coreutils}/bin/install --no-target-directory --owner=0 --group=0 --mode=04755 \
      ${pkgs.pam}/bin/unix_chkpwd "$helper"
    test ! -L "$helper"
    test -f "$helper"
    test "$(${pkgs.coreutils}/bin/stat -c '%u:%g:%a' -- "$helper")" = 0:0:4755
  '';
  # Nixpkgs' ext4 builder copies these closures into the guest and registers
  # their store paths. The foreign distro keeps its own package manager and
  # libc, while the guest contract uses stable FHS links to these reviewed,
  # reproducible tools for Python, networking, SSH and certificate handling.
  runtimeStorePaths = [
    pkgs.cacert pkgs.coreutils pkgs.e2fsprogs pkgs.git pkgs.iproute2
    pkgs.openssh pkgs.pam pkgs.python3 pkgs.shadow pkgs.glibc.getent
    pkgs.sudo pkgs.systemd pkgs.util-linux terminald lyraLinux pamHelperInstaller
  ] ++ githubTools.packages "linux-amd64"
    ++ lib.optionals editorEnabled [ vscodeWeb vscodeWebBroker editorConfiguration editorUnit pkgs.direnv ];
  rootfs = (pkgs.callPackage (pkgs.path + "/nixos/lib/make-ext4-fs.nix") {
    storePaths = runtimeStorePaths;
    volumeLabel = "overalls-${distribution}";
    populateImageCommands = ''
      mkdir -p ./files
      # @cc [owner:ghuntley,label:build;security] foreign-linux-upstream-executable-modes
      # Assembly MUST preserve upstream executable bits, including init, its
      # dynamic loader and the login shell. Only the build owner gains staging
      # write access; image assembly MUST NOT grant group/other write access.
      # Store normalization removes write access but preserves executable bits.
      # Dropping modes here also removes x, which chmod's conditional X cannot
      # recover and makes switch_root fail before any guest service can start.
      cp -a --no-preserve=ownership,links ${baseRoot}/. ./files/
      chmod -R u+rwX ./files
      rm -rf ./files/nix
      mkdir -p ./files/etc ./files/etc/ssh/sshd_config.d ./files/etc/pam.d ./files/etc/sudoers.d ./files/etc/systemd/system \
        ./files/etc/systemd/system/multi-user.target.wants \
        ./files/etc/systemd/system/timers.target.wants ./files/etc/systemd/system/sockets.target.wants \
        ./files/usr/bin ./files/usr/sbin ./files/usr/local/bin ./files/usr/local/lib/lilly \
        ./files/var/lib/overalls ./files/var/empty ./files/workspace
      # AlmaLinux ships /etc/ssl/certs as a symlink into its pki tree. The
      # shared CA layout below owns this path, so replace a dangling link or
      # other non-directory before creating it while preserving a real dir.
      if [ -L ./files/etc/ssl/certs ] || { [ -e ./files/etc/ssl/certs ] && [ ! -d ./files/etc/ssl/certs ]; }; then
        rm -rf ./files/etc/ssl/certs
      fi
      mkdir -p ./files/etc/ssl/certs
      touch ./files/etc/passwd ./files/etc/group
      printf '%s\n' 'overalls image: ${distribution}' > ./files/etc/overalls-distribution
      # @cc [owner:ghuntley,label:security;build] arch-root-runtime-permissions
      # Arch MUST override its vendor root tmpfiles policy with root-owned mode
      # 0755 so capability-free readiness can create and fsync its root probe.
      # The vendor policy MUST remain intact and nonroot users MUST NOT gain
      # root-directory write access.
      ${lib.optionalString (distribution == "arch") ''
        mkdir -p ./files/etc/tmpfiles.d
        rm -f ./files/etc/tmpfiles.d/root.conf
        printf 'z / 0755 root root -\n' > ./files/etc/tmpfiles.d/root.conf
        chmod 0644 ./files/etc/tmpfiles.d/root.conf
      ''}
      # Arch's bootstrap archive intentionally omits the traditional init
      # symlink. Point it at systemd so the shared Linux initrd reaches the
      # distribution's real init instead of an interactive shell.
      if [ ! -e ./files/sbin/init ]; then
        test -x ./files/usr/lib/systemd/systemd
        ln -s ../usr/lib/systemd/systemd ./files/sbin/init
      fi
      # FHS links are deliberately explicit: callers can inspect every binary
      # used by the systemd units and no host executable is copied implicitly.
      ln -sfn ${pkgs.python3}/bin/python3 ./files/usr/bin/python3
      ln -sfn ${pkgs.git}/bin/git ./files/usr/bin/git
      ln -sfn ${pkgs.iproute2}/bin/ip ./files/usr/sbin/ip
      ln -sfn ${pkgs.e2fsprogs}/bin/resize2fs ./files/usr/sbin/resize2fs
      ln -sfn ${pkgs.openssh}/bin/sshd ./files/usr/sbin/sshd
      ln -sfn ${pkgs.openssh}/bin/ssh-keygen ./files/usr/bin/ssh-keygen
      # @cc [owner:ghuntley,label:security;build] foreign-linux-sudo-setuid-copy
      # The guest sudo executable MUST be a regular root-owned setuid copy;
      # Nix store binaries are deliberately non-setuid and MUST NOT be chmodded.
      rm -f ./files/usr/bin/sudo
      # Nix forbids real setuid modes. The mkfs fakeroot invocation below sets
      # the image inode's mode without changing the unprivileged staging inode.
      install -m 0755 ${pkgs.sudo}/bin/sudo ./files/usr/bin/sudo
      ln -sfn ${pkgs.systemd}/bin/resolvectl ./files/usr/bin/resolvectl
      ln -sfn ${pkgs.glibc.getent}/bin/getent ./files/usr/bin/getent
      ln -sfn ${pkgs.util-linux}/bin/nologin ./files/usr/sbin/nologin
      for tool in groupadd useradd usermod; do
        ln -sfn ${pkgs.shadow}/bin/$tool ./files/usr/sbin/$tool
      done
      for tool in chown rm touch sync; do
        ln -sfn ${pkgs.coreutils}/bin/$tool ./files/usr/bin/$tool
      done
      ln -sfn ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt ./files/etc/ssl/certs/ca-bundle.crt
      ln -sfn ca-bundle.crt ./files/etc/ssl/certs/ca-certificates.crt

      install -D -m 0755 ${lyraLinux}/bin/overalls ./files/usr/local/bin/overalls
      install -D -m 0755 ${lyraLinux}/bin/overalls-ssh-authorize ./files/usr/local/bin/overalls-ssh-authorize
      install -D -m 0755 ${lyraLinux}/bin/overalls-host-certificate ./files/usr/local/bin/overalls-host-certificate
      install -D -m 0755 ${lyraLinux}/bin/overalls-trustd ./files/usr/local/bin/overalls-trustd
      install -D -m 0755 ${lyraLinux}/bin/overalls-workspaced ./files/usr/local/bin/overalls-workspaced
      ln -s ${githubTools.gh.linux-amd64}/bin/gh ./files/usr/local/bin/gh
      ln -s ${githubTools.lfs.linux-amd64}/bin/git-lfs ./files/usr/local/bin/git-lfs
      install -D -m 0644 ${githubTools.configuration} ./files/etc/overalls/github.gitconfig
      install -D -m 0755 ${terminald}/bin/lilly-terminald ./files/usr/local/lib/lilly/lilly-terminald
      install -D -m 0755 ${pamHelperInstaller} ./files/usr/local/lib/lilly/install-pam-helper
      install -D -m 0755 ${./network.py} ./files/usr/local/lib/lilly-network.py
      install -D -m 0755 ${./readiness.py} ./files/usr/local/lib/lilly-readiness.py
      install -D -m 0755 ${./flush.py} ./files/usr/local/lib/lilly-flush.py
      install -D -m 0755 ${./boot_report.py} ./files/usr/local/lib/lilly-boot-report.py
      ${customization}
      ${lib.optionalString editorEnabled ''
        mkdir -p ./files/nix/var/nix/gcroots
        ln -s ${vscodeWeb} ./files/nix/var/nix/gcroots/overalls-vscode-web
        ln -s ${vscodeWebBroker} ./files/nix/var/nix/gcroots/overalls-vscode-web-broker
        ln -s ${editorConfiguration} ./files/nix/var/nix/gcroots/overalls-vscode-web-configuration
        ln -s ${editorUnit} ./files/nix/var/nix/gcroots/overalls-vscode-web-unit
        ln -s ${pkgs.direnv} ./files/nix/var/nix/gcroots/overalls-vscode-web-direnv
        ln -s ${vscodeWeb}/bin/overalls-code ./files/usr/local/bin/overalls-code
        ln -s ${pkgs.direnv}/bin/direnv ./files/usr/local/bin/direnv
        install -D -m 0644 ${editorUnit} ./files/etc/systemd/system/overalls-vscode-web.service
      ''}
      # Unit sources live in the Nix store and are read-only. Do not preserve
      # those modes when copying because the distribution-neutral trust and
      # workspace units below replace files in this directory.
      cp -r --no-preserve=mode,ownership ${./ubuntu/units}/. ./files/etc/systemd/system/
      # @cc [owner:ghuntley,label:security;deployment] foreign-linux-account-command-path
      # Roster reconciliation and terminal account setup MUST resolve only the
      # explicit pinned FHS tools, including when invoked by the SSH PAM helper.
      for unit in overalls-ssh-sync lilly-terminals; do
        mkdir -p ./files/etc/systemd/system/$unit.service.d
        cat > ./files/etc/systemd/system/$unit.service.d/path.conf <<'EOF'
      [Service]
      Environment=PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      Environment=OVERALLS_SSH_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
      EOF
      done
      # Foreign Linux trustd/workspaced use the generic store strategy. The
      # base bundle is immutable; host roots are published atomically at the
      # conventional CA path on every boot.
      ${lib.optionalString (privateServiceRoots != [ ]) ''
        cat > ./files/etc/systemd/system/overalls-guest-trust.service <<EOF
      [Unit]
      Description=Install current Lilly platform trust before guest networking
      Before=lilly-network.service ssh.service
      ConditionKernelCommandLine=lilly.boot_challenge
      [Service]
      Type=notify
      NotifyAccess=main
      TimeoutStartSec=180s
      StateDirectory=overalls-trust
      StateDirectoryMode=0755
      ExecStart=/usr/local/bin/overalls-trustd linux ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
      EOF
        cat > ./files/etc/systemd/system/overalls-workspace.service <<EOF
      [Unit]
      Description=Clone the Lilly-delivered public repository into /workspace
      After=overalls-guest-trust.service
      Wants=network-online.target
      ConditionKernelCommandLine=lilly.boot_challenge
      [Service]
      Type=simple
      ExecStart=/usr/local/bin/overalls-workspaced linux /etc/ssl/certs/ca-certificates.crt /usr/bin/git
      StateDirectory=overalls-workspace
      StateDirectoryMode=0700
      RuntimeDirectory=overalls-workspace
      RuntimeDirectoryMode=0755
      Restart=on-failure
      RestartSec=5
      NoNewPrivileges=yes
      PrivateTmp=yes
      ProtectHome=yes
      ProtectSystem=strict
      ReadWritePaths=/workspace
      [Install]
      WantedBy=multi-user.target
      EOF
      ''}

      # The foreign roots do not share Ubuntu's openssh package policy. Install
      # a distro-neutral, roster-bound sshd service and preserve the same key
      # authorization and no-root-login boundary.

      # @cc [owner:ghuntley,label:security] foreign-linux-owned-ssh-policy
      # SSH MUST use a complete owned policy and pinned absolute PAM modules,
      # rather than optional distro includes or distro authentication stacks.
      # A fresh private login receipt MUST be requisite before opening a session.
      cat > ./files/etc/ssh/sshd_config <<'EOF'
      HostKey /run/overalls-ssh-host/ssh_host_ed25519_key
      HostCertificate /run/overalls-ssh-host/ssh_host_ed25519_key-cert.pub
      HostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com
      PermitRootLogin no
      PasswordAuthentication no
      PermitEmptyPasswords no
      KbdInteractiveAuthentication no
      UsePAM yes
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
      Subsystem sftp internal-sftp
      EOF
      # pam_unix supplies pam_setcred for key-authenticated sessions; a deny
      # auth module would also deny credential establishment. sshd disables
      # both password mechanisms, and managed account passwords stay locked.
      cat > ./files/etc/pam.d/sshd <<'EOF'
      auth required ${pkgs.pam}/lib/security/pam_unix.so
      account required ${pkgs.pam}/lib/security/pam_unix.so
      password required ${pkgs.pam}/lib/security/pam_deny.so
      session required ${pkgs.pam}/lib/security/pam_unix.so
      session requisite ${pkgs.pam}/lib/security/pam_exec.so quiet quiet_log type=open_session /usr/local/bin/overalls-ssh-authorize login
      EOF
      for service in sudo sudo-i; do
        cat > ./files/etc/pam.d/$service <<'EOF'
      auth required ${pkgs.pam}/lib/security/pam_unix.so
      account required ${pkgs.pam}/lib/security/pam_unix.so
      password required ${pkgs.pam}/lib/security/pam_deny.so
      session required ${pkgs.pam}/lib/security/pam_unix.so
      EOF
      done
      # /run is volatile: PAM's privileged shadow helper must be recreated on
      # every boot, before the owned sshd can accept key-authenticated users.
      cat > ./files/etc/systemd/system/overalls-pam-helpers.service <<'EOF'
      [Unit]
      Description=Install the pinned PAM account helper
      Before=ssh.service
      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/local/lib/lilly/install-pam-helper
      [Install]
      WantedBy=multi-user.target
      EOF
      cat > ./files/etc/systemd/system/ssh.service <<'EOF'
      [Unit]
      Description=Overalls roster-bound SSH server
      Requires=overalls-pam-helpers.service
      After=overalls-ssh-sync.service overalls-pam-helpers.service
      ConditionPathExists=/run/overalls-ssh-ready
      [Service]
      Type=simple
      Environment=PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      Environment=OVERALLS_SSH_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
      ExecStart=/usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
      Restart=on-failure
      [Install]
      WantedBy=multi-user.target
      EOF
      # Any vendor enablement must resolve to the same gated listener.
      ln -sfn ssh.service ./files/etc/systemd/system/sshd.service
      rm -f ./files/etc/ssh/ssh_host_*
      ${pkgs.python3}/bin/python3 ${./foreign_linux_accounts.py} ./files
      chmod 0755 ./files/var/empty
      if [ ! -e ./files/etc/sudoers ]; then
        printf '@includedir /etc/sudoers.d\n' > ./files/etc/sudoers
      fi
      printf '%%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n' > ./files/etc/sudoers.d/overalls
      chmod 0440 ./files/etc/sudoers.d/overalls
      if [ -f ./files/etc/pam.d/sshd ]; then
        printf '%s\n' 'session requisite pam_exec.so quiet quiet_log type=open_session /usr/local/bin/overalls-ssh-authorize login' >> ./files/etc/pam.d/sshd
      fi
      printf '[safe]\n\tdirectory = /workspace/*\n[include]\n\tpath = /run/overalls-workspace/git-identity/gitconfig\n\tpath = /etc/overalls/github.gitconfig\n' > ./files/etc/gitconfig
      ln -sfn /usr/lib/systemd/system/multi-user.target ./files/etc/systemd/system/default.target
      for unit in lilly-network lilly-grow-root lilly-readiness lilly-flush lilly-terminals lilly-console-ready lilly-boot-report; do
        ln -sfn ../$unit.service ./files/etc/systemd/system/multi-user.target.wants/$unit.service
      done
      ln -sfn ../overalls-pam-helpers.service ./files/etc/systemd/system/multi-user.target.wants/overalls-pam-helpers.service
      ln -sfn /dev/null ./files/etc/systemd/system/serial-getty@.service
      ln -sfn /dev/null ./files/etc/systemd/system/console-getty.service
      ${lib.optionalString (privateServiceRoots != [ ]) ''
        ${lib.optionalString editorEnabled ''
          ln -sfn ../overalls-vscode-web.service ./files/etc/systemd/system/multi-user.target.wants/overalls-vscode-web.service
        ''}
        ln -sfn ../overalls-guest-trust.service ./files/etc/systemd/system/multi-user.target.wants/overalls-guest-trust.service
        ln -sfn ../overalls-workspace.service ./files/etc/systemd/system/multi-user.target.wants/overalls-workspace.service
        ln -sfn ../ssh.service ./files/etc/systemd/system/multi-user.target.wants/ssh.service
        cp ${./ubuntu/agent-executor.service} ./files/etc/systemd/system/overalls-agent-executor.service
        ln -sfn ../overalls-agent-executor.service ./files/etc/systemd/system/multi-user.target.wants/overalls-agent-executor.service
        cp ${./ubuntu/private-dns.service} ./files/etc/systemd/system/lilly-private-dns.service
        ln -sfn ../lilly-private-dns.service ./files/etc/systemd/system/multi-user.target.wants/lilly-private-dns.service
        ln -sfn ../overalls-ssh-sync.service ./files/etc/systemd/system/multi-user.target.wants/overalls-ssh-sync.service
        ln -sfn ../overalls-ssh-sync.timer ./files/etc/systemd/system/timers.target.wants/overalls-ssh-sync.timer
        ln -sfn ../overalls-ssh-certificate.path ./files/etc/systemd/system/multi-user.target.wants/overalls-ssh-certificate.path
        mkdir -p ./files/etc/systemd/system/lilly-network.service.d
        cat > ./files/etc/systemd/system/lilly-network.service.d/trust.conf <<'EOF'
      [Unit]
      Requires=overalls-guest-trust.service
      After=overalls-guest-trust.service
      EOF
        mkdir -p ./files/etc/systemd/system/lilly-readiness.service.d
        cat > ./files/etc/systemd/system/lilly-readiness.service.d/private-dns.conf <<'EOF'
      [Unit]
      Requires=lilly-private-dns.service
      After=lilly-private-dns.service
      [Service]
      Environment="LILLY_REQUIRED_UNITS=lilly-grow-root.service lilly-private-dns.service"
      Environment=LILLY_SSH_UNIT=ssh.service
      EOF
      ''}
      for unit in ssh.socket sshd.socket systemd-networkd.service systemd-networkd.socket \
        NetworkManager.service networking.service; do
        ln -sfn /dev/null ./files/etc/systemd/system/$unit
      done
      rm -f ./files/etc/resolv.conf
      ${lib.optionalString (privateServiceRoots == [ ]) ''
        ln -sfn /dev/null ./files/etc/systemd/system/systemd-resolved.service
        printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > ./files/etc/resolv.conf
      ''}
      ${lib.optionalString (privateServiceRoots != [ ] && distribution == "almalinux") ''
          # @cc [owner:ghuntley,label:build;security] almalinux-private-resolver-runtime
          # Private Alma images MUST carry the pinned nonroot resolver service,
          # both sockets, D-Bus activation/policy and its sysusers configuration.
          # A dedicated bootstrap MUST create only that configured identity
          # before resolver/DBus startup, even when vendor sysusers is skipped.
          for unit in systemd-resolved.service systemd-resolved-varlink.socket systemd-resolved-monitor.socket; do
            install -D -m 0644 ${pkgs.systemd}/example/systemd/system/$unit ./files/usr/lib/systemd/system/$unit
          done
          install -D -m 0644 ${pkgs.systemd}/example/sysusers.d/systemd-resolve.conf ./files/usr/lib/sysusers.d/systemd-resolve.conf
          install -D -m 0644 ${pkgs.systemd}/share/dbus-1/system.d/org.freedesktop.resolve1.conf ./files/usr/share/dbus-1/system.d/org.freedesktop.resolve1.conf
          install -D -m 0644 ${pkgs.systemd}/share/dbus-1/system-services/org.freedesktop.resolve1.service ./files/usr/share/dbus-1/system-services/org.freedesktop.resolve1.service
          cat > ./files/etc/systemd/system/overalls-resolved-identity.service <<'EOF'
        [Unit]
        Description=Create the private DNS resolver service identity
        DefaultDependencies=no
        After=systemd-remount-fs.service systemd-sysusers.service
        Before=sysinit.target systemd-resolved.service dbus.socket dbus.service dbus-broker.service
        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=${pkgs.systemd}/bin/systemd-sysusers /usr/lib/sysusers.d/systemd-resolve.conf
        [Install]
        WantedBy=sysinit.target
        EOF
          mkdir -p ./files/etc/systemd/system/systemd-resolved.service.d ./files/etc/systemd/system/sysinit.target.wants
          cat > ./files/etc/systemd/system/systemd-resolved.service.d/identity.conf <<'EOF'
        [Unit]
        Requires=overalls-resolved-identity.service
        After=overalls-resolved-identity.service
        EOF
          ln -sfn ../overalls-resolved-identity.service ./files/etc/systemd/system/sysinit.target.wants/overalls-resolved-identity.service
          ln -sfn /usr/lib/systemd/system/systemd-resolved.service ./files/etc/systemd/system/dbus-org.freedesktop.resolve1.service
          for unit in systemd-resolved-varlink.socket systemd-resolved-monitor.socket; do
            ln -sfn /usr/lib/systemd/system/$unit ./files/etc/systemd/system/sockets.target.wants/$unit
          done
      ''}${lib.optionalString (privateServiceRoots != [ ]) ''
        ln -sfn /usr/lib/systemd/system/systemd-resolved.service ./files/etc/systemd/system/multi-user.target.wants/systemd-resolved.service
        mkdir -p ./files/etc/systemd/resolved.conf.d
        cat > ./files/etc/systemd/resolved.conf.d/lilly.conf <<'EOF'
      [Resolve]
      DNS=1.1.1.1 9.9.9.9
      Domains=~.
      FallbackDNS=
      DNSSEC=no
      DNSOverTLS=no
      EOF
        ln -s /run/systemd/resolve/stub-resolv.conf ./files/etc/resolv.conf
      ''}
      printf 'lilly-guest\n' > ./files/etc/hostname
      printf '127.0.0.1 localhost lilly-guest\n' > ./files/etc/hosts
      printf '/dev/vda / ext4 defaults 0 0\n' > ./files/etc/fstab
      rm -f ./files/etc/machine-id ./files/var/lib/dbus/machine-id ./files/var/lib/systemd/random-seed
      touch ./files/etc/machine-id
      chmod -R go-w ./files
      # @cc [owner:ghuntley,label:security;build] foreign-linux-sticky-temporary-directories
      # The final root MUST provide real root-owned /tmp and /var/tmp directories
      # with mode 01777 after general mode normalization. Guest accounts MUST be
      # able to create temporary files without deleting another account's files.
      for directory in ./files/tmp ./files/var/tmp; do
        test ! -L "$directory"
        mkdir -p "$directory"
        chmod 1777 "$directory"
      done
    '';
  }).overrideAttrs (previous: {
    # @cc [owner:ghuntley,label:build;verification] foreign-linux-reproducible-ext4
    # Identical root trees MUST produce identical ext4 bytes across builders.
    # Filesystem sizing MUST NOT depend on host directory sizes; source times,
    # filesystem hash seeds and every filesystem mutation's clock MUST be fixed.
    # Store optimisation's incidental hardlinks MUST NOT enter the filesystem.
    buildCommand = let
      registrationAnchor = "# Make a crude approximation of the size of the target image.";
      # @cc [owner:ghuntley,label:build;security] foreign-linux-editor-registered-closure
      # Editor-enabled roots MUST register the complete copied closure before
      # image construction and retain immutable package/configuration GC roots.
      # The shared normalizer MUST remove registration clocks and WAL/SHM bytes
      # without changing registered paths/references. No boot-time load or
      # network package installation may replace this offline registration.
      registerAtBuild = lib.optionalString editorEnabled ''
        NIX_STATE_DIR=$PWD/rootImage/nix/var/nix ${pkgs.nix}/bin/nix-store \
          --load-db --option build-users-group "" < ./rootImage/nix-path-registration
        rm ./rootImage/nix-path-registration ./rootImage/nix/var/nix/db/reserved
        ${pkgs.python3}/bin/python3 ${./ubuntu/normalize_nix_db.py} ./rootImage/nix/var/nix/db/db.sqlite
      '';
      oldSizing = ''
        numDataBlocks=$(du -s -c -B 4096 --apparent-size ./rootImage | tail -1 | awk '{ print int($1 * 1.20) }')
      '';
      oldMkfs = "faketime -f \"1970-01-01 00:00:01\" fakeroot mkfs.ext4";
      # Fakeroot mode changes and mkfs MUST share one virtual metadata state.
      # A separate fakeroot chmod process would lose sudo's setuid bit.
      newMkfs = "faketime -f \"1970-01-01 00:00:01\" fakeroot ${pkgs.runtimeShell} -e -c 'chmod 4755 ./rootImage/usr/bin/sudo; exec mkfs.ext4 \"$@\"' --";
    in
    assert lib.hasInfix oldSizing previous.buildCommand;
    assert lib.hasInfix oldMkfs previous.buildCommand;
    assert lib.hasInfix "resize2fs -M $img" previous.buildCommand;
    assert lib.hasInfix "resize2fs $img $new_size" previous.buildCommand;
    assert lib.hasInfix registrationAnchor previous.buildCommand;
    assert lib.hasInfix "./rootImage/nix-path-registration" previous.buildCommand;
    builtins.replaceStrings [ oldSizing oldMkfs "resize2fs -M $img" "resize2fs $img $new_size" "cp -a --reflink=auto" registrationAnchor ] [
      ''
        # Directory st_size differs between ext4 and ZFS build hosts. Charge
        # fixed inode headroom and sum only regular file/symlink content sizes.
        numDataBlocks=$(find ./rootImage \( -type f -o -type l \) -printf '%s\n' | awk '{ bytes += $1 } END { print int(bytes / 4096 * 1.20) + 1 }')
        find ./rootImage -print0 | xargs -0 touch -h -d @1
        export E2FSPROGS_FAKE_TIME=1 FAKETIME_DONT_FAKE_STAT=1
      ''
      "${newMkfs} -E hash_seed=44444444-4444-4444-8888-888888888888,lazy_itable_init=0,lazy_journal_init=0"
      "faketime -f \"1970-01-01 00:00:01\" resize2fs -M $img"
      "faketime -f \"1970-01-01 00:00:01\" resize2fs $img $new_size"
      "cp -a --no-preserve=links --reflink=auto"
      (registerAtBuild + registrationAnchor)
    ] previous.buildCommand;
  });
in
assert lib.assertMsg (lib.all (path: validFile path files.${path}) (builtins.attrNames files)) "Invalid or protected foreign Linux file destination/mode";
assert lib.assertMsg ((vscodeWeb == null) == (vscodeWebBroker == null)) "Foreign Linux editor and broker packages must be supplied together";
assert lib.assertMsg (!editorEnabled || minimumMemoryBytes >= 2147483648) "Browser editor guests require at least 2 GiB RAM";
# @cc [owner:ghuntley,label:security;build] foreign-linux-explicit-kernel-lsm
# Foreign Linux manifests MUST select the reviewed NixOS guest LSM stack
# explicitly. A distribution's default SELinux policy MUST NOT activate against
# the assembled root, which does not carry that distribution's SELinux labels.
# The arguments select Landlock, Yama and BPF; host VM/network authority is unchanged.
pkgs.runCommand imageName {
  nativeBuildInputs = [ pkgs.jq ];
  preferLocalBuild = true;
  passthru = {
    inherit distribution source sourceFormat boot rootfs runtimeStorePaths pamHelperInstaller
      editorEnabled editorDescriptor editorConfiguration editorUnit;
    workspaceSourceEnabled = privateServiceRoots != [ ];
  };
} ''
  set -euo pipefail
  mkdir -p "$out"
  ln -s ${boot.bootKernel}/vmlinux "$out/kernel"
  ln -s ${boot.initrd}/initrd "$out/initrd"
  ln -s ${rootfs} "$out/rootfs.ext4"
  kernel_bytes=$(stat -Lc %s "$out/kernel")
  initrd_bytes=$(stat -Lc %s "$out/initrd")
  rootfs_bytes=$(stat -Lc %s "$out/rootfs.ext4")
  minimum_disk_bytes=$rootfs_bytes
  # @cc [owner:ghuntley,label:build;capacity] foreign-linux-editor-writable-headroom
  # An editor image MUST reserve at least 2 GiB beyond its immutable rootfs,
  # rounded to whole GiB, while preserving any larger requested disk minimum.
  ${lib.optionalString editorEnabled ''
    minimum_disk_bytes=$(( (rootfs_bytes + 2147483648 + 1073741823) / 1073741824 * 1073741824 ))
  ''}
  minimum_disk_bytes=$(( minimum_disk_bytes > ${toString minimumDiskBytes} ? minimum_disk_bytes : ${toString minimumDiskBytes} ))
  jq -n \
    --arg distro ${lib.escapeShellArg distribution} \
    --argjson memory ${toString minimumMemoryBytes} --argjson disk "$minimum_disk_bytes" \
    --argjson kernel_bytes "$kernel_bytes" --arg kernel_sha256 "$(sha256sum "$out/kernel" | cut -d' ' -f1)" \
    --argjson initrd_bytes "$initrd_bytes" --arg initrd_sha256 "$(sha256sum "$out/initrd" | cut -d' ' -f1)" \
    --argjson rootfs_bytes "$rootfs_bytes" --arg rootfs_sha256 "$(sha256sum "$out/rootfs.ext4" | cut -d' ' -f1)" \
    --argjson editor '${builtins.toJSON editorDescriptor}' \
    '{version:4,architecture:"x86_64",boot_args:("console=ttyS0 root=/dev/vda rw lsm=landlock,yama,bpf overalls.distribution=" + $distro),minimum_disk_bytes:$disk,minimum_memory_bytes:$memory,workspace_source_version:${if privateServiceRoots == [] then "null" else "2"},kernel:{bytes:$kernel_bytes,sha256:$kernel_sha256},initrd:{bytes:$initrd_bytes,sha256:$initrd_sha256},rootfs:{bytes:$rootfs_bytes,sha256:$rootfs_sha256}} + ${if privateServiceRoots == [] then "{}" else "{git_identity_version:1}"} + (if $editor == null then {} else {editor:$editor} end)' \
    > "$out/manifest.json"
''
