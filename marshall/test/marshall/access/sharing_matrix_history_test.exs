defmodule Marshall.Access.SharingMatrixHistoryTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  @moduletag capture_log: true
  @moduletag timeout: 300_000

  alias Marshall.{Access, Compute, Ingress}
  alias Marshall.Authorization.SystemActor
  alias Marshall.SharingMatrixFixture, as: Fixture
  alias Marshall.Terminal.{Authority, Session, Tickets}

  @type role :: :manager | :operator | :viewer | :web | :revoked
  @type capability :: :inventory | :terminal_read | :terminal_write | :ssh | :web

  @type leases :: %{
          ssh: map() | nil,
          web: map() | nil,
          closed_ssh: [String.t()],
          closed_web: [String.t()],
          cookie: String.t() | nil
        }

  @type vm_state :: %{
          vm: Compute.VirtualMachine.t(),
          label: String.t(),
          role: role(),
          leases: leases()
        }

  # @cc [owner:ghuntley,label:verification] sharing-matrix-independent-oracle
  # Expected decisions MUST come from this literal role/capability matrix and the
  # generated role history, never from Cedar, Ash policies or
  # Marshall.Access.Authorization. Every shareable role is exercised across
  # terminal, SSH, private web and inventory entries in one generated history.
  @matrix %{
    manager: [:inventory, :terminal_read, :terminal_write, :ssh, :web],
    operator: [:inventory, :terminal_read, :terminal_write, :ssh, :web],
    viewer: [:inventory, :terminal_read, :web],
    web: [:web],
    revoked: []
  }

  @spec grants?(role(), capability()) :: boolean()
  defp grants?(role, capability), do: capability in Map.fetch!(@matrix, role)

  # Real database/transport histories cost 5–12 seconds per case; preserve100 cases.
  @tag timeout: 1_800_000
  @tag :hegel_case_sandbox
  property "every shared role composes terminal, SSH and web entries in one generated history",
    profile: :ci,
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()

    tail =
      draw(
        "tail",
        list_of(member_of([:manager, :operator, :viewer, :web, :revoked]),
          min_length: 2,
          max_length: 6
        )
      )

    fixture = Fixture.create()

    Marshall.TerminalFixtures.stream_fixture(
      fixture.host.id,
      &Overalls.HegelFixtures.start_supervised!/1
    )

    roles =
      [:manager, :viewer, :operator, :web, :revoked, :viewer, :manager, :revoked] ++ tail

    leases =
      Enum.reduce(roles, empty_leases(), fn role, leases ->
        assert {:ok, _} = set_role(fixture, fixture.vm, role)
        Fixture.fresh(fixture)
        leases = renew_leases(leases, fixture, role)
        refuse_closed_leases(leases, fixture)
        probe_inventory(fixture, role)
        probe_terminal(fixture, role)
        leases = probe_ssh(leases, fixture, role)
        probe_web(leases, fixture, role)
      end)

    settle(fixture, leases)
  end

  test "one ordinary withdrawal closes terminal, SSH and web derived entries" do
    fixture = Fixture.create()
    Marshall.TerminalFixtures.stream_fixture(fixture.host.id)

    assert {:ok, _} = set_role(fixture, fixture.vm, :operator)
    Fixture.fresh(fixture)

    {:ok, session} = open_terminal(fixture)
    {:ok, terminal_ticket} = Authority.ticket(session, fixture.member)
    assert {:ok, %{mode: :rw}} = Tickets.consume(terminal_ticket)
    assert Authority.writable?(fixture.vm.id, fixture.member)

    {:ok, ssh} = open_ssh(fixture, fixture.label)
    assert {:ok, _} = renew_ssh(fixture, ssh.ticket)
    leases = web_chain(%{empty_leases() | ssh: ssh}, fixture)
    assert {:ok, _} = renew_web(fixture, leases.web.ticket)
    approved = approve_pending(fixture)

    # One ordinary sharing withdrawal closes every derived entry.
    assert {:ok, _} = set_role(fixture, fixture.vm, :revoked)
    Fixture.fresh(fixture)
    pending = begin_login(fixture, fixture.label)
    before = Fixture.inventory(fixture)

    assert {:error, _} = renew_ssh(fixture, ssh.ticket)
    assert {:error, _} = open_ssh(fixture, fixture.label)
    assert {:error, :forbidden} = open_terminal(fixture)
    assert {:error, _} = Authority.ticket(session, fixture.member)
    refute Authority.writable?(fixture.vm.id, fixture.member)
    assert {:error, _} = renew_web(fixture, leases.web.ticket)
    assert {:error, _} = exchange(fixture, approved)
    assert {:error, _} = open_web(fixture, leases.cookie, fixture.label)
    assert {:error, _} = authorize(fixture, pending.ticket)
    assert {:error, _} = Compute.get_vm(%{vm_id: fixture.vm.id}, actor: fixture.member)
    assert {:ok, %{items: []}} = Compute.list_vms(%{}, actor: fixture.member)
    assert Fixture.inventory(fixture) == before

    # Ordinary explicit closes still succeed, exactly once each.
    assert {:ok, %{closed: true}} = close_ssh(fixture, ssh.ticket)
    assert {:ok, %{closed: true}} = close_web(fixture, leases.web.ticket)
    before = Fixture.inventory(fixture)
    assert {:error, _} = renew_ssh(fixture, ssh.ticket)
    assert {:error, _} = renew_web(fixture, leases.web.ticket)
    assert Fixture.inventory(fixture) == before

    # A web-only re-grant reopens web flows alone; closed tokens never revive.
    assert {:ok, _} = set_role(fixture, fixture.vm, :web)
    Fixture.fresh(fixture)
    before = Fixture.inventory(fixture)
    assert {:error, _} = renew_ssh(fixture, ssh.ticket)
    assert {:error, _} = open_ssh(fixture, fixture.label)
    assert {:error, :forbidden} = open_terminal(fixture)
    assert {:error, _} = renew_web(fixture, leases.web.ticket)
    assert {:ok, %{items: []}} = Compute.list_vms(%{}, actor: fixture.member)
    assert {:error, _} = Compute.get_vm(%{vm_id: fixture.vm.id}, actor: fixture.member)
    assert Fixture.inventory(fixture) == before

    leases = web_chain(empty_leases(), fixture)
    assert {:ok, _} = renew_web(fixture, leases.web.ticket)
    assert {:ok, %{closed: true}} = close_web(fixture, leases.web.ticket)
    before = Fixture.inventory(fixture)
    assert {:error, _} = renew_web(fixture, leases.web.ticket)
    assert Fixture.inventory(fixture) == before

    # A manager re-grant restores terminal and SSH for fresh entries only.
    assert {:ok, _} = set_role(fixture, fixture.vm, :manager)
    Fixture.fresh(fixture)
    {:ok, restored} = open_terminal(fixture)
    {:ok, restored_ticket} = Authority.ticket(restored, fixture.member)
    assert {:ok, %{mode: :rw}} = Tickets.consume(restored_ticket)
    {:ok, fresh_ssh} = open_ssh(fixture, fixture.label)
    assert {:ok, _} = renew_ssh(fixture, fresh_ssh.ticket)
    before = Fixture.inventory(fixture)
    assert {:error, _} = renew_ssh(fixture, ssh.ticket)
    assert {:error, _} = renew_web(fixture, leases.web.ticket)
    assert Fixture.inventory(fixture) == before
    assert {:ok, %{closed: true}} = close_ssh(fixture, fresh_ssh.ticket)
  end

  @tag timeout: 1_800_000
  @tag :hegel_case_sandbox
  property "grant churn across two machines keeps each machine on its own matrix cell",
    profile: :ci,
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()

    tail =
      draw(
        "tail",
        list_of(
          tuple(
            {member_of([:first, :second]),
             member_of([:manager, :operator, :viewer, :web, :revoked])}
          ),
          min_length: 2,
          max_length: 4
        )
      )

    fixture = Fixture.create()

    Marshall.TerminalFixtures.stream_fixture(
      fixture.host.id,
      &Overalls.HegelFixtures.start_supervised!/1
    )

    second = Fixture.provision_second(fixture)
    vms = [fixture.vm, second.vm]

    churn =
      [
        {:first, :operator},
        {:second, :manager},
        {:first, :viewer},
        {:second, :web},
        {:first, :revoked},
        {:second, :revoked}
      ] ++ tail

    states = %{
      first: %{vm: fixture.vm, label: fixture.label, role: :revoked, leases: empty_leases()},
      second: %{vm: second.vm, label: second.label, role: :revoked, leases: empty_leases()}
    }

    states =
      Enum.reduce(churn, states, fn {which, role}, states ->
        state = Map.fetch!(states, which)
        assert {:ok, _} = set_role(fixture, state.vm, role)
        states = Map.put(states, which, %{state | role: role})
        Fixture.fresh(fixture)
        states = probe_vm(states, fixture, vms, :first)
        probe_vm(states, fixture, vms, :second)
      end)

    for which <- [:first, :second] do
      state = Map.fetch!(states, which)
      leases = state.leases

      if leases.ssh,
        do: assert({:ok, %{closed: true}} = close_ssh(fixture, leases.ssh.ticket))

      if leases.web,
        do: assert({:ok, %{closed: true}} = close_web(fixture, leases.web.ticket))

      for ticket <-
            if(leases.ssh, do: [leases.ssh.ticket], else: []) ++ leases.closed_ssh,
          do: denied_vm(fixture, vms, fn -> renew_ssh(fixture, ticket) end)

      for ticket <-
            if(leases.web, do: [leases.web.ticket], else: []) ++ leases.closed_web,
          do: denied_vm(fixture, vms, fn -> renew_web(fixture, ticket) end)
    end

    :ok
  end

  @spec empty_leases() :: leases()
  defp empty_leases, do: %{ssh: nil, web: nil, closed_ssh: [], closed_web: [], cookie: nil}

  @spec set_role(Fixture.t(), Compute.VirtualMachine.t(), role()) ::
          {:ok, term()} | {:error, term()}
  defp set_role(fixture, vm, role) do
    Access.set_access(
      %{
        vm_id: vm.id,
        email: to_string(fixture.member.email),
        role: role,
        idempotency_key: Ash.UUID.generate()
      },
      actor: fixture.owner
    )
  end

  # @cc [owner:ghuntley,label:verification] sharing-matrix-stale-lease-rederivation
  # A live SSH or web lease MUST renew exactly when the current role row retains
  # the capability; a role change without any new lease action MUST flip the
  # renewal decision. Renewal refusal MUST be followed by one ordinary close and
  # permanent refusal of the same token.
  @spec renew_leases(leases(), Fixture.t(), role()) :: leases()
  defp renew_leases(leases, fixture, role) do
    leases =
      case leases.ssh do
        nil ->
          leases

        ssh ->
          if grants?(role, :ssh) do
            assert {:ok, renewed} = renew_ssh(fixture, ssh.ticket)
            assert renewed.binding == ssh.binding
            leases
          else
            denied(fixture, fn -> renew_ssh(fixture, ssh.ticket) end)
            assert {:ok, %{closed: true}} = close_ssh(fixture, ssh.ticket)
            %{leases | ssh: nil, closed_ssh: [ssh.ticket | leases.closed_ssh]}
          end
      end

    case leases.web do
      nil ->
        leases

      web ->
        if grants?(role, :web) do
          assert {:ok, renewed} = renew_web(fixture, web.ticket)
          assert renewed.binding == web.binding
          leases
        else
          denied(fixture, fn -> renew_web(fixture, web.ticket) end)
          assert {:ok, %{closed: true}} = close_web(fixture, web.ticket)
          %{leases | web: nil, closed_web: [web.ticket | leases.closed_web]}
        end
    end
  end

  @spec refuse_closed_leases(leases(), Fixture.t()) :: :ok
  defp refuse_closed_leases(leases, fixture) do
    for ticket <- leases.closed_ssh,
        do: denied(fixture, fn -> renew_ssh(fixture, ticket) end)

    for ticket <- leases.closed_web,
        do: denied(fixture, fn -> renew_web(fixture, ticket) end)

    :ok
  end

  @spec probe_inventory(Fixture.t(), role()) :: :ok
  defp probe_inventory(fixture, role) do
    expected = grants?(role, :inventory)
    assert {:ok, %{items: items}} = Compute.list_vms(%{}, actor: fixture.member)
    assert Enum.any?(items, &(&1.id == fixture.vm.id)) == expected

    if expected do
      assert {:ok, vm} = Compute.get_vm(%{vm_id: fixture.vm.id}, actor: fixture.member)
      assert vm.id == fixture.vm.id
    else
      denied(fixture, fn -> Compute.get_vm(%{vm_id: fixture.vm.id}, actor: fixture.member) end)
    end

    :ok
  end

  # @cc [owner:ghuntley,label:verification] sharing-matrix-terminal-modes
  # Terminal open MUST follow current read membership for an owned session; the
  # consumed one-use ticket mode MUST be rw exactly when the current role row
  # retains write. Refused opens and tickets MUST leave the durable inventory
  # untouched.
  @spec probe_terminal(Fixture.t(), role()) :: :ok
  defp probe_terminal(fixture, role) do
    Fixture.fresh(fixture)
    assert Authority.writable?(fixture.vm.id, fixture.member) == grants?(role, :terminal_write)

    if grants?(role, :terminal_read) do
      assert {:ok, %Session{} = session} = open_terminal(fixture)
      assert {:ok, ticket} = Authority.ticket(session, fixture.member)

      expected_mode = if grants?(role, :terminal_write), do: :rw, else: :ro
      assert {:ok, %{session_id: session_id, mode: mode}} = Tickets.consume(ticket)
      assert session_id == session.id
      assert mode == expected_mode
    else
      denied(fixture, fn -> open_terminal(fixture) end)
    end

    :ok
  end

  @spec probe_ssh(leases(), Fixture.t(), role()) :: leases()
  defp probe_ssh(leases, fixture, role) do
    Fixture.fresh(fixture)

    case {leases.ssh, grants?(role, :ssh)} do
      {nil, true} ->
        assert {:ok, ssh} = open_ssh(fixture, fixture.label)
        assert ssh.binding.vm_id == fixture.vm.id
        assert ssh.binding.service == :ssh
        assert {:ok, _} = renew_ssh(fixture, ssh.ticket)
        %{leases | ssh: ssh}

      {nil, false} ->
        denied(fixture, fn -> open_ssh(fixture, fixture.label) end)
        leases

      {_live, _} ->
        leases
    end
  end

  # @cc [owner:ghuntley,label:verification] sharing-matrix-web-flow
  # Private web begin is a gateway precondition; the member-visible approval,
  # exchange, stream opening and renewal MUST follow the current role row.
  # A credential minted under an earlier role MUST NOT open a stream after the
  # role lost web.
  @spec probe_web(leases(), Fixture.t(), role()) :: leases()
  defp probe_web(leases, fixture, role) do
    Fixture.fresh(fixture)
    started = begin_login(fixture, fixture.label)

    if grants?(role, :web) do
      assert {:ok, approved} = authorize(fixture, started.ticket)

      assert {:ok, %{cookie: cookie}} =
               exchange(fixture, Map.put(approved, :state, started.state))

      assert {:ok, opened} = open_web(fixture, cookie, fixture.label)
      assert opened.user_id == fixture.member.id
      assert opened.binding.service == :web

      leases =
        if leases.web do
          assert {:ok, %{closed: true}} = close_web(fixture, leases.web.ticket)
          %{leases | web: nil, closed_web: [leases.web.ticket | leases.closed_web]}
        else
          leases
        end

      leases = %{leases | web: opened, cookie: cookie}
      assert {:ok, _} = renew_web(fixture, opened.ticket)
      leases
    else
      denied(fixture, fn -> authorize(fixture, started.ticket) end)

      if leases.cookie,
        do: denied(fixture, fn -> open_web(fixture, leases.cookie, fixture.label) end)

      leases
    end
  end

  @spec settle(Fixture.t(), leases()) :: :ok
  defp settle(fixture, leases) do
    if leases.ssh,
      do: assert({:ok, %{closed: true}} = close_ssh(fixture, leases.ssh.ticket))

    if leases.web,
      do: assert({:ok, %{closed: true}} = close_web(fixture, leases.web.ticket))

    for ticket <-
          if(leases.ssh, do: [leases.ssh.ticket], else: []) ++ leases.closed_ssh,
        do: denied(fixture, fn -> renew_ssh(fixture, ticket) end)

    for ticket <-
          if(leases.web, do: [leases.web.ticket], else: []) ++ leases.closed_web,
        do: denied(fixture, fn -> renew_web(fixture, ticket) end)

    assert {:ok, %{items: [_]}} = Compute.list_vms(%{}, actor: fixture.owner)
    :ok
  end

  @spec probe_vm(%{atom() => vm_state()}, Fixture.t(), [Compute.VirtualMachine.t()], atom()) ::
          %{atom() => vm_state()}
  defp probe_vm(states, fixture, vms, which) do
    Fixture.fresh(fixture)
    state = Map.fetch!(states, which)
    role = state.role

    assert {:ok, %{items: items}} = Compute.list_vms(%{}, actor: fixture.member)
    assert Enum.any?(items, &(&1.id == state.vm.id)) == grants?(role, :inventory)

    if grants?(role, :terminal_read) do
      assert {:ok, %Session{}} =
               Authority.open_session(state.vm, fixture.member, "root", "xterm-256color")
    else
      denied_vm(fixture, vms, fn ->
        Authority.open_session(state.vm, fixture.member, "root", "xterm-256color")
      end)
    end

    state =
      case {state.leases.ssh, grants?(role, :ssh)} do
        {nil, true} ->
          assert {:ok, ssh} = open_ssh(fixture, state.label)
          %{state | leases: %{state.leases | ssh: ssh}}

        {nil, false} ->
          denied_vm(fixture, vms, fn -> open_ssh(fixture, state.label) end)
          state

        {ssh, true} ->
          assert {:ok, _} = renew_ssh(fixture, ssh.ticket)
          state

        {ssh, false} ->
          denied_vm(fixture, vms, fn -> renew_ssh(fixture, ssh.ticket) end)
          assert {:ok, %{closed: true}} = close_ssh(fixture, ssh.ticket)

          %{
            state
            | leases: %{
                state.leases
                | ssh: nil,
                  closed_ssh: [ssh.ticket | state.leases.closed_ssh]
              }
          }
      end

    state =
      case {state.leases.web, grants?(role, :web)} do
        {web, false} when not is_nil(web) ->
          denied_vm(fixture, vms, fn -> renew_web(fixture, web.ticket) end)
          assert {:ok, %{closed: true}} = close_web(fixture, web.ticket)

          %{
            state
            | leases: %{
                state.leases
                | web: nil,
                  closed_web: [web.ticket | state.leases.closed_web]
              }
          }

        {nil, true} ->
          started = begin_login(fixture, state.label)
          assert {:ok, approved} = authorize(fixture, started.ticket)

          assert {:ok, %{cookie: cookie}} =
                   exchange(fixture, Map.put(approved, :state, started.state))

          assert {:ok, opened} = open_web(fixture, cookie, state.label)
          assert {:ok, _} = renew_web(fixture, opened.ticket)
          %{state | leases: %{state.leases | web: opened, cookie: cookie}}

        {nil, false} ->
          started = begin_login(fixture, state.label)
          denied_vm(fixture, vms, fn -> authorize(fixture, started.ticket) end)
          state

        {web, true} ->
          assert {:ok, _} = renew_web(fixture, web.ticket)
          state
      end

    Map.put(states, which, state)
  end

  # @cc [owner:ghuntley,label:verification] sharing-matrix-refusal-equality
  # Every refused entry MUST leave the complete scoped durable inventory
  # byte-identical: expected failures roll back without partial rows.
  @spec denied(Fixture.t(), (-> term())) :: :ok
  defp denied(fixture, fun) do
    denied_vm(fixture, [fixture.vm], fun)
  end

  @spec denied_vm(Fixture.t(), [Compute.VirtualMachine.t()], (-> term())) :: :ok
  defp denied_vm(fixture, vms, fun) do
    before = Fixture.inventory(fixture, vms)
    assert {:error, _} = fun.()
    assert Fixture.inventory(fixture, vms) == before
    :ok
  end

  @spec open_terminal(Fixture.t()) :: {:ok, Session.t()} | {:error, atom()}
  defp open_terminal(fixture),
    do: Authority.open_session(fixture.vm, fixture.member, "root", "xterm-256color")

  @spec open_ssh(Fixture.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defp open_ssh(fixture, label),
    do:
      Ingress.open_ssh(
        %{
          service_token: fixture.service_token,
          public_key: fixture.member_public_key,
          label: label
        },
        actor: SystemActor.compute()
      )

  @spec renew_ssh(Fixture.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defp renew_ssh(fixture, ticket),
    do:
      Ingress.renew_ssh(
        %{service_token: fixture.service_token, session_token: ticket},
        actor: SystemActor.compute()
      )

  @spec close_ssh(Fixture.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defp close_ssh(fixture, ticket),
    do:
      Ingress.close_ssh(
        %{service_token: fixture.service_token, session_token: ticket},
        actor: SystemActor.compute()
      )

  @spec begin_login(Fixture.t(), String.t()) :: %{ticket: String.t(), state: String.t()}
  defp begin_login(fixture, label) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    digest = Base.encode16(:crypto.hash(:sha256, state), case: :lower)

    assert {:ok, started} =
             Ingress.begin_web_login(
               %{
                 service_token: fixture.service_token,
                 label: label,
                 app_port: 0,
                 state_digest: digest
               },
               actor: SystemActor.compute()
             )

    %{ticket: started.ticket, state: state}
  end

  @spec authorize(Fixture.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defp authorize(fixture, ticket),
    do:
      Ingress.authorize_web_login(%{ticket: ticket, login_token: fixture.member_token},
        actor: fixture.member
      )

  @spec exchange(Fixture.t(), map()) :: {:ok, map()} | {:error, term()}
  defp exchange(fixture, approved),
    do:
      Ingress.exchange_web_login(
        %{
          service_token: fixture.service_token,
          ticket: approved.ticket,
          code: approved.code,
          state: approved.state
        },
        actor: SystemActor.compute()
      )

  @spec open_web(Fixture.t(), String.t() | nil, String.t()) :: {:ok, map()} | {:error, term()}
  defp open_web(fixture, cookie, label),
    do:
      Ingress.open_web(
        %{
          service_token: fixture.service_token,
          label: label,
          app_port: 0,
          cookie: cookie
        },
        actor: SystemActor.compute()
      )

  @spec renew_web(Fixture.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defp renew_web(fixture, ticket),
    do:
      Ingress.renew_web(
        %{service_token: fixture.service_token, stream_token: ticket},
        actor: SystemActor.compute()
      )

  @spec close_web(Fixture.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defp close_web(fixture, ticket),
    do:
      Ingress.close_web(
        %{service_token: fixture.service_token, stream_token: ticket},
        actor: SystemActor.compute()
      )

  @spec approve_pending(Fixture.t()) :: map()
  defp approve_pending(fixture) do
    started = begin_login(fixture, fixture.label)
    assert {:ok, approved} = authorize(fixture, started.ticket)
    Map.put(approved, :state, started.state)
  end

  @spec web_chain(leases(), Fixture.t()) :: leases()
  defp web_chain(leases, fixture) do
    started = begin_login(fixture, fixture.label)
    assert {:ok, approved} = authorize(fixture, started.ticket)
    assert {:ok, %{cookie: cookie}} = exchange(fixture, Map.put(approved, :state, started.state))
    assert {:ok, opened} = open_web(fixture, cookie, fixture.label)
    %{leases | web: opened, cookie: cookie}
  end
end
