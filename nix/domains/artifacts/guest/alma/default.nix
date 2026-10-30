{ pkgs, mkUbuntuGuest, terminald, lyraLinux, vscodeWeb ? null, vscodeWebBroker ? null }:
import ../foreign-linux.nix {
  inherit pkgs mkUbuntuGuest terminald lyraLinux vscodeWeb vscodeWebBroker;
  distribution = "almalinux";
  defaultImageName = "lilly-almalinux-x86_64";
  source = pkgs.fetchurl {
    url = "https://vault.almalinux.org/10.1/cloud/x86_64/images/AlmaLinux-10-GenericCloud-ext4-10.1-20260518.0.x86_64.qcow2";
    hash = (import ../../pins.nix).almaLinuxCloudImage;
  };
  sourceFormat = "qcow2-ext4";
}
