defmodule Marshall.Compute do
  @moduledoc "Hosts, capacity admission, VM intent and durable provisioning operations."
  use Ash.Domain, otp_app: :marshall, extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource Marshall.Compute.LifecycleEvent do
      define :lifecycle_history, action: :list_for_admin
    end

    resource Marshall.Compute.Host do
      define :admin_configure_host, action: :configure_for_admin
    end

    resource Marshall.Compute.HostDrain

    resource Marshall.Compute.Evacuation do
      define :admin_nodes, action: :nodes_for_admin
      define :admin_node, action: :inspect_for_admin
      define :admin_node_capacity, action: :capacity_for_admin
      define :admin_node_timeline, action: :timeline_for_admin
      define :request_evacuation, action: :request_for_admin
      define :control_evacuation, action: :control_for_admin
      define :approve_evacuation_downtime, action: :approve_for_admin
      define :replan_evacuation_workload, action: :replan_for_admin
    end

    resource Marshall.Compute.EvacuationItem
    resource Marshall.Compute.EnrollmentOperation
    resource Marshall.Compute.HostCredential
    resource Marshall.Compute.HostSession
    resource Marshall.Compute.StoragePool
    resource Marshall.Compute.WorkloadPlacement
    resource Marshall.Compute.Relocation
    resource Marshall.Compute.RelocationRetry
    resource Marshall.Compute.CleanupRequest
    resource Marshall.Compute.ReadinessRequest
    resource Marshall.Compute.ProbeRequest
    resource Marshall.Compute.SourcePermitRequest
    resource Marshall.Compute.TransferSlot
    resource Marshall.Compute.Reservation
    resource Marshall.Compute.CloneEffect
    resource Marshall.Compute.CloneRequest
    resource Marshall.Compute.ResizeRequest
    resource Marshall.Compute.Operation
    resource Marshall.Compute.WakeRequest
    resource Marshall.Compute.WakeRequestKey
    resource Marshall.Compute.ServiceLevelAttempt
    resource Marshall.Compute.WorkflowServiceLevelAttempt
    resource Marshall.Compute.ServiceLevelTotal
    resource Marshall.Compute.PhysicalOutcome
    resource Marshall.Compute.Image
    resource Marshall.Compute.NetworkAddress
    resource Marshall.Compute.WorkspaceSource

    resource Marshall.Compute.VirtualMachine do
      define :get_vm, action: :get_for_user
      define :resolve_vm, action: :resolve_for_user
      define :list_vms, action: :list_for_user
      define :pinned_vms, action: :pinned_for_user
      define :list_vms_for_admin, action: :list_for_admin
      define :catalog, action: :catalog
      define :repository_launch_request, action: :repository_launch_request
      define :provision, action: :provision
      define :clone, action: :clone
      define :get_clone, action: :get_clone
      define :list_clones, action: :list_clones
      define :retry_clone, action: :retry_clone
      define :cancel_clone, action: :cancel_clone
      define :resize, action: :resize
      define :retry_resize, action: :retry_resize
      define :cancel_resize, action: :cancel_resize
      define :update_reflection_metadata, action: :set_reflection_metadata
      define :lifecycle, action: :lifecycle
      define :relocate, action: :relocate
      define :cancel_relocation, action: :cancel_relocation
      define :retry_relocation, action: :retry_relocation
    end
  end
end
