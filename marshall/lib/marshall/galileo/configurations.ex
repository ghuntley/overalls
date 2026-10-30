defmodule Marshall.Galileo.Configurations do
  @moduledoc "Transactional integration configuration: idempotent writes, attachments and views."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.{Cedar, SystemActor}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Galileo.{Attachment, Integration, IntegrationHeader}
  require Ash.Query
  require Marshall.Events

  @impl true
  def run(input, options, context) do
    operation = options[:operation] || :configure

    result =
      Ledger.transaction(
        fn ->
          value =
            case operation do
              :list -> list(context.actor, input.arguments)
              :remove -> remove(input.arguments, context.actor)
              :attach -> attach(input.arguments, context.actor)
              :detach -> detach(input.arguments, context.actor)
              :show -> show(input.arguments, context.actor)
              _ -> configure(input.arguments, context.actor)
            end

          record_receipt(operation, value, context.actor)
          value
        end,
        context.actor
      )

    case result do
      {:ok, value} ->
        unless Marshall.Repo.in_transaction?() do
          emit_configuration(operation, value, context.actor.id)
        end

        {:ok, value}

      {:error, reason} when is_atom(reason) ->
        {:error, Marshall.Compute.Error.exception(reason: reason)}

      other ->
        other
    end
  end

  defp emit_configuration(_, %{attached: _, integration_id: id, vm_id: vm_id}, actor_id) do
    Marshall.Events.emit("galileo.integration_configured",
      integration_id: id,
      vm_id: vm_id,
      actor_id: actor_id,
      operation_status: :attached
    )
  end

  defp emit_configuration(_, %{detached: _, integration_id: id, vm_id: vm_id}, actor_id) do
    Marshall.Events.emit("galileo.integration_configured",
      integration_id: id,
      vm_id: vm_id,
      actor_id: actor_id,
      operation_status: :detached
    )
  end

  defp emit_configuration(_, %{removed: _, integration_id: id}, actor_id) do
    Marshall.Events.emit("galileo.integration_configured",
      integration_id: id,
      actor_id: actor_id,
      operation_status: :removed
    )
  end

  defp emit_configuration(_, %Marshall.Galileo.Integration{} = integration, actor_id) do
    Marshall.Events.emit("galileo.integration_configured",
      integration_id: integration.id,
      actor_id: actor_id,
      operation_status: :configured
    )
  end

  defp emit_configuration(_, _, _), do: :ok

  # @cc [owner:ghuntley,label:security;durability] galileo-authority-admin-receipts
  # Secret-bearing integration authority changes MUST append a payload-free
  # AdminEvent atomically; secrets and headers MUST never enter the receipt.
  defp record_receipt(:configure, %Integration{id: id}, actor) do
    Ledger.create!(Marshall.Accounts.AdminEvent, :record, %{
      actor_id: actor.id,
      target_id: id,
      kind: :galileo_configure
    })
  end

  defp record_receipt(operation, value, actor) when operation in [:remove, :attach, :detach] do
    target_id = Map.fetch!(value, :integration_id)

    Ledger.create!(Marshall.Accounts.AdminEvent, :record, %{
      actor_id: actor.id,
      target_id: target_id,
      kind: galileo_receipt(operation)
    })
  end

  defp record_receipt(_, _, _), do: :ok

  defp galileo_receipt(:remove), do: :galileo_remove
  defp galileo_receipt(:attach), do: :galileo_attach
  defp galileo_receipt(:detach), do: :galileo_detach

  # @cc [owner:ghuntley,label:security;product] galileo-configure-idempotent
  # Configuration MUST validate every field through the shared protocol
  # before persistence, MUST be idempotent per actor/key/name, and MUST
  # replace target kind, peer VM, user/team ownership and the complete header
  # set atomically. Team ownership requires a current owner/admin membership;
  # team-scoped authority is evaluated fresh through Cedar. Stored secret
  # values are never returned. A removed integration closes its name history:
  # configuration of a name whose retained row is archived MUST refuse with
  # the closed name_unavailable reason after checking manage authority, never
  # replaying or updating the archived row; reusing a removed name as a fresh
  # identity requires an explicit future decision.
  defp configure(arguments, actor) do
    Marshall.Accounts.AccountLifecycle.admit!(actor.id)
    validated = validated!(arguments)
    if arguments[:peer_vm_id], do: share_vm!(arguments.peer_vm_id)
    team_authorized!(arguments[:team_id], actor)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["galileo:name:" <> arguments.name],
      log: false
    )

    case Ledger.history!(Integration, name: arguments.name) do
      [%Integration{archived_at: nil} = integration] ->
        unless manager?(integration, actor), do: Ledger.rollback(:forbidden)
        replay!(integration, validated, arguments, actor)

      [] ->
        integration =
          Ledger.create!(Integration, :register, %{
            name: arguments.name,
            target: validated.target,
            strip_prefix: validated.strip_prefix,
            peer: arguments.peer,
            peer_vm_id: arguments[:peer_vm_id],
            comment: arguments.comment,
            owner_id: if(arguments[:team_id], do: nil, else: actor.id),
            team_id: arguments[:team_id],
            idempotency_key: arguments.idempotency_key
          })

        record_headers!(integration.id, arguments.headers)
        integration

      [%Integration{archived_at: %DateTime{}} = removed | _] ->
        unless manager?(removed, actor), do: Ledger.rollback(:forbidden)
        Ledger.rollback(:name_unavailable)
    end
  end

  # @cc [owner:ghuntley,label:product] galileo-configure-replay-conflict
  # Reusing the same idempotency key on a live integration MUST return the
  # original configuration for an identical payload — including identical
  # secret values compared in memory — and MUST conflict for a changed payload.
  # A different key with a changed payload replaces the configuration and its
  # complete header set. The caller MUST reach replay!/4 only with a live row:
  # archived rows are refused by configure/2 before any replay comparison.
  defp replay!(integration, validated, arguments, actor) do
    owner_id = if(arguments[:team_id], do: nil, else: actor.id)

    same =
      integration.target == validated.target and
        integration.strip_prefix == validated.strip_prefix and
        integration.peer == arguments.peer and
        integration.peer_vm_id == arguments[:peer_vm_id] and
        integration.comment == arguments.comment and
        integration.owner_id == owner_id and
        integration.team_id == arguments[:team_id] and
        headers_equal?(integration.id, arguments.headers)

    cond do
      same and integration.idempotency_key == arguments.idempotency_key ->
        integration

      integration.idempotency_key == arguments.idempotency_key ->
        Ledger.rollback(:idempotency_conflict)

      true ->
        integration
        |> Ledger.update!(:edit, %{
          target: validated.target,
          strip_prefix: validated.strip_prefix,
          peer: arguments.peer,
          peer_vm_id: arguments[:peer_vm_id],
          comment: arguments.comment,
          owner_id: owner_id,
          team_id: arguments[:team_id],
          idempotency_key: arguments.idempotency_key
        })
        |> tap(fn updated ->
          Enum.each(
            Ledger.read!(IntegrationHeader, integration_id: updated.id),
            &Ledger.archive!(&1, :remove)
          )

          record_headers!(updated.id, arguments.headers)
        end)
    end
  end

  defp headers_equal?(integration_id, headers) do
    stored =
      Ledger.read!(IntegrationHeader, integration_id: integration_id)
      |> Ash.load!(:value, actor: SystemActor.compute())
      |> MapSet.new(&{&1.kind, &1.name, &1.value})

    MapSet.size(stored) == length(headers) and
      MapSet.subset?(
        MapSet.new(headers, &{&1.kind, &1.name, &1.value}),
        stored
      )
  end

  defp remove(arguments, actor) do
    integration = live_integration!(arguments.name)
    unless manager?(integration, actor), do: Ledger.rollback(:forbidden)
    Ledger.archive!(integration, :archive)
    %{removed: integration.name, integration_id: integration.id}
  end

  # @cc [owner:ghuntley,label:security] galileo-attachment-explicit
  # Only a manager of the integration may attach or detach machines, the
  # machine MUST exist, and attachment alone grants no other authority.
  defp attach(arguments, actor) do
    integration = live_integration!(arguments.name)
    unless manager?(integration, actor), do: Ledger.rollback(:forbidden)
    vm = live_vm!(arguments.vm_id)

    if Ledger.read!(Attachment, integration_id: integration.id, vm_id: vm.id) == [] do
      Ledger.create!(Attachment, :attach, %{
        integration_id: integration.id,
        vm_id: vm.id,
        attached_by_id: actor.id
      })
    end

    %{attached: integration.name, integration_id: integration.id, vm_id: vm.id}
  end

  defp detach(arguments, actor) do
    integration = live_integration!(arguments.name)
    unless manager?(integration, actor), do: Ledger.rollback(:forbidden)

    Enum.each(
      Ledger.read!(Attachment, integration_id: integration.id, vm_id: arguments.vm_id),
      &Ledger.archive!(&1, :detach)
    )

    %{detached: integration.name, integration_id: integration.id, vm_id: arguments.vm_id}
  end

  # @cc [owner:ghuntley,label:security] galileo-show-redacts-secrets
  # Views MUST list header names and kinds but never stored values; secret
  # material is write-only.
  defp show(arguments, actor) do
    integration = live_integration!(arguments.name)

    unless manager?(integration, actor) or reader?(integration, actor),
      do: Ledger.rollback(:forbidden)

    headers =
      Ledger.read!(IntegrationHeader, integration_id: integration.id)
      |> Enum.map(&%{kind: &1.kind, name: &1.name})

    Map.take(integration, [
      :id,
      :name,
      :target,
      :strip_prefix,
      :peer,
      :peer_vm_id,
      :comment,
      :owner_id,
      :team_id
    ])
    |> Map.put(:headers, headers)
  end

  defp list(actor, arguments) do
    require Ash.Query

    integrations =
      Integration
      |> Ash.Query.filter(owner_id == ^actor.id or team_id in ^team_ids(actor))
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.read!(actor: SystemActor.compute())

    integrations
    |> Enum.filter(&Marshall.Galileo.Ownership.live?/1)
    |> Enum.map(fn integration ->
      headers =
        Ledger.read!(IntegrationHeader, integration_id: integration.id)
        |> Enum.map(&%{kind: &1.kind, name: &1.name})

      attachments =
        Ledger.read!(Attachment, integration_id: integration.id)
        |> Enum.map(&%{id: &1.id, vm_id: &1.vm_id})

      integration
      |> Map.take([
        :id,
        :name,
        :target,
        :strip_prefix,
        :peer,
        :peer_vm_id,
        :owner_id,
        :team_id,
        :comment
      ])
      |> Map.put(:headers, headers)
      |> Map.put(:attachments, attachments)
    end)
    |> paginate(arguments)
  end

  # @cc [owner:ghuntley,label:security;product] galileo-validation-closed-refusals
  # Malformed targets, strip prefixes and static headers MUST return the shared
  # protocol's closed refusal reason and roll back before persistence. Invalid
  # user input MUST NOT escape as an exception or crash its calling LiveView.
  defp validated!(arguments) do
    unless OverallsProtocol.Integration.name?(arguments.name),
      do: Ledger.rollback(:invalid_name)

    if arguments.peer do
      unless OverallsProtocol.uuid?(arguments[:peer_vm_id] || ""),
        do: Ledger.rollback(:peer_target_required)
    else
      if is_nil(arguments.target), do: Ledger.rollback(:target_required)
      if arguments[:peer_vm_id], do: Ledger.rollback(:peer_target_forbidden)
      validated_value!(OverallsProtocol.Integration.target(arguments.target))
    end

    strip_prefix =
      validated_value!(OverallsProtocol.Integration.strip_prefix(arguments[:strip_prefix]))

    credential_kinds = arguments.headers |> Enum.map(& &1.kind) |> Enum.filter(&(&1 != :static))

    if length(credential_kinds) > 1,
      do: Ledger.rollback(:conflicting_credentials)

    Enum.each(arguments.headers, fn header ->
      case header.kind do
        :static ->
          validated_value!(
            OverallsProtocol.Integration.static_header([header.name, header.value])
          )

        :bearer ->
          case OverallsProtocol.Integration.bearer_credential(header.value) do
            {:ok, _} -> :ok
            _ -> Ledger.rollback(:invalid_credential)
          end

        :basic ->
          case OverallsProtocol.Integration.basic_credential(header.value) do
            {:ok, _} -> :ok
            _ -> Ledger.rollback(:invalid_credential)
          end
      end
    end)

    %{target: arguments.target, strip_prefix: strip_prefix}
  end

  @spec validated_value!({:ok, value} | {:error, atom()}) :: value when value: term()
  defp validated_value!({:ok, value}), do: value
  defp validated_value!({:error, reason}), do: Ledger.rollback(reason)

  defp record_headers!(integration_id, headers) do
    Enum.each(headers, fn header ->
      Ledger.create!(IntegrationHeader, :record, %{
        integration_id: integration_id,
        kind: header.kind,
        name: header.name,
        value: header.value
      })
    end)
  end

  defp team_authorized!(nil, _actor), do: :ok

  defp team_authorized!(team_id, actor) do
    team =
      case Ledger.read!(Marshall.Teams.Team, id: team_id) do
        [team] -> team
        _ -> Ledger.rollback(:unknown_team)
      end

    Marshall.Teams.Fence.require_resources_open!(team)

    unless Cedar.allowed?(actor, "team_manage_members", Cedar.team(team)),
      do: Ledger.rollback(:forbidden)
  end

  defp manager?(integration, actor) do
    entity = Cedar.integration(integration)

    Marshall.Galileo.Ownership.live?(integration) and
      Cedar.allowed?(actor, "integration_manage", entity)
  end

  defp reader?(integration, actor) do
    entity = Cedar.integration(integration)

    Marshall.Galileo.Ownership.live?(integration) and
      Cedar.allowed?(actor, "integration_read", entity)
  end

  defp team_ids(actor) do
    require Ash.Query

    Marshall.Teams.TeamMember
    |> Ash.Query.filter(user_id == ^actor.id)
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.map(& &1.team_id)
  end

  defp live_integration!(name) do
    case Ledger.read!(Integration, name: name) do
      [integration] -> integration
      _ -> Ledger.rollback(:unknown_integration)
    end
  end

  defp live_vm!(id), do: share_vm!(id) || Ledger.rollback(:unknown_machine)

  # @cc [owner:ghuntley,label:concurrency] galileo-vm-before-user-rows
  # Guest roster and authorized-key pulls lock the VM row and then its writers'
  # User rows. Configuration and attachment rows reference both a VM and a User,
  # and their foreign-key checks would take the User key-share lock first. They
  # MUST therefore take FOR KEY SHARE on the referenced VM before any statement
  # that locks or references a User row, so the two paths cannot deadlock.
  @spec share_vm!(String.t()) :: VirtualMachine.t() | nil
  defp share_vm!(id) do
    VirtualMachine
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock("FOR KEY SHARE")
    |> Ash.read_one!(actor: SystemActor.compute())
  end

  # @cc [owner:ghuntley,label:product] galileo-exclusive-list-cursor
  # A non-nil listing cursor MUST exclude the matching row. Unknown cursors
  # MUST return an empty page; pagination MUST NOT replay a terminal row forever.
  defp paginate(rows, arguments) do
    remaining =
      if is_nil(arguments[:after]) do
        rows
      else
        case Enum.drop_while(rows, &(&1.id != arguments[:after])) do
          [_cursor | rest] -> rest
          [] -> []
        end
      end

    Enum.take(remaining, arguments.limit)
  end
end
