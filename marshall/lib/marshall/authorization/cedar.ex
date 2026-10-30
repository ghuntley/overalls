defmodule Marshall.Authorization.Cedar do
  @moduledoc "Cedar policy compilation at startup and fail-closed request evaluation."
  use GenServer

  alias Marshall.Accounts.User
  alias Marshall.Authorization.{DecisionSnapshot, Entity, Native, Principal, SystemActor}
  require Marshall.Events

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # @cc [owner:ghuntley,label:security] cedar-startup-validation
  # Startup MUST require policy/schema compilation and strict Cedar validation
  # with no errors or warnings before publishing authorization state; invalid
  # policy files MUST prevent this server from starting.
  @impl true
  def init(_opts) do
    directory = Application.app_dir(:marshall, "priv/cedar")

    case Native.compile(
           File.read!(Path.join(directory, "compute.cedar")),
           File.read!(Path.join(directory, "schema.cedarschema"))
         ) do
      {:ok, engine} ->
        :persistent_term.put(__MODULE__, engine)
        {:ok, nil}

      {:error, _findings} ->
        {:stop, :invalid_cedar_policies}
    end
  end

  @doc "The compiled engine; nil before startup validation succeeds."
  @spec engine() :: reference() | nil
  def engine, do: :persistent_term.get(__MODULE__, nil)

  # @cc [owner:ghuntley,label:security] cedar-error-free-allow-only
  # Authorization MUST return true only for a recognized typed principal and an
  # explicit Cedar allow with no evaluation errors. Missing policy state,
  # incomplete entities, invalid principals and error-bearing decisions MUST deny.
  @spec allowed?(term(), String.t(), Entity.t()) :: boolean()
  def allowed?(actor, action, %Entity{} = resource) do
    with engine when not is_nil(engine) <- engine(),
         {:ok, principal} <- principal_entity(actor) do
      decide(fn ->
        Native.authorize(
          engine,
          Entity.terms([principal, resource]),
          Entity.reference(principal),
          action,
          Entity.reference(resource)
        )
      end)
    else
      _ -> false
    end
  end

  @doc "One decision per resource for the same actor and action, in one engine call."
  @spec allowed_many?(term(), String.t(), [Entity.t()]) :: [boolean()]
  def allowed_many?(_actor, _action, []), do: []

  def allowed_many?(actor, action, resources) do
    deny = Enum.map(resources, fn _ -> false end)

    with engine when not is_nil(engine) <- engine(),
         {:ok, principal} <- principal_entity(actor) do
      case decide(fn ->
             Native.authorize_many(
               engine,
               Entity.terms([principal | resources]),
               Entity.reference(principal),
               action,
               Enum.map(resources, &Entity.reference/1)
             )
           end) do
        decisions when is_list(decisions) -> decisions
        _ -> deny
      end
    else
      _ -> deny
    end
  end

  @doc "The actor's current Cedar principal, loaded once per decision scope."
  @spec principal(term()) ::
          {:ok, %{type: String.t(), id: String.t(), attributes: map()}} | {:error, atom()}
  def principal(actor) do
    with {:ok, %Entity{} = entity} <- principal_entity(actor),
         do: {:ok, %{type: entity.type, id: entity.id, attributes: entity.attributes}}
  end

  defp decide(evaluate) do
    evaluate.()
  rescue
    ErlangError -> evaluation_error(:evaluation_failed)
    ArgumentError -> evaluation_error(:decision_errors)
  end

  defp evaluation_error(reason) do
    Marshall.Events.emit("cedar.evaluation_error", reason: reason)
    false
  end

  @spec entity(String.t(), String.t(), map()) :: Entity.t()
  def entity(type, id, attributes \\ %{}), do: Entity.new(type, id, attributes)

  # @cc [owner:ghuntley,label:security] cedar-current-administrator
  # User administrator authority MUST come from the persisted account on each
  # decision, never the caller's struct, session claims or a permission cache.
  # Within one DecisionSnapshot batch the persisted principal MAY be read once
  # and reused, because every read in that snapshot returns the same rows; it
  # MUST NOT outlive the batch. Missing users and a presented login that is no
  # longer stored MUST deny; the system principal remains a separate entity type.
  defp principal_entity(%User{id: id} = actor) when is_binary(id) do
    jti = Marshall.Accounts.Security.jti(actor)

    DecisionSnapshot.fetch({:cedar_principal, id, jti}, fn ->
      case Principal.load(id, jti) do
        %Principal{login: :absent} ->
          {:error, :unauthorized}

        %Principal{} = principal ->
          {:ok,
           entity("User", id, %{
             "administrator" => principal.administrator,
             "elevated" => principal.elevated,
             "active" => principal.active
           })}

        nil ->
          {:error, :unknown_principal}
      end
    end)
  end

  defp principal_entity(%SystemActor{purpose: :compute}), do: {:ok, entity("System", "compute")}

  defp principal_entity(%SystemActor{purpose: :ash_authentication}),
    do: {:ok, entity("Service", "ash_authentication", %{"enabled" => true})}

  # SCIM's enablement is read per decision scope like any principal attribute.
  defp principal_entity(%SystemActor{purpose: :scim}) do
    DecisionSnapshot.fetch(:cedar_scim_principal, fn ->
      {:ok, entity("Service", "scim", %{"enabled" => Marshall.Scim.enabled?()})}
    end)
  end

  defp principal_entity(_), do: {:error, :unknown_principal}
end
