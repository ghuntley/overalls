{ pkgs, packages }:
let
  arch = packages.mkArchGuest { imageName = "arch-evaluation"; };
  alma = packages.mkAlmaLinuxGuest { imageName = "alma-evaluation"; };
  plain = builtins.unsafeDiscardStringContext;
  archCommand = plain arch.buildCommand;
  almaCommand = plain alma.buildCommand;
  archRootCommand = plain arch.passthru.rootfs.buildCommand;
  almaRootCommand = plain alma.passthru.rootfs.buildCommand;
  almaPrivate = packages.mkAlmaLinuxGuest {
    imageName = "alma-private-evaluation";
    privateServiceRoots = [ ../../../../secrets/private-services-root.pem ];
  };
  archPrivate = packages.mkArchGuest {
    imageName = "arch-private-evaluation";
    privateServiceRoots = [ ../../../../secrets/private-services-root.pem ];
  };
  expectedEditor = {
    protocol = packages.vscodeWeb.editorProtocol;
    commit = packages.vscodeWeb.sourceCommit;
    release = packages.vscodeWeb.releaseId;
  };
  constructor = distribution: editor: broker: import (../../../domains/artifacts/guest + "/${distribution}") {
    inherit pkgs;
    inherit (packages) mkUbuntuGuest terminald lyraLinux githubTools;
    vscodeWeb = editor;
    vscodeWebBroker = broker;
  };
  accepts = builder: args: (builtins.tryEval (builder args).drvPath).success;
  fixture = pkgs.writeText "foreign-linux-custom-file" "bounded fixture\n";
  # @cc [owner:ghuntley,label:verification;security] foreign-linux-editor-options
  # Both constructors MUST reject an incomplete editor/broker pair and an
  # editor image below 2 GiB RAM. With neither package, no editor descriptor,
  # payload, service or registration hook may enter the root builder.
  editorOptions = distribution:
    let
      disabled = constructor distribution null null { };
      disabledCommand = plain disabled.rootfs.buildCommand;
    in assert !(accepts (constructor distribution packages.vscodeWeb null) { });
       assert !(accepts (constructor distribution null packages.vscodeWebBroker) { });
       assert !(accepts (constructor distribution packages.vscodeWeb packages.vscodeWebBroker) { minimumMemoryBytes = 2147483647; });
       assert !disabled.editorEnabled && disabled.editorDescriptor == null;
       assert disabled.editorConfiguration == null && disabled.editorUnit == null;
       assert !(pkgs.lib.hasInfix "overalls-vscode" disabledCommand);
       assert !(pkgs.lib.hasInfix "normalize_nix_db.py" disabledCommand);
       assert pkgs.lib.hasInfix "--argjson editor 'null'" (plain disabled.buildCommand);
       true;
  # @cc [owner:ghuntley,label:verification;security] foreign-linux-custom-file-refusals
  # Optional files MUST accept the bounded /opt fixture shape and refuse
  # traversal, control characters, platform paths, writable-to-others modes,
  # unknown fields, missing sources and untyped source/mode values.
  fileOptions = builder:
    assert accepts builder { files."/opt/overalls-editor-fixture/check.json" = { source = fixture; mode = "0444"; }; };
    assert pkgs.lib.all (path: !(accepts builder { files.${path} = { source = fixture; }; })) [
      "/opt/../etc/passwd" "/opt//fixture" "/opt/./fixture" "/opt/fixture/" "opt/fixture"
      "/etc/systemd/system/ssh.service" "/usr/local/bin/overalls-ssh-authorize" "/opt/fixture\nother"
    ];
    assert pkgs.lib.all (value: !(accepts builder { files."/opt/fixture" = value; })) [
      { source = fixture; mode = "04755"; } { source = fixture; mode = "0666"; }
      { source = fixture; mode = 444; } { source = fixture; unexpected = true; }
      { source = 7; } { source = { __toString = _: "/tmp/fixture"; }; } { mode = "0444"; }
    ];
    true;
  # @cc [owner:ghuntley,label:verification;security] foreign-linux-editor-assembly
  # Enabled roots MUST bind the exact package descriptor and current personal
  # authorizer, register the copied closure, preserve its GC roots and reserve
  # editor disk headroom. Activation MUST be private-only and independent of
  # readiness; this evaluation is not execution of the editor or guest.
  editorAssembly = base: private:
    let
      command = plain base.rootfs.buildCommand;
      privateCommand = plain private.rootfs.buildCommand;
      config = builtins.fromJSON (plain base.editorConfiguration.text);
      unit = plain base.editorUnit.text;
      activation = "../overalls-vscode-web.service ./files/etc/systemd/system/multi-user.target.wants/overalls-vscode-web.service";
      readinessLines = builtins.filter (line: pkgs.lib.hasInfix "LILLY_REQUIRED_UNITS" line) (pkgs.lib.splitString "\n" privateCommand);
    in assert base.editorEnabled && base.editorDescriptor == expectedEditor;
       assert config == {
         descriptor = expectedEditor;
         editor_executable = "${packages.vscodeWeb}/bin/overalls-code";
         systemd_run = "/usr/bin/systemd-run";
         systemctl = "/usr/bin/systemctl";
         account_authorizer = "/usr/local/bin/overalls-ssh-authorize";
         worker_path = "/usr/local/bin:/usr/bin:/bin";
       };
       assert pkgs.lib.hasInfix "After=lilly-network.service lilly-private-dns.service overalls-ssh-sync.service" unit;
       assert !(pkgs.lib.hasInfix "lilly-ready" unit);
       assert !(pkgs.lib.hasInfix "KillMode=control-group" unit);
       assert pkgs.lib.hasInfix "--load-db --option build-users-group" command;
       assert pkgs.lib.hasInfix "normalize_nix_db.py" command;
       assert pkgs.lib.all (name: pkgs.lib.hasInfix "./files/nix/var/nix/gcroots/${name}" command) [
         "overalls-vscode-web" "overalls-vscode-web-broker" "overalls-vscode-web-configuration" "overalls-vscode-web-unit"
         "overalls-vscode-web-direnv"
       ];
       assert pkgs.lib.hasInfix (plain "ln -s ${pkgs.direnv}/bin/direnv ./files/usr/local/bin/direnv") command;
       assert !(pkgs.lib.hasInfix activation command) && pkgs.lib.hasInfix activation privateCommand;
       assert readinessLines != [ ] && !(pkgs.lib.any (line: pkgs.lib.hasInfix "vscode" line) readinessLines);
       assert pkgs.lib.hasInfix "rootfs_bytes + 2147483648 + 1073741823" (plain base.buildCommand);
       true;
  almaPrivateRootCommand = plain almaPrivate.passthru.rootfs.buildCommand;
  archSourceName = builtins.baseNameOf (toString arch.passthru.source);
  almaSourceName = builtins.baseNameOf (toString alma.passthru.source);
  # @cc [owner:ghuntley,label:verification] foreign-linux-builder-evaluation
  # Arch and Alma builders MUST use their own pinned upstream rootfs inputs;
  # a marker alone is not evidence of a different distribution.
  check = image: command: marker:
    assert image.passthru.distribution == marker;
    assert image.passthru.sourceFormat != "ubuntu";
    assert pkgs.lib.hasInfix "version:4" command;
    assert pkgs.lib.hasInfix "kernel:{bytes:" command;
    assert pkgs.lib.hasInfix "rootfs:{bytes:" command;
    assert pkgs.lib.hasInfix "overalls.distribution=" command;
    assert pkgs.lib.hasInfix "lsm=landlock,yama,bpf" command;
    assert builtins.elem image.passthru.sourceFormat [ "arch-bootstrap" "qcow2-ext4" ];
    true;
  # @cc [owner:ghuntley,label:verification] foreign-linux-determinism-inputs
  # Both foreign builders MUST fix filesystem clocks and hash seeds and avoid
  # directory st_size in image sizing. Evaluation guards these inputs only;
  # byte reproducibility requires rebuilding the actual rootfs derivations.
  reproducible = command:
    assert pkgs.lib.hasInfix "find ./rootImage \\( -type f -o -type l \\) -printf '%s\\n'" command;
    assert !(pkgs.lib.hasInfix "du -s -c -B 4096 --apparent-size ./rootImage" command);
    assert pkgs.lib.hasInfix "touch -h -d @1" command;
    assert !(pkgs.lib.hasInfix "cp -a --reflink=auto" command);
    assert pkgs.lib.hasInfix "cp -a --no-preserve=links --reflink=auto" command;
    assert pkgs.lib.hasInfix "cp -a --no-preserve=ownership,links" command;
    assert !(pkgs.lib.hasInfix "cp -a --no-preserve=mode,ownership,links" command);
    assert pkgs.lib.hasInfix "chmod -R u+rwX ./files" command;
    assert !(pkgs.lib.hasInfix "chmod -R a+rwX ./files" command);
    assert pkgs.lib.hasInfix "E2FSPROGS_FAKE_TIME=1 FAKETIME_DONT_FAKE_STAT=1" command;
    assert pkgs.lib.hasInfix "hash_seed=44444444-4444-4444-8888-888888888888,lazy_itable_init=0,lazy_journal_init=0" command;
    assert pkgs.lib.hasInfix ''faketime -f "1970-01-01 00:00:01" resize2fs -M $img'' command;
    assert pkgs.lib.hasInfix ''faketime -f "1970-01-01 00:00:01" resize2fs $img $new_size'' command;
    true;
  # @cc [owner:ghuntley,label:verification;security] foreign-linux-account-runtime-inputs
  # Both rootfs builders MUST own SSH/PAM policy, install executable account
  # tools with a fixed unit PATH, and copy sudo with setuid mode. These checks
  # guard assembly inputs only; runtime SSH and elevation require native boots.
  accountRuntime = command:
    assert pkgs.lib.hasInfix "cat > ./files/etc/ssh/sshd_config <<'EOF'" command;
    assert pkgs.lib.hasInfix "UsePAM yes" command;
    assert pkgs.lib.hasInfix "PermitRootLogin no" command;
    assert pkgs.lib.hasInfix "AuthorizedKeysFile none" command;
    assert pkgs.lib.hasInfix "AuthorizedKeysCommandUser overalls-ssh" command;
    assert pkgs.lib.hasInfix (plain "session requisite ${pkgs.pam}/lib/security/pam_exec.so quiet quiet_log type=open_session /usr/local/bin/overalls-ssh-authorize login") command;
    assert pkgs.lib.hasInfix (plain "install -m 0755 ${pkgs.sudo}/bin/sudo ./files/usr/bin/sudo") command;
    assert pkgs.lib.hasInfix (plain "fakeroot ${pkgs.runtimeShell} -e -c 'chmod 4755 ./rootImage/usr/bin/sudo; exec mkfs.ext4 \"$@\"' --") command;
    assert !(pkgs.lib.hasInfix (plain "ln -sfn ${pkgs.sudo}/bin/sudo") command);
    assert pkgs.lib.hasInfix (plain "${pkgs.glibc.getent}/bin/getent") command;
    assert pkgs.lib.hasInfix (plain "${pkgs.shadow}/bin/$tool") command;
    assert pkgs.lib.hasInfix "Environment=PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" command;
    assert pkgs.lib.hasInfix "ln -sfn ssh.service ./files/etc/systemd/system/sshd.service" command;
    assert pkgs.lib.hasInfix "@includedir /etc/sudoers.d" command;
    assert pkgs.lib.hasInfix "foreign_linux_accounts.py" command;
    assert pkgs.lib.hasInfix ''for directory in ./files/tmp ./files/var/tmp'' command;
    assert pkgs.lib.hasInfix ''chmod 1777 "$directory"'' command;
    true;
  # @cc [owner:ghuntley,label:verification;security] foreign-linux-pam-helper-assembly
  # Both builders MUST install the fixed runtime helper installer and order the
  # owned SSH listener after its successful persistent oneshot. Missing helper
  # units, dependencies or installation MUST fail, including on older inputs.
  pamHelperAssembly = command: pkgs.lib.all (input: pkgs.lib.hasInfix input command) [
    "./files/usr/local/lib/lilly/install-pam-helper"
    "cat > ./files/etc/systemd/system/overalls-pam-helpers.service <<'EOF'"
    "Requires=overalls-pam-helpers.service"
    "After=overalls-ssh-sync.service overalls-pam-helpers.service"
    "ExecStart=/usr/local/lib/lilly/install-pam-helper"
    "RemainAfterExit=yes"
    "../overalls-pam-helpers.service ./files/etc/systemd/system/multi-user.target.wants/overalls-pam-helpers.service"
  ];
in
assert check arch archCommand "arch";
assert check alma almaCommand "almalinux";
assert editorOptions "arch" && editorOptions "alma";
assert fileOptions packages.mkArchGuest && fileOptions packages.mkAlmaLinuxGuest;
assert editorAssembly arch archPrivate && editorAssembly alma almaPrivate;
assert reproducible archRootCommand;
assert reproducible almaRootCommand;
assert accountRuntime archRootCommand;
assert accountRuntime almaRootCommand;
assert pamHelperAssembly archRootCommand;
assert pamHelperAssembly almaRootCommand;
assert !pamHelperAssembly (builtins.replaceStrings [ "cat > ./files/etc/systemd/system/overalls-pam-helpers.service <<'EOF'" ] [ "" ] archRootCommand);
assert !pamHelperAssembly (builtins.replaceStrings [ "Requires=overalls-pam-helpers.service" ] [ "" ] almaRootCommand);
assert !pamHelperAssembly (builtins.replaceStrings [ "After=overalls-ssh-sync.service overalls-pam-helpers.service" ] [ "After=overalls-ssh-sync.service" ] archRootCommand);
assert pkgs.lib.hasInfix "z / 0755 root root -" archRootCommand;
assert !(pkgs.lib.hasInfix "z / 0755 root root -" almaRootCommand);
# @cc [owner:ghuntley,label:verification;build;security] almalinux-resolver-assembly-scope
# Only private Alma roots MUST install the pinned resolver bundle and scoped
# identity bootstrap. Plain Alma and Arch assembly MUST retain their own paths.
assert pkgs.lib.hasInfix "example/systemd/system/$unit" almaPrivateRootCommand;
assert pkgs.lib.hasInfix "systemd-resolved-monitor.socket" almaPrivateRootCommand;
assert pkgs.lib.hasInfix "example/sysusers.d/systemd-resolve.conf" almaPrivateRootCommand;
assert pkgs.lib.hasInfix "share/dbus-1/system.d/org.freedesktop.resolve1.conf" almaPrivateRootCommand;
assert pkgs.lib.hasInfix "share/dbus-1/system-services/org.freedesktop.resolve1.service" almaPrivateRootCommand;
assert pkgs.lib.hasInfix (plain "ExecStart=${pkgs.systemd}/bin/systemd-sysusers /usr/lib/sysusers.d/systemd-resolve.conf") almaPrivateRootCommand;
assert pkgs.lib.hasInfix "Requires=overalls-resolved-identity.service" almaPrivateRootCommand;
assert !(pkgs.lib.hasInfix "overalls-resolved-identity.service" almaRootCommand);
assert !(pkgs.lib.hasInfix "overalls-resolved-identity.service" archRootCommand);
assert arch.name == "arch-evaluation";
assert alma.name == "alma-evaluation";
# The source format remains part of the evaluated catalog contract, so a
# future refactor cannot silently present one distribution as the other.
assert arch.passthru.distribution != alma.passthru.distribution;
assert arch.passthru.sourceFormat != alma.passthru.sourceFormat;
assert pkgs.lib.hasInfix "archlinux-bootstrap" archSourceName;
assert pkgs.lib.hasInfix "AlmaLinux-10-GenericCloud" almaSourceName;
# The runtime setup is part of the rootfs derivation, rather than an
# evaluation-only marker. Keep these checks close to the image contract so a
# future source refactor cannot silently drop guest services.
assert pkgs.lib.hasInfix "overalls-trustd" archRootCommand;
assert pkgs.lib.hasInfix "overalls-workspaced" archRootCommand;
assert pkgs.lib.hasInfix "lilly-terminald" archRootCommand;
assert pkgs.lib.hasInfix "lilly-readiness.py" archRootCommand;
assert pkgs.lib.hasInfix "overalls-trustd" almaRootCommand;
assert pkgs.lib.hasInfix "overalls-workspaced" almaRootCommand;
assert pkgs.lib.hasInfix "lilly-terminald" almaRootCommand;
assert pkgs.lib.hasInfix "lilly-readiness.py" almaRootCommand;
pkgs.runCommand "foreign-linux-guest-evaluation" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  test ${pkgs.lib.escapeShellArg arch.passthru.distribution} = arch
  test ${pkgs.lib.escapeShellArg alma.passthru.distribution} = almalinux
  cp ${../../../domains/artifacts/guest/foreign_linux_accounts.py} foreign_linux_accounts.py
  cp ${../../../domains/artifacts/guest/test_foreign_linux_accounts.py} test_foreign_linux_accounts.py
  python3 -m unittest test_foreign_linux_accounts
  touch "$out"
''
