{ pkgs }:
let
  inherit (pkgs) lib;
  # @cc [owner:ghuntley,label:build] antithesis-wheel-source
  # The runtime image and Python static gates MUST consume this same fixed-output
  # wheel closure. A new workload wheel dependency MUST be pinned here before
  # the workload or its static gate uses it.
  wheels = [
    (pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/9d/7f/45fe532ac4cb372026acc4b8d8f0807b6c5791ff05c5d1adb988f0bdcc73/antithesis-0.4.0-py3-none-any.whl";
      hash = (import ../../nix/domains/artifacts/pins.nix).antithesisWheelAntithesis;
    })
    (pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/4a/90/422ffbbeeb9418c795dae2a768db860401446af0c6768bc061ce22325f58/psycopg-3.2.10-py3-none-any.whl";
      hash = (import ../../nix/domains/artifacts/pins.nix).antithesisWheelPsycopg;
    })
    (pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/fc/0d/59024313b5e6c5da3e2a016103494c609d73a95157a86317e0f600c8acb3/psycopg_binary-3.2.10-cp313-cp313-manylinux2014_x86_64.manylinux_2_17_x86_64.whl";
      hash = (import ../../nix/domains/artifacts/pins.nix).antithesisWheelPsycopgBinary;
    })
    (pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/04/13/95a45eb410019772002d8f53d81396dad4120f7df39ca9962f86f5d7cd01/websockets-17.2-cp313-cp313-manylinux1_x86_64.manylinux_2_28_x86_64.manylinux_2_5_x86_64.whl";
      hash = (import ../../nix/domains/artifacts/pins.nix).antithesisWheelWebsockets;
    })
  ];
in
pkgs.runCommand "overalls-antithesis-python-wheels" {
  nativeBuildInputs = [ pkgs.unzip ];
} ''
  mkdir -p "$out/lib/python3.13/site-packages"
  ${lib.concatMapStringsSep "\n" (wheel: ''unzip -q ${wheel} -d "$out/lib/python3.13/site-packages"'') wheels}
''
