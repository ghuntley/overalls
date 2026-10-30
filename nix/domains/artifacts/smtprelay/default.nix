# Based on ghuntley/loom third_party/smtprelay: Grafana v2.2.3, MIT upstream.
{ lib, buildGoModule, fetchFromGitHub }:
buildGoModule rec {
  pname = "overalls-smtprelay";
  version = "2.2.3";
  src = fetchFromGitHub {
    owner = "grafana";
    repo = "smtprelay";
    rev = "v${version}";
    hash = (import ../pins.nix).smtprelaySource;
  };
  vendorHash = (import ../pins.nix).smtprelayVendor;
  patches = [ ./transport.patch ];
  ldflags = [ "-s" "-w" ];
  env.OTEL_SDK_DISABLED = "true";
  doCheck = true;
  meta = {
    description = "Synchronous SMTP relay with bounded verified upstream delivery";
    homepage = "https://github.com/grafana/smtprelay";
    license = lib.licenses.mit;
    mainProgram = "smtprelay";
  };
}
