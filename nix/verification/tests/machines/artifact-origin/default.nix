{ pkgs, module, packages, hegel }:
let
  python = pkgs.python3.withPackages (p: [ p.playwright ]);
  contentHost = "usercontent.example.test";
  publicHost = "control.example.test";
  outsideHost = "outside.example.test";
  # @cc [owner:ghuntley,label:verification] artifact-origin-subprocess-typing
  # The executed browser probe and outside-origin fixture MUST pass their own
  # type check against the same packaged Python and Playwright that run them.
  checked = pkgs.runCommand "artifact-origin-helpers-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    mkdir -p "$out"
    cp ${./browser.py} "$out/browser.py"
    cp ${./outside.py} "$out/outside.py"
    ty check --python ${python}/bin/python3 "$out/browser.py" "$out/outside.py"
  '';
  marshallEval = pkgs.writeShellScriptBin "artifact-origin-eval" ''
    set -euo pipefail
    set -a
    . /run/overalls-test/marshall.env
    set +a
    unset PORT
    export PHX_SERVER=false PHX_HOST=${publicHost} RELEASE_DISTRIBUTION=none
    export RELEASE_COOKIE=isolated-artifact-origin RELEASE_TMP=/run/artifact-origin-eval
    export MARSHALL_INSTANCE_ID=artifact-origin-eval MARSHALL_REPLICA_COUNT=3
    export MARSHALL_DB_CONNECTION_BUDGET=19 POOL_SIZE=2 MARSHALL_DB_TLS=verify
    export MARSHALL_DB_CA_CERTFILE=/run/overalls-test/ca.crt ERL_CRASH_DUMP=/dev/null
    export MARSHALL_ARTIFACT_CONTENT_HOST=${contentHost}
    export ARTIFACT_ORIGIN_FIXTURES=${./fixtures}
    export ARTIFACT_MACHINE_FIXTURE=${../../support/artifact_fixture.exs}
    mkdir -p "$RELEASE_TMP"
    exec ${packages.marshall}/bin/marshall eval "Code.eval_file(\"$1\")"
  '';
in hegel.runTest {
  name = "overalls-artifact-origin";
  properties = {
    enable = true;
    profile = "ci";
    testCases = 8;
  };
  defaults = import ../../support/role-node.nix { inherit module packages; };
  nodes.web = { config, lib, ... }: {
    virtualisation.memorySize = lib.mkForce 4096;
    virtualisation.cores = lib.mkForce 4;
    networking.extraHosts = "127.0.0.1 ${publicHost} ${contentHost} ${outsideHost}\n";
    services.marshall = {
      enable = true;
      poolSize = lib.mkForce 10;
      databaseConnectionBudget = lib.mkForce 64;
      memoryMiB = lib.mkForce 2048;
      machineTestFixture = true;
      artifactContent = { host = contentHost; debugEcho = true; };
    };
    services.marshallProxy = {
      enable = true;
      artifactContent = {
        host = contentHost;
        certificateFile = "/run/overalls-test-proxy/content.pem";
      };
      secretUnits = [ "artifact-origin-content-tls.service" ];
    };
    environment.systemPackages = [ python pkgs.chromium pkgs.nssTools marshallEval ];
    # @cc [owner:ghuntley,label:verification;security] artifact-origin-content-certificate
    # The content host MUST present its own certificate from the disposable
    # fixture CA, selected by SNI on the proxy's single public listener. The
    # CA key never leaves the VM and nothing is printed.
    systemd.services.artifact-origin-content-tls = {
      requires = [ "overalls-test-fixture.service" ];
      after = [ "overalls-test-fixture.service" ];
      before = [ "haproxy.service" ];
      path = [ pkgs.openssl pkgs.coreutils ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
      script = ''
        work="$(mktemp -d)"
        openssl req -newkey rsa:2048 -nodes -subj /CN=${contentHost} \
          -keyout "$work/content.key" -out "$work/content.csr" >/dev/null 2>&1
        printf '%s\n' basicConstraints=critical,CA:FALSE keyUsage=critical,digitalSignature,keyEncipherment \
          extendedKeyUsage=serverAuth subjectAltName=DNS:${contentHost} > "$work/extensions"
        openssl x509 -req -in "$work/content.csr" -CA /run/overalls-test/ca.crt \
          -CAkey /run/overalls-test/ca.key -CAcreateserial -CAserial "$work/serial" -days 2 \
          -extfile "$work/extensions" -out "$work/content.crt" >/dev/null 2>&1
        cat "$work/content.key" "$work/content.crt" > /run/overalls-test-proxy/content.pem
        chgrp haproxy /run/overalls-test-proxy/content.pem
        chmod 0640 /run/overalls-test-proxy/content.pem
        rm -rf "$work"
      '';
    };
    # A plain-HTTP third-party origin that records only request paths. Every
    # escape probe targets it; any recorded hit is an isolation failure.
    systemd.services.artifact-origin-outside = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${python}/bin/python3 ${checked}/outside.py /run/artifact-origin-outside/hits";
        RuntimeDirectory = "artifact-origin-outside";
        RuntimeDirectoryMode = "0755";
      };
    };
  };
  # @cc [owner:ghuntley,label:verification;security] artifact-origin-lockdown
  # Through the real proxy and source-built Marshall, every content response
  # (200, 404 and refused tickets) MUST carry the exact lockdown headers and no
  # Set-Cookie even when the backend emits one; client Cookie/Authorization
  # MUST NOT reach the backend; non-GET/HEAD MUST get 405; each host's routes
  # MUST stay on its own backend. In headless Chromium, both a direct visit and
  # a Marshall-hosted iframe MUST be an opaque origin without cookies, storage,
  # service workers, network, forms, popups or top navigation; Marshall's
  # __Host- cookie MUST never be sent to the content host. Hegel-generated HTML
  # and SVG escape payloads MUST reach no outside origin.
  testScript = ''
    browser_probe = "${python}/bin/python ${checked}/browser.py"
    seed_script = "${./seed.exs}"
    ticket_script = "${./ticket.exs}"
    payload_script = "${./payload.exs}"
    content_host = "${contentHost}"
    public_host = "${publicHost}"
    outside_host = "${outsideHost}"
  '' + builtins.readFile ./driver.py;
  passthru = { inherit checked; };
}
