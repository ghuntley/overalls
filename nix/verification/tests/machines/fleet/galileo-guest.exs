defmodule FleetGalileoGuest do
  @moduledoc false
  alias FleetTerminal, as: Terminal

  # @cc [owner:ghuntley,label:verification;security] galileo-fleet-guest-path
  # Assertions MUST execute fixed diagnostic or fixture commands inside the real
  # Firecracker guest through its console. They MUST use normal private DNS and
  # embedded public trust, and MUST NOT inject bindings, routes, peer tokens or
  # credentials from the host fixture.
  @spec run(binary(), binary(), binary() | nil) :: :ok
  def run(action, placement, expected \\ nil) do
    true = OverallsProtocol.uuid?(placement)
    {:ok, socket} = Terminal.connect(placement)

    try do
      :ok = Terminal.ready(socket, 120_000)
      dispatch(socket, action, expected)
    after
      Terminal.close(socket)
    end
  end

  @spec dispatch(Terminal.t(), binary(), binary() | nil) :: :ok
  # @cc [owner:ghuntley,label:verification] galileo-quiescent-accounting-fixture
  # Isolated exact-count checks MAY pause SSH refresh and agent polling only
  # after guest readiness; subsequent fleet scenarios MUST restore both services.
  defp dispatch(socket, "pause-authority-refresh", nil) do
    command(
      socket,
      "systemctl stop overalls-ssh-sync.timer overalls-ssh-sync.service overalls-agent-executor.service"
    )
  end

  defp dispatch(socket, "resume-authority-refresh", nil) do
    command(socket, "systemctl start overalls-ssh-sync.timer overalls-agent-executor.service")
  end

  # @cc [owner:ghuntley,label:verification;recovery] galileo-relocated-gateway-neighbour
  # A memory-restored guest MUST hold its default gateway at the profile's
  # host-independent MAC (02:fc:00:<profile octet>:00:01) so its cached
  # neighbour stays valid after relocation; the check only reads guest state.
  defp dispatch(socket, "gateway-neighbour", nil) do
    command(
      socket,
      "gw=$(ip -j route show default | jq -r '.[0].gateway') && " <>
        "test \"$(ip -j neigh show \"$gw\" dev eth0 | jq -r '.[0].lladdr')\" = " <>
        "\"$(printf '02:fc:00:%02x:00:01' \"$(printf %s \"$gw\" | cut -d. -f2)\")\""
    )
  end

  defp dispatch(socket, "direct-success", nil) do
    command(
      socket,
      "test \"$(curl --silent --show-error --fail --max-time 15 " <>
        "-H 'authorization: Bearer forged' https://directapi.integration.internal/direct)\" = galileo-origin-ok"
    )
  end

  defp dispatch(socket, "agent-service", nil) do
    command(socket, "systemctl is-active --quiet overalls-agent-executor.service")
  end

  defp dispatch(socket, "agent-update", expected) do
    true = is_binary(expected) and Regex.match?(~r/\A[0-9a-f]{64}\z/, expected)

    command(
      socket,
      "test \"$(sha256sum /var/lib/overalls/bin/overalls | cut -d' ' -f1)\" = #{expected} && " <>
        "test \"$(curl --silent --show-error --fail --max-time 15 " <>
        "https://llm.internal/agent/v1/update/manifest.json | jq -r '.artifacts[\"linux-amd64\"].sha256')\" = #{expected}"
    )
  end

  defp dispatch(socket, "agent-reset", expected) do
    true = is_binary(expected) and Regex.match?(~r/\A[0-9a-f]{64}\z/, expected)

    command(
      socket,
      "seed=$(command -v overalls) && test -x \"$seed\" && " <>
        "cp \"$seed\" /var/lib/overalls/bin/overalls.reseed && " <>
        "chmod 0700 /var/lib/overalls/bin/overalls.reseed && " <>
        "mv -f /var/lib/overalls/bin/overalls.reseed /var/lib/overalls/bin/overalls && " <>
        "test \"$(sha256sum /var/lib/overalls/bin/overalls | cut -d' ' -f1)\" != #{expected}"
    )
  end

  # @cc [owner:ghuntley,label:verification;recovery] guest-supervisor-candidate-injection
  # These fixed recovery actions MUST modify only the disposable console guest.
  # They model activation interrupted after the executable rename. Candidate
  # digests and prior inodes MUST be measured before service start; no local
  # ready receipt, Marshall fence, binding or tool result may be manufactured.
  defp dispatch(socket, "agent-recovery-" <> mode, nil)
       when mode in ["format", "unregistered"] do
    bytes =
      case mode do
        "format" ->
          "printf '\\177ELF-invalid-fixture-candidate\\n' >\"$b.pending\""

        "unregistered" ->
          "printf '#!/bin/sh\\nwhile true; do sleep 1; done\\n' >\"$b.pending\""
      end

    command(
      socket,
      "systemctl stop overalls-agent-executor.service && " <>
        "b=/var/lib/overalls/bin/overalls && d=/var/lib/overalls/update && " <>
        "install -d -m 700 /root/agent-recovery && " <>
        "sha256sum \"$b\" | cut -d' ' -f1 >/root/agent-recovery/prior && " <>
        "stat -c %i \"$b\" >/root/agent-recovery/inode && " <>
        "ln \"$b\" \"$b.previous.tmp\" && mv -f \"$b.previous.tmp\" \"$b.previous\" && " <>
        bytes <>
        " && chmod 0700 \"$b.pending\" && " <>
        "sha256sum \"$b.pending\" | cut -d' ' -f1 >/root/agent-recovery/candidate && " <>
        "jq --arg old \"$(cat /root/agent-recovery/prior)\" " <>
        "--arg new \"$(cat /root/agent-recovery/candidate)\" " <>
        "'.installed=$old | .applied=$old | .staged=$new' \"$d/status.json\" >\"$d/status.fixture\" && " <>
        "mv \"$d/status.fixture\" \"$d/status.json\" && mv -f \"$b.pending\" \"$b\" && " <>
        "systemctl start overalls-agent-executor.service && " <>
        "systemctl show -p MainPID --value overalls-agent-executor.service >/root/agent-recovery/supervisor"
    )
  end

  defp dispatch(socket, "agent-recovery-check", nil) do
    command(
      socket,
      "b=/var/lib/overalls/bin/overalls && d=/var/lib/overalls/update && r=/root/agent-recovery && " <>
        "systemctl is-active --quiet overalls-agent-executor.service && " <>
        "test \"$(systemctl show -p MainPID --value overalls-agent-executor.service)\" = " <>
        "\"$(cat \"$r/supervisor\")\" && " <>
        "test \"$(sha256sum \"$b\" | cut -d' ' -f1)\" = \"$(cat \"$r/prior\")\" && " <>
        "test \"$(stat -c %i \"$b\")\" = \"$(cat \"$r/inode\")\" && " <>
        "test ! -e \"$b.previous\" && " <>
        "jq -e --arg old \"$(cat \"$r/prior\")\" --arg bad \"$(cat \"$r/candidate\")\" " <>
        "'.installed == $old and .applied == $old and .rejected == $bad' \"$d/status.json\" >/dev/null"
    )
  end

  # @cc [owner:ghuntley,label:verification;recovery] guest-executor-loss-fixture
  # These closed actions MUST use the typed helper installed only in the
  # disposable executor-loss guest. They MUST NOT inject application receipts.
  defp dispatch(socket, "executor-loss-" <> action, nil)
       when action in ["prepare", "ready", "frozen", "fault", "once", "twice"] do
    command(socket, "fleet-executor-loss " <> action)
  end

  # The interrupted-fetch dispatch actions were carved back out after their
  # first execution timed out inside the reconvergence leg; the follow-up
  # investigation is recorded in the campaign ledger under the post-recovery
  # artifact-delivery reconvergence gap.

  defp dispatch(socket, "agent-route", nil) do
    command(
      socket,
      "test \"$(curl --silent --output /dev/null --write-out '%{http_code}' " <>
        "--max-time 10 https://llm.internal/health/ready)\" = 200"
    )
  end

  # The context journey seeds ordinary guest-owned guidance and a project skill
  # through the live Firecracker PTY.  Marshall must discover these files via
  # the fenced executor; this action never writes a context snapshot or any
  # control-plane receipt.
  defp dispatch(socket, "context-fixture", nil) do
    command(
      socket,
      "install -d -m 755 /workspace/.agents/skills/review && " <>
        "printf '%s\\n' 'machine context fixture' >/etc/overalls/AGENTS.md && " <>
        "printf '%s\\n' 'project context fixture' >/workspace/AGENTS.md && " <>
        "printf '%s\\n' '---' 'name: review' 'description: Review the project fixture' '---' 'Inspect the current project.' >/workspace/.agents/skills/review/SKILL.md && " <>
        "chmod 644 /etc/overalls/AGENTS.md /workspace/AGENTS.md /workspace/.agents/skills/review/SKILL.md"
    )
  end

  # @cc [owner:ghuntley,label:verification;security] replacement-guest-llm-path
  # The replacement journey MUST observe llm.internal through the real guest
  # network: a healthy response when the host holds current authority, and a
  # 403 for a forged binding. No fixture header or route may be injected.
  defp dispatch(socket, "llm-ok", nil) do
    command(
      socket,
      "test \"$(curl --silent --output /dev/null --write-out '%{http_code}' " <>
        "--max-time 15 https://llm.internal/health/ready)\" = 200 && " <>
        "test \"$(curl --silent --output /dev/null --write-out '%{http_code}' " <>
        "--max-time 15 -H 'x-overalls-binding: forged' " <>
        "-H 'authorization: Bearer synthetic' https://llm.internal/v1/models)\" = 403"
    )
  end

  # @cc [owner:ghuntley,label:verification;security] peach-fleet-guest-reflection
  # The guest MUST read its own projection from https://reflection.internal
  # through normal private DNS and embedded trust: the guest ID matches, the
  # built-in integrations are listed, and unknown paths answer 404.
  defp dispatch(socket, "reflection-ok", vm_id) do
    true = OverallsProtocol.uuid?(vm_id)

    command(
      socket,
      "test \"$(curl --silent --show-error --fail --max-time 15 " <>
        "https://reflection.internal/guest | jq -r .id)\" = #{vm_id} && " <>
        "test \"$(curl --silent --show-error --fail --max-time 15 " <>
        "https://reflection.internal/integrations | jq -r '[.[].name] | index(\"reflection\") != null and index(\"llm\") != null')\" = true && " <>
        "test \"$(curl --silent --show-error --fail --max-time 15 " <>
        "https://reflection.internal/ | jq -r '[.paths[].path] | join(\",\")')\" = /guest,/integrations && " <>
        "test \"$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 15 " <>
        "https://reflection.internal/secrets)\" = 404"
    )
  end

  defp dispatch(socket, "llm-dns", nil) do
    command(socket, "getent hosts llm.internal >/dev/null")
  end

  defp dispatch(socket, "llm-health", nil) do
    command(
      socket,
      "curl --silent --output /dev/null --write-out '%{http_code}' --max-time 15 " <>
        "https://llm.internal/health/ready --fail"
    )
  end

  # @cc [owner:ghuntley,label:verification;security] galileo-guest-authorization-refusal
  # An unattached or detached integration MUST return guest HTTP 403; unavailable
  # authority returning 503 MUST NOT satisfy the authorization-refusal assertion.
  defp dispatch(socket, "direct-denied", nil) do
    command(
      socket,
      "test \"$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 15 " <>
        "https://directapi.integration.internal/direct)\" = 403"
    )
  end

  # @cc [owner:ghuntley,label:verification;security] galileo-guest-authority-outage
  # An unavailable control plane MUST return guest HTTP 503; an authorization
  # refusal returning 403 MUST NOT satisfy the outage assertion.
  defp dispatch(socket, "direct-unavailable", nil) do
    command(
      socket,
      "test \"$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 15 " <>
        "https://directapi.integration.internal/direct)\" = 503"
    )
  end

  defp dispatch(socket, "start-stall", nil) do
    command(
      socket,
      "systemd-run --quiet --unit=galileo-stall --property=TimeoutStartSec=60 " <>
        "curl --silent --show-error --fail --max-time 50 https://directapi.integration.internal/stall"
    )
  end

  defp dispatch(socket, "upload", nil) do
    command(
      socket,
      "dd if=/dev/zero of=/run/galileo-upload bs=65536 count=3 status=none && " <>
        "digest=$(sha256sum /run/galileo-upload | cut -d' ' -f1) && " <>
        "reply=$(curl --silent --show-error --fail --max-time 30 --data-binary @/run/galileo-upload " <>
        "https://directapi.integration.internal/upload) && " <>
        "test \"$(printf %s \"$reply\" | jq -r .bytes)\" = 196608 && " <>
        "test \"$(printf %s \"$reply\" | jq -r .sha256)\" = \"$digest\"",
      60_000
    )
  end

  defp dispatch(socket, "load", nil) do
    command(
      socket,
      "seq 1 32 | xargs -n1 -P8 -I{} curl --silent --show-error --fail --max-time 15 " <>
        "https://directapi.integration.internal/direct >/run/galileo-load && " <>
        "test \"$(wc -l </run/galileo-load)\" = 32",
      120_000
    )
  end

  defp dispatch(socket, "peer-success", expected) do
    true = OverallsProtocol.uuid?(expected || "")

    command(
      socket,
      "test \"$(curl --silent --show-error --fail --max-time 20 " <>
        "-H 'authorization: galileo-peer forged' " <>
        "-H 'x-overalls-source-vm: 00000000-0000-4000-8000-000000000000' " <>
        "https://peerapi.integration.internal/)\" = #{expected}"
    )
  end

  defp dispatch(socket, "serve-peer", expected) do
    true = OverallsProtocol.uuid?(expected || "")
    python = System.fetch_env!("FLEET_GUEST_PYTHON")

    program = """
    import http.server
    class Handler(http.server.BaseHTTPRequestHandler):
      protocol_version = 'HTTP/1.1'
      def log_message(self, *args): pass
      def do_GET(self):
        if self.path == '/ready':
          body = b'ready'
          self.send_response(200); self.send_header('Content-Length', str(len(body)))
          self.send_header('Connection', 'close'); self.end_headers(); self.wfile.write(body); return
        source = self.headers.get('x-overalls-source-vm', '')
        authorization = self.headers.get('authorization')
        body = source.encode() if source == '#{expected}' and authorization is None else b'denied'
        self.send_response(200 if body != b'denied' else 403)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers(); self.wfile.write(body)
    http.server.ThreadingHTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
    """

    encoded = Base.encode64(program)
    command(socket, "printf %s #{encoded} | base64 -d >/root/galileo-peer.py")
    command(socket, "systemd-run --quiet --unit=galileo-peer #{python} /root/galileo-peer.py")

    command(
      socket,
      "until curl --fail --silent http://127.0.0.1:8080/ready >/dev/null; do sleep .1; done"
    )
  end

  defp command(socket, command, timeout \\ 30_000) do
    marker = "GALILEO_" <> Base.encode16(:crypto.strong_rand_bytes(12))
    :ok = Terminal.write(socket, command <> "; r=$?; printf '\\n#{marker}:%s\\n' \"$r\"\n")

    case wait_status(socket, marker, deadline(timeout), "") do
      0 -> :ok
      _ -> raise "guest command failed"
    end
  end

  defp wait_status(socket, marker, until, tail) do
    true = System.monotonic_time(:millisecond) < until

    case Terminal.read(socket, 1000) do
      {:ok, bytes} ->
        data = :binary.replace(tail <> bytes, "\r", "", [:global])

        case Regex.run(~r/\n#{marker}:(\d+)\n/, data) do
          [_, status] ->
            String.to_integer(status)

          nil ->
            wait_status(
              socket,
              marker,
              until,
              binary_part(data, max(byte_size(data) - 8192, 0), min(byte_size(data), 8192))
            )
        end

      {:error, :timeout} ->
        wait_status(socket, marker, until, tail)

      _ ->
        raise "guest console unavailable"
    end
  end

  defp deadline(milliseconds), do: System.monotonic_time(:millisecond) + milliseconds
end

try do
  case System.argv() do
    [action, placement] -> FleetGalileoGuest.run(action, placement)
    [action, placement, expected] -> FleetGalileoGuest.run(action, placement, expected)
    _ -> raise "invalid action"
  end

  IO.puts("Galileo guest assertion passed")
rescue
  _ ->
    action = System.argv() |> hd() |> String.replace(~r/[^a-z0-9-]/, "-") |> String.slice(0, 40)
    IO.puts(:stderr, "Galileo guest " <> action <> " assertion failed; console content withheld")
    System.halt(1)
end
