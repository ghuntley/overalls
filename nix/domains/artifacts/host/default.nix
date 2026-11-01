{ pkgs }:
let
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  source = pkgs.runCommand "overalls-host-source" {} ''
    mkdir -p $out
    cp ${./.}/*.py $out/
    cp ${../secrets/cli.py} $out/secrets_cli.py
  '';
  anywhere = import ./installer.nix { inherit pkgs; };
in pkgs.writeShellApplication {
  name = "host";
  # tools/buck2 of the published checkout builds every host output (ADR-0269);
  # it runs bash, coreutils, awk, sed, findutils, git, nix and python3.
  runtimeInputs = [ python pkgs.sops pkgs.age pkgs.ssh-to-age pkgs.nix pkgs.git pkgs.openssh anywhere
    pkgs.bash pkgs.coreutils pkgs.gawk pkgs.gnused pkgs.findutils ];
  text = ''
    exec ${python}/bin/python ${source}/cli.py "$@"
  '';
}
