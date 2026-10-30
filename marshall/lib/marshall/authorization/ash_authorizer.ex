defmodule Marshall.Authorization.AshAuthorizer do
  @moduledoc """
  Marshall's only Ash authorizer, and the DSL every resource uses to say which
  Cedar question each of its actions asks. The mapping says only what is being
  asked; `priv/cedar` decides who may.

      cedar do
        control_plane "provision", [:list_for_user, :get_for_user]
        internal [:read, :record]
        service :ash_authentication, [:get_by_subject]
        service :scim, [:scim_read]
        record "account_self", "User", [:dismiss_newsletter]
        refused [:update]
      end

  - `control_plane` checks the Cedar action against `ControlPlane::"marshall"`
    for the acting user; public generic actions' coordinators then apply fresh
    record-level Cedar checks.
  - `internal` checks `coordinate` on `Internal::"<Resource>:<action>"` for the
    compute system principal.
  - `service` checks the service's Cedar action (`authenticate` or
    `scim_provision`) on the same `Internal` entity for that service principal.
  - `record` checks a Cedar action on the changed record (`<type>::"<id>"`)
    for the acting user; only update and destroy actions may use it.
  - `refused` names actions no principal may call (generated defaults such as
    paper-trail version updates).

  Every action must be mapped, at most once per principal kind, and a refused
  action admits no one; compilation fails otherwise.
  """
  @behaviour Ash.Authorizer

  alias Marshall.Authorization.{Cedar, Entity, SystemActor}
  alias Marshall.Authorization.Resource.{Info, Rule}

  @control_plane %Spark.Dsl.Entity{
    name: :control_plane,
    target: Rule,
    args: [:cedar_action, :actions],
    auto_set_fields: [kind: :control_plane],
    schema: [
      cedar_action: [type: :string, required: true, doc: "Cedar action on ControlPlane."],
      actions: [type: {:list, :atom}, required: true, doc: "Ash action names."]
    ],
    describe: "Admit the acting user through a Cedar action on the Marshall control plane."
  }

  @internal %Spark.Dsl.Entity{
    name: :internal,
    target: Rule,
    args: [:actions],
    auto_set_fields: [kind: :internal],
    schema: [actions: [type: {:list, :atom}, required: true, doc: "Ash action names."]],
    describe: "Admit the compute system principal to coordinate these actions."
  }

  @service %Spark.Dsl.Entity{
    name: :service,
    target: Rule,
    args: [:service, :actions],
    auto_set_fields: [kind: :service],
    schema: [
      service: [type: {:one_of, [:ash_authentication, :scim]}, required: true, doc: "Service."],
      actions: [type: {:list, :atom}, required: true, doc: "Ash action names."]
    ],
    describe: "Admit a library service principal to these actions."
  }

  @record %Spark.Dsl.Entity{
    name: :record,
    target: Rule,
    args: [:cedar_action, :entity_type, :actions],
    auto_set_fields: [kind: :record],
    schema: [
      cedar_action: [type: :string, required: true, doc: "Cedar action on the record."],
      entity_type: [type: :string, required: true, doc: "Cedar entity type of the record."],
      actions: [type: {:list, :atom}, required: true, doc: "Ash update or destroy actions."]
    ],
    describe: "Admit the acting user through a Cedar action on the changed record itself."
  }

  @refused %Spark.Dsl.Entity{
    name: :refused,
    target: Rule,
    args: [:actions],
    auto_set_fields: [kind: :refused],
    schema: [actions: [type: {:list, :atom}, required: true, doc: "Ash action names."]],
    describe: "Actions no principal may call."
  }

  @cedar %Spark.Dsl.Section{
    name: :cedar,
    describe: "Cedar authorization mapping for every action.",
    entities: [@control_plane, @internal, @service, @record, @refused]
  }

  use Spark.Dsl.Extension,
    sections: [@cedar],
    transformers: [Marshall.Authorization.Resource.Persist],
    verifiers: [Marshall.Authorization.Resource.Verifier]

  @impl true
  def initial_state(actor, resource, action, _domain) do
    %{actor: actor, resource: resource, action: action.name}
  end

  @impl true
  def strict_check_context(_), do: []

  # @cc [owner:ghuntley,label:security] ash-generic-action-recheck
  # Entry authorization for public generic actions MUST establish only signed-in
  # admission; their coordinators remain responsible for current record-level
  # Cedar checks. An action MUST be admitted only through its own declared rule
  # and a Cedar allow, never by another action's rule or a trusted actor alone.
  @impl true
  def strict_check(%{resource: resource, action: action} = state, context) do
    actor = principal(state.actor, context)

    if resource
       |> Info.rules_for(action)
       |> Enum.any?(&admits?(&1, resource, action, actor, context)),
       do: {:authorized, state},
       else: {:error, Ash.Error.Forbidden.exception([])}
  end

  # @cc [owner:ghuntley,label:security] ash-authentication-service-principal
  # AshAuthentication's own reads and writes carry no actor and mark their
  # subject with its private context flag. Only that actorless, flagged call
  # MUST be presented as the `ash_authentication` service principal; a call
  # with an actor keeps that actor, and Cedar still decides the service's scope.
  defp principal(nil, context) do
    subject = context[:query] || context[:changeset] || context[:action_input]

    case subject do
      %{context: %{private: %{ash_authentication?: true}}} ->
        SystemActor.service(:ash_authentication)

      _ ->
        nil
    end
  end

  defp principal(actor, _context), do: actor

  defp admits?(%Rule{kind: :refused}, _resource, _action, _actor, _context), do: false

  defp admits?(%Rule{kind: :control_plane, cedar_action: cedar_action}, _, _, actor, _),
    do: Cedar.allowed?(actor, cedar_action, Cedar.entity("ControlPlane", "marshall"))

  defp admits?(%Rule{kind: :internal}, resource, action, actor, _context),
    do: Cedar.allowed?(actor, "coordinate", internal(resource, action))

  # @cc [owner:ghuntley,label:security] ash-record-rule-loaded-record
  # A record rule MUST decide on the persisted record the changeset changes,
  # identified by its primary key; a changeset without a loaded record (bulk or
  # atomic updates by query) MUST deny.
  defp admits?(%Rule{kind: :record} = rule, resource, _action, actor, context) do
    with %Ash.Changeset{data: %{__meta__: %{state: :loaded}} = data} <- context[:changeset],
         [key] <- Ash.Resource.Info.primary_key(resource),
         id when is_binary(id) <- Map.get(data, key) do
      Cedar.allowed?(actor, rule.cedar_action, Entity.reference_only(rule.entity_type, id))
    else
      _ -> false
    end
  end

  # @cc [owner:ghuntley,label:security] ash-scim-service-entry
  # SCIM provisioning MUST be admitted only for the declared resource/action
  # pairs and only for the SCIM service principal while SCIM is enabled, which
  # Cedar decides from the principal's `enabled` attribute. The service never
  # receives compute coordinator authority.
  defp admits?(%Rule{kind: :service, service: service}, resource, action, actor, _context) do
    match?(%SystemActor{purpose: ^service}, actor) and
      Cedar.allowed?(actor, service_action(service), internal(resource, action))
  end

  defp service_action(:ash_authentication), do: "authenticate"
  defp service_action(:scim), do: "scim_provision"

  defp internal(resource, action), do: Cedar.entity("Internal", "#{inspect(resource)}:#{action}")

  @impl true
  def check_context(_), do: []
  @impl true
  def check(state, _), do: {:error, :forbidden, state}
end
