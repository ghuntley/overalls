defmodule Marshall.Authorization.VmDecisionTableTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  @moduletag capture_log: true
  @moduletag timeout: 600_000

  alias Marshall.Authorization
  alias Marshall.Authorization.{Cedar, SystemActor}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Threads.{Grant, Thread}

  @type action :: String.t()
  @type relation ::
          :owner
          | :stranger
          | {:machine, :viewer | :operator | :manager | :web}
          | {:thread, :viewer | :operator | :manager}
          | {:team, :admin | :member}
  @type state :: %{relation: relation(), profile: :customer | :standard, owner_active: boolean()}

  @actions ~w(read write manage web)

  setup do
    fixture = Marshall.TerminalFixtures.terminal_fixture(%{profile: :standard})
    {:ok, team} = create_team(fixture.owner)

    # The fixture provisions personally; the machine joins the owner's team here.
    sql!("UPDATE compute_virtual_machines SET team_id = $2 WHERE id = $1", [
      fixture.vm.id,
      team.id
    ])

    %{
      owner: fixture.owner,
      vm: fixture.vm,
      thread: bound_thread(fixture.owner, fixture.vm),
      member: user(),
      stranger: user(),
      team_admin: team_member(team, fixture.owner, :admin),
      team_member: team_member(team, fixture.owner, :member)
    }
  end

  # @cc [owner:ghuntley,label:security;verification] vm-decision-table
  # For every generated principal relation, machine profile and owner state, the
  # SQL record decision, membership of the Cedar-derived list filter, the
  # Cedar decision over a hand-built entity, and the real `get_vm` outcome MUST
  # all equal the intended decision table below, which is written from the
  # policy's intent and not from either implementation.
  property "VM decisions agree with the decision table on every path",
           c,
           profile: :ci,
           test_cases: 60 do
    state = %{
      relation:
        draw(
          "relation",
          member_of([
            :owner,
            :stranger,
            {:machine, :viewer},
            {:machine, :operator},
            {:machine, :manager},
            {:machine, :web},
            {:thread, :viewer},
            {:thread, :operator},
            {:thread, :manager},
            {:team, :admin},
            {:team, :member}
          ])
        ),
      profile: draw("profile", member_of([:customer, :standard])),
      owner_active: draw("owner_active", member_of([true, false]))
    }

    decide_all(c, state)
  end

  @spec decide_all(map(), state()) :: :ok
  defp decide_all(c, state) do
    {principal, grant} = arrange(c, state)

    try do
      for action <- @actions do
        expected = expected(state, action)
        label = "#{inspect(state)} #{action}"

        assert Authorization.allowed?(principal, action, VirtualMachine.Cedar, c.vm.id) ==
                 expected,
               "record decision " <> label

        assert listed?(principal, action, c.vm.id) == expected, "list filter " <> label

        assert Cedar.allowed?(principal, action, entity(c, state, principal)) == expected,
               "hand-built entity " <> label

        if action == "read" do
          outcome = Marshall.Compute.get_vm(%{vm_id: c.vm.id}, actor: principal)
          assert match?({:ok, _}, outcome) == expected, "get_vm " <> label
        end
      end
    after
      restore(c, grant)
    end

    :ok
  end

  # The intended table: roles by relation, then the owner-account, sharing and
  # web capability limits that bound every role.
  @spec expected(state(), action()) :: boolean()
  def expected(state, action) do
    granted =
      case state.relation do
        :owner -> ~w(read write manage web)
        :stranger -> []
        {_, :manager} -> ~w(read write manage web)
        {:team, :admin} -> ~w(read write manage web)
        {_, :operator} -> ~w(read write web)
        {:team, :member} -> ~w(read write web)
        {_, :viewer} -> ~w(read web)
        {:machine, :web} -> ~w(web)
      end

    sharing? = state.profile == :standard

    action in granted and state.owner_active and (state.relation == :owner or sharing?) and
      (action != "web" or sharing?)
  end

  # Outcome paths roll back through the ledger, so each case's changes are
  # undone explicitly instead of inside a wrapping transaction.
  @spec restore(map(), struct() | nil) :: :ok
  defp restore(c, grant) do
    sql!("UPDATE users SET active = true WHERE id = $1", [c.owner.id])
    sql!("UPDATE compute_virtual_machines SET profile = 'standard' WHERE id = $1", [c.vm.id])
    if grant, do: :ok = Ledger.archive!(grant, :revoke)
    :ok
  end

  @spec arrange(map(), state()) :: {Marshall.Accounts.User.t(), struct() | nil}
  defp arrange(c, state) do
    unless state.owner_active,
      do: sql!("UPDATE users SET active = false WHERE id = $1", [c.owner.id])

    if state.profile == :customer,
      do:
        sql!("UPDATE compute_virtual_machines SET profile = 'customer' WHERE id = $1", [c.vm.id])

    case state.relation do
      :owner ->
        {c.owner, nil}

      :stranger ->
        {c.stranger, nil}

      {:team, :admin} ->
        {c.team_admin, nil}

      {:team, :member} ->
        {c.team_member, nil}

      {:machine, role} ->
        Marshall.Access.Grant
        |> Ledger.create!(:grant, %{
          vm_id: c.vm.id,
          user_id: c.member.id,
          role: role,
          granted_by_id: c.owner.id
        })
        |> then(&{c.member, &1})

      {:thread, role} ->
        Grant
        |> Ledger.create!(:grant, %{
          thread_id: c.thread.id,
          user_id: c.member.id,
          role: role,
          granted_by_id: c.owner.id
        })
        |> then(&{c.member, &1})
    end
  end

  @spec listed?(Marshall.Accounts.User.t(), action(), String.t()) :: boolean()
  defp listed?(principal, action, id) do
    VirtualMachine
    |> Ash.Query.for_read(:read, %{}, actor: SystemActor.compute())
    |> Authorization.filter(principal, action, VirtualMachine.Cedar)
    |> Ash.Query.select([:id])
    |> Ash.read!()
    |> Enum.any?(&(&1.id == id))
  end

  @spec entity(map(), state(), Marshall.Accounts.User.t()) :: Marshall.Authorization.Entity.t()
  defp entity(c, state, principal) do
    grants =
      case state.relation do
        {:team, :admin} -> %{team_admins: [principal.id], team_members: [principal.id]}
        {:team, :member} -> %{team_members: [principal.id]}
        {_, role} -> %{role => [principal.id]}
        _ -> %{}
      end

    sharing? = state.profile == :standard

    Marshall.CedarEntities.vm(c.vm.id, c.owner.id, grants, %{
      "owner_active" => state.owner_active,
      "sharing" => sharing?,
      "web_enabled" => sharing?
    })
  end

  defp sql!(statement, ids),
    do: Ecto.Adapters.SQL.query!(Marshall.Repo, statement, Enum.map(ids, &Ecto.UUID.dump!/1))

  defp create_team(owner) do
    Marshall.Teams.create_team(
      %{
        name: "team-" <> binary_part(Ash.UUID.generate(), 0, 8),
        idempotency_key: Ash.UUID.generate()
      },
      actor: owner
    )
  end

  defp team_member(team, owner, role) do
    member = user()

    {:ok, _} =
      Marshall.Teams.set_team_member(
        %{
          team_id: team.id,
          email: to_string(member.email),
          role: role,
          idempotency_key: Ash.UUID.generate()
        },
        actor: owner
      )

    member
  end

  @spec bound_thread(Marshall.Accounts.User.t(), VirtualMachine.t()) :: Thread.t()
  defp bound_thread(owner, vm) do
    key = Ash.UUID.generate()

    Thread
    |> Ledger.create!(:open, %{
      creator_id: owner.id,
      objective: "Decision table work",
      mode: :medium,
      machine_spec: request(),
      idempotency_key: key,
      machine_key: key
    })
    |> Marshall.ThreadStateFixture.ready!(%{machine_id: vm.id})
  end
end
