{ pkgs, mkUbuntuGuest, terminald, lyraLinux, vscodeWeb ? null, vscodeWebBroker ? null }:
import ../foreign-linux.nix {
  inherit pkgs mkUbuntuGuest terminald lyraLinux vscodeWeb vscodeWebBroker;
  distribution = "arch";
  defaultImageName = "lilly-archlinux-x86_64";
  source = pkgs.fetchurl {
    url = "https://geo.mirror.pkgbuild.com/iso/2026.10.01/archlinux-bootstrap-2026.10.01-x86_64.tar.zst";
    hash = (import ../../pins.nix).archLinuxBootstrap;
  };
  sourceFormat = "arch-bootstrap";
}
