defmodule Marshall.Authorization.TerminalSessionDecisionTableTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  @moduletag capture_log: true
  @moduletag timeout: 600_000

  alias Marshall.Authorization
  alias Marshall.Authorization.{Cedar, SystemActor}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Terminal.{Grant, Session, Sharing}

  @action "terminal_session_use"

  @type relation ::
          :owner
          | :stranger
          | :viewer
          | :revoked
          | :regranted
          | :other_session_viewer
          | {:machine, :viewer | :operator | :manager}
  @type state :: %{relation: relation(), owner_active: boolean()}

  @relations [
    :owner,
    :stranger,
    :viewer,
    :revoked,
    :regranted,
    :other_session_viewer,
    {:machine, :viewer},
    {:machine, :operator},
    {:machine, :manager}
  ]

  setup do
    fixture = Marshall.TerminalFixtures.terminal_fixture(%{profile: :standard})
    [vm] = Ledger.history!(VirtualMachine, id: fixture.vm.id)

    %{
      owner: fixture.owner,
      vm: vm,
      session: open_session(vm, fixture.owner, 1),
      other_session: open_session(vm, fixture.owner, 2),
      member: user(),
      stranger: user()
    }
  end

  # @cc [owner:ghuntley,label:security;verification] terminal-session-decision-table
  # For every generated owner account state, every principal relation (owner,
  # stranger, current/revoked/re-issued terminal grant, grant on another
  # session, direct machine role) and a generated sequence of further
  # relations exercising grant churn, the SQL
  # record decision, membership of the Cedar-derived session filter, the Cedar
  # decision over a hand-built entity, and the real `Sharing.usable/2` outcome
  # (a prefetched page decision) MUST all equal the intended decision table
  # below, which is written from the policy's intent and not from either
  # implementation.
  property "TerminalSession decisions agree with the decision table on every path",
           c,
           profile: :ci,
           test_cases: 30 do
    owner_active = draw("owner_active", member_of([true, false]))
    relations = draw("relations", list_of(member_of(@relations), max_length: 6))

    unless owner_active,
      do: sql!("UPDATE users SET active = false WHERE id = $1", [c.owner.id])

    try do
      Enum.each(
        @relations ++ relations,
        &decide_all(c, %{relation: &1, owner_active: owner_active})
      )
    after
      sql!("UPDATE users SET active = true WHERE id = $1", [c.owner.id])
    end
  end

  @spec decide_all(map(), state()) :: :ok
  defp decide_all(c, state) do
    {principal, grants} = arrange(c, state.relation)

    try do
      expected = expected(state)
      label = inspect(state)

      assert Authorization.allowed?(principal, @action, Session.Cedar, c.session.id) ==
               expected,
             "record decision " <> label

      assert listed?(principal, c.session.id) == expected, "list filter " <> label

      assert Cedar.allowed?(principal, @action, entity(c, state, principal)) == expected,
             "hand-built entity " <> label

      assert Enum.map(Sharing.usable([c.session], principal), & &1.id) ==
               if(expected, do: [c.session.id], else: []),
             "Sharing.usable " <> label
    after
      restore(c, grants)
    end

    :ok
  end

  # The intended table: the session's immutable owner and users holding a
  # current terminal grant on this session may use it. Revoked grants, grants
  # on another session and machine roles confer nothing: terminal sharing and
  # VM authority are separate, and callers check VM authority (which carries
  # the owner-account bound) on their own, so owner account state does not
  # change this decision.
  @spec expected(state()) :: boolean()
  def expected(state), do: state.relation in [:owner, :viewer, :regranted]

  # Outcome paths roll back through the ledger, so each case's changes are
  # undone explicitly instead of inside a wrapping transaction.
  @spec restore(map(), [struct()]) :: :ok
  defp restore(_c, grants) do
    Enum.each(grants, &(:ok = Ledger.archive!(&1, :revoke)))
    :ok
  end

  @spec arrange(map(), relation()) :: {Marshall.Accounts.User.t(), [struct()]}
  defp arrange(c, relation) do
    case relation do
      :owner ->
        {c.owner, []}

      :stranger ->
        {c.stranger, []}

      :viewer ->
        {c.member, [share(c, c.session)]}

      :revoked ->
        :ok = Ledger.archive!(share(c, c.session), :revoke)
        {c.member, []}

      :regranted ->
        :ok = Ledger.archive!(share(c, c.session), :revoke)
        {c.member, [share(c, c.session)]}

      :other_session_viewer ->
        {c.member, [share(c, c.other_session)]}

      {:machine, role} ->
        Marshall.Access.Grant
        |> Ledger.create!(:grant, %{
          vm_id: c.vm.id,
          user_id: c.member.id,
          role: role,
          granted_by_id: c.owner.id
        })
        |> then(&{c.member, [&1]})
    end
  end

  @spec share(map(), Session.t()) :: Grant.t()
  defp share(c, session) do
    Ledger.create!(Grant, :grant, %{
      session_id: session.id,
      user_id: c.member.id,
      granted_by_id: c.owner.id
    })
  end

  @spec listed?(Marshall.Accounts.User.t(), String.t()) :: boolean()
  defp listed?(principal, id) do
    Session
    |> Ash.Query.for_read(Session.Cedar.read_action(), %{}, actor: SystemActor.compute())
    |> Authorization.filter(principal, @action, Session.Cedar)
    |> Ash.Query.select([:id])
    |> Ash.read!()
    |> Enum.any?(&(&1.id == id))
  end

  @spec entity(map(), state(), Marshall.Accounts.User.t()) :: Marshall.Authorization.Entity.t()
  defp entity(c, state, principal) do
    viewers = if state.relation in [:viewer, :regranted], do: [principal.id], else: []
    Marshall.CedarEntities.terminal_session(c.session.id, c.owner.id, viewers)
  end

  @spec open_session(VirtualMachine.t(), Marshall.Accounts.User.t(), pos_integer()) ::
          Session.t()
  defp open_session(vm, owner, guest_session_id) do
    Ledger.create!(Session, :open, %{
      vm_id: vm.id,
      owner_id: owner.id,
      placement_id: vm.current_placement_id,
      execution_epoch: vm.execution_epoch,
      guest_session_id: guest_session_id
    })
  end

  @spec sql!(String.t(), [String.t()]) :: Postgrex.Result.t()
  defp sql!(statement, ids),
    do: Ecto.Adapters.SQL.query!(Marshall.Repo, statement, Enum.map(ids, &Ecto.UUID.dump!/1))
end
