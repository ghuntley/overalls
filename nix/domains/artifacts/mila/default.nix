# Mila native client artifacts. The Flutter client has been retired; all
# platform UI targets are native wrappers over the shared Rust workspace.
{ pkgs }:
let
  inherit (pkgs) lib;
  root = ../../../../mila;
  version = "0.1.0";
  nativeLinux = import ./native-linux.nix { inherit pkgs lib; };
  rust = import ./rust.nix { inherit pkgs; };
  sourceBundle = import ./source-bundle.nix { inherit pkgs version root; };
  windowsSourceBundle = import ./windows-source-bundle.nix { inherit pkgs version root; };
  linuxRelease = pkgs.runCommand "mila-linux-release-${version}" { } ''
    mkdir -p $out
    name=mila-${version}-linux-x86_64.tar.gz
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
      -czf $out/$name -C ${nativeLinux} .
    (cd $out && sha256sum $name > SHA256SUMS)
  '';
in {
  linuxNative = nativeLinux;
  linuxRelease = linuxRelease;
  linuxDev = nativeLinux;
  sourceBundle = sourceBundle;
  windowsSourceBundle = windowsSourceBundle;
  rust = rust.package;
  rustCheck = rust.check;
  # Native machine checks consume the release binary directly.
  integration = nativeLinux;
  demo = nativeLinux;
  probe = nativeLinux;
}
