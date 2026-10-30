{ pkgs, nixpkgs, module }:
let
  inherit (pkgs) lib;
  evaluate = settings: (nixpkgs.lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [ module {
      system.stateVersion = "26.05";
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
    } settings ];
  }).config;
  # Static grants use documentation addresses; fleet hosts take theirs from
  # the SOPS-delivered fleet addresses (runtimeGrant below).
  grants = {
    panterloons = { address = "192.0.2.51"; comment = "Panterloons fleet host"; };
    dungarees = { address = "192.0.2.52"; comment = "Dungarees fleet host"; };
  };
  nft = evaluate {
    networking.nftables.enable = true;
    overalls.fleetFirewall = { enable = true; allowedHosts = grants; };
  };
  iptables = evaluate {
    networking.nftables.enable = false;
    overalls.fleetFirewall = { enable = true; allowedHosts = grants; };
  };
  defaultHosts = evaluate { overalls.fleetFirewall.enable = true; };
  fleetNetwork = {
    overalls.fleetNetwork = {
      enable = true;
      address = "10.90.0.1";
      endpointAddress = "192.0.2.1";
      privateKeyFile = "/run/fleet/private-key";
      tcpPorts = [ 5443 ];
      peers.worker = {
        address = "10.90.0.2";
        endpointAddress = "192.0.2.2";
        publicKey = lib.concatStrings (lib.replicate 43 "A") + "=";
      };
    };
  };
  composedNft = evaluate {
    imports = [ ../../../domains/system/fleet-network.nix fleetNetwork ];
    networking.nftables.enable = true;
    overalls.fleetFirewall = { enable = true; allowedHosts = grants; };
    networking.firewall.extraInputRules = "tcp dport 9999 accept";
  };
  composedIptables = evaluate {
    imports = [ ../../../domains/system/fleet-network.nix fleetNetwork ];
    networking.nftables.enable = false;
    overalls.fleetFirewall = { enable = true; allowedHosts = grants; };
    networking.firewall.extraCommands = "iptables -w -A nixos-fw -p tcp --dport 9999 -j nixos-fw-accept";
  };
  standaloneNft = evaluate {
    imports = [ ../../../domains/system/fleet-network.nix fleetNetwork ];
    networking.nftables.enable = true;
    networking.firewall.extraInputRules = "tcp dport 9999 accept";
  };
  standaloneIptables = evaluate {
    imports = [ ../../../domains/system/fleet-network.nix fleetNetwork ];
    networking.nftables.enable = false;
    networking.firewall.extraCommands = "iptables -w -A nixos-fw -p tcp --dport 9999 -j nixos-fw-accept";
  };
  disabled = evaluate {};
  valid = cfg: lib.all (item: item.assertion) cfg.assertions;
  rejected = allowedHosts:
    let result = builtins.tryEval (let cfg = evaluate {
      overalls.fleetFirewall = { enable = true; inherit allowedHosts; };
    }; in builtins.deepSeq cfg.overalls.fleetFirewall.allowedHosts (valid cfg));
    in !result.success || !result.value;
  publicService = {
    overalls.fleetFirewall = {
      enable = true;
      publicServices.audi = {
        address = "192.0.2.10";
        tcpPorts = [ 22 53 443 ];
        udpPorts = [ 53 ];
        comment = "Audi public plane";
      };
    };
  };
  runtimeService = {
    networking.nftables.enable = false;
    systemd.services.fixture-address.serviceConfig.Type = "oneshot";
    overalls.fleetFirewall = {
      enable = true;
      publicServices.susan = {
        addressFile = "/run/fixture/ipv4";
        addressUnit = "fixture-address.service";
        tcpPorts = [ 80 443 ];
        comment = "Susan push relay";
      };
    };
  };
  runtimeGrant = {
    systemd.services.fixture-grant.serviceConfig.Type = "oneshot";
    overalls.fleetFirewall.allowedHosts.peer = {
      addressFile = "/run/fixture/peer";
      addressUnit = "fixture-grant.service";
      comment = "Runtime fleet host";
    };
  };
  runtimeIptables = evaluate (lib.recursiveUpdate runtimeService runtimeGrant);
  runtimeNft = evaluate (lib.recursiveUpdate runtimeService (runtimeGrant // { networking.nftables.enable = true; }));
  runtimeUnit = runtimeIptables.systemd.services.overalls-runtime-firewall;
  runtimeNftUnit = runtimeNft.systemd.services.overalls-runtime-firewall;
  rejectedRuntime = settings:
    let result = builtins.tryEval (let cfg = evaluate (lib.recursiveUpdate runtimeService settings);
      in builtins.deepSeq cfg.overalls.fleetFirewall.publicServices (valid cfg));
    in !result.success || !result.value;
  publicNft = evaluate (publicService // { networking.nftables.enable = true; });
  publicIptables = evaluate (publicService // { networking.nftables.enable = false; });
  rejectedPublic = publicServices:
    let result = builtins.tryEval (let cfg = evaluate {
      networking.nftables.enable = true;
      overalls.fleetFirewall = { enable = true; inherit publicServices; };
    }; in builtins.deepSeq cfg.overalls.fleetFirewall.publicServices (valid cfg));
    in !result.success || !result.value;

  # @cc [owner:ghuntley,label:verification] fleet-firewall-configuration-check
  # These checks MUST exercise both NixOS firewall backends, typed registry
  # failures and the disabled standalone module without substituting rules.
  cases = {
    optIn = !disabled.overalls.fleetFirewall.enable
      && !(builtins.elem "tailscale0" disabled.networking.firewall.trustedInterfaces);
    # The reviewed policy names fleet addresses, never literals; hosts map it.
    defaults = defaultHosts.overalls.fleetFirewall.allowedHosts == {}
      && lib.all (grant: grant ? name && !(grant ? address)) (lib.attrValues (import ../../../policy/network/allowed-hosts.nix));
    # ADR-0247: every reviewed grant, including the operator source, names a
    # fleet address whose value exists only in the SOPS document.
    grantsNameFleetAddresses = lib.all (grant: (import ../../../policy/network/fleet-addresses.nix) ? ${grant.name})
      (lib.attrValues (import ../../../policy/network/allowed-hosts.nix));
    tailscaleTrusted = nft.networking.firewall.enable
      && lib.sort builtins.lessThan nft.networking.firewall.trustedInterfaces == [ "lo" "tailscale0" ];
    noPublicPorts = lib.all (ports: ports == []) [
      nft.networking.firewall.allowedTCPPorts
      nft.networking.firewall.allowedUDPPorts
      nft.networking.firewall.allowedTCPPortRanges
      nft.networking.firewall.allowedUDPPortRanges
      iptables.networking.firewall.allowedTCPPorts
      iptables.networking.firewall.allowedUDPPorts
      iptables.networking.firewall.allowedTCPPortRanges
      iptables.networking.firewall.allowedUDPPortRanges
    ];
    nftRules = lib.all (fragment: lib.hasInfix fragment nft.networking.firewall.extraInputRules) [
      ''ip saddr 192.0.2.51 meta l4proto { tcp, udp } accept comment "Panterloons fleet host"''
      ''ip saddr 192.0.2.52 meta l4proto { tcp, udp } accept comment "Dungarees fleet host"''
    ] && !(lib.hasInfix "dport" nft.networking.firewall.extraInputRules);
    iptablesRules = lib.all (fragment: lib.hasInfix fragment iptables.networking.firewall.extraCommands) [
      "-s 192.0.2.51 -p tcp"
      "-s 192.0.2.51 -p udp"
      "-s 192.0.2.52 -p tcp"
      "-s 192.0.2.52 -p udp"
    ] && !(lib.hasInfix "--dport" iptables.networking.firewall.extraCommands);
    composedRules = valid composedNft && valid composedIptables
      && lib.all (fragment: lib.hasInfix fragment composedNft.networking.firewall.extraInputRules) [
      ''ip saddr 192.0.2.52 meta l4proto { tcp, udp } accept comment "Dungarees fleet host"''
      ''iifname "fleet0" ip saddr 10.90.0.2 ip daddr 10.90.0.1 tcp dport 5443 accept''
    ] && lib.all (fragment: lib.hasInfix fragment composedIptables.networking.firewall.extraCommands) [
      "-s 192.0.2.52 -p tcp"
      "-i fleet0 -s 10.90.0.2 -d 10.90.0.1 -p tcp --dport 5443"
    ]
      && !(lib.hasInfix "dport 9999" composedNft.networking.firewall.extraInputRules)
      && !(lib.hasInfix "--dport 9999" composedIptables.networking.firewall.extraCommands);
    standaloneComposition = valid standaloneNft && valid standaloneIptables
      && lib.hasInfix "dport 5443" standaloneNft.networking.firewall.extraInputRules
      && lib.hasInfix "dport 9999" standaloneNft.networking.firewall.extraInputRules
      && lib.hasInfix "--dport 5443" standaloneIptables.networking.firewall.extraCommands
      && lib.hasInfix "--dport 9999" standaloneIptables.networking.firewall.extraCommands;
    malformedAddress = rejected {
      invalid = { address = "999.1.1.1"; comment = "Invalid octet"; };
    };
    duplicateAddress = rejected {
      one = { address = "192.0.2.1"; comment = "First"; };
      two = { address = "192.0.2.1"; comment = "Second"; };
    };
    missingComment = rejected { invalid.address = "192.0.2.1"; };
    publicServiceRules = valid publicNft && valid publicIptables
      && lib.all (fragment: lib.hasInfix fragment publicNft.networking.firewall.extraInputRules) [
      ''ip daddr 192.0.2.10 tcp dport 443 accept comment "Audi public plane"''
      ''ip daddr 192.0.2.10 tcp dport 53 accept comment "Audi public plane"''
      ''ip daddr 192.0.2.10 udp dport 53 accept comment "Audi public plane"''
    ] && lib.all (fragment: lib.hasInfix fragment publicIptables.networking.firewall.extraCommands) [
      "-d 192.0.2.10 -p tcp --dport 443"
      "-d 192.0.2.10 -p udp --dport 53"
      "--comment 'Audi public plane'"
    ];
    # Runtime addresses: a static jump to a dedicated chain that only the
    # address-following unit fills; no address enters the evaluated rules.
    runtimeServiceRules = valid runtimeIptables && valid runtimeNft
      && lib.hasInfix "iptables -w -N overalls-runtime 2>/dev/null || true" runtimeIptables.networking.firewall.extraCommands
      && lib.hasInfix "iptables -w -A nixos-fw -j overalls-runtime" runtimeIptables.networking.firewall.extraCommands
      && !(lib.hasInfix "--dport" runtimeIptables.networking.firewall.extraCommands)
      && lib.hasInfix "jump overalls-runtime" runtimeNft.networking.firewall.extraInputRules
      && lib.hasInfix "chain overalls-runtime" runtimeNft.networking.nftables.tables.nixos-fw.content
      && !(lib.hasInfix "dport" runtimeNft.networking.firewall.extraInputRules)
      && lib.attrNames runtimeIptables.overalls.runtimeFirewall.rules == [ "public-susan-tcp" "source-peer" ]
      && runtimeIptables.overalls.runtimeFirewall.rules.public-susan-tcp.destinationFile == "/run/fixture/ipv4"
      && runtimeIptables.overalls.runtimeFirewall.rules.public-susan-tcp.ports == [ 80 443 ]
      && runtimeIptables.overalls.runtimeFirewall.rules.source-peer.sourceFile == "/run/fixture/peer"
      && runtimeIptables.overalls.runtimeFirewall.rules.source-peer.protocol == "any"
      && lib.all (unit: builtins.elem unit runtimeUnit.requires && builtins.elem unit runtimeUnit.after)
        [ "fixture-address.service" "fixture-grant.service" ]
      && builtins.elem "firewall.service" runtimeUnit.partOf
      && builtins.elem "nftables.service" runtimeNftUnit.partOf
      && runtimeNftUnit.unitConfig.ReloadPropagatedFrom == [ "nftables.service" ];
    runtimeServiceNeedsUnit = rejectedRuntime { overalls.fleetFirewall.publicServices.susan.addressUnit = null; };
    runtimeServiceNotBoth = rejectedRuntime { overalls.fleetFirewall.publicServices.susan.address = "192.0.2.10"; };
    runtimeGrantNeedsUnit = rejected { peer = { addressFile = "/run/fixture/peer"; comment = "No unit"; }; };
    runtimeGrantNotBoth = rejected { peer = { address = "192.0.2.1"; addressFile = "/run/fixture/peer"; addressUnit = "fixture-grant.service"; comment = "Both"; }; };
    runtimeGrantOutsideRun = rejected { peer = { addressFile = "/var/lib/peer"; addressUnit = "fixture-grant.service"; comment = "Persistent"; }; };
    publicServiceNoWildcard = rejectedPublic {
      wildcard = { address = "0.0.0.0"; tcpPorts = [ 443 ]; comment = "Wildcard"; };
    };
    publicServiceDuplicateAddress = rejectedPublic {
      one = { address = "192.0.2.10"; tcpPorts = [ 443 ]; comment = "First"; };
      two = { address = "192.0.2.10"; udpPorts = [ 53 ]; comment = "Second"; };
    };
    publicServiceNoPorts = rejectedPublic {
      empty = { address = "192.0.2.10"; comment = "No ports"; };
    };
    publicServiceDuplicatePorts = rejectedPublic {
      duplicate = { address = "192.0.2.10"; tcpPorts = [ 443 443 ]; comment = "Duplicate"; };
    };
  };
  failed = lib.attrNames (lib.filterAttrs (_: result: !result) cases);
in
assert lib.assertMsg (failed == []) "Fleet firewall checks failed: ${lib.concatStringsSep ", " failed}";
pkgs.writeText "overalls-fleet-firewall-check.json" (builtins.toJSON cases)
