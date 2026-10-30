defmodule Marshall.Compute.Views do
  @moduledoc "Bounded user-facing VM views. Resource mutation remains in the trusted coordinators."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Access.{Authorization, Pin, Pins}
  alias Marshall.Authorization.{DecisionSnapshot, SystemActor}
  alias Marshall.Compute.{Budget, Host, Image, Ledger, Reservation, StoragePool, VirtualMachine}
  require Ash.Query

  @fields [
    :id,
    :name,
    :labels,
    :comment,
    :profile,
    :architecture,
    :image_id,
    :vcpu,
    :memory_bytes,
    :disk_bytes,
    :desired_state,
    :observed_state,
    :failure_reason,
    :generation,
    :inserted_at
  ]

  @impl true
  def run(input, options, context) do
    Overalls.Diagnostics.Tracing.with_span(
      "marshall.views.read",
      [operation: options[:operation]],
      fn ->
        {result, queries} =
          Marshall.Observability.count_queries(fn -> read(input, options, context) end)

        :ok =
          Overalls.Diagnostics.Tracing.annotate(query_count: queries, row_count: rows(result))

        result
      end
    )
  end

  @spec rows(term()) :: non_neg_integer()
  defp rows({:ok, %{items: items}}) when is_list(items), do: length(items)
  defp rows({:ok, %{images: images}}) when is_list(images), do: length(images)
  defp rows({:ok, %{}}), do: 1
  defp rows(_), do: 0

  defp read(input, options, context) do
    result =
      DecisionSnapshot.transaction(fn ->
        case options[:operation] do
          :get ->
            input.arguments.vm_id
            |> Authorization.live_vm!(context.actor, "read", false, true)
            |> view(context.actor)

          :list ->
            list(input.arguments, context.actor)

          :pinned ->
            pinned(context.actor, Map.get(input.arguments, :limit, 20))

          :resolve ->
            resolve(input.arguments.reference, context.actor)

          :catalog ->
            catalog()

          :repository_launch_request ->
            repository_launch_request(input.arguments.idempotency_key, context.actor)
        end
      end)

    case result do
      {:error, reason} when is_atom(reason) ->
        {:error, Marshall.Compute.Error.exception(reason: reason)}

      other ->
        other
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] launch-replay-original-request
  # A launch replay MUST expose only the current actor's original admission
  # request under that key, including archived VM history and original sizes.
  # It MUST NOT authorize a mutation; Compute.provision must still validate the
  # current actor, source and idempotent request before returning a VM.
  @spec repository_launch_request(String.t(), Marshall.Accounts.User.t()) :: map()
  defp repository_launch_request(key, actor) do
    case Ledger.history!(VirtualMachine, owner_id: actor.id, idempotency_key: key) do
      [vm] ->
        request =
          vm
          |> Map.take([:architecture, :image_id, :profile, :vcpu, :memory_bytes, :disk_bytes])
          |> Map.merge(
            Map.new(vm.provisioning_sizes, fn {field, value} ->
              {String.to_existing_atom(field), value}
            end)
          )

        %{request: request}

      [] ->
        %{request: nil}
    end
  end

  # @cc [owner:ghuntley,label:security] views-reference-current-access
  # Name/UUID resolution MUST return only a currently readable, unarchived VM.
  # Resolving a name MUST NOT itself grant authority for a later mutation.
  defp resolve(reference, actor) do
    filter =
      cond do
        OverallsProtocol.uuid?(reference) -> [id: reference]
        OverallsProtocol.MachineName.valid?(reference) -> [name: reference]
        true -> Ledger.rollback(:forbidden)
      end

    case Ledger.read!(VirtualMachine, filter) do
      [vm] ->
        vm.id |> Authorization.live_vm!(actor, "read", false, true) |> view(actor)

      [] ->
        Ledger.rollback(:forbidden)
    end
  end

  # @cc [owner:ghuntley,label:security] views-bounded-current-access
  # User VM pages MUST be bounded by the validated limit and cursor, include only
  # current Cedar-readable VMs, and expose only the view field allowlist, the
  # current physical host name, the registered image display name, opaque
  # execution reference, finite editor image status, current permissions, the
  # caller's own pin flag and bounded authorized operation summaries. Rows are
  # selected by the Cedar-derived read filter for the current principal, so the
  # page holds exactly the readable machines. The validated `exclude` list (at most the
  # pin limit) MUST remove those ids from the keyset page without changing its
  # order or cursor semantics. Internal host IDs, placements, reservations,
  # image manifests and other users' pins stay private.
  defp list(request, actor) do
    exclude = Map.get(request, :exclude, [])

    query =
      VirtualMachine
      |> Authorization.filter(actor, "read")
      |> Ash.Query.sort(:id)
      |> Ash.Query.limit(request.limit + 1)

    query =
      if Map.get(request, :after), do: Ash.Query.filter(query, id > ^request.after), else: query

    query = if exclude == [], do: query, else: Ash.Query.filter(query, id not in ^exclude)

    rows = Ash.read!(query, actor: SystemActor.compute())
    page = Enum.take(rows, request.limit)
    prefetch(page, actor)

    %{
      items: Enum.map(page, &view(&1, actor)),
      next_cursor: if(length(rows) > request.limit, do: Enum.at(rows, request.limit - 1).id)
    }
  end

  # @cc [owner:ghuntley,label:security;product] views-pinned-section-bounded
  # The pinned section MUST contain only the caller's live `pinned` rows (at
  # most the pin limit), ordered newest pin first, restricted to unarchived VMs
  # that pass the same fresh per-row Cedar read decision and projected through
  # the same view as the keyset page. A pin on a VM the caller can no longer
  # read MUST be omitted, not fail the whole section. Only the first `limit`
  # readable pins are projected; `ids` lists every readable pin, in order.
  defp pinned(actor, limit) do
    ids = Pins.pinned_vm_ids(actor)

    rows =
      if ids == [] do
        %{}
      else
        VirtualMachine
        |> Ash.Query.for_read(:read, %{}, actor: SystemActor.compute())
        |> Ash.Query.filter(id in ^ids)
        |> Authorization.filter(actor, "read")
        |> Ash.read!()
        |> Map.new(&{&1.id, &1})
      end

    readable = Enum.flat_map(ids, &List.wrap(rows[&1]))
    prefetch(readable, actor)

    %{
      items: readable |> Enum.take(limit) |> Enum.map(&view(&1, actor)),
      ids: Enum.map(readable, & &1.id)
    }
  end

  # @cc [owner:ghuntley,label:security;observability] views-batched-reads
  # Page projections MAY batch the reads a later per-row projection or decision
  # would make, but only into the current DecisionSnapshot batch, keyed exactly
  # as the per-row read, and with identical filters. Outside a batch nothing is
  # primed and every row reads fresh. Batching MUST NOT change any decision or
  # projected field.
  @spec prefetch([VirtualMachine.t()], map()) :: :ok
  defp prefetch(vms, actor) do
    if DecisionSnapshot.active?() and vms != [] do
      Authorization.prefetch(vms, actor)
      ids = Enum.map(vms, & &1.id)
      image_ids = vms |> Enum.map(& &1.image_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      host_ids = vms |> Enum.map(& &1.host_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      owner_ids = vms |> Enum.map(& &1.owner_id) |> Enum.uniq()

      images = by(Image, :id, image_ids)
      hosts = by(Host, :id, host_ids)
      endpoints = by(Marshall.Ingress.Endpoint, :vm_id, ids)

      pins =
        Pin
        |> Ash.Query.filter(vm_id in ^ids and user_id == ^actor.id and state == :pinned)
        |> Ash.read!(actor: SystemActor.compute())
        |> MapSet.new(& &1.vm_id)

      owners =
        Marshall.Accounts.User
        |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
        |> Ash.Query.filter(id in ^owner_ids)
        |> Ash.read!()
        |> Map.new(&{&1.id, &1})

      # read_one! raises on duplicate active requests; leave those rows to the
      # per-row read so the failure is unchanged.
      resizes =
        Marshall.Compute.ResizeRequest
        |> Ash.Query.filter(vm_id in ^ids and is_nil(finished_at))
        |> Ash.read!(actor: SystemActor.compute())
        |> Enum.group_by(& &1.vm_id)

      # Relocation status is projected only for managers (relocation-status-projection),
      # so only rows with a current manage decision are batched.
      DecisionSnapshot.prime(
        vms
        |> Enum.filter(&Authorization.allowed?(&1, actor, "manage"))
        |> Enum.map(& &1.id)
        |> Marshall.Compute.RelocationStatus.latest_many()
        |> Map.new(fn {id, status} -> {{:latest_relocation, id}, status} end)
      )

      DecisionSnapshot.prime(
        ids
        |> Enum.flat_map(fn id ->
          case Map.get(resizes, id, []) do
            [] -> [{{:active_resize, id}, nil}]
            [request] -> [{{:active_resize, id}, request}]
            _ -> []
          end
        end)
        |> Map.new()
      )

      DecisionSnapshot.prime(
        Map.new(image_ids, &{{:image, &1}, Map.get(images, &1, [])})
        |> Map.merge(Map.new(host_ids, &{{:host, &1}, Map.get(hosts, &1, [])}))
        |> Map.merge(Map.new(ids, &{{:endpoint, &1}, Map.get(endpoints, &1, [])}))
        |> Map.merge(Map.new(ids, &{{:pinned, &1, actor.id}, MapSet.member?(pins, &1)}))
        |> Map.merge(Map.new(owner_ids, &{{:user, &1}, Map.get(owners, &1)}))
      )
    end

    :ok
  end

  @spec by(module(), atom(), [term()]) :: %{term() => [Ash.Resource.Record.t()]}
  defp by(_resource, _field, []), do: %{}

  defp by(resource, field, values) do
    resource
    |> Ash.Query.filter(^[{field, [in: values]}])
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.group_by(&Map.fetch!(&1, field))
  end

  # @cc [owner:ghuntley,label:product;security] views-reflection-metadata
  # Authorized machine views MUST retain persisted Reflection labels and comment,
  # including their empty defaults, so settings renders the stored values.
  # Projection MUST retain the existing read authorization; metadata visibility
  # MUST NOT grant permission to change it.
  @spec view(VirtualMachine.t(), map()) :: map()
  defp view(vm, actor) do
    image =
      List.first(
        DecisionSnapshot.fetch({:image, vm.image_id}, fn ->
          Ledger.read!(Image, id: vm.image_id)
        end)
      )

    permissions =
      Map.new(
        [:read, :write, :manage],
        &{&1, Authorization.allowed?(vm, actor, Atom.to_string(&1))}
      )

    Map.merge(Map.take(vm, @fields), %{
      image_name: image_name(image),
      execution_ref: execution_ref(vm),
      host: host_name(vm),
      ssh_host: ssh_host_name(vm),
      editor_image_status: editor_image_status(image),
      guest_capabilities: Image.guest_capabilities(image),
      pinned:
        DecisionSnapshot.fetch({:pinned, vm.id, actor.id}, fn -> Pins.pinned?(vm, actor) end),
      resize: resize_view(vm, permissions.manage),
      relocation:
        if(permissions.manage,
          do:
            DecisionSnapshot.fetch({:latest_relocation, vm.id}, fn ->
              Marshall.Compute.RelocationStatus.latest(vm.id)
            end)
        ),
      owner: vm.owner_id == actor.id,
      permissions: permissions
    })
    |> Map.merge(owner_view(vm, actor))
  end

  # @cc [owner:ghuntley,label:security;product] views-shared-owner-identity
  # A view MUST name the owner (email and saved display zone, ADR-0195) only
  # when the caller is not the owner and already holds read access to the
  # machine; the owner's own view carries nil for both so no page shows a
  # person their own local time as another user. SSH wire views drop both.
  @spec owner_view(VirtualMachine.t(), map()) :: %{
          owner_email: String.t() | nil,
          owner_time_zone: String.t() | nil
        }
  defp owner_view(%VirtualMachine{owner_id: owner_id}, %{id: owner_id}),
    do: %{owner_email: nil, owner_time_zone: nil}

  defp owner_view(vm, _actor) do
    owner =
      DecisionSnapshot.fetch({:user, vm.owner_id}, fn ->
        Marshall.Accounts.Security.current(vm.owner_id)
      end)

    %{
      owner_email: owner && to_string(owner.email),
      owner_time_zone: owner && owner.time_zone
    }
  end

  # @cc [owner:ghuntley,label:product;security] views-image-display-name
  # The view MUST expose the registered image's display name (`image_name`) as
  # the machine's operating-system label, and nothing else from the image row;
  # a missing image row MUST project nil rather than failing or a placeholder.
  @spec image_name(Image.t() | nil) :: String.t() | nil
  defp image_name(%Image{name: name}) when is_binary(name), do: name
  defp image_name(_), do: nil

  # @cc [owner:ghuntley,label:security;product] views-editor-image-status
  # An authorized VM view MUST expose only a finite status derived from its
  # immutable image and current configured editor release, never the descriptor.
  # Missing image data MUST fail closed. Projection MUST NOT allocate accounts,
  # mutate images or replace fresh editor launch authorization.

  # @cc [owner:ghuntley,label:security;product] views-guest-capabilities
  # The same view MUST expose finite per-capability booleans (guest_capabilities)
  # from the immutable image's agent set so presentation can hide terminal, agent,
  # editor and SSH controls the guest cannot serve; the booleans never authorize.
  @spec editor_image_status(Image.t() | nil) :: Image.editor_image_status()
  defp editor_image_status(image) do
    case Image.editor_capability(image, Application.get_env(:marshall, :ingress_editor_releases)) do
      {:ok, _} -> :available
      {:error, status} -> status
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] views-opaque-execution
  # The public execution reference MUST change on placement, epoch or generation
  # changes without exposing internal placement IDs. It grants no authority.
  @spec execution_ref(VirtualMachine.t()) :: String.t()
  defp execution_ref(vm) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({vm.id, vm.current_placement_id, vm.execution_epoch, vm.generation})
    )
    |> Base.url_encode64(padding: false)
  end

  defp host_name(vm) do
    case DecisionSnapshot.fetch({:host, vm.host_id}, fn -> Ledger.read!(Host, id: vm.host_id) end) do
      [%{name: name}] when is_binary(name) -> name
      _ -> nil
    end
  end

  # @cc [owner:ghuntley,label:security;product] views-authorized-ssh-name
  # A readable VM view MUST expose its stable Audi SSH name separately from
  # the physical host. The name comes from the persisted endpoint label and
  # configured zone; it MUST NOT reveal another VM or a mutable placement.
  @doc "The stable guest SSH host name `show` exposes, or nil without an ingress zone/endpoint."
  @spec ssh_host_name(Marshall.Compute.VirtualMachine.t()) :: String.t() | nil
  def ssh_host_name(vm) do
    case {Application.get_env(:marshall, :ingress_zone),
          DecisionSnapshot.fetch({:endpoint, vm.id}, fn ->
            Ledger.read!(Marshall.Ingress.Endpoint, vm_id: vm.id)
          end)} do
      {zone, [%{label: label}]}
      when is_binary(zone) and is_binary(label) and byte_size(label) + byte_size(zone) < 253 ->
        label <> "." <> zone

      _ ->
        nil
    end
  end

  defp resize_view(vm, manage?) do
    if manage? do
      case DecisionSnapshot.fetch({:active_resize, vm.id}, fn ->
             Marshall.Compute.Resize.active(vm.id)
           end) do
        nil ->
          nil

        request ->
          Map.take(request, [
            :id,
            :phase,
            :failure,
            :original_sizes,
            :target_sizes,
            :original_power_state,
            :cancelled_at
          ])
      end
    end
  end

  # @cc [owner:ghuntley,label:capacity] catalog-observations-are-not-reservations
  # Catalog totals MUST include only eligible fresh hosts/pools and advertise only
  # enabled locally available images. Count host CPU/RAM once across its pools;
  # these unlocked totals MUST NOT substitute for transactional admission checks.
  defp catalog do
    now = Ledger.now()

    hosts =
      Ledger.read!(Host, enabled: true)
      |> Enum.filter(
        &(&1.maintenance_mode == :normal and &1.inventory["execution_ready"] == true and
            Marshall.Compute.HostLiveness.capacity_fresh?(&1.reported_at, now) and
            &1.capacity != nil)
      )

    host_ids = Enum.map(hosts, & &1.id)
    reservations_by_host = by(Reservation, :host_id, host_ids)
    pools_by_host = by(StoragePool, :host_id, host_ids)

    {available, ids, known} =
      Enum.reduce(hosts, {%{vcpu: 0, memory_bytes: 0, disk_bytes: 0}, [], false}, fn host,
                                                                                     {sum, ids,
                                                                                      known} ->
        reservations = Map.get(reservations_by_host, host.id, [])

        pools =
          pools_by_host
          |> Map.get(host.id, [])
          |> Enum.filter(&Marshall.Compute.HostLiveness.capacity_fresh?(&1.reported_at, now))

        budgets = Enum.map(pools, &Budget.available(host, &1, reservations))

        case budgets do
          [] ->
            {sum, ids, known}

          [first | _] ->
            {%{
               vcpu: sum.vcpu + first.vcpu,
               memory_bytes: sum.memory_bytes + first.memory_bytes,
               disk_bytes: sum.disk_bytes + Enum.sum(Enum.map(budgets, & &1.disk_bytes))
             }, host.inventory["images"] ++ ids, true}
        end
      end)

    images =
      Ledger.read!(Image, enabled: true)
      |> Enum.filter(&(&1.id in ids))
      |> Enum.sort_by(&{&1.name, &1.id})
      |> Enum.map(fn image ->
        Map.put(
          Map.take(image, [:id, :name, :architecture, :minimum_memory_bytes, :minimum_disk_bytes]),
          :android,
          Image.guest_capabilities(image).android_sdk
        )
      end)

    %{images: images, available: available, sampled_at: now, capacity_known: known}
  end
end
