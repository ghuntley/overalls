defmodule Marshall.TerminalFixtures do
  @moduledoc false
  import Marshall.ComputeFixtures
  alias Marshall.Compute.{Credentials, Host, Ledger, Operation, ProvisionerControl}

  def terminal_fixture(overrides \\ %{}) do
    machine = "sha256:" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    fixture = host_fixture(%{machine_id: machine})

    fixture = %{
      fixture
      | report: %{
          fixture.report
          | inventory: Map.put(fixture.report.inventory, "terminal_protocol", 2)
        }
    }

    owner = user()

    # @cc [owner:ghuntley,label:verification] terminal-fixture-host-identity
    # The reported machine identity MUST belong to the host chosen for this VM.
    # Competing test hosts may be disabled only during admission and MUST be
    # restored even if provisioning fails; capacity itself stays measured.
    other_hosts =
      Host
      |> Ledger.read!()
      |> Enum.filter(&(&1.id != fixture.host.id and &1.enabled))

    Enum.each(other_hosts, &Ledger.update!(&1, :configure, %{enabled: false}))

    vm =
      try do
        {:ok, vm} = Marshall.Compute.provision(request(overrides), actor: owner)
        vm
      after
        Enum.each(other_hosts, &Ledger.update!(&1, :configure, %{enabled: true}))
      end

    [operation] = Ledger.read!(Operation, vm_id: vm.id)
    {:ok, credential} = Credentials.rotate(vm.host_id, 3600)
    connection = connect(credential.token, machine)

    {:ok, _} =
      ProvisionerControl.exchange_execution(
        credential.token,
        Map.merge(connection, %{
          report: fixture.report,
          acknowledgements: [],
          outcomes: [
            %{
              id: Ash.UUID.generate(),
              vm_id: vm.id,
              placement_id: operation.placement_id,
              execution_epoch: operation.execution_epoch,
              operation_id: operation.id,
              generation: vm.generation,
              sequence: 1,
              state: :running,
              compute_empty: false,
              disk_present: true,
              cleanup_complete: false,
              reason: :none
            }
          ]
        })
      )

    Map.merge(fixture, %{
      owner: owner,
      vm: vm,
      credential: credential,
      connection: connection,
      machine: machine,
      token: user_token(owner)
    })
  end

  def connect(token, machine) do
    id = Ash.UUID.generate()

    {:ok, session} =
      ProvisionerControl.open_execution(token, %{session_id: id, machine_id: machine})

    %{session_id: id, epoch: session["epoch"]}
  end

  def user_token(user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    token
  end

  @spec terminal_session(map(), Marshall.Accounts.User.t(), String.t(), String.t()) ::
          {:ok, Marshall.Terminal.Session.t()} | {:error, atom()}
  def terminal_session(context, user, _token, id \\ Ash.UUID.generate()),
    do: Marshall.Terminal.Authority.open_session(context.vm, user, "root", "xterm-256color", id)

  @typedoc "The six-field SSH roster/host-certificate boot binding wire."
  @type roster_binding :: %{String.t() => String.t() | pos_integer()}

  # @cc [owner:ghuntley,label:verification] roster-binding-fixture-current-boot
  # The fixture binding MUST name the VM's newest provision/start operation for
  # its current placement, execution epoch and generation; it never invents an
  # operation, so Marshall still decides whether that boot may read a roster.
  @spec roster_binding(Marshall.Compute.VirtualMachine.t()) :: roster_binding()
  def roster_binding(vm) do
    operation =
      Ledger.read!(Operation, vm_id: vm.id)
      |> Enum.filter(
        &(&1.kind in [:provision, :start, :resume] and &1.placement_id == vm.current_placement_id and
            &1.execution_epoch == vm.execution_epoch and &1.generation == vm.generation)
      )
      |> Enum.max_by(& &1.inserted_at, DateTime)

    %{
      "host_id" => vm.host_id,
      "vm_id" => vm.id,
      "placement_id" => vm.current_placement_id,
      "execution_epoch" => vm.execution_epoch,
      "generation" => vm.generation,
      "operation_id" => operation.id
    }
  end

  def grant(context, member, role) do
    Marshall.Access.set_access(
      %{
        vm_id: context.vm.id,
        email: to_string(member.email),
        role: role,
        idempotency_key: Ash.UUID.generate()
      },
      actor: context.owner
    )
  end

  # @cc [owner:ghuntley,label:integration] fake-stream-replies-synthetic-controls
  # The stream fixture MUST only answer catalogued control messages with
  # synthetic identifiers; it never carries terminal bytes or host secrets.
  #
  # `start` owns the stream's lifetime: ExUnit's start_supervised!/1 for a
  # test, or a generated-case starter such as the test-time
  # `Overalls.HegelFixtures.start_supervised!/1` for one Hegel case. The
  # starter is passed in because that helper is a script loaded by
  # test_helper.exs, never a compiled test-support module Dialyzer can see.
  @spec stream_fixture(String.t(), (map() -> pid())) :: pid()
  def stream_fixture(host_id, start \\ &ExUnit.Callbacks.start_supervised!/1)
      when is_function(start, 1) do
    owner = self()
    ref = make_ref()

    pid =
      start.(%{
        id: ref,
        restart: :temporary,
        start:
          {Task, :start_link,
           [
             fn ->
               counter = :counters.new(1, [])
               :ok = Marshall.Terminal.Relay.register(Marshall.Terminal.Relay, host_id, self())
               send(owner, {:stream_ready, ref})
               receive_loop(counter, [], %{})
             end
           ]}
      })

    receive do
      {:stream_ready, ^ref} -> pid
    after
      5000 -> raise "synthetic terminal stream registration timed out"
    end
  end

  @type fake_session :: %{
          guest_session_id: pos_integer(),
          user: String.t(),
          cols: pos_integer(),
          rows: pos_integer(),
          viewers: non_neg_integer(),
          alive: boolean(),
          created_ms: non_neg_integer(),
          last_ms: non_neg_integer()
        }
  @type creations :: %{String.t() => pos_integer() | :cancelled}

  @spec receive_loop(:counters.counters_ref(), [fake_session()], creations(), boolean()) ::
          no_return()
  defp receive_loop(counter, sessions, creations, lose_kill_reply? \\ false) do
    receive do
      {:lose_next_kill_reply, caller, reference} ->
        send(caller, {:kill_reply_loss_armed, reference})
        receive_loop(counter, sessions, creations, true)

      {:guest_exited, guest_session_id} ->
        receive_loop(
          counter,
          Enum.reject(sessions, &(&1.guest_session_id == guest_session_id)),
          creations,
          lose_kill_reply?
        )

      {:relay_control, request} ->
        :counters.add(counter, 1, 1)
        guest_session_id = :counters.get(counter, 1)

        {reply, sessions, creations} =
          synthetic_reply(request.message, guest_session_id, sessions, creations)

        lost? = lose_kill_reply? and request.message.type == :kill
        reply = if lost?, do: {:error, :stream_unavailable}, else: reply
        Marshall.Terminal.Relay.reply(request, reply)
        receive_loop(counter, sessions, creations, lose_kill_reply? and not lost?)

      {:viewer_attach, request} ->
        :counters.add(counter, 1, 1)
        channel = :counters.get(counter, 1)

        send(
          request.caller,
          {:terminal_attached,
           %{
             type: :attached,
             replay_bytes: 0,
             channel: channel,
             ok: true,
             guest_session_id: request.message.guest_session_id,
             from: request.message.cursor,
             reason: nil
           }}
        )

        receive_loop(counter, sessions, creations, lose_kill_reply?)

      _other ->
        receive_loop(counter, sessions, creations, lose_kill_reply?)
    end
  end

  @spec synthetic_reply(map(), pos_integer(), [fake_session()], creations()) ::
          {{:ok, map()}, [fake_session()], creations()}
  defp synthetic_reply(
         %{type: :create, request_id: request_id} = message,
         id,
         sessions,
         creations
       ) do
    previous = creations[request_id]

    if is_nil(previous) do
      session = %{
        guest_session_id: id,
        user: message.user,
        cols: message.cols,
        rows: message.rows,
        viewers: 0,
        alive: true,
        created_ms: 1,
        last_ms: 1
      }

      reply = %{
        type: :created,
        request_id: request_id,
        ok: true,
        channel: 0,
        guest_session_id: id,
        reason: nil
      }

      {{:ok, reply}, [session | sessions], Map.put(creations, request_id, id)}
    else
      live = Enum.any?(sessions, &(&1.guest_session_id == previous))

      reply = %{
        type: :created,
        request_id: request_id,
        ok: live,
        channel: 0,
        guest_session_id: if(live, do: previous),
        reason: if(live, do: nil, else: :rejected)
      }

      {{:ok, reply}, sessions, creations}
    end
  end

  defp synthetic_reply(%{type: :creation_query, request_id: id}, _, sessions, creations) do
    guest_id = creations[id]
    live = Enum.any?(sessions, &(&1.guest_session_id == guest_id))

    state =
      cond do
        live -> :running
        is_integer(guest_id) -> :exited
        true -> :unknown
      end

    reply = %{
      type: :creation_status,
      request_id: id,
      state: state,
      guest_session_id: if(is_integer(guest_id), do: guest_id)
    }

    {{:ok, reply}, sessions, creations}
  end

  defp synthetic_reply(%{type: :creation_cancel, request_id: id}, _, sessions, creations) do
    sessions = Enum.reject(sessions, &(&1.guest_session_id == creations[id]))

    {{:ok, %{type: :creation_cancelled, request_id: id, ok: true}}, sessions,
     Map.put(creations, id, :cancelled)}
  end

  defp synthetic_reply(%{type: :listing, vm_id: vm_id}, _, sessions, creations),
    do: {{:ok, %{type: :listed, vm_id: vm_id, sessions: sessions}}, sessions, creations}

  defp synthetic_reply(%{type: :kill, guest_session_id: id} = message, _, sessions, creations) do
    reply = message |> Map.put(:type, :killed) |> Map.put(:ok, true)
    {{:ok, reply}, Enum.reject(sessions, &(&1.guest_session_id == id)), creations}
  end

  defp synthetic_reply(%{type: :boot_log, vm_id: vm_id}, _, sessions, creations),
    do: {{:ok, %{type: :boot_log_data, vm_id: vm_id, next: 0, bytes: ""}}, sessions, creations}

  defp synthetic_reply(_, _, sessions, creations), do: {{:ok, %{}}, sessions, creations}

  # @cc [owner:ghuntley,label:verification] terminal-generated-mailbox-isolation
  # Completed generated cases MUST retire their fixture notifications before a
  # successor case measures viewer mailbox pressure. Unrelated messages remain.
  @spec drain_case_messages() :: :ok
  def drain_case_messages do
    receive do
      {:terminal_attached, _} -> drain_case_messages()
      {:terminal_output, _} -> drain_case_messages()
      {:terminal_closed, _} -> drain_case_messages()
      :terminal_slow_viewer -> drain_case_messages()
      :renew_location -> drain_case_messages()
      {:expire_request, _, _} -> drain_case_messages()
    after
      0 -> :ok
    end
  end
end
