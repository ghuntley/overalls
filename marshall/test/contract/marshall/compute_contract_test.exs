defmodule MarshallComputeContractTest do
  use Covenant.Case, component: "marshall.compute"

  @tag obligation: "marshall.compute.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Marshall.Compute,
      Marshall.Compute.AddressAllocation,
      Marshall.Compute.AdminHostConfiguration,
      Marshall.Compute.AdminViews,
      Marshall.Compute.Admission,
      Marshall.Compute.AdvanceDrain,
      Marshall.Compute.AdvanceEvacuation,
      Marshall.Compute.Budget,
      Marshall.Compute.CapacityPolicy,
      Marshall.Compute.Changes.ValidateImage,
      Marshall.Compute.CleanupRequest,
      Marshall.Compute.CloneCoordinator,
      Marshall.Compute.CloneDispatch,
      Marshall.Compute.CloneEffect,
      Marshall.Compute.CloneEffects,
      Marshall.Compute.CloneFailure,
      Marshall.Compute.CloneGuard,
      Marshall.Compute.ClonePlacement,
      Marshall.Compute.CloneRequest,
      Marshall.Compute.Cloning,
      Marshall.Compute.CommandSnapshot,
      Marshall.Compute.CredentialLifetime,
      Marshall.Compute.Credentials,
      Marshall.Compute.DestinationReceiveDispatch,
      Marshall.Compute.Dispatch,
      Marshall.Compute.Drains,
      Marshall.Compute.Enrollment,
      Marshall.Compute.EnrollmentOperation,
      Marshall.Compute.EnrollmentPreparation,
      Marshall.Compute.EnrollmentRequest,
      Marshall.Compute.Error,
      Marshall.Compute.Evacuation,
      Marshall.Compute.EvacuationActions,
      Marshall.Compute.EvacuationItem,
      Marshall.Compute.EvacuationViews,
      Marshall.Compute.Evacuations,
      Marshall.Compute.ExpireLifecycleEvents,
      Marshall.Compute.Host,
      Marshall.Compute.HostCredential,
      Marshall.Compute.HostDrain,
      Marshall.Compute.HostLiveness,
      Marshall.Compute.HostReports,
      Marshall.Compute.HostSession,
      Marshall.Compute.Image,
      Marshall.Compute.Images,
      Marshall.Compute.Ledger,
      Marshall.Compute.Lifecycle,
      Marshall.Compute.LifecycleAudit,
      Marshall.Compute.LifecycleEvent,
      Marshall.Compute.LifecycleHistory,
      Marshall.Compute.LifecycleLog,
      Marshall.Compute.NativeGuid,
      Marshall.Compute.NetworkAddress,
      Marshall.Compute.Operation,
      Marshall.Compute.Outcomes,
      Marshall.Compute.PhysicalOutcome,
      Marshall.Compute.ProbeDispatch,
      Marshall.Compute.ProbeRequest,
      Marshall.Compute.ProbeRequestPayload,
      Marshall.Compute.Profiles,
      Marshall.Compute.ProvisionerControl,
      Marshall.Compute.ProvisionerRequests,
      Marshall.Compute.ReadinessRequest,
      Marshall.Compute.Relocation,
      Marshall.Compute.RelocationAdmission,
      Marshall.Compute.RelocationAdvance,
      Marshall.Compute.RelocationCancellation,
      Marshall.Compute.RelocationCapacity,
      Marshall.Compute.RelocationCleanup,
      Marshall.Compute.RelocationCoordinator,
      Marshall.Compute.RelocationDeletion,
      Marshall.Compute.RelocationDestinationCleanups,
      Marshall.Compute.RelocationDestinationRevocations,
      Marshall.Compute.RelocationGuard,
      Marshall.Compute.RelocationImports,
      Marshall.Compute.RelocationKeyDispatch,
      Marshall.Compute.RelocationKeyRetirement,
      Marshall.Compute.RelocationKeys,
      Marshall.Compute.RelocationProbes,
      Marshall.Compute.RelocationReadiness,
      Marshall.Compute.RelocationReadinessState,
      Marshall.Compute.RelocationReceives,
      Marshall.Compute.RelocationRestoration,
      Marshall.Compute.RelocationRetry,
      Marshall.Compute.RelocationRetryAdmission,
      Marshall.Compute.RelocationRevocations,
      Marshall.Compute.RelocationSnapshotCleanups,
      Marshall.Compute.RelocationSources,
      Marshall.Compute.RelocationStatus,
      Marshall.Compute.Reservation,
      Marshall.Compute.Resize,
      Marshall.Compute.ResizeRequest,
      Marshall.Compute.RestartCapacity,
      Marshall.Compute.ServiceLevelAdmission,
      Marshall.Compute.ServiceLevelAttempt,
      Marshall.Compute.ServiceLevelPublisher,
      Marshall.Compute.ServiceLevelTotal,
      Marshall.Compute.ServiceLevelTotals,
      Marshall.Compute.ServiceLevels,
      Marshall.Compute.SourcePermitDispatch,
      Marshall.Compute.SourcePermitRequest,
      Marshall.Compute.SourceRequestPayload,
      Marshall.Compute.StartupHolds,
      Marshall.Compute.StoragePool,
      Marshall.Compute.TransferDescriptor,
      Marshall.Compute.TransferEndpoint,
      Marshall.Compute.TransferPublicKey,
      Marshall.Compute.TransferSlot,
      Marshall.Compute.TransferSlots,
      Marshall.Compute.Views,
      Marshall.Compute.VirtualMachine,
      Marshall.Compute.WorkflowServiceLevelAttempt,
      Marshall.Compute.WorkflowServiceLevels,
      Marshall.Compute.WorkloadPlacement,
      Marshall.Compute.WorkspaceSource,
      Marshall.Control.Concurrency,
      Marshall.Control.FaultGate,
      Marshall.Control.Hints,
      Marshall.Control.Hints.Change,
      Marshall.Control.Hints.Hosts,
      Marshall.Control.Hints.Relay,
      Marshall.Control.Service,
      Marshall.Control.Services.Audi,
      Marshall.Control.Services.Galileo,
      Marshall.Control.Services.Lilly,
      Marshall.Control.Services.Porsche,
      Marshall.Control.Services.Peach,
      Marshall.Control.Services.Ziggy,
      Marshall.Control.Socket
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "marshall.compute.I3"
  test "inception default shape preserves minimum resources" do
    shape =
      Marshall.Compute.Profiles.default_shape(:inception, %{
        minimum_memory_bytes: 34_359_738_368,
        minimum_disk_bytes: 68_719_476_736
      })

    # The profile's declared defaults are an API contract, not just lower
    # bounds. Keeping these exact values catches accidental drift (for example
    # changing the form's default while leaving admission's minimum intact).
    assert shape == %{
             vcpu: 16,
             memory_bytes: 34_359_738_368,
             disk_bytes: 68_719_476_736
           }

    ordinary =
      Marshall.Compute.Profiles.default_shape(:standard, %{
        minimum_memory_bytes: 3,
        minimum_disk_bytes: 4
      })

    assert ordinary.vcpu == 1
    assert ordinary.memory_bytes >= 1_048_576
    assert ordinary.disk_bytes >= 2_147_483_648
  end

  @tag obligation: "marshall.compute.I2"
  test "inception admission enforces its configured image and resource minima" do
    previous = Application.get_env(:marshall, :inception_image_id)
    Application.put_env(:marshall, :inception_image_id, "sha256:" <> String.duplicate("a", 64))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:marshall, :inception_image_id, previous),
        else: Application.delete_env(:marshall, :inception_image_id)
    end)

    request = %{
      profile: :inception,
      image_id: "sha256:" <> String.duplicate("a", 64),
      vcpu: 16,
      memory_bytes: 34_359_738_368,
      disk_bytes: 68_719_476_736
    }

    assert :ok = Marshall.Compute.Profiles.validate(request)

    assert {:error, :profile_image_mismatch} =
             Marshall.Compute.Profiles.validate(%{
               request
               | image_id: "sha256:" <> String.duplicate("b", 64)
             })

    assert {:error, :image_requirements_not_met} =
             Marshall.Compute.Profiles.validate(%{request | vcpu: 1})

    assert Marshall.Compute.Profiles.host_ready?(request, %{
             "inception_image_id" => request.image_id
           })

    refute Marshall.Compute.Profiles.host_ready?(request, %{
             "inception_image_id" => "sha256:" <> String.duplicate("b", 64)
           })
  end

  @tag obligation: "marshall.compute.I4"
  test "the owner-pin refusal is a closed compute reason across the SSH control API" do
    error = Marshall.Compute.Error.exception(reason: :machine_pinned)
    assert Exception.message(error) == "Compute request rejected: machine_pinned"

    assert {:error, 409, "machine_pinned"} =
             Marshall.SSH.ControlRequests.classify({:error, :machine_pinned})

    assert {:error, 409, "pin_limit"} =
             Marshall.SSH.ControlRequests.classify({:error, :pin_limit})
  end

  @tag obligation: "marshall.compute.I5"
  test "a Lilly-limited socket runs a bounded FIFO and expires stale queued requests" do
    previous = Application.get_env(:marshall, Marshall.Control.Concurrency)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:marshall, Marshall.Control.Concurrency, previous),
        else: Application.delete_env(:marshall, Marshall.Control.Concurrency)
    end)

    Application.put_env(:marshall, Marshall.Control.Concurrency,
      lilly_running: 2,
      queue_deadline_ms: 5_000
    )

    state = Marshall.ControlSocketDriver.bound(%{test: self()})

    state =
      Enum.reduce(1..5, state, fn id, state ->
        {state, []} = Marshall.ControlSocketDriver.request(state, id, "stub.wait")
        state
      end)

    assert map_size(state.tasks) == 2 and :queue.len(state.queue) == 3
    assert_receive {:control_stub_started, 1, first}
    assert_receive {:control_stub_started, 2, second}
    refute_received {:control_stub_started, 3, _}

    send(first, :release)

    {state, [{1, {:ok, %{"n" => 1}}}]} =
      receive do
        {ref, _} = reply when is_reference(ref) ->
          Marshall.ControlSocketDriver.deliver(state, reply)
      end

    assert_receive {:control_stub_started, 3, third}
    assert map_size(state.tasks) == 2 and :queue.len(state.queue) == 2
    # The queued requests never start; stop the two blocked stub tasks.
    on_exit(fn -> Enum.each([second, third], &Process.exit(&1, :kill)) end)

    full =
      Enum.reduce(6..65, state, fn id, state ->
        {state, []} = Marshall.ControlSocketDriver.request(state, id, "stub.wait")
        state
      end)

    # Request 1 was answered, so 2..65 fill the advertised in_flight of 64.
    assert {_full, [{66, {:error, "busy"}}]} =
             Marshall.ControlSocketDriver.request(full, 66, "stub.wait")

    Application.put_env(:marshall, Marshall.Control.Concurrency,
      lilly_running: 1,
      queue_deadline_ms: 1
    )

    stale = Marshall.ControlSocketDriver.bound(%{test: self()})
    {stale, []} = Marshall.ControlSocketDriver.request(stale, 100, "stub.wait")
    {stale, []} = Marshall.ControlSocketDriver.request(stale, 101, "stub.wait")
    assert_receive {:control_stub_started, 100, holder}
    Process.sleep(5)
    send(holder, :release)

    reply =
      receive do
        {ref, {:ok, %{"n" => 100}}} = reply when is_reference(ref) -> reply
      end

    assert {_stale, [{100, {:ok, _}}, {101, {:error, "temporarily_unavailable"}}]} =
             Marshall.ControlSocketDriver.deliver(stale, reply)

    refute_received {:control_stub_started, 101, _}
  end
end
