defmodule Marshall.Compute.VirtualMachine.Cedar do
  @moduledoc """
  The Cedar `VM` entity in SQL. Each schema attribute is defined once here, as
  an Ash expression over the machine row, and both record decisions and list
  reads evaluate the Cedar residual through these definitions.
  """
  @behaviour Marshall.Authorization.Record
  import Ash.Expr
  alias OverallsProtocol.ProfilePolicy

  @profiles [:customer, :standard, :oss, :inception]
  @bound_statuses [:pending, :provisioning, :ready, :failed, :deleting]

  @impl true
  def type, do: "VM"

  @impl true
  def resource, do: Marshall.Compute.VirtualMachine

  # Decisions see archived machines too, so a deleted machine's receipts and
  # idempotent replays stay decided on its row; coordinators check liveness.
  @impl true
  def read_action, do: :history

  # @cc [owner:ghuntley,label:security] access-fresh-cedar-entity
  # VM membership MUST come from current rows only: the immutable owner, the
  # actor's unarchived machine grants, unarchived grants on the machine's single
  # current thread binding (created by the VM owner, on a sharing profile), and
  # current membership of an unarchived owning team. Sources are additive;
  # customer-profile and capability limits are Cedar forbids over `sharing`,
  # `terminal` and `web_enabled`, and every role requires a current owner account.
  @impl true
  def filter("owner", :equals, principal), do: expr(owner_id == ^principal)

  def filter("owner_active", :truthy, _),
    do: expr(exists(owner, is_nil(deleted_at) and active == true))

  def filter("sharing", :truthy, _), do: expr(profile in ^profiles(:sharing))
  def filter("terminal", :truthy, _), do: expr(profile in ^profiles(:terminal))
  def filter("web_enabled", :truthy, _), do: expr(profile in ^profiles(:web))

  def filter(attribute, use, principal) when use in [:equals, :member] do
    case source(attribute, use) do
      {:ok, source} -> source |> sources(%{}) |> expression(principal)
      :error -> :unsupported
    end
  end

  def filter(_attribute, _use, _principal), do: :unsupported

  # Several membership attributes in one residual disjunction (the read
  # residual tests owner, managers, operators, viewers and both team roles)
  # become one expression that reads each grant table once.
  @impl true
  def members(uses, principal) do
    Enum.reduce_while(uses, %{}, fn {attribute, use}, acc ->
      case source(attribute, use) do
        {:ok, source} -> {:cont, sources(source, acc)}
        :error -> {:halt, :unsupported}
      end
    end)
    |> case do
      :unsupported -> :unsupported
      sources -> expression(sources, principal)
    end
  end

  @typep source ::
           :owner
           | {:machine, String.t()}
           | {:role, String.t()}
           | {:team, :any | [String.t()]}
  @typep sources :: %{
           optional(:owner) => true,
           optional(:machine) => [String.t()],
           optional(:thread) => [String.t()],
           optional(:team) => :any | [String.t()]
         }

  @spec source(String.t(), :equals | :member | :truthy) :: {:ok, source()} | :error
  defp source("owner", :equals), do: {:ok, :owner}
  defp source("web_users", :member), do: {:ok, {:machine, "web"}}
  defp source("viewers", :member), do: {:ok, {:role, "viewer"}}
  defp source("operators", :member), do: {:ok, {:role, "operator"}}
  defp source("managers", :member), do: {:ok, {:role, "manager"}}
  defp source("team_members", :member), do: {:ok, {:team, :any}}
  defp source("team_admins", :member), do: {:ok, {:team, ~w(owner admin)}}
  defp source(_attribute, _use), do: :error

  @spec sources(source(), sources()) :: sources()
  defp sources(:owner, acc), do: Map.put(acc, :owner, true)
  defp sources({:machine, role}, acc), do: Map.update(acc, :machine, [role], &[role | &1])

  defp sources({:role, role}, acc) do
    acc = sources({:machine, role}, acc)
    Map.update(acc, :thread, [role], &[role | &1])
  end

  defp sources({:team, :any}, acc), do: Map.put(acc, :team, :any)
  defp sources({:team, _roles}, %{team: :any} = acc), do: acc
  defp sources({:team, roles}, acc), do: Map.update(acc, :team, roles, &Enum.uniq(&1 ++ roles))

  # @cc [owner:ghuntley,label:performance] vm-cedar-membership-index-paths
  # Each principal-dependent VM membership source MUST compile to an indexed
  # machine column compared with `= ANY(ARRAY(<uncorrelated subquery>))`: an
  # InitPlan PostgreSQL evaluates once from the principal's own grant or
  # membership rows before probing `compute_virtual_machines` by primary key,
  # owner or team index. The residual's OR of sources then plans as a BitmapOr
  # instead of a per-machine scan; no source may correlate an aggregate or
  # EXISTS with the machine row, which would visit every machine to return the
  # visible few. Sources MUST stay two-valued (a nullable team id is guarded
  # before `ANY`) so a negated residual remains exact.
  @spec expression(sources(), String.t()) :: Ash.Expr.t()
  defp expression(sources, principal) do
    [
      Map.has_key?(sources, :owner) && expr(owner_id == ^principal),
      sources[:machine] && machine_grant(principal, Enum.uniq(sources.machine)),
      sources[:thread] && thread_grant(principal, Enum.uniq(sources.thread)),
      sources[:team] && team_member(principal, sources.team)
    ]
    |> Enum.filter(& &1)
    |> Enum.reduce(fn arm, acc -> expr(^acc or ^arm) end)
  end

  defp machine_grant(principal, roles) do
    expr(
      fragment(
        """
        ? = ANY(ARRAY(
          SELECT g.vm_id FROM access_grants AS g
          WHERE g.user_id = ? AND g.role = ANY(?) AND g.archived_at IS NULL))
        """,
        id,
        type(^principal, :uuid),
        ^roles
      )
    )
  end

  # Thread grants reach the machine only through exactly one current binding:
  # an unarchived thread in a bound status created by the machine owner. The
  # grant must sit on that binding and its machine spec must allow sharing.
  # `machine_id IS NOT NULL` lets the planner start from whichever is smaller,
  # the principal's thread grants or the bound threads.
  defp thread_grant(principal, roles) do
    sharing = Enum.map(profiles(:sharing), &Atom.to_string/1)
    bound = Enum.map(@bound_statuses, &Atom.to_string/1)

    expr(
      fragment(
        """
        ? = ANY(ARRAY(
          SELECT t.machine_id FROM thread_grants AS g
          JOIN threads AS t ON t.id = g.thread_id
          JOIN compute_virtual_machines AS v ON v.id = t.machine_id
          WHERE g.user_id = ? AND g.role = ANY(?) AND g.archived_at IS NULL
            AND t.machine_id IS NOT NULL AND t.archived_at IS NULL AND t.status = ANY(?) AND t.creator_id = v.owner_id
            AND (t.machine_spec->>'profile') = ANY(?)
            AND (SELECT count(*) FROM threads AS b
                 WHERE b.machine_id = t.machine_id AND b.archived_at IS NULL
                   AND b.status = ANY(?) AND b.creator_id = v.owner_id) = 1))
        """,
        id,
        type(^principal, :uuid),
        ^roles,
        ^bound,
        ^sharing,
        ^bound
      )
    )
  end

  # Current membership, in any role or in one of `roles`, of an unarchived team.
  defp team_member(principal, :any) do
    expr(
      fragment(
        """
        ? IS NOT NULL AND ? = ANY(ARRAY(
          SELECT m.team_id FROM team_members AS m JOIN teams AS t ON t.id = m.team_id
          WHERE m.user_id = ? AND m.archived_at IS NULL AND t.archived_at IS NULL))
        """,
        team_id,
        team_id,
        type(^principal, :uuid)
      )
    )
  end

  defp team_member(principal, roles) do
    expr(
      fragment(
        """
        ? IS NOT NULL AND ? = ANY(ARRAY(
          SELECT m.team_id FROM team_members AS m JOIN teams AS t ON t.id = m.team_id
          WHERE m.user_id = ? AND m.role = ANY(?) AND m.archived_at IS NULL
            AND t.archived_at IS NULL))
        """,
        team_id,
        team_id,
        type(^principal, :uuid),
        ^roles
      )
    )
  end

  defp profiles(capability), do: Enum.filter(@profiles, &ProfilePolicy.allows?(&1, capability))
end
