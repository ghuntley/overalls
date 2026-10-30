{ hosts }:
let
  central = [ (builtins.head hosts) ];
  candidates = import ./candidate-sources.nix;
  serviceHosts = {
    brady = hosts;
    galileo = hosts;
    enrico = central;
    porsche = central;
    ziggy = hosts;
    audi_private = hosts;
    audi_dns = hosts;
    marshall_web = central;
    audi_ssh = hosts;
    underclass_proxy = hosts;
    marshall_ready = central;
    lilly_physical = central;
    porsche_physical = central;
    porsche_clone = central;
    porsche_relocate = central;
    porsche_retry = central;
    porsche_cancel = central;
    vscode_browser_nixos = central;
    vscode_browser_ubuntu = central;
    marshall_live = central;
  };
  # Latency objectives read a candidate source's own duration histogram. The
  # bound MUST be one of that source's fixed bucket labels; an admitted request
  # without a duration sample counts against the objective.
  latency = [
    { id = "marshall_live_latency"; service = "marshall_live"; bound = "1.0"; title = "Marshall page interactions within 1 s"; }
  ];
in
# @cc [owner:ghuntley,label:reliability;deployment] provisional-objective-roster
# A seven-day application objective MUST name every enrolled source host and
# remain provisional until source crash accounting and its actual journey have
# been reviewed. A placement change MUST update this roster in the same change.
[
  { id = "collectors"; target = 0.999; kind = "collector"; minRequests = 0; inherit hosts; }
  { id = "ingress"; target = 0.995; kind = "ingress"; minRequests = 100; inherit hosts; }
] ++ builtins.map (source: {
  id = source.service;
  target = 0.99;
  kind = "candidate";
  minRequests = 100;
  hosts = serviceHosts.${source.service};
}) candidates ++ builtins.map (objective: objective // {
  target = 0.99;
  kind = "latency";
  minRequests = 100;
  hosts = serviceHosts.${objective.service};
}) latency ++ [
  { id = "underclass_monitor"; target = 0.99; kind = "monitor"; minRequests = 0; inherit hosts; }
]
