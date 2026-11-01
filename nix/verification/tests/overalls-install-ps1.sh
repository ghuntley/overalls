#!/usr/bin/env bash
# Usage: overalls-install-ps1.sh INSTALL_PS1
# Run by the Buck2 //nix:overalls-install-ps1 check, with pwsh on PATH and a
# scratch HOME as the working directory's parent.

# @cc [owner:ghuntley,label:verification;security] overalls-install-ps1-check
# The Windows installer MUST parse under PowerShell and MUST refuse a non-https
# origin, a foreign management host, a foreign zone and a host outside the zone
# before any network access or file write.
set -euo pipefail
script=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
mkdir -p "$HOME"
cd "$work"
sed -e 's/@OVERALLS_MANAGEMENT_HOST@/overalls.example/' \
    -e 's/@OVERALLS_GUEST_ZONE@/apps.overalls.example/' "$script" > install.ps1
pwsh -NoProfile -NonInteractive -Command '
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile("install.ps1", [ref]$null, [ref]$errors)
  if ($errors.Count -gt 0) { $errors | ForEach-Object { [Console]::Error.WriteLine($_.ToString()) }; exit 1 }
'
refuse() {
  expected="$1"; shift
  if pwsh -NoProfile -NonInteractive -File install.ps1 "$@" 2> err.txt; then
    echo "installer accepted $*"; exit 1
  fi
  grep -q -- "$expected" err.txt || { echo "expected '$expected' for $*"; cat err.txt; exit 1; }
}
host=vm-0123456789abcdef0123456789abcdef.apps.overalls.example
refuse 'origin must be an https:// URL' http://overalls.example apps.overalls.example "$host"
refuse 'origin does not match this installer' https://evil.example apps.overalls.example "$host"
refuse 'zone does not match this installer' https://overalls.example apps.evil.example "$host"
refuse 'invalid machine host' https://overalls.example apps.overalls.example vm.other.example
refuse 'invalid machine host' https://overalls.example apps.overalls.example 'a;b.apps.overalls.example'
test ! -e "$HOME/AppData"
