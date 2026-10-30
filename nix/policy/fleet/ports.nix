# @cc [owner:ghuntley,label:security] fleet-port-roster
# Every port a fleet consumer opens on the fleet tunnel, the tailnet or a
# reviewed public listener MUST be named here exactly once, and no two names
# may share a port: consumers read these names instead of repeating literals.
{ ports ? {
    # Public HTTPS (Susan push relay origin).
    https = 443;
    # Administrative OpenSSH on physical hosts; also the remote-builder transport.
    adminSsh = 2222;
    # Lilly's guest transfer endpoint.
    transferSsh = 2223;
    # Public Grafana behind the Marshall proxy.
    publicGrafana = 3443;
    # Central OpenTelemetry OTLP/gRPC intake on the control plane.
    otlpGrpc = 4317;
    # Marshall backend HTTPS, loopback behind the proxy.
    marshallBackend = 4443;
    # Marshall fleet API (host exchange and terminal peering).
    marshallFleet = 5443;
    # Enrico cache on the fleet tunnel.
    enrico = 5445;
    # Fleet log store insert/query entry.
    logStore = 8443;
    # Audi relay between gateway peers.
    audiRelay = 9445;
    # Buck2 NativeLink cache on the tailnet (ADR-0272): read-only host
    # listener and CI upload listener, then the developer remote-execution
    # listener and the worker API (M10).
    buckCacheRead = 50071;
    buckCacheUpload = 50072;
    buckExecute = 50073;
    buckWorker = 50074;
    # Per-host OpenTelemetry collector metrics.
    otelMetrics = 9464;
    # Independent per-host logging health metrics.
    loggingHealth = 9467;
  }
}:
let
  values = builtins.attrValues ports;
  distinct = builtins.length (builtins.attrNames (builtins.listToAttrs
    (map (port: { name = toString port; value = null; }) values)));
in
assert builtins.all (port: builtins.isInt port && port > 0 && port < 65536) values
  || throw "Fleet ports must be integers in 1-65535";
assert distinct == builtins.length values || throw "Fleet port roster assigns one port twice";
ports
