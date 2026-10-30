# @cc [owner:ghuntley,label:verification] inception-outer-production-admission
# The fixture MUST enroll native inventory and create its Inception VM as an
# ordinary user through production admission and dispatch. It MUST NOT inject
# successful outcomes or print credentials or terminal contents.
defmodule InceptionOuterFixture do
  alias Marshall.Compute.{Enrollment, EnrollmentPreparation, Images, Ledger, Operation, VirtualMachine}
  @root "/run/inception-outer"
  # Capacity admission waits for Lilly's fresh host report after enrollment;
  # keep this bounded but longer than one reporting interval plus cold startup.
  @provision_retry_ms 900_000
  # A newly enrolled host must publish a fresh execution-ready report before
  # Marshall will enable admission. Keep retrying that authoritative check
  # while Lilly's credentialed control connection converges.
  @enable_retry_ms 900_000

  def run do
    Application.put_env(:marshall, :operator_mode, true)
    {:ok, _} = Application.ensure_all_started(:marshall)
    action = System.fetch_env!("INCEPTION_OUTER_ACTION") |> String.trim_trailing("-two")
    case action do
      "enroll" -> enroll()
      "enroll-gateway" ->
        host = read("lilly.json")["host_id"]
        {lilly_uid, 0} = System.cmd(System.fetch_env!("INCEPTION_ID_BINARY"), ["-u", "lilly"])
        lilly_uid = lilly_uid |> String.trim() |> String.to_integer()
        true = lilly_uid > 0
        {token, _} = Marshall.Ingress.Token.issue()
        {:ok, _service} = Marshall.Ingress.configure_service(
          %{name: "inception-outer-audi", role: :gateway, host_id: host,
            addresses: ["11.0.0.5"], token: token},
          actor: Marshall.Authorization.SystemActor.compute())
        path = Path.join(@root, "audi.token")
        :ok = File.write(path, token <> "\n", [:exclusive])
        :ok = File.chmod(path, 0o600)
        write("audi.json", %{
          version: 1, role: "gateway", host_id: host, control_plane: "https://control.example.test:5443",
          credential_file: "/run/audi/gateway.token", cacertfile: "/run/credentials/audi.service/ca.pem",
          connector_path: "/run/lilly-ingress/audi.sock", connector_uid: lilly_uid,
          host_key_dir: "/var/lib/audi/keys", status_socket: "/run/audi/status.sock",
          bind: "11.0.0.5", port: 22,
          tls: %{zone: "apps.inception.test",
            trust_file: "/run/credentials/audi.service/certificate-roots.pem",
            browser_origin: "https://control.example.test",
            http_port: 80, https_port: 443}
        })
      "enroll-dns" ->
        for name <- ["ns1", "ns2"] do
          {token, _} = Marshall.Ingress.Token.issue()
          {:ok, _service} = Marshall.Ingress.configure_service(
            %{name: "inception-" <> name, role: :dns, addresses: [], token: token},
            actor: Marshall.Authorization.SystemActor.compute())
          path = Path.join(@root, name <> ".token")
          {:ok, file} = :file.open(String.to_charlist(path), [:write, :exclusive, :raw, :binary])
          try do
            :ok = File.chmod(path, 0o600)
            :ok = :file.write(file, token <> "\n")
            :ok = :file.sync(file)
          after
            :file.close(file)
          end
        end
      "enable" ->
        config = read("lilly.json")

        :ok =
          enable_host(config["host_id"], System.monotonic_time(:millisecond) + @enable_retry_ms)
      "create" ->
        actor = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "outer-native-#{instance()}@example.test"})
        image = System.fetch_env!("MARSHALL_INCEPTION_IMAGE_ID")
        request = %{name: "native-inception-#{instance()}", idempotency_key: "native-inception-#{instance()}", architecture: :x86_64,
          profile: :inception, image_id: image, vcpu: 16,
          memory_bytes: 32 * 1024 ** 3, disk_bytes: 64 * 1024 ** 3}
        {:ok, vm} = provision_retry(request, actor, System.monotonic_time(:millisecond) + @provision_retry_ms)
        write_instance("vm.json", %{user_id: actor.id, vm_id: vm.id})
        [operation] = Ledger.read!(Operation, vm_id: vm.id, generation: vm.generation)
        write_instance("command.json", operation.command_snapshot)
        await(vm.id, :running)
        [environment] = Ledger.read!(Marshall.Ingress.Environment, vm_id: vm.id)
        {:ok, origins} = Marshall.Ingress.Environments.origins(environment, "apps.inception.test")
        write_instance("origins.json", origins)
      kind when kind in ["stop", "start", "delete"] ->
        state = read_instance("vm.json")
        actor = Ash.get!(Marshall.Accounts.User, state["user_id"], authorize?: false)
        {:ok, _} = Marshall.Compute.lifecycle(%{vm_id: state["vm_id"],
          kind: String.to_existing_atom(kind), idempotency_key: "native-" <> kind}, actor: actor)
        await(state["vm_id"], Map.fetch!(%{"stop" => :stopped, "start" => :running, "delete" => :deleted}, kind))
    end
  end

  defp enroll do
    image = System.fetch_env!("INCEPTION_IMAGE")
    {:ok, _} = Images.register(Path.join(image, "manifest.json") |> File.read!() |> JSON.decode!(), "Inception")
    {:ok, host} = EnrollmentPreparation.prepare_file(
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", :prepare,
      Path.join(@root, "request.json"), Path.join(@root, "credential.json"))
    tools = System.fetch_env!("INCEPTION_TOOLS") |> File.read!() |> JSON.decode!()
    {uid, 0} = System.cmd(System.fetch_env!("INCEPTION_ID_BINARY"), ["-u", "audi"])
    audi_uid = uid |> String.trim() |> String.to_integer()
    true = audi_uid > 0
    write("lilly.json", %{
      version: 4, host_id: host.host_id, control_plane: "https://control.example.test:5443",
      cacertfile: "/run/overalls-test/ca.crt", credential_file: Path.join(@root, "credential.json"),
      state_dir: "/var/lib/lilly/control", cgroup_path: "/sys/fs/cgroup/lilly.slice",
      images: [%{"path" => image}],
      pools:
        Enum.map(host.pools, fn pool ->
          # Marshall's descriptor includes the display-only `name` field;
          # Lilly's closed startup schema accepts only the bound pool identity
          # and local path, so project the descriptor before JSON encoding.
          pool |> Map.take([:id, :filesystem_id, :storage]) |> Map.put(:path, "/pool")
        end),
      ingress: %{path: "/run/lilly-ingress/audi.sock", audi_uid: audi_uid},
      execution: Map.merge(Map.take(tools, ~w(firecracker jailer unshare)), %{
        "state_dir" => "/var/lib/lilly/vms", "network_state_dir" => "/var/lib/lilly/network",
        "egress_interface" => "eth1", "protected_cidrs" => [], "audi_ingress" => true,
        # The nested image enables the boot-bound private trust receiver. Its
        # network unit is ordered after that receiver, so this fixture must
        # publish the outer control CA for Lilly to deliver before readiness.
        # The nested guest verifies both the outer control plane and the
        # canonical github.com HTTPS mirror with the current fixture roots.
        "guest_trust_roots" => [
          "/run/overalls-test/ca.crt",
          "/run/inception-public-issuer-ca.pem",
          "/run/inception-public-roots.pem",
          System.fetch_env!("INCEPTION_SOURCE_CA")
        ],
        "inception_smtp_file" => "/run/inception-test/smtp.json",
        # Keep the bounded native Firecracker collector active for this
        # production-dispatch fixture so failed nested boots retain a private
        # diagnostic stream for triage.
        "firecracker_logging" => true,
        "inception_image_id" => System.fetch_env!("MARSHALL_INCEPTION_IMAGE_ID"),
        "inception_proof_file" => "/run/lilly-inception/proof.json",
        "inception_probe_id" => System.fetch_env!("INCEPTION_PROBE_IMAGE")
      })
    })
  end

  defp await(id, state), do: await(id, state, System.monotonic_time(:millisecond) + 2_700_000)

  # @cc [owner:ghuntley,label:verification;recovery] inception-enable-readiness-retry
  # The fixture MUST retry only the authoritative `:host_not_ready` result
  # within a bounded deadline. Every other enable refusal MUST fail closed.
  @spec enable_host(String.t(), integer()) :: :ok
  defp enable_host(host_id, deadline) do
    case Enrollment.set_enabled(host_id, true) do
      {:ok, _} ->
        :ok

      {:error, :host_not_ready} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1_000)
          enable_host(host_id, deadline)
        else
          raise "Inception host did not become ready before the enable deadline"
        end

      {:error, _reason} ->
        raise "Inception host enable was refused"

      _other ->
        raise "Inception host enable failed"
    end
  end

  defp provision_retry(request, actor, deadline) do
    case Marshall.Compute.provision(request, actor: actor) do
      {:ok, vm} -> {:ok, vm}
      {:error, _reason} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1_000)
          provision_retry(request, actor, deadline)
        else
          {:error, :provision_failed}
        end
      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1_000)
          provision_retry(request, actor, deadline)
        else
          {:error, :provision_failed}
        end
    end
  end
  defp await(id, state, deadline) do
    [vm] = Ledger.history!(VirtualMachine, id: id)
    cond do
      vm.observed_state == state ->
        [operation] = Ledger.read!(Operation, vm_id: id, generation: vm.generation)
        write_instance("command.json", operation.command_snapshot)
      vm.observed_state == :failed ->
        IO.puts("Outer lifecycle state: observed=failed failure=#{vm.failure_reason || :none}")
        raise "Outer lifecycle failed"
      System.monotonic_time(:millisecond) >= deadline ->
        IO.puts("Outer lifecycle state: observed=#{vm.observed_state} failure=#{vm.failure_reason || :none}")
        raise "Outer lifecycle outcome timed out"
      true -> Process.sleep(250); await(id, state, deadline)
    end
  end

  # @cc [owner:ghuntley,label:verification] inception-fixture-distinct-instances
  # Concurrent environments MUST have separate ordinary users, idempotency keys
  # and lifecycle receipts. Shared host enrollment MUST remain one identity.
  defp instance do
    if String.ends_with?(System.fetch_env!("INCEPTION_OUTER_ACTION"), "-two"),
      do: "two", else: "one"
  end

  defp instance_file(name), do: if(instance() == "two", do: "two-" <> name, else: name)
  defp read_instance(name), do: read(instance_file(name))
  defp write_instance(name, value), do: write(instance_file(name), value)

  defp read(name), do: Path.join(@root, name) |> File.read!() |> JSON.decode!()
  defp write(name, value) do
    path = Path.join(@root, name)
    File.write!(path, JSON.encode!(value))
    File.chmod!(path, 0o600)
  end
end

InceptionOuterFixture.run()
