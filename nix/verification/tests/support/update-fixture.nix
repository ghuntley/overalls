{ pkgs, buck2 }:
# Offline Buck2 fixture repository for updater machine tests (ADR-0271).
# support/update.py copies /etc/overalls-update-fixture into each in-VM Git
# repository and publishes candidates as flake inputs. The repository uses the
# real tools/buck2, .buckconfig, toolchains and fleet rules, and the buck2 that
# buckCells pins; only the toolchain paths are cut down to what the deployment
# rule runs, so no network or full toolchain closure is needed in the VM.
# Tests import `module`; host-enrollment seeds `skeleton` into its nested VM.
let
  root = ../../../..;
  cells = import ../../../buck/cells.nix {
    inherit pkgs buck2;
    toolchain = null;
    fixture = {
      # What the deployment rule runs; toolchains/BUCK declares the rest,
      # which no fixture action runs.
      tools = {
        bash = "${pkgs.bash}/bin/bash";
        coreutils = "${pkgs.coreutils}/bin";
        python = "${pkgs.python3}/bin/python3";
        nix = "${pkgs.nix}/bin/nix";
        jq = "${pkgs.jq}/bin/jq";
        nix_store = "${pkgs.nix}/bin/nix-store";
      };
      stub = "${pkgs.coreutils}";
    };
  };
  skeleton = pkgs.runCommand "overalls-update-fixture" { } ''
    mkdir -p "$out/tools" "$out/toolchains" "$out/buck" "$out/fleet/hosts/host"
    cp ${root + "/.buckconfig"} "$out/.buckconfig"
    cp ${root + "/.gitignore"} "$out/.gitignore"
    install -m 0755 ${root + "/tools/buck2"} "$out/tools/buck2"
    # The whole toolchains cell: its BUCK loads every sibling .bzl.
    cp -r ${root + "/toolchains"}/. "$out/toolchains/"
    chmod -R u+w "$out/toolchains"
    # The whole rules package: buck/BUCK loads its siblings.
    cp -r ${root + "/buck"}/. "$out/buck/"
    chmod -R u+w "$out/buck"
    # The fixture holds no application sources, so its assemblies take every
    # leaf from the Nix package set: production hosts pass ASSEMBLY_ARTIFACTS.
    printf '%s\n' 'ASSEMBLY_ARTIFACTS = {}' > "$out/buck/artifacts.bzl"
    # A host package declares itself exactly as fleet/hosts/<host>/BUCK does.
    printf '%s\n' 'load("@root//buck:fleet.bzl", "fleet_host")' "" 'fleet_host()' > "$out/fleet/hosts/host/BUCK"
    cat > "$out/BUCK" <<'EOF'
    load("//buck:nix.bzl", "nix_owned", "owned_set")

    nix_owned()

    # The declared assembly tree: the root package and the host package.
    owned_set(name = "flake_srcs", deps = [":srcs", "//fleet/hosts/host:srcs"], visibility = ["PUBLIC"])
    EOF
    printf '%s\n' ${cells} > "$out/cells"
  '';
in
{
  inherit cells skeleton;
  module = { environment.etc."overalls-update-fixture".source = skeleton; };
}
