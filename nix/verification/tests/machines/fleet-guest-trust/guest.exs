defmodule FleetGuestTrust do
  @moduledoc "Bounded native trust probe; all terminal contents remain private."
  alias FleetTerminal, as: Terminal
  alias Lilly.VM.{Boot, Driver, GuestTrust, Intent, Spec}

  @type stage ::
          :receipt
          | :positive_delivery
          | :wrong_boot_refusal
          | :trust_failure_exhaustion
          | :receipt_unchanged
          | :terminal_connect
          | :terminal_prompt
          | :guest_boot_id
          | :services
          | :trust_active
          | :trust_before_network
          | :network_before_ssh
          | :unprivileged_read
          | :local_http
          | :retained_data
          | :bundle_base
          | :bundle_roots
          | :exact_nixos_bundle
          | :root_file_count
          | :exact_root_files
          | :system_trust_store
          | :installed_digest
          | :final_delivery
  @stages [
    :receipt,
    :positive_delivery,
    :wrong_boot_refusal,
    :trust_failure_exhaustion,
    :receipt_unchanged,
    :terminal_connect,
    :terminal_prompt,
    :guest_boot_id,
    :services,
    :trust_active,
    :trust_before_network,
    :network_before_ssh,
    :unprivileged_read,
    :local_http,
    :retained_data,
    :bundle_base,
    :bundle_roots,
    :exact_nixos_bundle,
    :root_file_count,
    :exact_root_files,
    :system_trust_store,
    :installed_digest,
    :final_delivery
  ]

  @receipt_boot_fields [:placement_id, :execution_epoch, :generation, :boot_challenge]

  # @cc [owner:ghuntley,label:verification;security] fleet-trust-real-boot-receipt
  # The probe MUST compare real journal, current boot and configured roots,
  # including the readiness-recorded guest boot UUID against the receipt, then
  # reject a wrong-boot vsock exchange without writing journal or guest authority.
  # It MUST check actual guest bundle/service ordering and retained data; only
  # the public boot UUID or a closed failure stage may leave the probe, never
  # challenge, command output, certificate payload or terminal bytes.
  @spec run(String.t(), String.t(), String.t()) :: OverallsProtocol.uuid()
  def run(placement, distribution, mode) do
    checkpoint(:receipt)
    true = mode in ["seed", "check"]
    true = OverallsProtocol.uuid?(placement)
    true = distribution in ["nixos", "ubuntu"]
    directory = "/var/lib/lilly/vms/" <> placement
    {:ok, intent} = Intent.read(directory)

    {:ok, journal} =
      Lilly.Lifecycle.Journal.load(Lilly.Lifecycle.GuestTrust, directory, "guest-trust.json")

    receipt = journal.payload
    {:ok, runtime} = Lilly.Control.Config.load("/run/lilly-release/config.json")
    roots = runtime.execution.guest_trust_roots
    true = roots != []
    {:ok, bytes} = Lilly.Host.PrivateFiles.read_secret(Path.join(directory, "vm.json"))
    %{"pool_path" => pool_path, "spec" => shape} = JSON.decode!(bytes)

    {:ok, spec} =
      Spec.new(%{
        id: shape["id"],
        image_id: shape["image_id"],
        pool_id: shape["pool_id"],
        profile: Map.fetch!(%{"oss" => :oss}, shape["profile"]),
        slot: shape["slot"],
        vcpu: shape["vcpu"],
        memory_bytes: shape["memory_bytes"],
        disk_bytes: shape["disk_bytes"]
      })

    pool = Enum.find(runtime.pools, &(&1.id == spec.pool_id))
    true = pool.path == pool_path and spec.id == placement
    options = [execution_epoch: intent.execution_epoch, generation: intent.generation]
    boot = checked_boot(runtime.execution, pool, spec, options)
    true = receipt["state"] == "installed"
    true = receipt["bundle_digest"] == GuestTrust.digest(roots)
    true = OverallsProtocol.uuid?(receipt["boot_id"])
    true = receipt["host_id"] == runtime.execution.network.host_id
    # The receipt binds the boot's placement, epoch, generation and challenge.
    # Readiness then records the attested guest kernel boot UUID in the boot
    # record (never a field of the trust receipt); it MUST equal the receipt's
    # boot UUID. A fresh boot carries no continuation or other boot field.
    {guest_boot_id, bound} = Map.pop(boot, :guest_boot_id)
    true = Map.keys(bound) -- @receipt_boot_fields == [] and map_size(bound) == 4
    true = Enum.all?(bound, fn {key, value} -> receipt[Atom.to_string(key)] == value end)
    true = guest_boot_id == receipt["boot_id"]

    socket_path =
      Path.join([pool.path, ".lilly-jails", "firecracker", placement, "root", "v.sock"])

    checkpoint(:positive_delivery)
    {:ok, boot_id, digest} = GuestTrust.deliver(socket_path, boot, roots, 15_000)
    ^boot = checked_boot(runtime.execution, pool, spec, options)
    true = boot_id == receipt["boot_id"] and digest == receipt["bundle_digest"]

    wrong = %{
      boot
      | boot_challenge:
          String.duplicate(
            if(String.starts_with?(boot.boot_challenge, "0"), do: "1", else: "0"),
            64
          )
    }

    # A different valid root set makes accidental installation observable even
    # if the sender rejects the receiver's response for the wrong challenge.
    refused_roots = Enum.drop(roots, -1)
    true = refused_roots != [] and GuestTrust.digest(refused_roots) != digest
    checkpoint(:wrong_boot_refusal)
    :ok = require_completed_refusal(socket_path, wrong, refused_roots)
    ^boot = checked_boot(runtime.execution, pool, spec, options)

    checkpoint(:trust_failure_exhaustion)
    :ok = exhaust_trust_failures(socket_path, boot, roots, digest)
    ^boot = checked_boot(runtime.execution, pool, spec, options)

    checkpoint(:receipt_unchanged)

    {:ok, after_refusal} =
      Lilly.Lifecycle.Journal.load(Lilly.Lifecycle.GuestTrust, directory, "guest-trust.json")

    true = after_refusal.payload == receipt
    checkpoint(:terminal_connect)
    {:ok, terminal} = Terminal.connect(placement)

    try do
      checkpoint(:terminal_prompt)

      :ok = Terminal.ready(terminal, 30_000)
      shell = if distribution == "ubuntu", do: "ssh.service", else: "sshd.service"

      checks = [
        {:guest_boot_id, "test $(cat /proc/sys/kernel/random/boot_id) = #{receipt["boot_id"]}"},
        {:services,
         "timeout 60 sh -c 'until systemctl is-active --quiet overalls-guest-trust.service && systemctl is-active --quiet lilly-network.service && systemctl is-active --quiet lilly-private-dns.service && systemctl is-active --quiet #{shell} && test -e /run/overalls-ssh-ready && test \"$(systemctl show overalls-ssh-sync.service -p Result --value)\" = success; do sleep .2; done'"},
        {:trust_active,
         "test $(systemctl show overalls-guest-trust.service -p ActiveEnterTimestampMonotonic --value) -gt 0"},
        {:trust_before_network,
         "test $(systemctl show overalls-guest-trust.service -p ActiveEnterTimestampMonotonic --value) -le $(systemctl show lilly-network.service -p ActiveEnterTimestampMonotonic --value)"},
        {:network_before_ssh,
         "test $(systemctl show lilly-network.service -p ActiveEnterTimestampMonotonic --value) -le $(systemctl show #{shell} -p ActiveEnterTimestampMonotonic --value)"},
        {:unprivileged_read,
         if(distribution == "ubuntu",
           do: "su -s /bin/sh overalls-ssh -c 'test -r /etc/ssl/certs/ca-certificates.crt'",
           else: "sudo -u overalls-ssh -- test -r /etc/ssl/certs/ca-certificates.crt"
         )},
        {:local_http,
         "curl --fail --silent --max-time 10 http://11.0.0.1:8080/ | grep -qx fixture-egress-ok"},
        {:retained_data,
         if(mode == "seed",
           do: "test ! -e /root/trust-data && printf native-trust-data >/root/trust-data && sync",
           else: "test $(cat /root/trust-data) = native-trust-data"
         )}
      ]

      Enum.each(checks, fn {stage, check} -> command(terminal, stage, check) end)

      if distribution == "nixos" do
        command(
          terminal,
          :bundle_base,
          "base=$(systemctl show overalls-guest-trust.service -p ExecStart --value | sed -n 's/.*overalls-trustd nixos \\([^ ;]*\\).*/\\1/p'); " <>
            "test -s \"$base\" && cat \"$base\" >/run/trust-expected-bundle && printf '\\n' >>/run/trust-expected-bundle"
        )

        Enum.each(roots, fn root ->
          command(
            terminal,
            :bundle_roots,
            "printf %s #{Base.encode64(root)} | base64 -d >>/run/trust-expected-bundle && printf '\\n' >>/run/trust-expected-bundle"
          )
        end)

        command(
          terminal,
          :exact_nixos_bundle,
          "cmp /run/trust-expected-bundle /etc/ssl/certs/ca-certificates.crt && rm /run/trust-expected-bundle"
        )
      else
        command(
          terminal,
          :root_file_count,
          "test $(find /usr/local/share/ca-certificates/overalls-platform -type f | wc -l) = #{length(roots)}"
        )

        roots
        |> Enum.with_index()
        |> Enum.each(fn {root, index} ->
          command(
            terminal,
            :exact_root_files,
            "printf %s #{Base.encode64(root)} | base64 -d | cmp - /usr/local/share/ca-certificates/overalls-platform/overalls-#{index}.crt"
          )
        end)
      end

      Enum.each(roots, fn root ->
        command(
          terminal,
          :system_trust_store,
          "python3 -c 'import base64, ssl; expected: bytes = ssl.PEM_cert_to_DER_cert(base64.b64decode(\"#{Base.encode64(root)}\", validate=True).decode(\"ascii\")); certificates: list[bytes] = ssl.create_default_context(cafile=\"/etc/ssl/certs/ca-certificates.crt\").get_ca_certs(binary_form=True); assert expected in certificates'"
        )
      end)

      digest = receipt["bundle_digest"]

      if distribution == "ubuntu" do
        command(
          terminal,
          :installed_digest,
          "test $(cat /var/lib/overalls-trust/installed) = #{digest}"
        )
      else
        command(
          terminal,
          :installed_digest,
          "test $(readlink /var/lib/overalls-trust/current) = bundle-#{digest}"
        )
      end

      checkpoint(:final_delivery)
      ^boot = checked_boot(runtime.execution, pool, spec, options)
      {:ok, ^boot_id, ^digest} = GuestTrust.deliver(socket_path, boot, roots, 15_000)
      ^boot = checked_boot(runtime.execution, pool, spec, options)
      receipt["boot_id"]
    after
      Terminal.close(terminal)
    end
  end

  @spec checkpoint(stage()) :: :ok
  defp checkpoint(stage) when stage in @stages do
    Process.put({__MODULE__, :stage}, stage)
    :ok
  end

  @spec failure_stage() :: stage() | :unknown
  def failure_stage do
    case Process.get({__MODULE__, :stage}) do
      stage when stage in @stages -> stage
      _ -> :unknown
    end
  end

  # trustd handles one connection synchronously and drops its stream only after
  # validation/installation completes. Require peer EOF without response bytes:
  # a sender timeout cannot prove refusal, and no positive delivery may repair
  # installed contents before the checks above inspect the completed request.
  @spec require_completed_refusal(Path.t(), Boot.t(), [binary()]) :: :ok
  defp require_completed_refusal(path, boot, roots) do
    require_completed_request(path, request(boot, roots))
  end

  # every wrong, forged and expired boot trust mutation ends in a peer-EOF refusal with no response bytes
  # wrong, forged and expired boot-bound trust deliveries exhaust to completed
  # refusals with an unchanged durable receipt, installed bundle and services:
  # each mutation below violates exactly one receiver check (protocol version,
  # placement, execution epoch, nonce, digest or forged certificate material)
  # and must terminate with peer EOF and no response bytes. trustd is the only
  # authority that may install; the expired epoch is a stale boot's authority.
  @spec exhaust_trust_failures(Path.t(), Boot.t(), [binary()], String.t()) :: :ok
  defp exhaust_trust_failures(path, boot, roots, digest) do
    base = %{
      version: 1,
      placement_id: boot.placement_id,
      execution_epoch: boot.execution_epoch,
      boot_challenge: boot.boot_challenge,
      nonce: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      bundle_digest: digest,
      roots: roots
    }

    forged = hd(roots) <> "-----BEGIN PRIVATE KEY-----\nAA==\n-----END PRIVATE KEY-----\n"
    forged_roots = [forged | tl(roots)]
    duplicate = [hd(roots) | roots]

    [
      %{base | version: 0},
      %{base | placement_id: Lilly.UUID.generate()},
      %{base | execution_epoch: boot.execution_epoch - 1},
      %{base | nonce: String.duplicate("z", 64)},
      %{base | bundle_digest: String.duplicate("0", 64)},
      %{base | roots: duplicate, bundle_digest: GuestTrust.digest(duplicate)},
      %{base | roots: forged_roots, bundle_digest: GuestTrust.digest(forged_roots)}
    ]
    |> Enum.each(fn request -> :ok = require_completed_request(path, request) end)
  end

  @spec request(Boot.t(), [binary()]) :: map()
  defp request(boot, roots) do
    %{
      version: 1,
      placement_id: boot.placement_id,
      execution_epoch: boot.execution_epoch,
      boot_challenge: boot.boot_challenge,
      nonce: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      bundle_digest: GuestTrust.digest(roots),
      roots: roots
    }
  end

  @spec require_completed_request(Path.t(), map()) :: :ok
  defp require_completed_request(path, request) do
    body = JSON.encode!(request)

    true = byte_size(body) in 1..1_048_576
    deadline = System.monotonic_time(:millisecond) + 15_000

    options = [
      :binary,
      active: false,
      packet: :line,
      packet_size: 64,
      send_timeout_close: true,
      show_econnreset: true
    ]

    {:ok, socket} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, options, remaining(deadline))

    try do
      :ok = :inet.setopts(socket, send_timeout: remaining(deadline))
      :ok = :gen_tcp.send(socket, "CONNECT 1030\n")
      {:ok, handshake} = :gen_tcp.recv(socket, 0, remaining(deadline))
      true = Regex.match?(~r/\AOK [1-9][0-9]{0,9}\n\z/, handshake)
      :ok = :inet.setopts(socket, packet: :raw, send_timeout: remaining(deadline))
      :ok = :gen_tcp.send(socket, <<byte_size(body)::32, body::binary>>)
      {:error, :closed} = :gen_tcp.recv(socket, 0, remaining(deadline))
      true = remaining(deadline) > 0
      :ok
    after
      :gen_tcp.close(socket)
    end
  end

  @spec remaining(integer()) :: non_neg_integer()
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @spec checked_boot(Lilly.VM.Config.t(), Lilly.Host.Pool.t(), Spec.t(), keyword()) :: Boot.t()
  defp checked_boot(config, pool, spec, options) do
    # Owned spec, current boot record and confined VMM under the placement lock
    # (ADR-0133 boot proof); the VMM identity itself stays inside the probe.
    {:ok, %{pid: _, cgroup: _}} = Driver.boot_proof(config, pool, spec, options)
    directory = Path.join(config.state_dir, spec.id)
    {:ok, lock} = Lilly.Host.Lock.acquire(Path.join(directory, "lock"), 1000)

    try do
      {:ok, boot} =
        Boot.current(directory, spec.id, {options[:execution_epoch], options[:generation]})

      boot
    after
      Lilly.Host.Lock.release(lock)
    end
  end

  @spec command(Terminal.t(), stage(), String.t()) :: :ok
  defp command(terminal, stage, check) do
    checkpoint(stage)
    marker = "TRUST_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    input =
      "(#{check}) >/dev/null 2>&1 && printf '\\n%s%s\\n' #{marker} _OK || printf '\\n%s%s\\n' #{marker} _FAIL\n"

    # A completion marker can arrive before the shell returns to its prompt.
    # Keep each input below the Linux canonical PTY line bound in either mode.
    true = byte_size(input) <= 3072
    :ok = Terminal.write(terminal, input)

    wait(
      terminal,
      marker <> "_OK",
      marker <> "_FAIL",
      System.monotonic_time(:millisecond) + 70_000,
      ""
    )
  end

  @spec wait(Terminal.t(), String.t(), String.t() | nil, integer(), binary()) :: :ok
  defp wait(terminal, marker, failure, deadline, tail) do
    true = System.monotonic_time(:millisecond) < deadline

    case Terminal.read(terminal, 1000) do
      {:ok, bytes} ->
        data = tail <> bytes

        cond do
          String.contains?(data, marker) ->
            :ok

          is_binary(failure) and String.contains?(data, failure) ->
            raise "Native trust check failed"

          true ->
            wait(
              terminal,
              marker,
              failure,
              deadline,
              binary_part(data, max(byte_size(data) - 8192, 0), min(byte_size(data), 8192))
            )
        end

      {:error, :timeout} ->
        wait(terminal, marker, failure, deadline, tail)

      _ ->
        raise "Native trust terminal unavailable"
    end
  end
end

try do
  [placement, distribution, mode] = System.argv()
  IO.puts("TRUST_OK " <> FleetGuestTrust.run(placement, distribution, mode))
rescue
  _ ->
    IO.puts(
      :stderr,
      "Native trust probe failed at #{FleetGuestTrust.failure_stage()}; private state withheld"
    )

    System.halt(1)
end
