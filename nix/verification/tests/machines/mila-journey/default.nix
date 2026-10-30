{ pkgs, module, packages }:
let
  driver = "${packages.mila.rust}/bin/mila-journey";
in
pkgs.testers.runNixOSTest {
  name = "overalls-mila-journey";
  nodes.control = { ... }: {
    imports = [ (import ./fixture.nix { inherit module packages; }) ];
    users.users.mila = { isNormalUser = true; home = "/home/mila"; };
    environment.systemPackages = [
      (pkgs.runCommand "mila-journey-driver" { } ''
        mkdir -p $out/bin
        ln -s ${driver} $out/bin/mila-journey
      '')
    ];
  };
  # @cc [owner:ghuntley,label:verification;security] mila-journey-machine-scope
  # Every subtest MUST drive the Rust core through its production C FFI over
  # strict-certificate SSH into the packaged Porsche and Marshall releases and
  # assert durable Marshall effects. Approval MUST complete in a real browser.
  # The synthetic host observation establishes admission and intent only: this
  # check MUST NOT claim guest execution, terminal PTY output, push delivery or
  # platform key custody.
  testScript = builtins.readFile ./driver.py;
}
