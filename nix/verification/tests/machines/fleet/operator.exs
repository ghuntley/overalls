Code.require_file("/etc/fleet-account-lifecycle.exs")
Code.require_file("/etc/fleet-github-historical.exs")

# Trusted fixture entry point; all actions are fenced by the disposable DB sentinel.
defmodule FleetOperator do
  require Ash.Query
  alias Marshall.Compute.{Enrollment, EnrollmentRequest, Host, Images, Ledger, StoragePool}
  alias Marshall.Authorization.SystemActor

  @spec await_barrier(nil | String.t()) :: :ok
  def await_barrier(nil), do: :ok

  def await_barrier(id) do
    true = OverallsProtocol.uuid?(id)
    root = "/tmp/shared/fleet-barrier-#{id}"
    node = System.fetch_env!("FLEET_NODE")
    true = node in ["m1", "m2", "m3"]
    :ok = File.write(Path.join(root, "#{node}.ready"), "", [:exclusive])
    await_file(Path.join(root, "release"), System.monotonic_time(:millisecond) + 120_000)
  end

  @spec run(map()) :: map()
  def run(%{"action" => "github-historical-windows"} = request),
    do: GitHubHistoricalFleet.run(request)

  def run(%{"action" => "account-lifecycle", "request" => request}) do
    FleetAccountLifecycle.run(request)
  end

  def run(%{"action" => "service-levels", "vm_id" => vm_id}) when is_binary(vm_id),
    do: service_levels(vm_id)

  # @cc [owner:ghuntley,label:verification] fleet-synthetic-mailbox-edit
  # Only disposable users may receive this internal mailbox edit. The fixture
  # MUST update the User resource without changing guest accounts or VM intent.
  def run(%{"action" => "identity-email", "user_id" => id, "email" => email}) do
    true = OverallsProtocol.uuid?(id)
    true = Marshall.Accounts.EmailAddress.valid?(email)
    true = String.ends_with?(email, "@example.test")
    user = Ash.get!(Marshall.Accounts.User, id, authorize?: false)
    true = is_nil(user.deleted_at)
    true = String.ends_with?(to_string(user.email), "@example.test")

    updated =
      user
      |> Ash.Changeset.for_update(:security_state, %{email: email}, actor: SystemActor.compute())
      |> Ash.update!()

    %{updated: updated.id == id and to_string(updated.email) == email}
  end

  # @cc [owner:ghuntley,label:verification;capacity] relocation-source-observation-only
  # The disposable preflight MUST return only boolean current-source predicates.
  # It MUST NOT update telemetry, holds, operations or authority, invoke admission,
  # or turn a passing unlocked observation into a production readiness proof.
  def run(%{"action" => "relocation-source-observations", "vm_id" => id}) do
    true = OverallsProtocol.uuid?(id)
    observe_source_until(id, System.monotonic_time(:millisecond) + 60_000)
  end

  # @cc [owner:ghuntley,label:verification;capacity] repository-admission-observation-only
  # Repository preflight MUST read actual image, host, pool and reservation rows
  # and reuse production shape, liveness and Budget arithmetic. Polling MUST stay
  # bounded; it MUST NOT alter telemetry, budgets, holds, freshness or authority.
  # An unlocked eligible observation MUST NOT establish transactional admission.
  def run(%{"action" => "repository-admission-observations", "image_id" => id}) do
    true = OverallsProtocol.ImageManifest.id?(id)
    observe_admission_until(id, System.monotonic_time(:millisecond) + 60_000)
  end

  # @cc [owner:ghuntley,label:verification;security] evacuation-native-fixture-authority
  # The disposable bootstrap administrator MUST authenticate with a normal
  # short-lived magic link and enroll/elevate a real browser passkey. Fixture
  # advancement MUST call the durable coordinator, never forge physical receipts.
  def run(%{
        "action" => "evacuation-browser",
        "source" => source,
        "output" => output,
        "host_id" => host
      }) do
    true = OverallsProtocol.uuid?(host)

    admin =
      Marshall.Accounts.User
      |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
      |> Ash.Query.filter(email == "profile-bootstrap@example.test")
      |> Ash.read_one!()

    true = admin.administrator
    strategy = AshAuthentication.Info.strategy!(Marshall.Accounts.User, :magic_link)
    {:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, admin)
    users = source |> File.read!() |> JSON.decode!()
    private_write(output, Map.merge(users, %{"admin_token" => token, "source_host" => host}))
    %{prepared: true}
  end

  def run(%{"action" => "evacuation-advance", "id" => id}) do
    true = OverallsProtocol.uuid?(id)
    {:ok, state} = Marshall.Compute.Evacuations.advance(id)

    true =
      state in [
        :scheduled,
        :paused,
        :ready,
        :awaiting_cleanup,
        :already_scheduled,
        :plan_changed,
        :blocked
      ]

    %{state: state}
  end

  # @cc [owner:ghuntley,label:verification] fleet-abandoned-real-transaction
  # The loss fixture MUST hold an actual VM row lock using the release Repo's
  # production connection parameters and publish its backend PID only after
  # locking. No database timeout may be overridden by this fixture.
  def run(%{"action" => "hold-transaction", "vm_id" => vm}) do
    true = OverallsProtocol.uuid?(vm)
    output = "/var/lib/overalls-fleet/held-transaction.json"

    {:ok, :ok} =
      Marshall.Repo.transaction(
        fn ->
          %{rows: [[pid]]} =
            Ecto.Adapters.SQL.query!(Marshall.Repo, "SELECT pg_backend_pid()", [], log: false)

          %{num_rows: 1} =
            Ecto.Adapters.SQL.query!(
              Marshall.Repo,
              "SELECT id FROM compute_virtual_machines WHERE id = $1 FOR UPDATE",
              [Ecto.UUID.dump!(vm)],
              log: false
            )

          private_write(output <> ".pending", %{pid: pid})
          :ok = File.rename(output <> ".pending", output)
          await_file(output <> ".release", System.monotonic_time(:millisecond) + 60_000)
        end,
        timeout: 65_000
      )

    %{released: true}
  end

  def run(%{
        "action" => "enroll",
        "host_id" => host_id,
        "pool_id" => pool_id,
        "request" => request,
        "output" => output
      }) do
    true = OverallsProtocol.uuid?(host_id) and OverallsProtocol.uuid?(pool_id)
    {:ok, parsed} = EnrollmentRequest.parse(request)
    [pool] = parsed.pools
    # @cc [owner:ghuntley,label:verification] fleet-fixed-public-resource-identifiers
    # Only fixture resource UUIDs are selected in advance so immutable NixOS
    # configurations can bind them. Enrollment parser/actions, credential issuance
    # and runtime authentication MUST remain real. Capacity MUST stay unknown and
    # the host disabled until its actual Lilly service reports.
    {:ok, :ok} =
      Ledger.transaction(fn ->
        create_with_id(Host, parsed.host, host_id)
        create_with_id(StoragePool, Map.put(pool, :host_id, host_id), pool_id)
        :ok
      end)

    {:ok, _} = Enrollment.rotate_file(host_id, parsed.ttl, output)
    [host] = Ledger.read!(Host, id: host_id)
    [stored] = Ledger.read!(StoragePool, id: pool_id)
    false = host.enabled
    nil = host.reported_at
    0 = host.effective_cores
    0 = stored.total_bytes
    %{enrolled: true, host_id: host_id}
  end

  def run(%{"action" => "revoke-host", "host_id" => id}) do
    true = OverallsProtocol.uuid?(id)
    {:ok, result} = Enrollment.revoke(id)
    result
  end

  def run(%{"action" => "rotate-host", "host_id" => id, "output" => output}) do
    true = OverallsProtocol.uuid?(id)
    {:ok, _} = Enrollment.rotate_file(id, 3600, output)
    %{rotated: true}
  end

  # @cc [owner:ghuntley,label:verification;security] fleet-fresh-browser-tokens
  # Late browser acceptance MUST mint normal short-lived tokens for the existing
  # fixture users without changing their identities or authentication deadlines.
  # Tokens MUST leave this action only through its private output file.
  def run(%{"action" => "refresh-browser-tokens", "source" => source, "output" => output}) do
    users = source |> File.read!() |> JSON.decode!()
    strategy = AshAuthentication.Info.strategy!(Marshall.Accounts.User, :magic_link)

    refreshed =
      Enum.reduce(["owner", "member", "stranger"], users, fn role, values ->
        user =
          Ash.get!(Marshall.Accounts.User, Map.fetch!(users, role <> "_id"), authorize?: false)

        {:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, user)
        Map.put(values, role <> "_token", token)
      end)

    private_write(output, refreshed)
    %{refreshed: true}
  end

  # @cc [owner:ghuntley,label:verification] fleet-browser-permitted-identities
  # Fixture browser identities MUST satisfy production sign-in validation.
  # Authentication policy MUST NOT be bypassed to make browser acceptance pass.

  # @cc [owner:ghuntley,label:verification] fleet-audi-real-domain-actions
  # Audi enrollment and endpoint policy MUST use the production Ash actions.
  # Fresh bearer credentials MUST be written privately and never returned in
  # fixture output. These actions do not fabricate routes or certificates.
  def run(
        %{"action" => "audi-enroll", "role" => role, "name" => name, "output" => output} = request
      ) do
    role = Map.fetch!(%{"dns" => :dns, "gateway" => :gateway}, role)
    {token, _} = Marshall.Ingress.Token.issue()

    {:ok, service} =
      Marshall.Ingress.configure_service(
        %{
          name: name,
          role: role,
          host_id: request["host_id"],
          addresses: Map.get(request, "addresses", []),
          relay_address:
            if(System.get_env("FLEET_SUSPENSION_RELAY") == "1" and role == :gateway,
              do: if(name == "audi-l1", do: "10.90.0.1", else: "10.90.0.2"),
              else: nil
            ),
          relay_port:
            if(System.get_env("FLEET_SUSPENSION_RELAY") == "1" and role == :gateway,
              do: 9445,
              else: nil
            ),
          token: token
        },
        actor: SystemActor.compute()
      )

    true = String.starts_with?(output, "/var/lib/overalls-fleet/")
    {:ok, file} = :file.open(String.to_charlist(output), [:write, :exclusive, :raw, :binary])

    try do
      :ok = File.chmod(output, 0o600)
      :ok = :file.write(file, token <> "\n")
      :ok = :file.sync(file)
    after
      :file.close(file)
    end

    %{id: service.id, registered: true}
  end

  # @cc [owner:ghuntley,label:verification;security] customer-admin-promotion-fixture
  # The promotion fixture MAY set only an existing disposable user's persisted
  # administrator flag inside the sentinel-fenced database; it MUST NOT mint
  # passkeys, sessions, elevation proofs or any production authority path.
  def run(%{"action" => "customer-promote-admin", "member_id" => member_id}) do
    true = OverallsProtocol.uuid?(member_id)
    user = Ash.get!(Marshall.Accounts.User, member_id, authorize?: false)

    user =
      if user.administrator,
        do: user,
        else: Ash.Seed.update!(user, %{administrator: true})

    %{administrator: user.administrator}
  end

  def run(%{
        "action" => "customer-denial",
        "owner_id" => owner,
        "vm_id" => vm,
        "member_email" => email
      }) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)
    {:ok, endpoint} = Marshall.Ingress.get_endpoint(%{vm_id: vm}, actor: actor)

    for visibility <- [:public, :private] do
      {:error, _} =
        Marshall.Ingress.configure_endpoint(
          %{
            vm_id: vm,
            expected_revision: endpoint.policy_revision,
            primary_port: 8080,
            visibility: visibility
          },
          actor: actor
        )
    end

    for role <- [:web, :viewer, :operator, :manager] do
      {:error, _} =
        Marshall.Access.set_access(
          %{vm_id: vm, email: email, role: role, idempotency_key: Ash.UUID.generate()},
          actor: actor
        )
    end

    %{denied: true, label: endpoint.label}
  end

  def run(%{
        "action" => "audi-policy",
        "owner_id" => owner,
        "vm_id" => vm,
        "visibility" => visibility
      }) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)
    {:ok, endpoint} = Marshall.Ingress.get_endpoint(%{vm_id: vm}, actor: actor)

    {:ok, changed} =
      Marshall.Ingress.configure_endpoint(
        %{
          vm_id: vm,
          expected_revision: endpoint.policy_revision,
          primary_port: 8080,
          visibility: Map.fetch!(%{"public" => :public, "private" => :private}, visibility)
        },
        actor: actor
      )

    %{label: changed.label, revision: changed.policy_revision}
  end

  def run(%{"action" => "audi-ssh-key", "owner_id" => owner, "public_key" => public}) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)
    {:ok, key} = Marshall.SSH.add_key(%{public_key: public, label: "audi-fleet"}, actor: actor)
    %{id: key.id}
  end

  def run(%{"action" => "audi-ssh-revoke", "owner_id" => owner, "key_id" => key}) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)
    {:ok, _} = Marshall.SSH.remove_key(%{id: key}, actor: actor)
    %{revoked: true}
  end

  # @cc [owner:ghuntley,label:verification;security] fleet-ssh-terminal-attach-actions
  # SSH attach acceptance MUST open the browser's personal session through
  # the same production call and deterministic request TerminalLive uses,
  # and revoke the gateway key through the owner's production removal
  # action. Only identifiers and the post-commit wall clock leave the action.
  def run(%{"action" => "terminal-personal-session", "owner_id" => owner, "vm_id" => vm}) do
    true = OverallsProtocol.uuid?(owner) and OverallsProtocol.uuid?(vm)
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)

    # Readiness refusals (for example a host stream not yet registered) are
    # closed atoms; the scenario retries them within its own deadline.
    case Marshall.Terminal.Authority.open_personal_session(%{id: vm}, actor, :default, :connect) do
      {:ok, session} -> %{session_id: session.id}
      {:error, reason} when is_atom(reason) -> %{session_id: nil, reason: reason}
    end
  end

  def run(%{"action" => "ssh-key-revoke", "owner_id" => owner, "public_key" => public}) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)
    {:ok, parsed} = OverallsProtocol.SSHKey.parse(public)
    {:ok, keys} = Marshall.SSH.list_keys(actor: actor)
    [key] = Enum.filter(keys, &(&1.fingerprint == parsed.fingerprint))
    {:ok, _} = Marshall.SSH.remove_key(%{id: key.id}, actor: actor)
    %{revoked_at_ms: System.os_time(:millisecond)}
  end

  # @cc [owner:ghuntley,label:verification;security] galileo-fleet-domain-actions
  # Galileo acceptance setup MUST use production credential and Ash domain
  # actions. The fixture exposes only two fixed synthetic integrations and
  # attach/detach operations; it MUST NOT mutate Galileo tables or return secret
  # header values, peer tokens or host credentials.
  def run(%{"action" => "galileo-enroll", "host_id" => host, "output" => output}) do
    true = OverallsProtocol.uuid?(host)
    true = String.starts_with?(output, "/var/lib/overalls-fleet/galileo-")
    {:ok, result} = Marshall.Operations.Galileo.rotate(host, 14_400, output)
    Map.take(result, [:host_id, :credential_id]) |> Map.put(:issued, true)
  end

  def run(%{"action" => "peach-enroll", "host_id" => host, "output" => output}) do
    true = OverallsProtocol.uuid?(host)
    true = String.starts_with?(output, "/var/lib/overalls-fleet/peach-")
    {:ok, result} = Marshall.Operations.Peach.rotate(host, 14_400, output)
    Map.take(result, [:host_id, :credential_id]) |> Map.put(:issued, true)
  end

  def run(
        %{
          "action" => "galileo-configure-direct",
          "owner_id" => owner
        } = request
      ) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)

    {:ok, integration} =
      Marshall.Galileo.configure_integration(
        %{
          name: "directapi",
          team_id: request["team_id"],
          target: "https://origin.galileo.test",
          strip_prefix: nil,
          headers: [
            %{kind: :bearer, name: "authorization", value: "galileo-fleet-secret"},
            %{kind: :static, name: "x-galileo-fleet", value: "platform"}
          ],
          peer: false,
          idempotency_key: "galileo-fleet-direct-v1"
        },
        actor: actor
      )

    %{id: integration.id, name: integration.name, configured: true}
  end

  def run(%{
        "action" => "galileo-configure-peer",
        "owner_id" => owner,
        "target_vm_id" => target
      }) do
    true = OverallsProtocol.uuid?(target)
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)

    {:ok, integration} =
      Marshall.Galileo.configure_integration(
        %{
          name: "peerapi",
          target: nil,
          strip_prefix: nil,
          headers: [],
          peer: true,
          peer_vm_id: target,
          idempotency_key: "galileo-fleet-peer-v1"
        },
        actor: actor
      )

    %{id: integration.id, name: integration.name, configured: true}
  end

  def run(%{
        "action" => action,
        "owner_id" => owner,
        "vm_id" => vm
      })
      when action in [
             "galileo-attach-direct",
             "galileo-detach-direct",
             "galileo-attach-peer",
             "galileo-detach-peer"
           ] do
    true = OverallsProtocol.uuid?(vm)
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)

    name =
      if action in ["galileo-attach-peer", "galileo-detach-peer"],
        do: "peerapi",
        else: "directapi"

    attached = action in ["galileo-attach-direct", "galileo-attach-peer"]

    result =
      if attached do
        {:ok, result} =
          Marshall.Galileo.attach_integration(%{name: name, vm_id: vm}, actor: actor)

        result
      else
        {:ok, result} =
          Marshall.Galileo.detach_integration(%{name: name, vm_id: vm}, actor: actor)

        result
      end

    Map.take(result, [:integration_id, :vm_id])
    |> Map.put(:attached, attached)
  end

  # @cc [owner:ghuntley,label:verification;security] fleet-ssh-profile-fixture
  # SSH profiles MUST use the test-only template and fixed fixture origins.
  # Only a validated label from the authorized endpoint may enter the template;
  # this fixture MUST NOT depend on a production configuration renderer.
  def run(%{
        "action" => "audi-ssh-profile",
        "owner_id" => owner,
        "vm_id" => vm,
        "output" => output
      }) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)
    {:ok, endpoint} = Marshall.Ingress.get_ssh_endpoint(%{vm_id: vm}, actor: actor)

    true = OverallsProtocol.IngressName.valid_label?(endpoint.label)

    profile =
      File.read!("/etc/fleet-audi-ssh.conf.in")
      |> String.replace("@label@", endpoint.label)
      |> String.replace("@zone@", "apps.example.test")
      |> String.replace("@origin@", "https://control.example.test")
      |> String.replace("@port@", "22")

    :ok = File.write(output, profile, [:exclusive])
    %{written: true}
  end

  # @cc [owner:ghuntley,label:verification;security] default-oss-ordinary-fixture
  # Default-profile acceptance MUST represent an installed system before any
  # browser login. A distinct unused administrator completes bootstrap; the
  # owner/member/stranger seeds MUST acquire no global administrator authority.
  def run(%{"action" => "default-oss-users", "output" => output}) do
    Ash.Seed.seed!(Marshall.Accounts.User, %{
      email: "profile-bootstrap@example.test",
      administrator: true
    })

    [bootstrap] = Ledger.read!(Marshall.Accounts.AdminBootstrap, id: "installation")
    Ledger.update!(bootstrap, :complete, %{})
    run(%{"action" => "users", "output" => output})
  end

  # @cc [owner:ghuntley,label:verification;security] default-customer-agent-refusal
  # A newly selected Customer MUST have no agent root and its owner MUST receive
  # a closed conversation refusal; no fixture may create a Customer agent root.
  def run(%{"action" => "customer-agent-refusal", "vm_id" => vm_id, "owner_id" => owner_id}) do
    true = OverallsProtocol.uuid?(vm_id) and OverallsProtocol.uuid?(owner_id)
    [vm] = Ledger.read!(Marshall.Compute.VirtualMachine, id: vm_id)
    :customer = vm.profile
    ^owner_id = vm.owner_id
    actor = Ash.get!(Marshall.Accounts.User, owner_id, authorize?: false)
    [] = Ledger.read!(Marshall.Agents.Root, vm_id: vm_id)
    {:error, :machine_unavailable} = Marshall.Agents.Conversation.list(vm_id, actor)
    %{refused: true}
  end

  # @cc [owner:ghuntley,label:verification;security] fleet-user-public-projection
  # Every seeded ordinary account MUST expose its UUID and email in the public
  # fixture receipt. Authentication tokens MUST remain only in the private file.
  def run(%{"action" => "users", "output" => output}) do
    {:ok, image} =
      Images.register(
        System.fetch_env!("FLEET_GUEST")
        |> Path.join("manifest.json")
        |> File.read!()
        |> JSON.decode!(),
        System.get_env("FLEET_GUEST_NAME", "nixos-fleet")
      )

    alternative =
      case System.get_env("FLEET_ALTERNATIVE_GUEST") do
        nil ->
          nil

        path ->
          manifest = path |> Path.join("manifest.json") |> File.read!() |> JSON.decode!()
          {:ok, other} = Images.register(manifest, "NixOS")
          other.id
      end

    suffix =
      System.fetch_env!("FLEET_FIXTURE_ID") |> String.replace("-", "") |> binary_part(0, 16)

    owner = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "owner-#{suffix}@example.test"})
    member = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "member-#{suffix}@example.test"})

    stranger =
      Ash.Seed.seed!(Marshall.Accounts.User, %{email: "stranger-#{suffix}@example.test"})

    strategy = AshAuthentication.Info.strategy!(Marshall.Accounts.User, :magic_link)
    {:ok, owner_token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, owner)

    {:ok, owner_mfa_token} =
      AshAuthentication.Strategy.MagicLink.request_token_for(strategy, owner)

    {:ok, member_token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, member)

    {:ok, stranger_token} =
      AshAuthentication.Strategy.MagicLink.request_token_for(strategy, stranger)

    private_write(output, %{
      owner_id: owner.id,
      owner_email: to_string(owner.email),
      member_id: member.id,
      stranger_id: stranger.id,
      stranger_email: to_string(stranger.email),
      member_email: to_string(member.email),
      image_id: image.id,
      alternative_image_id: alternative,
      owner_token: owner_token,
      owner_mfa_token: owner_mfa_token,
      member_token: member_token,
      stranger_token: stranger_token
    })

    %{
      created: true,
      owner_id: owner.id,
      owner_email: to_string(owner.email),
      member_id: member.id,
      stranger_id: stranger.id,
      stranger_email: to_string(stranger.email),
      member_email: to_string(member.email),
      image_id: image.id,
      alternative_image_id: alternative
    }
  end

  def run(%{"action" => "enable", "host_id" => id, "enabled" => enabled})
      when is_boolean(enabled) do
    enable_host(id, enabled, System.monotonic_time(:millisecond) + 30_000)
  end

  # @cc [owner:ghuntley,label:verification] fleet-enable-once-single-attempt
  # This fixture exposes exactly one Enrollment.set_enabled/2 attempt so the
  # driver can observe the documented pre-readiness refusal; no retry loop, no
  # readiness fabrication and no second entry point.
  def run(%{"action" => "enable-once", "host_id" => id, "enabled" => true}) do
    true = OverallsProtocol.uuid?(id)

    case Enrollment.set_enabled(id, true) do
      {:ok, result} -> %{enabled: result.enabled, refused: false}
      {:error, reason} -> %{enabled: false, refused: true, reason: Atom.to_string(reason)}
    end
  end

  # @cc [owner:ghuntley,label:verification;security] fleet-host-retire-real-drain-chain
  # Retirement MUST run the real Drains request/advance/retire chain in order.
  # The fixture reports each step's durable status and must not fabricate
  # quiescence, closure or revocation.
  def run(%{"action" => "host-retire", "host_id" => id}) do
    true = OverallsProtocol.uuid?(id)
    drain_id = Ash.UUID.generate()
    {:ok, requested} = Marshall.Compute.Drains.request(id, drain_id, "verify112:native")
    {:ok, _} = Marshall.Compute.Drains.advance(drain_id)
    {:ok, retired} = await_drain_closure(drain_id, System.monotonic_time(:millisecond) + 90_000)

    %{
      drain_id: drain_id,
      requested: requested.status,
      status: retired.status,
      host_mode: retired.host_mode,
      enabled: retired.enabled
    }
  end

  # Advancing or closing with only current evidence; a live host refreshes its
  # report continuously, so bounded real retries converge without fabrication.
  defp await_drain_closure(drain_id, deadline) do
    {:ok, _} = Marshall.Compute.Drains.advance(drain_id)

    case Marshall.Compute.Drains.retire(drain_id) do
      {:ok, retired} ->
        {:ok, retired}

      {:error, :host_not_quiescent} ->
        if System.monotonic_time(:millisecond) >= deadline, do: raise("host never quiesced")
        Process.sleep(250)
        await_drain_closure(drain_id, deadline)
    end
  end

  # @cc [owner:ghuntley,label:verification;product] fleet-image-catalog-churn-fixture
  # Operator image availability changes MUST traverse the audited `configure`
  # action with its image row lock; identity, manifest and minima never change.
  # Fixture drivers use this to prove existing workloads survive catalog churn.
  def run(%{"action" => "image-configure", "image_id" => id, "enabled" => enabled})
      when is_boolean(enabled) do
    [image] = Ledger.read!(Marshall.Compute.Image, id: id)
    updated = Ledger.update!(image, :configure, %{enabled: enabled})
    %{image_id: updated.id, enabled: updated.enabled}
  end

  # @cc [owner:ghuntley,label:verification;recovery] fleet-clone-cancel-fixture
  # Clone cancellation from a fixture MUST traverse the authorized domain action
  # with the owner actor. The response carries only id, phase and failure.
  def run(%{"action" => "cancel-clone", "owner_id" => owner, "request_id" => id}) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)
    {:ok, request} = Marshall.Compute.cancel_clone(%{request_id: id}, actor: actor)
    Map.take(request, [:id, :phase, :failure])
  end

  # @cc [owner:ghuntley,label:verification;security] fleet-agent-user-authority
  # Agent acceptance enters the real authorized domain actions. The fixture
  # returns only IDs and a fixed answer match, never prompt or tool content.
  def run(
        %{
          "action" => "agent-prompt",
          "actor_id" => actor_id,
          "vm_id" => vm_id,
          "key" => key
        } = request
      ) do
    actor = Ash.get!(Marshall.Accounts.User, actor_id, authorize?: false)
    {:ok, [thread | _]} = Marshall.Agents.Conversation.list(vm_id, actor)
    prompt = Map.get(request, "prompt", "Read this machine's hostname")

    true =
      prompt in [
        "Read this machine's hostname",
        "Read guest context and skills $review",
        "Try child agent",
        "Search example topic",
        "Fetch local content"
      ]

    {:ok, result} =
      Marshall.Agents.submit_prompt(
        %{thread_id: thread.id, prompt: prompt, request_key: key},
        actor: actor
      )

    %{thread_id: thread.id, turn_id: result.turn_id, status: result.status}
  end

  # @cc [owner:ghuntley,label:verification;security] fleet-porsche-thread-fixture
  # The porsche-threads fixture MUST create its thread through the authorized
  # Threads action with the owner actor and the manifest-derived default shape.
  # It returns only identifiers and status, never the objective text.
  def run(%{"action" => "thread-create", "owner_id" => owner, "image_id" => image, "key" => key}) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)
    [catalog_image] = Ledger.read!(Marshall.Compute.Image, id: image)

    {:ok, thread} =
      Marshall.Threads.create_thread(
        %{
          objective: "Read this machine's hostname",
          mode: :medium,
          idempotency_key: key,
          machine_spec: %{
            idempotency_key: key,
            architecture: :x86_64,
            image_id: image,
            profile: :standard,
            vcpu: 1,
            memory_bytes: max(536_870_912, catalog_image.minimum_memory_bytes),
            disk_bytes: max(3_221_225_472, catalog_image.minimum_disk_bytes)
          }
        },
        actor: actor
      )

    %{thread_id: thread.id, status: thread.status}
  end

  # @cc [owner:ghuntley,label:verification;security] fleet-porsche-planning-stand-in
  # The porsche-threads fleet has no model provider. These fixtures stand in
  # only for the model's question and plan tool calls, through the same
  # Planning domain functions; answers and approval MUST still travel through
  # Porsche. They settle earlier fixture turns first and return identifiers only.
  def run(%{"action" => "thread-question", "owner_id" => owner, "thread_id" => id}) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)
    [thread] = Ledger.read!(Marshall.Threads.Thread, id: id)

    {:ok, question} =
      Ledger.transaction(fn ->
        agent = Ledger.lock!(Marshall.Agents.Thread, thread.agent_thread_id)
        turns = Ledger.read!(Marshall.Agents.Turn, thread_id: agent.id)
        Enum.each(turns, &settle_turn/1)

        turn =
          Ledger.create!(Marshall.Agents.Turn, :enqueue, %{
            thread_id: agent.id,
            actor_id: actor.id,
            request_key: Ash.UUID.generate(),
            ordinal: length(turns) + 1,
            prompt: "Choose the implementation approach.",
            collaboration_mode: :plan
          })

        turn = Ledger.update!(turn, :transition, %{status: :running, started_at: Ledger.now()})
        agent = Ledger.update!(agent, :set_context, %{collaboration_mode: :plan})
        agent = Ledger.update!(agent, :advance, %{active_turn_id: turn.id})

        Marshall.Agents.Planning.request_questions_locked!(agent, turn, %{
          id: "fleet-question",
          arguments: %{
            "questions" => [
              %{
                "id" => "approach",
                "header" => "Approach",
                "question" => "Which approach should the plan use?",
                "options" => [
                  %{"label" => "First", "description" => "Keep the current interface."},
                  %{"label" => "Second", "description" => "Add a new interface."}
                ]
              }
            ]
          }
        })
      end)

    %{question_id: question.id}
  end

  def run(%{"action" => "thread-proposal", "thread_id" => id}) do
    [thread] = Ledger.read!(Marshall.Threads.Thread, id: id)

    {:ok, proposal} =
      Ledger.transaction(fn ->
        agent = Ledger.lock!(Marshall.Agents.Thread, thread.agent_thread_id)
        turns = Ledger.read!(Marshall.Agents.Turn, thread_id: agent.id)
        Enum.each(turns, &settle_turn/1)
        Ledger.update!(agent, :advance, %{active_turn_id: nil})
        turn = Enum.max_by(turns, & &1.ordinal)
        text = "Inspect the route, implement the change, and verify the response."

        Ledger.create!(Marshall.Agents.PlanProposal, :record, %{
          thread_id: agent.id,
          turn_id: turn.id,
          event_sequence: agent.next_event_sequence,
          text: text,
          digest: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
        })
      end)

    %{plan_id: proposal.id}
  end

  def run(%{"action" => "agent-result", "actor_id" => actor_id, "turn_id" => turn_id}) do
    actor = Ash.get!(Marshall.Accounts.User, actor_id, authorize?: false)
    {:ok, result} = Marshall.Agents.Conversation.turn(turn_id, actor)

    %{
      status: result.status,
      answer_matches: Map.get(result, :text) == "fixture agent reply",
      reason: Map.get(result, :reason)
    }
  end

  # @cc [owner:ghuntley,label:verification;capacity] fleet-explicit-provision-shapes
  # Fixture provisioning MUST use the real authorized admission action and a
  # manifest-derived default or an explicitly supported test disk size. The
  # 17 GiB root is reserved for the native
  # physical-refusal control; unsupported shapes and unclassified failures MUST
  # fail instead of being reported as insufficient capacity. An explicit vcpu
  # of 3 MUST force a running clone's copy onto the other provisioner: with 6
  # enrolled cores and 1 overhead core, the source's 3-vCPU restart hold plus a
  # 3-vCPU same-host copy exceeds the 5 schedulable cores. Two vCPUs still fit.
  def run(
        %{
          "action" => "provision",
          "owner_id" => owner,
          "image_id" => image,
          "profile" => profile,
          "key" => key
        } = request
      ) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)
    # @cc [owner:ghuntley,label:verification] fleet-manifest-disk-default
    # Default provisioning MUST meet the registered image's minimum disk size.
    # Capacity refusal assertions MUST retain real admission errors; image growth
    # must not turn a capacity probe into an invalid-shape request.
    [catalog_image] = Ledger.read!(Marshall.Compute.Image, id: image)
    default_disk_bytes = max(3_221_225_472, catalog_image.minimum_disk_bytes)
    default_memory_bytes = max(536_870_912, catalog_image.minimum_memory_bytes)
    disk_bytes = Map.get(request, "disk_bytes", default_disk_bytes)

    true =
      disk_bytes in [
        default_disk_bytes,
        4_294_967_296,
        5_368_709_120,
        6_442_450_944,
        68_719_476_736
      ]

    true = disk_bytes >= catalog_image.minimum_disk_bytes
    # @cc [owner:ghuntley,label:verification] fleet-manifest-memory-shapes
    # Default provisioning MUST meet the registered image's minimum memory.
    # Coding-client fixtures MAY explicitly request 2 GiB or the image minimum;
    # unsupported shapes MUST fail before actual admission is invoked.
    memory_bytes = Map.get(request, "memory_bytes", default_memory_bytes)
    true = memory_bytes in [default_memory_bytes, 2_147_483_648]
    true = memory_bytes >= catalog_image.minimum_memory_bytes
    vcpu = Map.get(request, "vcpu", 1)
    true = vcpu in [1, 3]
    # A team machine carries its team; team members' authority derives from it.
    team_id = Map.get(request, "team_id")
    true = is_nil(team_id) or match?({:ok, _}, Ecto.UUID.cast(team_id))

    profile =
      Map.fetch!(%{"customer" => :customer, "standard" => :standard, "oss" => :oss}, profile)

    result =
      Marshall.Compute.provision(
        %{
          idempotency_key: key,
          architecture: :x86_64,
          image_id: image,
          profile: profile,
          vcpu: vcpu,
          memory_bytes: memory_bytes,
          disk_bytes: disk_bytes,
          team_id: team_id
        },
        actor: actor
      )

    case result do
      {:ok, vm} ->
        %{
          accepted: true,
          vm_id: vm.id,
          placement_id: vm.current_placement_id,
          host_id: vm.host_id
        }

      {:error, error} ->
        true = capacity_failure?(error)
        %{accepted: false, reason: "insufficient_capacity"}
    end
  end

  # @cc [owner:ghuntley,label:verification] fleet-bootstrap-lifecycle-authority
  # Bootstrap regression scenarios MUST use authorized clone/resize actions.
  # No observation, phase, reservation or readiness proof may be fabricated.
  def run(%{"action" => "clone", "owner_id" => owner, "vm_id" => vm, "key" => key}) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)
    {:ok, request} = Marshall.Compute.clone(%{vm_id: vm, idempotency_key: key}, actor: actor)
    Map.take(request, [:id, :destination_vm_id])
  end

  # @cc [owner:ghuntley,label:verification] clone-native-observed-dispatch
  # Fixture stepping MUST run the unchanged coordinator against actual Lilly
  # receipts; it MUST NOT synthesize effects, phases or physical outcomes.
  def run(%{"action" => "clone-advance", "request_id" => id}) do
    true = OverallsProtocol.uuid?(id)
    {:ok, _} = Marshall.Compute.CloneCoordinator.advance(id)
    [request] = Ledger.read!(Marshall.Compute.CloneRequest, id: id)
    Map.take(request, [:id, :phase, :failure])
  end

  # @cc [owner:ghuntley,label:verification;capacity] clone-native-settled-activation
  # The first manual activation MUST observe real post-startup host/pool reports
  # and settled source operations before calling the unchanged coordinator once.
  # Waiting MUST be read-only and bounded; timeout and every coordinator refusal
  # remain fatal. It MUST NOT retry the accepted request or fabricate telemetry.
  def run(%{"action" => "clone-activate", "request_id" => id}) do
    true = OverallsProtocol.uuid?(id)
    :ok = await_clone_activation(id, Ledger.now(), System.monotonic_time(:millisecond) + 60_000)
    {:ok, _} = Marshall.Compute.CloneCoordinator.advance(id)
    [request] = Ledger.read!(Marshall.Compute.CloneRequest, id: id)

    request
    |> Map.take([:id, :phase, :failure])
    |> Map.put(:activation_preconditions_observed, true)
  end

  def run(%{"action" => "retry-clone", "owner_id" => owner, "request_id" => id}) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)
    {:ok, request} = Marshall.Compute.retry_clone(%{request_id: id}, actor: actor)
    %{id: request.id}
  end

  def run(%{"action" => "resize", "owner_id" => owner, "vm_id" => id, "key" => key}) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)
    [vm] = Ledger.read!(Marshall.Compute.VirtualMachine, id: id)

    {:ok, request} =
      Marshall.Compute.resize(
        %{
          vm_id: id,
          idempotency_key: key,
          expected_generation: vm.generation,
          vcpu: vm.vcpu,
          disk_bytes: vm.disk_bytes,
          memory_bytes: 805_306_368
        },
        actor: actor
      )

    %{id: request.id}
  end

  # @cc [owner:ghuntley,label:verification] fleet-relocation-public-admission
  # Relocation acceptance MUST use the authorized public action and automatic
  # placement selection. This fixture MUST NOT inject reservations, receipts,
  # phase transitions or execution authority into the database.
  def run(%{"action" => "relocate", "owner_id" => owner, "vm_id" => vm, "key" => key}) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)

    result =
      Marshall.Compute.relocate(%{vm_id: vm, idempotency_key: key}, actor: actor)

    case result do
      {:ok, relocation} ->
        relocation
        |> Map.take([
          :id,
          :vm_id,
          :source_placement_id,
          :destination_placement_id,
          :source_host_id,
          :destination_host_id,
          :source_epoch,
          :destination_epoch
        ])
        |> Map.put(:accepted, true)

      {:error, error} ->
        %{accepted: false, reason: relocation_failure(error)}
    end
  end

  # @cc [owner:ghuntley,label:verification] fleet-relocation-public-cancellation
  # Cancellation fixtures MUST use the current user's public domain action.
  # Accepted intent MUST NOT be reported as restored execution or finished cleanup.
  def run(%{"action" => "cancel-relocation", "owner_id" => owner, "relocation_id" => id}) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)
    {:ok, relocation} = Marshall.Compute.cancel_relocation(%{relocation_id: id}, actor: actor)
    %{id: relocation.id, requested: not is_nil(relocation.cancellation_requested_at)}
  end

  # @cc [owner:ghuntley,label:verification] fleet-relocation-retry-public-authority
  # Failed destination recovery MUST enter the authorized retry action. The
  # fixture MUST NOT reset readiness deadlines/results or manufacture activation.
  def run(%{
        "action" => "retry-relocation",
        "owner_id" => owner,
        "relocation_id" => id,
        "key" => key
      }) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)

    {:ok, retry} =
      Marshall.Compute.retry_relocation(
        %{relocation_id: id, idempotency_key: key},
        actor: actor
      )

    %{id: retry.id, stop_operation_id: retry.stop_operation_id}
  end

  # @cc [owner:ghuntley,label:verification;security] fleet-editor-real-private-cookie
  # Editor credentials MUST use ordinary stored user login and production
  # launch/begin/authorize/exchange actions. The credential MUST leave only
  # through an exclusive private fixture file, never operator output.
  def run(%{
        "action" => "suspension-editor-cookie",
        "owner_id" => owner,
        "vm_id" => vm,
        "gateway" => gateway,
        "output" => output
      })
      when gateway in ["l1", "l2"] do
    alias Marshall.Accounts.{Login, Security, User}
    user = Ash.get!(User, owner, authorize?: false)
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    {:ok, jti, _} = Login.verify(token, user)
    actor = Security.bind(user, jti)
    {:ok, launched} = Marshall.Editor.launch(%{vm_id: vm}, actor: actor)
    label = launched.hostname |> String.split(".") |> hd()
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    digest = :crypto.hash(:sha256, state) |> Base.encode16(case: :lower)
    service_token = File.read!("/var/lib/overalls-fleet/audi-#{gateway}.token") |> String.trim()

    {:ok, login} =
      Marshall.Editor.begin_editor_login(
        %{service_token: service_token, label: label, state_digest: digest},
        actor: SystemActor.compute()
      )

    {:ok, approved} =
      Marshall.Editor.authorize_editor_login(
        %{ticket: login.ticket, login_token: token},
        actor: actor
      )

    {:ok, cookie} =
      Marshall.Editor.exchange_editor_login(
        %{service_token: service_token, ticket: login.ticket, code: approved.code, state: state},
        actor: SystemActor.compute()
      )

    true = String.starts_with?(output, "/var/lib/overalls-fleet/")
    private_write(output, %{hostname: cookie.hostname, cookie: cookie.cookie})
    %{prepared: true}
  end

  # @cc [owner:ghuntley,label:verification;security] fleet-idle-clock-only-fixture
  # This isolated fixture MAY advance only the durable idle-policy clock of the
  # fixture owner's VM. It MUST NOT fabricate pause completion, capacity,
  # checkpoints or execution observations; Idle.suspend performs the real checks.
  def run(%{
        "action" => "suspension-idle",
        "owner_id" => owner,
        "vm_id" => id,
        "age_seconds" => age
      })
      when age in [10800, 14401] do
    alias Marshall.Compute.{Host, Idle, Ledger, VirtualMachine}

    {:ok, :aged} =
      Ledger.transaction(fn ->
        [candidate] = Ledger.read!(VirtualMachine, id: id)
        true = candidate.owner_id == owner
        _host = Ledger.lock!(Host, candidate.host_id)
        vm = Ledger.lock!(VirtualMachine, id)

        Ledger.update!(vm, :idle_policy, %{
          idle_suspend_enabled: true,
          idle_activity_at: DateTime.add(Ledger.now(), -age, :second),
          idle_revision: vm.idle_revision + 1
        })

        :aged
      end)

    {:ok, result} = Idle.suspend(id)
    %{result: Atom.to_string(result)}
  end

  def run(%{
        "action" => "lifecycle",
        "owner_id" => owner,
        "vm_id" => vm,
        "kind" => kind,
        "key" => key
      }) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)

    kind =
      Map.fetch!(
        %{
          "start" => :start,
          "stop" => :stop,
          "delete" => :delete,
          "pause" => :pause,
          "resume" => :resume
        },
        kind
      )

    case Marshall.Compute.lifecycle(%{vm_id: vm, kind: kind, idempotency_key: key}, actor: actor) do
      {:ok, _} ->
        %{requested: true}

      {:error, error} ->
        true = kind == :start and capacity_failure?(error)
        %{requested: false, reason: "insufficient_capacity"}
    end
  end

  # @cc [owner:ghuntley,label:verification;security] fleet-team-membership-real-owner-actions
  # Team creation and membership changes MUST use the public Teams domain actions
  # as the committed owner actor; this fixture adds no bypass and returns only
  # durable identifiers.
  def run(%{"action" => "team-create", "owner_id" => owner, "name" => name, "key" => key}) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)
    true = is_binary(name) and byte_size(name) in 1..64

    {:ok, team} =
      Marshall.Teams.create_team(%{name: name, idempotency_key: key}, actor: actor)

    %{team_id: team.id}
  end

  def run(%{
        "action" => "team-set-member",
        "owner_id" => owner,
        "team_id" => team,
        "email" => email,
        "role" => role,
        "key" => key
      }) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)
    [team] = Marshall.Compute.Ledger.read!(Marshall.Teams.Team, id: team)
    role = Map.fetch!(%{"member" => :member, "removed" => :removed}, role)

    {:ok, changed} =
      Marshall.Teams.set_team_member(
        %{team_id: team.id, email: email, role: role, idempotency_key: key},
        actor: actor
      )

    %{changed: changed.role == role}
  end

  def run(%{
        "action" => "share",
        "owner_id" => owner,
        "vm_id" => vm,
        "email" => email,
        "role" => role,
        "key" => key
      }) do
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)

    role =
      Map.fetch!(%{"viewer" => :viewer, "operator" => :operator, "revoked" => :revoked}, role)

    {:ok, _} =
      Marshall.Access.set_access(%{vm_id: vm, email: email, role: role, idempotency_key: key},
        actor: actor
      )

    %{shared: true}
  end

  defp settle_turn(%{status: status} = turn) when status in [:queued, :running],
    do: Ledger.update!(turn, :transition, %{status: :completed, finished_at: Ledger.now()})

  defp settle_turn(turn), do: turn

  defp create_with_id(resource, attributes, id) do
    resource
    |> Ash.Changeset.for_create(:enroll, attributes, actor: SystemActor.compute())
    |> Ash.Changeset.force_change_attribute(:id, id)
    |> Ash.create!()
  end

  defp capacity_failure?(%Marshall.Compute.Error{reason: :insufficient_capacity}), do: true

  defp capacity_failure?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &capacity_failure?/1)

  defp capacity_failure?(_), do: false

  # @cc [owner:ghuntley,label:security;verification] relocation-fixture-finite-failure
  # Admission diagnostics MUST expose only this closed reason set, never Ash
  # exception text, records or arguments. Unknown errors remain explicit failures.
  defp relocation_failure(%Marshall.Compute.Error{reason: reason})
       when reason in [
              :insufficient_capacity,
              :source_unavailable,
              :transfer_busy,
              :workload_not_stable,
              :placement_changed,
              :relocation_in_progress,
              :resize_in_progress,
              :forbidden
            ],
       do: Atom.to_string(reason)

  defp relocation_failure(%Ash.Error.Invalid{errors: errors}) do
    case Enum.map(errors, &relocation_failure/1) |> Enum.uniq() do
      [reason] -> reason
      _ -> "unclassified_failure"
    end
  end

  defp relocation_failure(_), do: "unclassified_failure"

  # @cc [owner:ghuntley,label:verification] fleet-enable-current-observation
  # Transient host_not_ready responses may be retried for at most thirty seconds.
  # Every attempt MUST use production enrollment validation; other failures MUST
  # fail immediately. The fixture MUST NOT change report timestamps or freshness.
  @spec enable_host(String.t(), boolean(), integer()) :: map()
  defp enable_host(id, enabled, deadline) do
    case Enrollment.set_enabled(id, enabled) do
      {:ok, result} ->
        result

      {:error, :host_not_ready} when enabled ->
        if System.monotonic_time(:millisecond) >= deadline do
          IO.puts(:stderr, "FLEET_HOST_NOT_READY " <> JSON.encode!(host_readiness(id)))
          raise "Fleet host is not ready"
        end

        receive do
        after
          250 -> enable_host(id, enabled, deadline)
        end

      _ ->
        raise "Fleet enable failed"
    end
  end

  # @cc [owner:ghuntley,label:verification;security] fleet-host-refusal-closed-observation
  # A refused admission MAY expose only current readiness/freshness booleans and
  # a report age clamped to one day. Diagnostic reads MUST NOT change authority,
  # report timestamps or deadlines, or print host records and database errors.
  @spec host_readiness(String.t()) :: %{
          observation_available: boolean(),
          execution_ready: boolean(),
          report_present: boolean(),
          fresh: boolean(),
          age_ms: integer() | nil
        }
  defp host_readiness(id) do
    now = Ledger.now()

    case Ledger.read!(Host, id: id) do
      [host] ->
        reported = host.reported_at

        %{
          observation_available: true,
          execution_ready: host.inventory["execution_ready"] == true,
          report_present: not is_nil(reported),
          fresh: Marshall.Compute.HostLiveness.capacity_fresh?(reported, now),
          age_ms:
            if(reported,
              do:
                reported
                |> then(&DateTime.diff(now, &1, :millisecond))
                |> max(-86_400_000)
                |> min(86_400_000),
              else: nil
            )
        }

      _ ->
        unavailable_readiness()
    end
  rescue
    _ -> unavailable_readiness()
  catch
    :exit, _ -> unavailable_readiness()
  end

  @spec unavailable_readiness() :: %{
          observation_available: false,
          execution_ready: false,
          report_present: false,
          fresh: false,
          age_ms: nil
        }
  defp unavailable_readiness,
    do: %{
      observation_available: false,
      execution_ready: false,
      report_present: false,
      fresh: false,
      age_ms: nil
    }

  @type admission_pool_observation :: %{
          index: pos_integer(),
          fresh: boolean(),
          fits: boolean(),
          eligible: boolean(),
          available: Marshall.Compute.Budget.available()
        }
  @type admission_host_observation :: %{
          index: pos_integer(),
          enabled: boolean(),
          normal: boolean(),
          architecture_matches: boolean(),
          execution_ready: boolean(),
          profile_ready: boolean(),
          fresh: boolean(),
          image_advertised: boolean(),
          pools: [admission_pool_observation()]
        }
  @type admission_observation :: %{
          eligible: boolean(),
          image_enabled: boolean(),
          manifest_current: boolean(),
          source_capable: boolean(),
          minima_met: boolean(),
          required: Marshall.Compute.Budget.request(),
          hosts: [admission_host_observation()]
        }

  @spec observe_admission_until(String.t(), integer()) :: admission_observation()
  defp observe_admission_until(id, deadline) do
    observation = admission_observations(id)

    if observation.eligible or System.monotonic_time(:millisecond) >= deadline do
      observation
    else
      receive do
      after
        250 -> observe_admission_until(id, deadline)
      end
    end
  end

  @spec admission_observations(String.t()) :: admission_observation()
  defp admission_observations(id) do
    alias Marshall.Compute.{Budget, HostLiveness, Image, Profiles, Reservation}
    [image] = Ledger.read!(Image, id: id)
    shape = Profiles.default_shape(:oss, image)
    request = Map.merge(shape, %{profile: :oss, image_id: id, architecture: image.architecture})
    required = OverallsProtocol.VMShape.reservation(request)
    validated = OverallsProtocol.ImageManifest.validate(image.manifest)
    manifest_current = match?({:ok, %{id: ^id}}, validated)
    source_capable = match?({:ok, %{id: ^id, workspace_source_version: 2}}, validated)

    minima_met =
      request.memory_bytes >= image.minimum_memory_bytes and
        request.disk_bytes >= image.minimum_disk_bytes

    image_ready = image.enabled and manifest_current and source_capable and minima_met
    now = Ledger.now()

    hosts =
      Host
      |> Ledger.read!()
      |> Enum.sort_by(& &1.id)
      |> Enum.with_index(1)
      |> Enum.map(fn {host, index} ->
        predicates = %{
          enabled: host.enabled,
          normal: host.maintenance_mode == :normal,
          architecture_matches: host.architecture == image.architecture,
          execution_ready: Map.get(host.inventory, "execution_ready") == true,
          profile_ready: Profiles.host_ready?(request, host.inventory),
          fresh: HostLiveness.capacity_fresh?(host.reported_at, now),
          image_advertised: id in Map.get(host.inventory, "images", [])
        }

        host_ready = image_ready and Enum.all?(Map.values(predicates))
        reservations = Ledger.read!(Reservation, host_id: host.id)

        pools =
          StoragePool
          |> Ledger.read!(host_id: host.id)
          |> Enum.sort_by(& &1.id)
          |> Enum.with_index(1)
          |> Enum.map(fn {pool, pool_index} ->
            fresh = HostLiveness.capacity_fresh?(pool.reported_at, now)
            available = Budget.available(host, pool, reservations)
            fits = Budget.fits?(available, required)

            %{
              index: pool_index,
              fresh: fresh,
              fits: fits,
              eligible: host_ready and fresh and fits,
              available: available
            }
          end)

        Map.merge(predicates, %{index: index, pools: pools})
      end)

    %{
      eligible: Enum.any?(hosts, fn host -> Enum.any?(host.pools, & &1.eligible) end),
      image_enabled: image.enabled,
      manifest_current: manifest_current,
      source_capable: source_capable,
      minima_met: minima_met,
      required: required,
      hosts: hosts
    }
  end

  @type source_observations :: %{String.t() => boolean()}
  @source_observation_keys ~w(stable_power operations_settled host_enabled host_normal endpoint_valid architecture_matches execution_ready host_fresh pool_fresh reports_recent pool_zfs pool_space_known disk_held temporary_disk_settled compute_hold_matches)

  # @cc [owner:ghuntley,label:verification;capacity] atomic-source-observation-clock
  # Each snapshot MUST use one database clock and one read-only query. Normal
  # freshness and the reserved RPC freshness budget MUST be separate flags.
  # Polling MUST be bounded and MUST NOT refresh reports or modify authority.
  @spec observe_source_until(OverallsProtocol.uuid(), integer()) :: source_observations()
  defp observe_source_until(id, deadline) do
    flags = source_observations(id)

    if Enum.all?(Map.values(flags)) or System.monotonic_time(:millisecond) >= deadline do
      flags
    else
      receive do
      after
        100 -> observe_source_until(id, deadline)
      end
    end
  end

  @spec source_observations(OverallsProtocol.uuid()) :: source_observations()
  defp source_observations(id) do
    freshness = Application.fetch_env!(:marshall, :capacity_freshness_ms)
    true = is_integer(freshness) and freshness > 0

    %{rows: [[flags, endpoint]]} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        """
        WITH observed AS MATERIALIZED (
          SELECT clock_timestamp() AT TIME ZONE 'UTC' AS now
        )
        SELECT jsonb_build_object(
          'stable_power', COALESCE(v.desired_state IN ('running','stopped') AND v.observed_state=v.desired_state, false),
          'operations_settled', NOT EXISTS (SELECT 1 FROM compute_operations o WHERE o.vm_id=v.id AND o.status IN ('pending','acknowledged')),
          'host_enabled', COALESCE(h.enabled, false),
          'host_normal', COALESCE(h.maintenance_mode='normal', false),
          'endpoint_valid', false,
          'architecture_matches', COALESCE(h.architecture=v.architecture, false),
          'execution_ready', COALESCE(h.inventory->'execution_ready'='true'::jsonb, false),
          'host_fresh', COALESCE(h.reported_at BETWEEN observed.now - $2::bigint * interval '1 millisecond' AND observed.now, false),
          'pool_fresh', COALESCE(s.reported_at BETWEEN observed.now - $2::bigint * interval '1 millisecond' AND observed.now, false),
          'reports_recent', COALESCE(h.reported_at BETWEEN observed.now - GREATEST($2::bigint - 2000, 1) * interval '1 millisecond' AND observed.now AND s.reported_at BETWEEN observed.now - GREATEST($2::bigint - 2000, 1) * interval '1 millisecond' AND observed.now, false),
          'pool_zfs', COALESCE(s.backend='zfs', false),
          'pool_space_known', COALESCE(s.free_bytes >= s.overhead_bytes, false),
          'disk_held', COALESCE(r.disk_held, false),
          'temporary_disk_settled', COALESCE(r.temporary_disk_bytes=0, false),
          'compute_hold_matches', COALESCE(r.compute_held=(v.desired_state='running'), false)
        ), h.transfer_endpoint
        FROM compute_virtual_machines v
        JOIN compute_workload_placements p ON p.id=v.current_placement_id
        JOIN compute_hosts h ON h.id=p.host_id
        JOIN compute_storage_pools s ON s.id=p.pool_id
        JOIN compute_reservations r ON r.placement_id=p.id
        CROSS JOIN observed
        WHERE v.id=$1::uuid
        """,
        [Ecto.UUID.dump!(id), freshness],
        log: false,
        timeout: 5_000
      )

    true = is_map(flags) and Enum.sort(Map.keys(flags)) == Enum.sort(@source_observation_keys)
    true = Enum.all?(Map.values(flags), &is_boolean/1)

    Map.put(
      flags,
      "endpoint_valid",
      match?({:ok, _}, OverallsProtocol.TransferSSH.endpoint(endpoint))
    )
  end

  @spec await_clone_activation(OverallsProtocol.uuid(), DateTime.t(), integer()) :: :ok
  defp await_clone_activation(id, barrier, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    freshness = Application.fetch_env!(:marshall, :capacity_freshness_ms)
    true = is_integer(freshness) and freshness > 0

    # fleet-op starts Marshall before dispatching run/1. Polling in the outer
    # Python process can therefore age out while this release starts. This
    # private read waits here for actual receipts newer than the barrier and
    # within the production freshness window less two seconds, the margin
    # source_observations uses, leaving the coordinator time inside its window.
    # A loaded host's reports routinely arrive more than one second old.
    %{rows: [[phase, active, failure_absent, snapshot_absent, flags]]} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        """
        WITH observed AS MATERIALIZED (
          SELECT clock_timestamp() AT TIME ZONE 'UTC' AS now
        )
        SELECT c.phase, c.active, c.failure IS NULL, c.snapshot IS NULL,
          jsonb_build_object(
            'host_available', COALESCE(h.enabled AND h.maintenance_mode='normal', false),
            'architecture_matches', COALESCE(h.architecture=v.architecture, false),
            'execution_ready', COALESCE(h.inventory->>'execution_ready'='true', false),
            'stable_power', COALESCE(v.desired_state IN ('running','stopped') AND v.observed_state=v.desired_state, false),
            'operations_settled', NOT EXISTS (
              SELECT 1 FROM compute_operations o WHERE o.vm_id=v.id
                AND o.status NOT IN ('completed','cancelled')),
            'disk_held', COALESCE(r.disk_held AND r.temporary_disk_bytes=0, false),
            'transfer_slots_free', NOT EXISTS (
              SELECT 1 FROM compute_transfer_slots t
                WHERE t.host_id=h.id AND t.released_at IS NULL),
            'reports_after_barrier', COALESCE(
              h.reported_at >= ($2::timestamptz AT TIME ZONE 'UTC')
              AND s.reported_at >= ($2::timestamptz AT TIME ZONE 'UTC'), false),
            'reports_recent', COALESCE(
              h.reported_at BETWEEN observed.now - GREATEST($3::bigint - 2000, 1) * interval '1 millisecond' AND observed.now
              AND s.reported_at BETWEEN observed.now - GREATEST($3::bigint - 2000, 1) * interval '1 millisecond' AND observed.now, false)
          )
        FROM observed, compute_clone_requests c
        JOIN compute_virtual_machines v ON v.id=c.source_vm_id
        JOIN compute_workload_placements p ON p.id=v.current_placement_id
        JOIN compute_hosts h ON h.id=p.host_id
        JOIN compute_storage_pools s ON s.id=p.pool_id
        JOIN compute_reservations r ON r.placement_id=p.id
        WHERE c.id=$1::uuid
        """,
        [Ecto.UUID.dump!(id), barrier, freshness],
        log: false,
        timeout: max(1, min(remaining, 5_000))
      )

    true = phase == "queued" and active == false and failure_absent and snapshot_absent

    unready =
      flags |> Enum.reject(fn {_name, value} -> value == true end) |> Enum.map(&elem(&1, 0))

    cond do
      unready == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        # Closed readiness names only; no identifiers, times or row data.
        IO.puts(:stderr, "clone activation unready: " <> Enum.join(Enum.sort(unready), ","))
        raise "Clone activation preconditions unavailable"

      true ->
        receive do
        after
          100 -> await_clone_activation(id, barrier, deadline)
        end
    end
  end

  defp await_file(path, deadline) do
    unless File.regular?(path) do
      true = System.monotonic_time(:millisecond) < deadline

      receive do
      after
        50 -> await_file(path, deadline)
      end
    end

    :ok
  end

  # @cc [owner:ghuntley,label:verification;accounting] native-durable-service-level-evidence
  # This sentinel-fenced fixture MUST use the production reconciler and retained
  # physical/readiness evidence. It MUST NOT forge outcomes, move deadlines or
  # mutate execution. The digest MUST cover permanent source identities and
  # all counters/buckets, excluding the reconstructible sampling timestamp.
  @spec service_levels(String.t()) :: %{
          measured: boolean(),
          ssh_measured: boolean(),
          totals_digest: String.t()
        }
  defp service_levels(vm_id) do
    true = OverallsProtocol.uuid?(vm_id)
    {:ok, _} = Marshall.Compute.ServiceLevels.reconcile()
    {:ok, _} = Marshall.Compute.WorkflowServiceLevels.reconcile()

    measured =
      Marshall.Compute.ServiceLevelAttempt
      |> Ash.Query.filter(
        operation.vm_id == ^vm_id and status == :finished and success == true and
          service in [:marshall_ready, :lilly_physical, :porsche_physical]
      )
      |> Ash.read!(actor: SystemActor.compute())
      |> Enum.map(& &1.service)
      |> Enum.uniq()
      |> Enum.sort()

    {:ok, snapshots} =
      Ledger.transaction(fn ->
        now = Ledger.now()

        for service <- [
              :marshall_ready,
              :lilly_physical,
              :porsche_physical,
              :porsche_clone,
              :porsche_relocate,
              :porsche_retry,
              :porsche_cancel
            ] do
          total = Marshall.Compute.ServiceLevelTotals.ensure!(service)
          true = total.requests == total.successes + total.failures
          true = total.requests == Enum.sum(total.bucket_counts)

          total
          |> Marshall.Compute.ServiceLevelTotals.snapshot(now)
          |> Map.delete(:sampled_at_unix_nano)
        end
      end)

    digest =
      snapshots
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    ready_measured = Enum.all?([:lilly_physical, :marshall_ready], &(&1 in measured))

    %{
      measured: ready_measured,
      ssh_measured: ready_measured and :porsche_physical in measured,
      totals_digest: digest
    }
  end

  defp private_write(path, value) do
    {:ok, file} = File.open(path, [:write, :exclusive, :binary])

    try do
      :ok = File.chmod(path, 0o600)
      :ok = IO.binwrite(file, JSON.encode!(value))
    after
      File.close(file)
    end
  end
end

# @cc [owner:ghuntley,label:security] fleet-operator-private-diagnostics
# Operator work MUST match the private fixture's DB sentinel and suppress exception
# data. Secret envelopes and browser tokens MUST leave only through private files.
try do
  Application.put_env(:marshall, :operator_mode, true)
  {:ok, _} = Application.ensure_all_started(:marshall)
  id = System.fetch_env!("FLEET_FIXTURE_ID")
  true = OverallsProtocol.uuid?(id)

  %{rows: [[^id]]} =
    Ecto.Adapters.SQL.query!(Marshall.Repo, "SELECT id::text FROM overalls_fleet_fixture", [],
      log: false
    )

  [request] = System.argv()
  request = request |> File.read!() |> JSON.decode!()
  :ok = FleetOperator.await_barrier(request["barrier"])
  result = FleetOperator.run(request)
  IO.puts("FLEET_OK " <> JSON.encode!(result))
rescue
  error ->
    # Exception class and source locations are public; terms, arguments and
    # exception messages may contain private fixture data and stay suppressed.
    locations =
      for {module, function, _arity_or_args, location} <- __STACKTRACE__,
          module == FleetOperator,
          do: "#{function}:#{Keyword.get(location, :line, 0)}"

    IO.puts(
      :stderr,
      "Fleet operator failed (#{inspect(error.__struct__)}, #{Enum.join(locations, ",")}); private diagnostics withheld"
    )

    System.halt(1)
end
