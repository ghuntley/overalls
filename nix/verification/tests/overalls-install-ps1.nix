{ pkgs }:
# @cc [owner:ghuntley,label:verification;security] overalls-install-ps1-check
# The Windows installer MUST parse under PowerShell and MUST refuse a non-https
# origin, a foreign management host, a foreign zone and a host outside the zone
# before any network access or file write. overalls-install-ps1.sh holds the
# checks; the Buck2 //nix:overalls-install-ps1 target is canonical and this
# Nix check stays until M11.
pkgs.runCommand "overalls-install-ps1-check" {
  nativeBuildInputs = [ pkgs.powershell ];
  script = ../../../marshall/priv/overalls-install.ps1;
} ''
  ${pkgs.bash}/bin/bash ${./overalls-install-ps1.sh} "$script"
  touch "$out"
''
