defmodule Lilly.Events do
  @moduledoc """
  Catalog of reviewed structured-log events under ADR-0042.

  Lilly modules emit events through `Lilly.Events.emit/2`, which the
  shared catalog machinery validates at caller compile time (event
  name and metadata keys) and at runtime (UUID, fixed-atom, bounded integer
  and pid shapes). Message text is fixed here; call sites never interpolate
  payloads. Credentials, terminal bytes, native command arguments/output and
  key material must never be passed as event metadata; there is deliberately
  no string-valued metadata type.
  """

  # @cc [owner:ghuntley,label:security] lilly-structured-events-through-catalog
  # Production Lilly modules MUST emit diagnostic structured events only
  # through Lilly.Events.emit/2 with catalogued names and metadata keys.
  # Credentials, terminal bytes, native command arguments/output and key
  # material MUST NOT be passed as event metadata under any event.
  use Overalls.Diagnostics.Events.Catalog, service: :lilly

  defevent("lilly.image_prewarm_finished",
    message: "Image prewarming finished",
    metadata: [pool_id: :uuid, outcome: :atom, duration_ms: :int]
  )

  defevent("lilly.image_template_quarantined",
    level: :warning,
    message: "Image template quarantined",
    metadata: [
      pool_id: :uuid,
      stage:
        {:enum,
         [
           :ready_validation,
           :verifying_native,
           :verifying_image_stage,
           :verifying_image_load,
           :verifying_digest,
           :verifying_image_id,
           :verifying_file_set,
           :verifying_identities,
           :sealing
         ]}
    ]
  )

  defevent("vm.disk_materialization_step",
    level: :info,
    message: "VM disk materialization step completed",
    metadata: [vm_id: :uuid, utility: :atom, duration_ms: :int]
  )

  defevent("vm.image_materialized",
    level: :info,
    message: "VM image materialized",
    metadata: [
      placement_id: :uuid,
      method: :atom,
      bytes: :int,
      source: :atom,
      template_record_id: {:uuid, :optional},
      template_incarnation: {:uuid, :optional}
    ]
  )

  defevent("lilly.template_sweep_finished",
    level: :info,
    message: "Unconfigured image templates swept",
    metadata: [pool_id: :uuid, outcome: :atom, stage: :atom]
  )

  defevent("vm.provisioning_ready",
    message: "Guest provisioning readiness committed",
    metadata: [placement_id: :uuid, execution_epoch: :int, generation: :int, duration_ms: :int]
  )

  defevent("lilly.roster_binding_refused",
    level: :warning,
    message: "Guest account roster binding refused",
    metadata: [stage: :atom, reason: :atom]
  )

  defevent("vm.trust_delivering",
    message: "Guest trust delivery started",
    metadata: [placement_id: :uuid, execution_epoch: :int]
  )

  defevent("vm.trust_installed",
    message: "Guest trust installation confirmed",
    metadata: [placement_id: :uuid, execution_epoch: :int]
  )

  defevent("vm.trust_failed",
    level: :warning,
    message: "Guest trust installation unconfirmed",
    metadata: [placement_id: :uuid, execution_epoch: :int]
  )

  defevent("vm.trust_skipped",
    message: "Guest trust delivery skipped for a guest without agents",
    metadata: [placement_id: :uuid, execution_epoch: :int]
  )

  defevent("vm.provisioning_unattested",
    message: "Guest without agents running without a readiness proof",
    metadata: [placement_id: :uuid, execution_epoch: :int, generation: :int]
  )

  defevent("lilly.terminal_creation_cancel_ack",
    message: "Guest acknowledged terminal creation cancellation",
    metadata: [request_id: :uuid]
  )

  defevent("lilly.terminal_creation_cancelled",
    message: "Terminal creation cancellation confirmed",
    metadata: [request_id: :uuid, placement_id: :uuid, execution_epoch: :int]
  )

  # Application and control channel
  defevent("lilly.started", message: "Lilly started", metadata: [])

  defevent("lilly.ingress_bridges_adopted",
    level: :info,
    message: "Detached ingress bridges reconciled after start",
    metadata: [adopting: :int, ended: :int, forgotten: :int]
  )

  defevent("lilly.ingress_bridge_ended",
    level: :info,
    message: "Detached ingress bridge ended by its keeper",
    metadata: [
      reason: {:enum, [:fenced, :unadopted, :unknown]},
      outcome: {:enum, [:ended, :end_unconfirmed]}
    ]
  )

  defevent("lilly.images_verified",
    message: "Configured image digest verification finished",
    metadata: [verified_images: :int, rejected_images: :int]
  )

  defevent("lilly.supervised_component_stopped",
    level: :warning,
    message: "Lilly supervised component stopped unexpectedly",
    metadata: [component: :atom, reason: :atom]
  )

  defevent("lilly.vm_actor_exit",
    level: :warning,
    message: "Lilly VM actor exited unexpectedly",
    metadata: [
      vm_id: :uuid,
      placement_id: :uuid,
      reason: :atom,
      source_module: :atom,
      source_function: :atom,
      source_arity: :int
    ]
  )

  defevent("lilly.control_connected",
    message: "Control channel connected",
    metadata: [host_id: :uuid]
  )

  defevent("lilly.control_recovered",
    message: "Control channel recovered",
    metadata: [host_id: :uuid]
  )

  defevent("lilly.control_unavailable",
    level: :warning,
    message: "Control channel unavailable",
    metadata: [host_id: :uuid, reason: :atom]
  )

  defevent("lilly.control_fenced",
    level: :warning,
    message: "Control channel fenced",
    metadata: [host_id: :uuid, reason: :atom]
  )

  defevent("lilly.control_exchange_failed",
    level: :warning,
    message: "Control exchange failed",
    metadata: [host_id: {:uuid, :optional}, utility: {:atom, :optional}, reason: :atom]
  )

  defevent("lilly.control_worker_unavailable",
    level: :warning,
    message: "Control worker unavailable",
    metadata: [utility: :atom, reason: :atom]
  )

  defevent("lilly.terminal_stream_connected",
    message: "Terminal stream connected",
    metadata: [host_id: :uuid]
  )

  defevent("lilly.terminal_stream_established",
    message: "Terminal stream established",
    metadata: [host_id: :uuid]
  )

  defevent("lilly.terminal_guest_retired",
    message: "Guest terminal session retired",
    metadata: [placement_id: :uuid, execution_epoch: :int]
  )

  defevent("lilly.terminal_stream_lost",
    level: :warning,
    message: "Terminal stream lost",
    metadata: [host_id: :uuid, reason: :atom]
  )

  # Privileged host utilities
  defevent("lilly.utility_unconfirmed",
    level: :warning,
    message: "Host utility unconfirmed",
    metadata: [
      utility: :atom,
      reason: :atom,
      duration_ms: {:int, :optional},
      lease_id: {:int, :optional}
    ]
  )

  defevent("lilly.collection_failed",
    level: :warning,
    message: "Capacity collection failed",
    metadata: [reason: :atom]
  )

  defevent("lilly.ownership_acquired",
    message: "Physical host ownership acquired",
    metadata: []
  )

  defevent("lilly.ownership_unconfirmed",
    level: :warning,
    message: "Physical host ownership unconfirmed",
    metadata: [reason: :atom]
  )

  # VM lifecycle
  defevent("vm.launched",
    message: "VM launched",
    metadata: [vm_id: :uuid, placement_id: :uuid, execution_epoch: :int, generation: :int]
  )

  defevent("vm.stopped",
    message: "VM stopped",
    metadata: [vm_id: :uuid, placement_id: :uuid, execution_epoch: :int]
  )

  defevent("vm.deleted", message: "VM deleted", metadata: [vm_id: :uuid, placement_id: :uuid])

  defevent("vm.failed",
    level: :warning,
    message: "VM failed",
    metadata: [vm_id: :uuid, placement_id: :uuid, reason: :atom]
  )

  defevent("vm.readiness_failed",
    level: :warning,
    message: "Guest readiness failed",
    metadata: [
      vm_id: :uuid,
      placement_id: :uuid,
      operation_id: :uuid,
      execution_epoch: :int,
      generation: :int,
      reason: :atom
    ]
  )

  defevent("vm.failure_cleanup_unconfirmed",
    level: :warning,
    message: "Failed execution cleanup unconfirmed",
    metadata: [vm_id: {:uuid, :optional}, placement_id: :uuid, stage: :atom, reason: :atom]
  )

  defevent("vm.adopted", message: "VM adopted", metadata: [vm_id: :uuid, placement_id: :uuid])

  defevent("vm.adoption_unconfirmed",
    level: :warning,
    message: "Running VM adoption unconfirmed",
    metadata: [vm_id: :uuid, placement_id: :uuid, reason: :atom]
  )

  defevent("vm.actor_stopped",
    level: :warning,
    message: "VM actor stopped",
    metadata: [vm_id: :uuid, placement_id: {:uuid, :optional}, reason: :atom]
  )

  defevent("vm.execution_deferred",
    level: :warning,
    message: "VM execution deferred until a host prerequisite recovers",
    metadata: [vm_id: :uuid, placement_id: :uuid, reason: :atom]
  )

  defevent("vm.observation_failed",
    level: :info,
    message: "VMM observation check failed",
    metadata: [placement_id: :uuid, check: :atom]
  )

  defevent("vm.watch_ended",
    level: :warning,
    message: "VM exit watcher ended and revoked the live proof",
    metadata: [vm_id: :uuid, placement_id: :uuid, reason: :atom]
  )

  defevent("vm.outcome_recorded",
    message: "VM outcome recorded",
    metadata: [vm_id: :uuid, placement_id: :uuid, outcome_state: :atom]
  )

  defevent("vm.launch_preparation_failed",
    level: :warning,
    message: "VM launch preparation failed",
    metadata: [vm_id: :uuid, stage: :atom, reason: :atom]
  )

  defevent("vm.disk_preparation_failed",
    level: :warning,
    message: "VM disk preparation failed",
    metadata: [vm_id: :uuid, stage: :atom]
  )

  defevent("vm.disk_readiness_failed",
    level: :warning,
    message: "Placement disk readiness failed",
    metadata: [placement_id: :uuid, stage: :atom, reason: :atom]
  )

  defevent("vm.disk_materialization_failed",
    level: :warning,
    message: "VM disk materialization failed",
    metadata: [vm_id: :uuid, utility: :atom, duration_ms: :int]
  )

  defevent("vm.execution_preempted",
    level: :info,
    message: "VM execution preempted by a newer command before its launch commit",
    metadata: [vm_id: :uuid, placement_id: :uuid]
  )

  defevent("lilly.lease_order_inverted",
    level: :warning,
    message: "Lease acquired in the reverse of an order seen earlier (possible deadlock)",
    metadata: [held_class: :atom, acquired_class: :atom]
  )

  defevent("lilly.pool_section",
    level: :info,
    message: "Slow or contended pool-locked section",
    metadata: [
      pool_id: :uuid,
      kind: :atom,
      outcome: :atom,
      wait_ms: :int,
      hold_ms: :int,
      items: :int
    ]
  )

  defevent("pool.snapshot_withheld",
    level: :warning,
    message: "Storage pool capacity snapshot withheld",
    metadata: [pool_id: :uuid, stage: :atom]
  )

  defevent("pool.snapshot_recovered",
    message: "Storage pool capacity snapshot recovered",
    metadata: [pool_id: :uuid]
  )

  defevent("vm.dataset_identity_probe_failed",
    level: :warning,
    message: "Retained disk pool identity probe failed",
    metadata: [placement_id: :uuid, stage: :atom, reason: :atom]
  )

  defevent("vm.dataset_observation_failed",
    level: :warning,
    message: "Retained disk pool observation check failed",
    metadata: [placement_id: :uuid, stage: :atom, reason: :atom]
  )

  defevent("vm.dataset_preparation_failed",
    level: :warning,
    message: "ZFS dataset preparation failed",
    metadata: [host_id: :uuid, vm_id: :uuid, reason: :atom]
  )

  # Privileged execution: units, jails, credentials, network
  defevent("lilly.unit_started",
    message: "VMM unit started",
    metadata: [vm_id: :uuid, placement_id: :uuid, generation: {:int, :optional}]
  )

  defevent("lilly.unit_stop_unconfirmed",
    level: :warning,
    message: "VMM unit stop unconfirmed",
    metadata: [vm_id: :uuid, placement_id: :uuid, reason: :atom]
  )

  defevent("lilly.jail_prepare_failed",
    level: :warning,
    message: "Jail preparation failed",
    metadata: [vm_id: :uuid, placement_id: :uuid, reason: :atom]
  )

  defevent("lilly.jail_cleanup_unconfirmed",
    level: :warning,
    message: "Jail cleanup unconfirmed",
    metadata: [vm_id: :uuid, placement_id: :uuid, reason: :atom]
  )

  defevent("lilly.vm_credentials_delivered",
    message: "VM credentials delivered",
    metadata: [vm_id: :uuid, placement_id: :uuid, execution_epoch: :int]
  )

  defevent("lilly.vm_credentials_delivery_failed",
    level: :warning,
    message: "VM credentials delivery failed",
    metadata: [vm_id: :uuid, placement_id: :uuid, reason: :atom]
  )

  defevent("lilly.workspace_source_delivered",
    message: "Workspace source reference accepted by the guest",
    metadata: [vm_id: :uuid, placement_id: :uuid]
  )

  defevent("lilly.workspace_source_delivery_failed",
    level: :warning,
    message: "Workspace source reference delivery failed",
    metadata: [vm_id: :uuid, placement_id: :uuid, reason: :atom]
  )

  defevent("lilly.network_attached",
    message: "Guest network attached",
    metadata: [vm_id: :uuid, placement_id: :uuid]
  )

  defevent("lilly.network_detached",
    message: "Guest network detached",
    metadata: [vm_id: :uuid, placement_id: :uuid]
  )

  defevent("lilly.network_setup_failed",
    level: :warning,
    message: "Guest network setup failed",
    metadata: [reason: :atom]
  )

  defevent("lilly.logging_preparation_failed",
    level: :warning,
    message: "VMM logging preparation failed",
    metadata: [placement_id: :uuid, reason: :atom]
  )

  # Storage
  defevent("lilly.zfs_destroyed",
    message: "Owned dataset destroyed",
    metadata: [placement_id: :uuid]
  )

  defevent("lilly.zfs_delete_unconfirmed",
    level: :warning,
    message: "Owned dataset deletion unconfirmed",
    metadata: [placement_id: :uuid, reason: :atom, stage: :atom]
  )

  defevent("lilly.zfs_namespace_mounts_detached",
    message: "Owned dataset mount copies detached from other namespaces",
    metadata: [placement_id: :uuid, namespace_count: :int]
  )

  defevent("lilly.zfs_namespace_cleanup_unconfirmed",
    level: :warning,
    message: "Owned dataset mount copies could not be safely detached",
    metadata: [placement_id: :uuid, reason: :atom]
  )

  defevent("lilly.zfs_import_adoption_unconfirmed",
    level: :warning,
    message: "ZFS import adoption unconfirmed",
    metadata: [placement_id: :uuid]
  )

  defevent("lilly.backup_snapshot_created",
    message: "Backup snapshot created",
    metadata: [placement_id: :uuid]
  )

  defevent("lilly.backup_completed",
    message: "Host backup completed",
    metadata: [
      placement_id: {:uuid, :optional},
      pool_id: {:uuid, :optional},
      run_id: {:uuid, :optional},
      operation:
        {:enum, [:inventory, :pressure, :capture, :release, :cleanup, :metadata, :unknown]}
    ]
  )

  defevent("lilly.backup_failed",
    level: :warning,
    message: "Host backup operation unconfirmed",
    metadata: [
      operation:
        {:enum, [:inventory, :pressure, :capture, :release, :cleanup, :metadata, :unknown]},
      reason: :atom
    ]
  )

  # Intent and receipts
  defevent("lilly.intent_conflict",
    level: :warning,
    message: "Durable intent conflict",
    metadata: [
      vm_id: :uuid,
      placement_id: {:uuid, :optional},
      reason: :atom,
      field: {:atom, :optional}
    ]
  )

  # Relocation transfer: credentials, SSH, snapshots, cleanup
  defevent("lilly.key_created",
    message: "Relocation key created",
    metadata: [relocation_id: :uuid, placement_id: :uuid]
  )

  defevent("lilly.key_retired",
    message: "Relocation key retired",
    metadata: [relocation_id: :uuid, placement_id: :uuid]
  )

  defevent("lilly.key_retirement_failed",
    level: :warning,
    message: "Relocation key retirement failed",
    metadata: [relocation_id: :uuid, reason: :atom]
  )

  defevent("lilly.ssh_pull_failed",
    level: :warning,
    message: "Relocation SSH pull failed",
    metadata: [relocation_id: :uuid, reason: :atom]
  )

  defevent("lilly.ssh_probe_completed",
    message: "Relocation SSH probe completed",
    metadata: [relocation_id: :uuid]
  )

  defevent("lilly.ssh_probe_failed",
    level: :warning,
    message: "Relocation SSH probe failed",
    metadata: [relocation_id: :uuid, reason: :atom]
  )

  defevent("lilly.transfer_received",
    message: "Relocation transfer received",
    metadata: [relocation_id: :uuid, placement_id: :uuid]
  )

  defevent("lilly.transfer_adopted",
    message: "Relocation disk adopted",
    metadata: [relocation_id: :uuid, placement_id: :uuid]
  )

  defevent("lilly.transfer_export_failed",
    level: :warning,
    message: "Relocation export failed",
    metadata: [
      reason: :atom,
      request_id: {:uuid, :optional},
      operation:
        {{:enum,
          [
            :prepare,
            :probe,
            :revoke,
            :prune,
            :destination_cleanup,
            :retire,
            :cancel,
            :receive,
            :import,
            :readiness,
            :cleanup
          ]}, :optional}
    ]
  )

  defevent("lilly.transfer_effect_failed",
    level: :warning,
    message: "Relocation effect failed",
    metadata: [
      reason: :atom,
      request_id: {:uuid, :optional},
      operation:
        {{:enum,
          [
            :prepare,
            :probe,
            :revoke,
            :prune,
            :destination_cleanup,
            :retire,
            :cancel,
            :receive,
            :import,
            :readiness,
            :cleanup
          ]}, :optional}
    ]
  )

  defevent("lilly.transfer_worker_unavailable",
    level: :warning,
    message: "Transfer worker unavailable",
    metadata: [
      component: {:enum, [:source, :key, :receive, :clone]},
      operation:
        {:enum,
         [
           :control,
           :copy,
           :prepare,
           :probe,
           :revoke,
           :prune,
           :destination_cleanup,
           :retire,
           :cancel,
           :receive,
           :import,
           :readiness,
           :cleanup
         ]},
      reason: {:enum, [:exception, :effect_task_exited, :unconfirmed]}
    ]
  )

  defevent("lilly.transfer_worker_recovered",
    message: "Transfer worker recovered",
    metadata: [
      component: {:enum, [:source, :key, :receive, :clone]},
      operation:
        {:enum,
         [
           :control,
           :copy,
           :prepare,
           :probe,
           :revoke,
           :prune,
           :destination_cleanup,
           :retire,
           :cancel,
           :receive,
           :import,
           :readiness,
           :cleanup
         ]}
    ]
  )

  # Durable lifecycle state machines (ADR-0074)
  defevent("lilly.lifecycle_effect_attempted",
    message: "Native storage effect attempted",
    metadata: [action: :atom]
  )

  defevent("lilly.lifecycle_effect_returned",
    message: "Native storage effect returned",
    metadata: [action: :atom, reason: :atom]
  )

  defevent("lilly.lifecycle_transition_committed",
    message: "Lifecycle transition committed",
    delivery: :custody,
    metadata: [
      event_id: :uuid,
      resource_type: :atom,
      resource_id: :uuid,
      action: :atom,
      previous_state: {:atom, :optional},
      next_state: :atom,
      occurred_at: :int64,
      revision: :int64,
      host_id: {:uuid, :optional},
      pool_id: {:uuid, :optional},
      placement_id: {:uuid, :optional},
      workflow_id: {:uuid, :optional}
    ]
  )

  defevent("lilly.control_request_refused",
    level: :warning,
    message: "Control request refused with an unexpected reason",
    metadata: [reason: :atom]
  )

  defevent("lilly.snapshot_created",
    message: "Relocation snapshot created",
    metadata: [relocation_id: :uuid, placement_id: :uuid]
  )

  defevent("lilly.snapshot_destroyed",
    message: "Relocation snapshot destroyed",
    metadata: [relocation_id: :uuid, placement_id: :uuid]
  )

  defevent("lilly.cleanup_completed",
    message: "Relocation cleanup completed",
    metadata: [relocation_id: :uuid, placement_id: {:uuid, :optional}]
  )

  defevent("lilly.cleanup_unconfirmed",
    level: :warning,
    message: "Relocation cleanup unconfirmed",
    metadata: [relocation_id: :uuid, placement_id: {:uuid, :optional}, reason: :atom]
  )

  defevent("lilly.readiness_probed",
    message: "Relocation readiness probed",
    metadata: [relocation_id: :uuid, placement_id: :uuid, generation: :int]
  )

  # Cloning
  defevent("lilly.clone_effect_completed",
    message: "Clone effect completed",
    metadata: [clone_id: :uuid, utility: :atom]
  )

  defevent("lilly.clone_effect_unconfirmed",
    level: :warning,
    message: "Clone effect unconfirmed",
    metadata: [clone_id: :uuid, utility: :atom, reason: :atom, stage: :atom]
  )

  defevent("lilly.clone_effect_contended",
    message: "Clone effect deferred by host contention",
    metadata: [clone_id: :uuid, utility: :atom, reason: :atom, stage: :atom]
  )

  defevent("lilly.workload_bundle_materialized",
    message: "Placement workload bundle materialized",
    metadata: [placement_id: :uuid]
  )

  defevent("lilly.workload_bundle_refused",
    level: :warning,
    message: "Placement workload bundle refused",
    metadata: [placement_id: :uuid, reason: :atom]
  )

  defevent("lilly.runtime_metrics",
    message: "Runtime metrics observed",
    metadata: [
      control_fenced_count: {:int64, :optional},
      control_fenced_duration_us: {:int64, :optional},
      control_fenced_errors: {:int64, :optional},
      control_errors_count: {:int64, :optional},
      control_errors_duration_us: {:int64, :optional},
      control_errors_errors: {:int64, :optional},
      beam_memory_bytes: {:int64, :optional},
      beam_processes: {:int64, :optional},
      beam_atoms: {:int64, :optional},
      beam_run_queue: {:int64, :optional}
    ]
  )

  defevent("lilly.observability_health",
    trace: false,
    message: "Observability producer health observed",
    metadata: [
      trace_available: :int64,
      trace_pending: :int64,
      trace_queue_dropped: :int64,
      trace_export_failed: :int64
    ]
  )
end
