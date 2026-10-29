{ pkgs, terminald, lyraLinux }:
let
  inherit (pkgs) lib;
  source = lib.fileset.toSource {
    # Keep the source tree rooted at the Nix checkout.  The guest constructor
    # imports sibling system modules through the `nix/domains/...` hierarchy;
    # flattening `guest/` to the fileset root makes those imports resolve to
    # `/nix/system/...` in the generated offline recipe.
    root = ../../../..;
    fileset = lib.fileset.unions [
      ../.
      ../../../system/nix-cache.nix
      ../../../../platform/nix-cache.nix
    ];
  };
  # @cc [owner:ghuntley,label:security;build] inception-nested-image-public-input
  # The runtime recipe MUST use the same pinned package and guest sources as
  # its prewarmed build closure. It MUST reject private-key material before
  # copying the input into the store and keep the public root as a reproducible
  # image input. No writable-root injection or TLS verification bypass is allowed.
  expression = ''
    { rootCertificate }:
    let
      pkgs = import ${pkgs.path} {
        system = "${pkgs.stdenv.hostPlatform.system}";
        config = {};
        overlays = [];
      };
      pem = builtins.readFile (builtins.toPath rootCertificate);
      pemLines = pkgs.lib.splitString "\n" pem;
      # Line-wise scanning keeps each regex bounded; whole-file hasInfix
      # overflows Nix's regex stack on large CA bundles.
      hasCertificate = pkgs.lib.any (line: pkgs.lib.hasInfix "BEGIN CERTIFICATE" line) pemLines;
      hasPrivateKey = pkgs.lib.any (line: pkgs.lib.hasInfix "PRIVATE KEY" line) pemLines;
    in
    assert pkgs.lib.assertMsg (hasCertificate && !hasPrivateKey)
      "Nested guest trust requires public certificates only";
    import ${source}/domains/artifacts/guest {
      inherit pkgs;
      terminald = ${terminald};
      lyraLinux = ${lyraLinux};
      privateServiceRoots = [ (builtins.path {
        path = builtins.toPath rootCertificate;
        name = "inception-private-root.pem";
      }) ];
      # The rebuilt child is still the Inception console-gated seed. Keep its
      # SSH roster service enabled and retrying, but let boot readiness precede
      # namespace publication so roster authority can become available later.
      extraModules = [
        ({ lib, ... }: {
          systemd.services.lilly-readiness.serviceConfig.Environment =
            lib.mkForce "LILLY_SSH_UNIT=";
        })
      ];
    }
  '';
  recipe = pkgs.writeText "inception-nested-image.nix" expression;
  # A public system bundle exercises the enabled private-service build graph.
  # This cache seed is not enrolled or selected as an environment's guest image.
  # Construct it directly so pure flake evaluation retains the derivation
  # contexts. The exported recipe intentionally contains literal store paths for
  # the guest's offline evaluator; importing that generated text here would turn
  # those paths back into unrestricted builtins.storePath lookups.
  # Construct the seed from the checked-out guest constructor directly.  The
  # exported recipe above is the runtime source tree; evaluating the local
  # constructor here retains derivation contexts under pure flake evaluation
  # without attempting to coerce a subdirectory of the fileset output into an
  # unrestricted store-path lookup.
  seed = import ../default.nix {
    inherit pkgs terminald lyraLinux;
    privateServiceRoots = [ "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];
    # This seed is used only for Inception's console-gated child bootstrap.
    # Keep roster SSH enabled and retrying, but do not make initial boot
    # readiness wait for the inner Audi namespace that is published only after
    # readiness. Ordinary guest images retain the SSH readiness gate.
    extraModules = [
      ({ lib, ... }: {
        systemd.services.lilly-readiness.serviceConfig.Environment =
          lib.mkForce "LILLY_SSH_UNIT=";
      })
    ];
  };
  # @cc [owner:ghuntley,label:build] inception-nested-image-offline-closure
  # The cache MUST retain the seed derivation's recursive build closure, the
  # pinned package sources used at evaluation time, and the recipe itself, so
  # a new independent public root can rebuild the enabled image with offline
  # local builders. Inert documentation and unpacked-source outputs MUST be
  # excluded: a certificate rebuild never executes those toolchain builds, and
  # the retained set MUST stay within the nested image's root filesystem
  # budget enforced by the manifest validator. The cache contains outputs
  # only, never instance credentials.
  closure = pkgs.closureInfo {
    rootPaths = [ seed.drvPath recipe source pkgs.path lyraLinux ];
  };
in {
  # The seed is a complete private-services guest whose trust is replaced by
  # Lilly's boot-bound delivery. Inception can use it directly when rebuilding
  # an ext4 image would exceed the nested host's bounded startup window.
  inherit recipe closure seed;
  # @cc [owner:ghuntley,label:build] inception-nested-image-runtime-cache
  # The cache output MUST retain the recipe and every closure store path in a
  # single runtime reference, so baking it into an environment keeps the whole
  # offline rebuild graph present in that environment's local store.
  cache = pkgs.runCommand "inception-image-cache" {
    nativeBuildInputs = [ pkgs.coreutils ];
  } ''
    mkdir -p $out
    ln -s ${recipe} $out/recipe.nix
    # The exported recipe imports both trees while evaluating inside the
    # environment. Keep them as explicit runtime references before filtering
    # incidental compiler and package sources from the seed closure.
    ln -s ${source} $out/pinned-guest-source
    ln -s ${pkgs.path} $out/pinned-nixpkgs-source
    ln -s ${lyraLinux} $out/pinned-linux-cli
    number=0
    while read -r path; do
      case "$path" in
        # The seed image itself is rebuilt, never reused.
        ${seed}) continue ;;
      esac
      name="''${path##*/}"
      name="''${name#*-}"
      case "$name" in
        # Derivation files expand to every output of their build graph during
        # closure computation, which reintroduces the inert outputs below and
        # exceeds the image budget; the offline rebuild re-instantiates them.
        *.drv) ;;
        # A certificate rebuild never executes source/vendor or compiler
        # toolchains whose compiled outputs already serve every package the
        # rebuild links; excluding them keeps the cache within the nested
        # image's root filesystem budget. The seed rootfs is also rebuilt.
        ext4-fs.img|*-ext4-fs.img) ;;
        source|source-*|*-source|*-source-*|vendor|vendor-*|*-vendor|*-vendor-*) ;;
        ghc-*|ghc-binary-*|*ghc-binary-*|*ghc-[0-9]*|shake-[0-9]*) ;;
        lyra-rust-toolchain-*|cargo-zigbuild-*|rust-std-*|MacOSX*.sdk.tar.xz|rustc-*|rust-*-x86_64-unknown-linux-gnu.tar.gz|llvm-*|clang-*|zig-*|go-[0-9]*|go[0-9]*.src.tar.gz) ;;
        *-debug|*-devdoc|*-doc|*-man|*-info|*-src|*-src-[0-9]*) ;;
        *)
          number=$((number + 1))
          ln -s "$path" "$out/$number-''${path##*/}"
          ;;
      esac
    done < ${closure}/store-paths
  '';
}
