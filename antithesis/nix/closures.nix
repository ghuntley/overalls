{ pkgs }:
let
  inherit (pkgs) lib;
  # These are runtime tools, not build inputs downloaded by Docker. The link
  # farm supplies ordinary command lookup for release scripts and entrypoints.
  runtimeTools = pkgs.buildEnv {
    name = "overalls-antithesis-runtime-tools";
    paths = [
      pkgs.bash pkgs.coreutils pkgs.findutils pkgs.gawk pkgs.gnugrep
      pkgs.gnused pkgs.procps pkgs.util-linux pkgs.openssl pkgs.curl
      pkgs.socat pkgs.iproute2 pkgs.netcat-openbsd pkgs.jq pkgs.xxd
    ];
    pathsToLink = [ "/bin" ];
    ignoreCollisions = true;
  };
  commonRoots = [ runtimeTools pkgs.cacert ];
  # @cc [owner:ghuntley,label:build] image-recursive-closure
  # Each Docker context MUST contain every Nix store path transitively
  # referenced by its runtime roots, including its source-built release.
  mkContext = { name, application ? null, release ? null, extraRoots ? [ ], extraLinks ? { } }:
    let
      roots = commonRoots ++ lib.optional (release != null) release ++ extraRoots;
      closure = pkgs.closureInfo { rootPaths = roots; };
      manifest = pkgs.writeText "overalls-antithesis-${name}-identity.json" (builtins.toJSON {
        format = 1;
        inherit name application;
        system = pkgs.stdenv.hostPlatform.system;
        release = if release == null then null else toString release;
        releaseDerivation = if release == null then null else release.drvPath;
        # A Buck2-built release (an import) has no Nix source; null there.
        source = if release == null || !(release ? src) then null else toString release.src;
        roots = map toString roots;
      });
      links = lib.concatStringsSep "\n" (lib.mapAttrsToList
        (target: source: ''
          mkdir -p "$(dirname "$out/rootfs/${target}")"
          ln -s ${lib.escapeShellArg source} "$out/rootfs/${target}"
        '') extraLinks);
    in
    assert builtins.elem name [ "marshall" "lilly" "lilly-guest" "audi" "porsche" "ziggy" "galileo" "brady" "enrico" "workload" "origin" "smtp" "producer-peer" "request-recorder" "trace-spool" "pg" "guest-vmm" "router-vmm" "host-vmm" "private-host-vmm" "recorder-host-vmm" ];
    assert (release == null) == (application == null);
    pkgs.runCommand "overalls-antithesis-${name}-context" {
      nativeBuildInputs = [ pkgs.coreutils ];
      preferLocalBuild = true;
    } ''
      mkdir -p "$out/rootfs/nix/store" "$out/rootfs/etc/ssl/certs" \
        "$out/rootfs/bin" "$out/rootfs/usr" "$out/rootfs/opt/overalls" \
        "$out/rootfs/tmp" "$out/rootfs/run" "$out/rootfs/var/lib/overalls-antithesis-sdk"
      while IFS= read -r storePath; do
        case "$storePath" in
          /nix/store/*) cp --archive --no-preserve=ownership --parents "$storePath" "$out/rootfs" ;;
          *) echo "invalid closure path" >&2; exit 1 ;;
        esac
      done < ${closure}/store-paths
      ln -s ${pkgs.bash}/bin/bash "$out/rootfs/bin/sh"
      ln -s ${runtimeTools}/bin "$out/rootfs/usr/bin"
      ln -s ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
        "$out/rootfs/etc/ssl/certs/ca-certificates.crt"
      ${lib.optionalString (release != null) ''
        mkdir -p "$out/rootfs/opt/overalls/${application}"
        rmdir "$out/rootfs/opt/overalls/${application}"
        ln -s ${release} "$out/rootfs/opt/overalls/${application}"
      ''}
      ${links}
      cat > "$out/rootfs/etc/passwd" <<'PASSWD'
      root:x:0:0:root:/root:/bin/sh
      overalls:x:10001:10001:overalls:/var/lib/overalls:/bin/sh
      PASSWD
      cat > "$out/rootfs/etc/group" <<'GROUP'
      root:x:0:
      overalls:x:10001:
      GROUP
      ${lib.optionalString (name == "pg") ''
        # The PostgreSQL container has one stable unprivileged runtime UID.
        # Its writable volume is private to this image, so UID 10001 is the
        # same synthetic-service identity used by the other closures.
        sed -i '/^overalls:/d' "$out/rootfs/etc/passwd" "$out/rootfs/etc/group"
        printf 'postgres:x:10001:10001:postgres:/var/lib/postgresql:/bin/sh\n' >> "$out/rootfs/etc/passwd"
        printf 'postgres:x:10001:\n' >> "$out/rootfs/etc/group"
      ''}
      chmod 1777 "$out/rootfs/tmp"
      chmod 0750 "$out/rootfs/var/lib/overalls-antithesis-sdk"
      cp ${manifest} "$out/identity.json"
      cp ${manifest} "$out/rootfs/opt/overalls/image-identity.json"
      cp ${closure}/store-paths "$out/closure-store-paths.txt"
      cp ${closure}/store-paths "$out/rootfs/opt/overalls/closure-store-paths.txt"
    '';
in
{ inherit mkContext runtimeTools; }
