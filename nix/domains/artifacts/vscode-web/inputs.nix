{
  sourceCommit = "2a59476c9bfcb90b3ddc372c36762471b7dfad1c";
  sourceHash = (import ../pins.nix).vscodeSource;
  npmHash = (import ../pins.nix).vscodeNpm;
  version = "1.141.0";
  nodeVersion = "24.21.0";
  nodeSourceHash = (import ../pins.nix).vscodeNodeSource;
  electronTypesVersion = "43.7.7";
  electronTypesHash = (import ../pins.nix).vscodeElectronTypes;
}
