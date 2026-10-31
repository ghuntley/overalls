defmodule Marshall.Events do
  @moduledoc """
  Catalog of reviewed structured-log events under ADR-0042.

  Domain modules emit events through `Marshall.Events.emit/2`, which the
  shared catalog machinery validates at caller compile time
  (event name and metadata keys) and at runtime (UUID, fixed-atom and bounded
  integer shapes). Message text is fixed here; call sites never interpolate
  payloads. Credentials, authentication tokens, terminal bytes and decrypted
  payloads must never be passed as event metadata; there is deliberately no
  string-valued metadata type. Emit outcome logs after the outer transaction
  commits (`unless Marshall.Repo.in_transaction?()`).
  """

  # @cc [owner:ghuntley,label:security] marshall-structured-events-through-catalog
  # Production Marshall modules MUST emit diagnostic structured events only
  # through Marshall.Events.emit/2 with catalogued names and metadata keys.
  # Secrets, credentials, authentication tokens, terminal bytes and decrypted
  # payloads MUST NOT be passed as event metadata under any event. Outcome
  # events for transactional work MUST be emitted after the outer transaction
  # commits.
  use Overalls.Diagnostics.Events.Catalog, service: :marshall

  defevent("operations.migration_failed",
    level: :error,
    message: "Release database migration failed",
    metadata: [
      exception_class:
        {:enum,
         [
           :postgrex,
           :connection,
           :migration,
           :match,
           :argument,
           :runtime,
           :unknown,
           :exit,
           :unexpected_result
         ]},
      postgres_code:
        {:enum,
         [
           :unknown,
           :duplicate_table,
           :duplicate_column,
           :undefined_table,
           :undefined_column,
           :invalid_schema_name,
           :invalid_catalog_name,
           :invalid_password,
           :invalid_authorization_specification,
           :insufficient_privilege,
           :too_many_connections,
           :cannot_connect_now,
           :connection_failure,
           :query_canceled,
           :lock_not_available,
           :deadlock_detected,
           :serialization_failure,
           :disk_full,
           :out_of_memory,
           :admin_shutdown
         ]}
    ]
  )

  defevent("telemetry.service_levels_unavailable",
    level: :warning,
    message: "Durable service level publication unavailable",
    metadata: []
  )

  defevent("enrico.refresh_succeeded",
    message: "Git mirror refresh published",
    metadata: [repository_id: :uuid]
  )

  defevent("enrico.refresh_failed",
    level: :warning,
    message: "Git mirror refresh failed",
    metadata: [repository_id: :uuid, reason: :atom]
  )

  defevent("enrico.remove_succeeded",
    message: "Git mirror removed",
    metadata: [repository_id: :uuid]
  )

  defevent("agent.prompt_admitted",
    message: "Agent prompt admitted",
    metadata: [vm_id: :uuid, thread_id: :uuid, turn_id: :uuid]
  )

  defevent("thread.created",
    message: "User thread created",
    metadata: [thread_id: :uuid]
  )

  defevent("thread.access_changed",
    message: "User thread access changed",
    metadata: [thread_id: :uuid, user_id: :uuid]
  )

  defevent("thread.feed_appended",
    message: "User thread feed notification appended",
    metadata: [thread_id: :uuid, turn_id: :uuid]
  )

  defevent("thread.subscription_revoked",
    message: "Thread subscription revoked after read authority was lost",
    metadata: [subscription_id: :uuid, thread_id: :uuid, user_id: :uuid]
  )

  defevent("thread.subscriptions_reviewed",
    message: "Thread subscriptions re-evaluated after an authority change",
    metadata: [checked: :int, revoked: :int]
  )

  defevent("thread.provision_failed",
    level: :warning,
    message: "User thread machine provisioning failed",
    metadata: [thread_id: :uuid, reason: :atom]
  )

  defevent("attachment.operation",
    message: "Thread attachment operation completed",
    metadata: [attachment_id: :uuid, thread_id: :uuid, operation: :atom, outcome: :atom]
  )

  defevent("agent.server_tool_poll_failed",
    level: :error,
    message: "Server tool polling transaction failed",
    metadata: [reason: {:enum, [:exception]}]
  )

  defevent("agent.notification_poll_failed",
    level: :error,
    message: "Subscription notification polling failed",
    metadata: [reason: {:enum, [:exception]}]
  )

  defevent("attachment.cleanup_failed",
    level: :error,
    message: "Attachment cleanup failed",
    metadata: [reason: {:enum, [:exception]}]
  )

  defevent("agent.child_created",
    message: "Agent child thread created",
    metadata: [vm_id: :uuid, thread_id: :uuid, parent_thread_id: :uuid]
  )

  defevent("agent.turn_started",
    message: "Agent turn started",
    metadata: [vm_id: :uuid, thread_id: :uuid, turn_id: :uuid]
  )

  defevent("agent.turn_finished",
    message: "Agent turn finished",
    metadata: [vm_id: :uuid, thread_id: :uuid, turn_id: :uuid, outcome: :atom]
  )

  defevent("agent.context_waiting",
    level: :warning,
    message: "Agent turn is waiting for execution context",
    metadata: [thread_id: :uuid, turn_id: :uuid, reason: :atom]
  )

  defevent("agent.context_timeout",
    level: :error,
    message: "Agent turn context wait timed out",
    metadata: [thread_id: :uuid, turn_id: :uuid, reason: :atom]
  )

  defevent("agent.executor_registered",
    message: "Agent executor registered",
    metadata: [vm_id: :uuid, executor_id: :uuid]
  )

  defevent("agent.command_finished",
    message: "Agent tool command finished",
    metadata: [vm_id: :uuid, command_id: :uuid, outcome: :atom]
  )

  defevent("agent.search_claimed",
    message: "Agent web search claimed",
    metadata: [vm_id: :uuid, command_id: :uuid]
  )

  defevent("agent.search_cache_hit",
    message: "Agent web search cache hit",
    metadata: [vm_id: :uuid, command_id: :uuid]
  )

  defevent("agent.search_finished",
    message: "Agent web search finished",
    metadata: [vm_id: :uuid, command_id: :uuid, outcome: :atom, credits: {:int, :optional}]
  )

  defevent("agent.search_execution_failed",
    level: :warning,
    message: "Agent search execution failed before a durable completion",
    metadata: [
      command_id: :uuid,
      claim_id: :uuid,
      reason: {:enum, [:exception, :exit, :rejected]}
    ]
  )

  defevent("agent.server_tool_finished",
    message: "Agent server tool finished",
    metadata: [
      vm_id: :uuid,
      command_id: :uuid,
      tool: :atom,
      outcome: :atom,
      reason: {:atom, :optional}
    ]
  )

  defevent("agent.server_tool_reconciled",
    message: "Agent server tool commands reconciled",
    metadata: [requeued: :int, uncertain: :int]
  )

  defevent("artifact.published",
    message: "Artifact version published",
    metadata: [artifact_id: :uuid, version: :int, via: :atom]
  )

  defevent("artifact.publish_refused",
    message: "Artifact publish refused",
    metadata: [artifact_id: {:uuid, :optional}, reason: :atom, via: :atom]
  )

  defevent("artifact.access_changed",
    message: "Artifact access changed",
    metadata: [artifact_id: :uuid, operation: :atom]
  )

  defevent("artifact.deleted",
    message: "Artifact deletion requested",
    metadata: [artifact_id: :uuid, via: :atom]
  )

  defevent("artifact.admin_deleted",
    message: "Artifact deleted by an elevated administrator",
    metadata: [artifact_id: :uuid, reason: :atom]
  )

  defevent("artifact.purged",
    message: "Artifact content purged",
    metadata: [artifact_id: :uuid, outcome: :atom]
  )

  defevent("artifact.content_refused",
    message: "Artifact content request refused",
    metadata: [reason: :atom]
  )

  defevent("artifact.storage_refused",
    message: "Artifact storage operation refused",
    metadata: [artifact_id: :uuid, namespace: :atom, reason: :atom]
  )

  defevent("artifact.usage_drift",
    message: "Artifact storage usage counter corrected",
    metadata: [artifact_id: :uuid, namespace: :atom]
  )

  defevent("artifact.blobs_swept",
    message: "Unreferenced artifact blobs swept",
    metadata: [count: :int]
  )

  defevent("agent.model_claimed",
    message: "Agent model call claimed",
    metadata: [vm_id: :uuid, call_id: :uuid]
  )

  defevent("agent.model_finished",
    message: "Agent model call finished",
    metadata: [vm_id: :uuid, call_id: :uuid, outcome: :atom]
  )

  defevent("agent.skill_operation_finished",
    message: "Agent managed skill operation finished",
    metadata: [operation_id: :uuid, installation_id: :uuid, outcome: :atom]
  )

  defevent("agent.skill_restoration_failed",
    level: :warning,
    message: "Agent managed skill restoration failed",
    metadata: [thread_id: :uuid, reason: :atom]
  )

  defevent("agent.loop_failed",
    level: :warning,
    message: "Agent scheduler tick failed",
    metadata: [reason: :atom]
  )

  defevent("agent.installation_transition",
    message: "Managed agent installation transitioned",
    metadata: [
      vm_id: :uuid,
      attempt_id: :uuid,
      executor_id: :uuid,
      kind: {:enum, [:bootstrap, :maintenance]},
      phase: {:enum, [:claimed, :started, :completed, :failed, :uncertain]}
    ]
  )

  defevent("agent.turn_preparation_failed",
    message: "Agent turn preparation failed",
    metadata: [turn_id: :uuid, reason: :atom]
  )

  defevent("agent.context_published",
    message: "Agent context publication committed",
    metadata: [
      vm_id: :uuid,
      thread_id: :uuid,
      turn_id: :uuid,
      target_id: :uuid,
      kind: {:enum, [:context_captured, :context_compacted]}
    ]
  )

  defevent("redaction.run_started",
    message: "Historical thread redaction started",
    metadata: [run_id: :uuid]
  )

  defevent("redaction.admission_unavailable",
    level: :warning,
    message: "Historical thread redaction admission unavailable",
    metadata: [run_id: :uuid]
  )

  defevent("redaction.run_finished",
    message: "Historical thread redaction finished",
    metadata: [
      run_id: :uuid,
      outcome: :atom,
      processed: {:int, :optional},
      changed: {:int, :optional}
    ]
  )

  defevent("redaction.run_requested",
    message: "Historical thread redaction requested",
    metadata: [run_id: :uuid, actor_id: :uuid]
  )

  defevent("message_board.posts_purged",
    message: "Machine-scoped message board posts purged",
    metadata: [vm_id: :uuid, state: :atom, count: {:int, :optional}]
  )

  defevent("agent.cli_approved",
    message: "Agent CLI session approved",
    metadata: [vm_id: :uuid, actor_id: :uuid]
  )

  defevent("agent.cli_refused",
    level: :warning,
    message: "Agent CLI approval refused",
    metadata: [vm_id: {:uuid, :optional}, actor_id: {:uuid, :optional}, reason: :atom]
  )

  defevent("agent.cli_expired",
    message: "Agent CLI session expired",
    metadata: [vm_id: :uuid, session_id: :uuid]
  )

  defevent("agent.executor_registration_refused",
    level: :warning,
    message: "Agent executor registration refused",
    metadata: [vm_id: :uuid, reason: :atom]
  )

  defevent("agent.executor_claim_refused",
    level: :warning,
    message: "Agent executor tool claim refused",
    metadata: [vm_id: :uuid, reason: :atom]
  )

  defevent("terminal.sharing_refused",
    level: :warning,
    message: "Terminal sharing request refused",
    metadata: [vm_id: :uuid, session_id: :uuid, reason: :atom]
  )

  defevent("terminal.sharing_changed",
    message: "Terminal view-only sharing changed",
    metadata: [vm_id: :uuid, session_id: :uuid, reason: :atom]
  )

  defevent("terminal.creation_refused",
    level: :warning,
    message: "Terminal creation refused",
    metadata: [vm_id: {:uuid, :optional}, reason: :atom]
  )

  defevent("terminal.creation_cancelled",
    message: "Terminal creation intent retired",
    metadata: [request_id: :uuid]
  )

  defevent("terminal.directory_published",
    message: "Terminal stream location published",
    metadata: [host_id: :uuid]
  )

  defevent("terminal.closure_processed",
    message: "Terminal registry closure processed",
    metadata: [vm_id: :uuid, session_id: :uuid, reason: :atom]
  )

  # Compute: admission, lifecycle, outcomes
  defevent("vm.capacity_reserved",
    message: "VM capacity reserved",
    metadata: [vm_id: :uuid, host_id: :uuid]
  )

  defevent("vm.admission_refused",
    level: :warning,
    message: "VM admission refused",
    metadata: [reason: :atom]
  )

  # Source capability refusal uses the closed workspace_source_unavailable atom;
  # manifest/source input never enters metadata.
  # A provider workspace source was stored with a newly admitted VM (ADR-0157).
  # Only the VM identity is logged; URLs, owners, repositories and refs never are.
  defevent("vm.workspace_source_recorded",
    message: "VM workspace source recorded",
    metadata: [vm_id: :uuid]
  )

  defevent("vm.repository_launch_refused",
    level: :warning,
    message: "Repository launch refused",
    metadata: [reason: :atom]
  )

  defevent("vm.lifecycle_requested",
    message: "VM lifecycle requested",
    metadata: [vm_id: :uuid, operation_id: :uuid]
  )

  defevent("vm.lifecycle_refused",
    level: :warning,
    message: "VM lifecycle request refused",
    metadata: [vm_id: :uuid, reason: :atom]
  )

  defevent("vm.wake_requested",
    message: "VM wake requested",
    metadata: [vm_id: :uuid, wake_id: :uuid]
  )

  defevent("vm.wake_ready",
    message: "VM wake ready",
    metadata: [vm_id: :uuid, wake_id: :uuid]
  )

  defevent("vm.wake_failed",
    level: :warning,
    message: "VM wake failed",
    metadata: [vm_id: :uuid, wake_id: :uuid]
  )

  defevent("vm.wake_cancelled",
    message: "VM wake cancelled",
    metadata: [vm_id: :uuid, wake_id: :uuid]
  )

  defevent("vm.pinned",
    message: "VM pinned by a user",
    metadata: [vm_id: :uuid]
  )

  defevent("vm.unpinned",
    message: "VM unpinned by a user",
    metadata: [vm_id: :uuid]
  )

  defevent("vm.pin_refused",
    level: :warning,
    message: "VM pin request refused",
    metadata: [vm_id: :uuid, reason: :atom]
  )

  defevent("vm.physical_outcome",
    message: "VM physical outcome recorded",
    metadata: [
      host_id: :uuid,
      vm_id: :uuid,
      operation_id: :uuid,
      placement_id: :uuid,
      execution_epoch: :int,
      generation: :int,
      outcome_state: :atom,
      reason: {:atom, :optional}
    ]
  )

  defevent("vm.recovery_restarted",
    message: "VM recovery restart enqueued",
    metadata: [vm_id: :uuid, operation_id: :uuid]
  )

  defevent("vm.access_changed",
    message: "VM access request applied",
    metadata: [vm_id: :uuid]
  )

  defevent("vm.resize_requested",
    message: "VM resize requested",
    metadata: [vm_id: :uuid, operation_id: :uuid]
  )

  defevent("vm.resize_phase",
    message: "VM resize advanced",
    metadata: [vm_id: :uuid, operation_status: :atom]
  )

  defevent("vm.resize_finished",
    message: "VM resize finished",
    metadata: [vm_id: :uuid, operation_id: :uuid]
  )

  defevent("vm.resize_failed",
    level: :warning,
    message: "VM resize failed",
    metadata: [vm_id: :uuid, reason: :atom]
  )

  defevent("vm.resize_refused",
    level: :warning,
    message: "VM resize request refused",
    metadata: [vm_id: :uuid, reason: :atom]
  )

  defevent("vm.resize_cancelled",
    message: "VM resize cancelled before any size changed",
    metadata: [vm_id: :uuid, resize_request_id: :uuid]
  )

  # Compute: hosts, credentials, drains, evacuation
  defevent("host.credentials_revoked",
    message: "Host credentials revoked",
    metadata: [host_id: :uuid]
  )

  defevent("host.credentials_rotated",
    message: "Host credentials rotated",
    metadata: [host_id: :uuid, credential_id: :uuid]
  )

  defevent("host.credential_file_issued",
    message: "Host credential file issued",
    metadata: [host_id: :uuid]
  )

  defevent("host.admission_changed",
    message: "Host admission setting changed",
    metadata: [host_id: :uuid, operation_status: :atom]
  )

  defevent("host.auth_rejected",
    level: :warning,
    message: "Host authentication rejected",
    metadata: [host_id: {:uuid, :optional}, reason: :atom]
  )

  defevent("host.report_rejected",
    level: :warning,
    message: "Host report rejected",
    metadata: [host_id: :uuid, reason: :atom]
  )

  defevent("host.connection_reset",
    message: "Host control connection reset",
    metadata: [host_id: :uuid]
  )

  defevent("host.drain_requested",
    message: "Host maintenance changed",
    metadata: [host_id: :uuid, drain_id: :uuid, operation_status: :atom]
  )

  defevent("host.drain_confirmed",
    message: "Host maintenance changed",
    metadata: [host_id: :uuid, drain_id: :uuid, operation_status: :atom]
  )

  defevent("host.drain_closed",
    message: "Host maintenance changed",
    metadata: [host_id: :uuid, drain_id: :uuid, operation_status: :atom]
  )

  defevent("evacuation.requested",
    message: "Evacuation campaign requested",
    metadata: [evacuation_id: :uuid, host_id: :uuid]
  )

  defevent("evacuation.controlled",
    message: "Evacuation campaign controlled",
    metadata: [evacuation_id: :uuid, host_id: :uuid, operation_status: :atom]
  )

  defevent("evacuation.approved",
    message: "Evacuation item approved",
    metadata: [evacuation_id: :uuid, vm_id: :uuid]
  )

  defevent("evacuation.replanned",
    message: "Evacuation item replanned",
    metadata: [evacuation_id: :uuid, vm_id: :uuid]
  )

  defevent("evacuation.blocked",
    level: :warning,
    message: "Evacuation item blocked",
    metadata: [evacuation_id: :uuid, host_id: {:uuid, :optional}, reason: :atom]
  )

  # Compute: cloning
  defevent("clone.submission_refused",
    level: :warning,
    message: "Clone submission refused",
    metadata: [vm_id: {:uuid, :optional}, reason: :atom]
  )

  defevent("clone.accepted",
    message: "Clone accepted",
    metadata: [vm_id: :uuid, clone_id: :uuid, destination_vm_id: :uuid]
  )

  defevent("clone.completed",
    message: "Clone completed",
    metadata: [clone_id: :uuid, vm_id: :uuid, destination_vm_id: :uuid]
  )

  defevent("clone.failed",
    level: :warning,
    message: "Clone failed",
    metadata: [
      clone_id: :uuid,
      vm_id: {:uuid, :optional},
      reason: :atom,
      effect: {:atom, :optional}
    ]
  )

  defevent("clone.effect_unconfirmed",
    level: :warning,
    message: "Clone effect unconfirmed by host",
    metadata: [clone_id: :uuid, host_id: :uuid, effect: :atom, reason: :atom, attempt: :int]
  )

  defevent("clone.effect_confirmed",
    message: "Clone effect confirmed after unconfirmed attempts",
    metadata: [clone_id: :uuid, host_id: :uuid, effect: :atom, attempt: :int]
  )

  defevent("clone.cancelled",
    message: "Clone cancelled",
    metadata: [clone_id: :uuid, vm_id: :uuid]
  )

  defevent("clone.activation_deferred",
    message: "Clone activation deferred",
    metadata: [clone_id: :uuid, vm_id: :uuid, reason: :atom]
  )

  defevent("clone.phase_failed",
    level: :warning,
    message: "Clone phase recorded a failure",
    metadata: [clone_id: :uuid, vm_id: :uuid, phase: :atom, reason: :atom]
  )

  defevent("clone.cleanup_deferred",
    level: :warning,
    message: "Clone completed with source snapshot cleanup still pending",
    metadata: [clone_id: :uuid, vm_id: :uuid, effect: :atom, reason: :atom]
  )

  defevent("clone.cleanup_completed",
    message: "Clone source snapshot cleanup completed",
    metadata: [clone_id: :uuid, vm_id: :uuid]
  )

  # Compute: durable lifecycle audit (ADR-0074)
  defevent("lifecycle.retention_deleted",
    message: "Lifecycle audit retention deleted",
    metadata: [deleted_count: :int]
  )

  defevent("lifecycle.transition_committed",
    message: "Lifecycle transition committed",
    metadata: [
      event_id: :uuid,
      resource_type: :atom,
      resource_id: :uuid,
      action: :atom,
      previous_state: {:atom, :optional},
      next_state: :atom
    ]
  )

  # Compute: relocation
  defevent("relocation.receive_recorded",
    message: "Relocation receive receipt recorded",
    metadata: [host_id: :uuid, relocation_id: :uuid, vm_id: :uuid]
  )

  defevent("relocation.receive_refused",
    level: :warning,
    message: "Relocation receive exchange refused",
    metadata: [reason: :atom]
  )

  defevent("relocation.source_recorded",
    message: "Relocation source result recorded",
    metadata: [host_id: :uuid, relocation_id: :uuid, vm_id: :uuid]
  )

  defevent("relocation.source_refused",
    level: :warning,
    message: "Relocation source exchange refused",
    metadata: [reason: :atom]
  )

  # Compute: relocation
  defevent("relocation.admission_refused",
    level: :warning,
    message: "Relocation admission refused",
    metadata: [vm_id: {:uuid, :optional}, reason: :atom]
  )

  defevent("relocation.admitted",
    message: "Relocation admitted",
    metadata: [vm_id: :uuid, relocation_id: :uuid, host_id: :uuid]
  )

  defevent("relocation.stop_enqueued",
    message: "Relocation source stop enqueued",
    metadata: [relocation_id: :uuid, vm_id: :uuid, operation_id: :uuid]
  )

  defevent("relocation.handoff_committed",
    message: "Relocation placement handoff committed",
    metadata: [
      relocation_id: :uuid,
      vm_id: :uuid,
      host_id: :uuid,
      placement_id: :uuid,
      execution_epoch: :int,
      generation: :int
    ]
  )

  # Accounts and authentication
  defevent("account.invited",
    message: "Account invited",
    metadata: [user_id: :uuid, actor_id: {:uuid, :optional}]
  )

  defevent("account.mfa_reset",
    message: "Account MFA reset",
    metadata: [user_id: :uuid, actor_id: :uuid]
  )

  defevent("account.deleted",
    message: "Account deleted",
    metadata: [user_id: :uuid, actor_id: :uuid]
  )

  defevent("account.sessions_revoked",
    message: "Account sessions revoked",
    metadata: [user_id: :uuid, actor_id: :uuid, deleted_count: {:int, :optional}]
  )

  defevent("account.deletion_progress",
    message: "Account machine deletion progressed",
    metadata: [user_id: :uuid, deleted_count: :int]
  )

  defevent("account.deletion_blocked",
    level: :warning,
    message: "Account machine deletion blocked",
    metadata: [user_id: :uuid, reason: :atom]
  )

  defevent("admin.role_changed",
    message: "Administrator role changed",
    metadata: [user_id: :uuid, actor_id: :uuid, operation_status: :atom]
  )

  defevent("admin.bootstrapped",
    message: "Administrator bootstrapped",
    metadata: [user_id: :uuid]
  )

  defevent("passkey.registered",
    message: "Passkey registered",
    metadata: [user_id: :uuid]
  )

  defevent("passkey.verified",
    message: "Passkey verified",
    metadata: [user_id: :uuid]
  )

  defevent("passkey.verify_failed",
    level: :warning,
    message: "Passkey verification failed",
    metadata: [user_id: {:uuid, :optional}, reason: :atom]
  )

  defevent("passkey.removed",
    message: "Passkey removed",
    metadata: [user_id: :uuid, actor_id: {:uuid, :optional}]
  )

  defevent("mfa.locked",
    message: "MFA elevation locked",
    metadata: [user_id: :uuid]
  )

  # The zone text is a preference, not an outcome; it is never metadata.
  defevent("account.time_zone_changed",
    message: "Account time zone changed",
    metadata: [user_id: :uuid]
  )

  defevent("auth.signed_in",
    message: "Account signed in",
    metadata: [user_id: {:uuid, :optional}]
  )

  defevent("auth.sign_in_failed",
    level: :warning,
    message: "Account sign-in failed",
    metadata: [reason: :atom]
  )

  defevent("auth.signed_out",
    message: "Account signed out",
    metadata: [user_id: {:uuid, :optional}]
  )

  defevent("auth.retired_token_rejected",
    level: :warning,
    message: "Retired-account authentication token rejected",
    metadata: []
  )

  # SSH gateway
  defevent("ssh.gateway_configured",
    message: "SSH gateway configured",
    metadata: [gateway_id: :uuid]
  )

  defevent("ssh.gateway_disabled",
    message: "SSH gateway disabled",
    metadata: [gateway_id: :uuid]
  )

  defevent("ssh.session_opened",
    message: "SSH gateway session opened",
    metadata: [session_id: {:uuid, :optional}, gateway_id: {:uuid, :optional}]
  )

  defevent("ssh.session_closed",
    message: "SSH gateway session closed",
    metadata: [session_id: :uuid]
  )

  defevent("ssh.key_approved",
    message: "SSH gateway key approved",
    metadata: [session_id: :uuid, key_id: :uuid]
  )

  defevent("ssh.watch_subscription_refused",
    level: :warning,
    message: "SSH watch subscription refused",
    metadata: [
      reason:
        {:enum,
         [
           :unauthorized,
           :approval_required,
           :forbidden,
           :not_found,
           :invalid_request,
           :unavailable
         ]}
    ]
  )

  defevent("ssh.key_added",
    message: "Account SSH key added",
    metadata: [key_id: :uuid, user_id: :uuid]
  )

  defevent("ssh.key_renamed",
    message: "Account SSH key renamed",
    metadata: [key_id: :uuid, user_id: :uuid]
  )

  defevent("ssh.key_removed",
    message: "Account SSH key removed",
    metadata: [key_id: :uuid, user_id: :uuid]
  )

  defevent("ssh.admin_key_revoked",
    message: "SSH key revoked by administrator",
    metadata: [key_id: :uuid, actor_id: :uuid]
  )

  defevent("ssh.admin_session_revoked",
    message: "SSH gateway session revoked by administrator",
    metadata: [session_id: :uuid, actor_id: :uuid]
  )

  defevent("ssh.command_admitted",
    message: "SSH command admitted",
    metadata: []
  )

  defevent("ssh.guest_key_eligible",
    message: "Guest SSH key eligible",
    metadata: [vm_id: :uuid, user_id: :uuid, key_id: :uuid]
  )

  defevent("ssh.guest_login_reported",
    message: "Guest SSH login reported by guest PAM",
    metadata: [vm_id: :uuid, user_id: :uuid, key_id: :uuid, login_id: :uuid]
  )

  # Ingress (Audi)
  defevent("ingress.relay_issued",
    message: "Ingress relay issued",
    metadata: [relay_id: :uuid, origin_host_id: :uuid, destination_host_id: :uuid]
  )

  defevent("ingress.relay_consumed",
    message: "Ingress relay consumed",
    metadata: [relay_id: :uuid, origin_host_id: :uuid, destination_host_id: :uuid]
  )

  defevent("ingress.service_configured",
    message: "Ingress service configured",
    metadata: [service_id: :uuid, host_id: {:uuid, :optional}]
  )

  defevent("ingress.service_disabled",
    message: "Ingress service disabled",
    metadata: [service_id: :uuid, host_id: {:uuid, :optional}]
  )

  defevent("ingress.host_key_published",
    message: "Ingress host key published",
    metadata: [service_id: :uuid, host_id: :uuid]
  )

  defevent("ingress.service_auth_rejected",
    level: :warning,
    message: "Ingress service authentication rejected",
    metadata: [reason: :atom]
  )

  defevent("editor.authority",
    message: "Editor authority transitioned",
    metadata: [kind: :atom, vm_id: :uuid, user_id: {:uuid, :optional}]
  )

  defevent("editor.assets_ready",
    message: "Editor asset readiness recorded",
    metadata: [host_id: :uuid]
  )

  defevent("ingress.web_login_started", message: "Ingress web login started", metadata: [])

  defevent("ingress.web_login_approved",
    message: "Ingress web login approved",
    metadata: [user_id: :uuid, vm_id: :uuid]
  )

  defevent("ingress.web_login_exchanged",
    message: "Ingress web login exchanged",
    metadata: [vm_id: :uuid]
  )

  defevent("ingress.web_login_denied",
    level: :warning,
    message: "Ingress web login denied",
    metadata: [reason: :atom]
  )

  defevent("ingress.ssh_session_opened",
    message: "Ingress SSH session opened",
    metadata: [vm_id: :uuid, host_id: :uuid, session_id: :uuid]
  )

  defevent("ingress.ssh_session_closed",
    message: "Ingress SSH session closed",
    metadata: [session_id: :uuid]
  )

  defevent("ingress.fleet_certificate_installed",
    message: "Fleet wildcard certificate installed by gateway",
    metadata: [host_id: :uuid, generation: :int]
  )

  defevent("ingress.fleet_certificate_ordered",
    message: "Fleet wildcard ACME order recorded",
    metadata: [certificate_id: :uuid, generation: :int]
  )

  defevent("ingress.fleet_certificate_propagation_waiting",
    level: :warning,
    message: "Fleet wildcard ACME proof propagation check refused",
    metadata: [certificate_id: :uuid, generation: :int, reason: :atom]
  )

  defevent("ingress.fleet_certificate_issued",
    message: "Fleet wildcard certificate issued",
    metadata: [certificate_id: :uuid, generation: :int]
  )

  defevent("ingress.fleet_certificate_activated",
    message: "Fleet wildcard certificate activated",
    metadata: [certificate_id: :uuid, generation: :int]
  )

  defevent("ingress.fleet_certificate_rotation_requested",
    message: "Fleet wildcard emergency rotation requested",
    metadata: [certificate_id: :uuid, generation: :int, actor_id: :uuid]
  )

  defevent("ingress.fleet_certificate_failed",
    level: :warning,
    message: "Fleet wildcard issuance failed",
    metadata: [certificate_id: :uuid, generation: :int, reason: :atom]
  )

  # Inference (Ziggy)
  defevent("inference.credential_rotated",
    message: "Inference service credential rotated",
    metadata: [host_id: :uuid, credential_id: :uuid]
  )

  defevent("inference.credential_revoked",
    message: "Inference service credential revoked",
    metadata: [host_id: :uuid, credential_id: :uuid]
  )

  defevent("inference.auth_rejected",
    level: :warning,
    message: "Inference service authentication rejected",
    metadata: [reason: :atom]
  )

  # Push notifications (ADR-0225): identifiers and closed reasons only, never
  # push keys, device keys, routes, ciphertext or Susan bodies.
  defevent("notifications.device_registered",
    message: "Push notification device registered",
    metadata: [
      device_id: :uuid,
      user_id: :uuid,
      platform: {:enum, [:ios, :android, :macos, :windows]}
    ]
  )

  defevent("notifications.device_transition",
    message: "Push notification device changed",
    metadata: [
      device_id: :uuid,
      state: {:enum, [:pending, :active, :invalidated, :revoked]},
      reason:
        {:enum,
         [
           :refreshed,
           :removed,
           :key_revoked,
           :account_retired,
           :provider_unregistered,
           :preference_on,
           :preference_off
         ]}
    ]
  )

  defevent("notifications.delivery_transition",
    message: "Push notification delivery changed",
    metadata: [
      delivery_id: :uuid,
      device_id: :uuid,
      state: {:enum, [:queued, :sending, :delivered, :retry_wait, :failed_permanent, :dropped]},
      reason:
        {:enum,
         [
           :produced,
           :begin_send,
           :sent,
           :device_inactive,
           :preference_off,
           :coalesced,
           :expired,
           :transport,
           :timeout,
           :server_error,
           :rate_limited,
           :rejected,
           :request_too_large,
           :exhausted,
           :unsealable
         ]}
    ]
  )

  defevent("notifications.poke_refused",
    level: :warning,
    message: "Push notification poke refused",
    metadata: [
      reason: {:enum, [:producer_failed, :rejected, :request_too_large, :unsealable]},
      status: {:int, :optional}
    ]
  )

  defevent("notifications.susan_unavailable",
    level: :warning,
    message: "Push relay unavailable; delivery will retry",
    metadata: [
      reason: {:enum, [:transport, :timeout, :server_error, :rate_limited]},
      status: {:int, :optional}
    ]
  )

  defevent("notifications.deliveries_pruned",
    message: "Push notification delivery retention batch deleted",
    metadata: [deleted_count: :int]
  )

  defevent("inference.retention_deleted",
    message: "Inference retention batch deleted",
    metadata: [deleted_count: :int]
  )

  defevent("inference.request_admitted",
    message: "Inference request admitted",
    metadata: [request_id: :uuid, vm_id: :uuid]
  )

  defevent("inference.request_completed",
    message: "Inference request completed",
    metadata: [request_id: :uuid]
  )

  defevent("inference.request_refused",
    level: :warning,
    message: "Inference request refused",
    metadata: [request_id: {:uuid, :optional}, reason: :atom]
  )

  # Galileo
  defevent("github.connected",
    message: "GitHub identity connected",
    metadata: [connection_id: :uuid, user_id: :uuid]
  )

  defevent("github.disconnected",
    message: "GitHub identity disconnected",
    metadata: [connection_id: :uuid, user_id: :uuid]
  )

  defevent("github.refresh_finished",
    message: "GitHub credential refresh settled",
    metadata: [connection_id: :uuid, outcome: {:enum, [:connected, :reconnect_required]}]
  )

  defevent("github.authorization_failed",
    level: :warning,
    message: "GitHub authorization refused",
    metadata: [user_id: :uuid, reason: :atom]
  )

  defevent("github.machine_access_changed",
    message: "GitHub machine access changed",
    metadata: [user_id: :uuid, vm_id: :uuid]
  )

  defevent("github.token_revoked",
    message: "GitHub token revocation settled",
    metadata: [kind: :atom, outcome: :atom]
  )

  defevent("galileo.authorization_denied",
    level: :warning,
    message: "Galileo integration authorization denied",
    metadata: [reason: :atom]
  )

  defevent("galileo.integration_configured",
    message: "Galileo integration changed",
    metadata: [
      integration_id: :uuid,
      vm_id: {:uuid, :optional},
      actor_id: :uuid,
      operation_status: :atom
    ]
  )

  defevent("team.membership_changed",
    message: "Team membership changed",
    metadata: [
      team_id: :uuid,
      user_id: :uuid,
      actor_id: {:uuid, :optional},
      operation_status: :atom
    ]
  )

  defevent("galileo.credential_rotated",
    message: "Integration service credential rotated",
    metadata: [host_id: :uuid, credential_id: :uuid]
  )

  defevent("galileo.credential_revoked",
    message: "Integration service credential revoked",
    metadata: [host_id: :uuid]
  )

  defevent("peach.credential_rotated",
    message: "Reflection service credential rotated",
    metadata: [host_id: :uuid, credential_id: :uuid]
  )

  defevent("peach.credential_revoked",
    message: "Reflection service credential revoked",
    metadata: [host_id: :uuid]
  )

  # Teams
  defevent("team.transfer_changed",
    message: "Team ownership transfer changed state",
    metadata: [transfer_id: :uuid, team_id: :uuid, actor_id: {:uuid, :optional}, state: :atom]
  )

  # Administration
  defevent("admin.job_retried",
    message: "Administrative job retried",
    metadata: [job_id: :int, actor_id: :uuid]
  )

  defevent("admin.job_history_deleted",
    message: "Administrative job history deleted",
    metadata: [deleted_count: :int]
  )

  # Authorization
  defevent("cedar.evaluation_error",
    level: :warning,
    message: "Cedar policy evaluation error",
    metadata: [reason: :atom]
  )

  defevent("cedar.filter_unsupported",
    level: :error,
    message: "Cedar residual could not be translated; the read filter denies",
    metadata: [reason: :atom]
  )

  # Mail
  defevent("mail.delivery_attempt",
    message: "Mail attempt finished",
    metadata: [delivery_id: :uuid, delivery_status: :atom]
  )

  defevent("mail.enqueue_failed",
    level: :error,
    message: "Magic-link enqueue failed",
    metadata: []
  )

  # API boundary fallbacks and denials
  defevent("ssh.request_unavailable",
    level: :error,
    message: "SSH gateway request unavailable",
    metadata: []
  )

  defevent("provisioner.transaction_failed",
    level: :error,
    message: "Provisioner control transaction failed",
    metadata: []
  )

  defevent("audi.control_unavailable",
    level: :error,
    message: "Audi control request unavailable",
    metadata: [reason: :atom]
  )

  defevent("api.request_unauthorized",
    level: :warning,
    message: "API request unauthorized",
    metadata: [reason: :atom]
  )

  defevent("terminal.attached",
    message: "Terminal viewer attached",
    metadata: [
      vm_id: :uuid,
      session_id: :uuid,
      actor_id: :uuid,
      origin: {:enum, [:browser, :ssh]}
    ]
  )

  defevent("control.connected",
    level: :info,
    message: "Control WebSocket bound",
    metadata: [service: :atom]
  )

  defevent("control.closed",
    level: :info,
    message: "Control WebSocket closed",
    metadata: [reason: :atom]
  )

  defevent("control.request_expired",
    level: :warning,
    message: "Queued control request refused after its queue deadline",
    metadata: [service: :atom]
  )

  defevent("control.hints_resynced",
    level: :info,
    message: "Control hint subscribers resynced after notifier recovery",
    metadata: [next_state: :atom]
  )

  defevent("terminal.viewer_refused",
    level: :warning,
    message: "Terminal viewer refused",
    metadata: [reason: :atom]
  )

  defevent("terminal.ticket_refused",
    level: :warning,
    message: "Terminal attach ticket refused",
    metadata: [reason: :atom]
  )

  defevent("terminal.viewer_authority_inconclusive",
    level: :warning,
    message: "Terminal viewer authority recheck inconclusive",
    metadata: []
  )

  defevent("terminal.stream_fenced",
    level: :warning,
    message: "Terminal host stream fenced by location change",
    metadata: [host_id: :uuid]
  )

  defevent("terminal.stream_rejected",
    level: :warning,
    message: "Terminal stream rejected",
    metadata: [host_id: :uuid]
  )

  defevent("terminal.stream_registered",
    message: "Terminal host stream registered",
    metadata: [host_id: :uuid]
  )

  defevent("marshall.runtime_metrics",
    message: "Runtime metrics observed",
    metadata: [
      http_count: {:int64, :optional},
      http_duration_us: {:int64, :optional},
      http_errors: {:int64, :optional},
      control_count: {:int64, :optional},
      control_duration_us: {:int64, :optional},
      control_errors: {:int64, :optional},
      ssh_count: {:int64, :optional},
      ssh_duration_us: {:int64, :optional},
      ssh_errors: {:int64, :optional},
      terminal_authority_count: {:int64, :optional},
      terminal_authority_duration_us: {:int64, :optional},
      terminal_authority_errors: {:int64, :optional},
      terminal_input_count: {:int64, :optional},
      terminal_input_duration_us: {:int64, :optional},
      terminal_input_errors: {:int64, :optional},
      database_count: {:int64, :optional},
      database_duration_us: {:int64, :optional},
      database_errors: {:int64, :optional},
      database_queue_count: {:int64, :optional},
      database_queue_duration_us: {:int64, :optional},
      database_queue_errors: {:int64, :optional},
      database_queue_max_us: {:int64, :optional},
      jobs_count: {:int64, :optional},
      jobs_duration_us: {:int64, :optional},
      jobs_errors: {:int64, :optional},
      job_failures_count: {:int64, :optional},
      job_failures_duration_us: {:int64, :optional},
      job_failures_errors: {:int64, :optional},
      beam_memory_bytes: {:int64, :optional},
      beam_processes: {:int64, :optional},
      beam_atoms: {:int64, :optional},
      beam_run_queue: {:int64, :optional},
      agent_stuck_turns: {:int64, :optional},
      terminal_host_streams: {:int64, :optional},
      terminal_viewer_sockets: {:int64, :optional},
      terminal_peer_sockets: {:int64, :optional},
      live_overview_count: {:int64, :optional},
      live_overview_duration_us: {:int64, :optional},
      live_overview_queries: {:int64, :optional},
      live_machines_count: {:int64, :optional},
      live_machines_duration_us: {:int64, :optional},
      live_machines_queries: {:int64, :optional},
      live_machine_new_count: {:int64, :optional},
      live_machine_new_duration_us: {:int64, :optional},
      live_machine_new_queries: {:int64, :optional},
      live_machine_count: {:int64, :optional},
      live_machine_duration_us: {:int64, :optional},
      live_machine_queries: {:int64, :optional},
      liveview_mount_count: {:int64, :optional},
      liveview_mount_duration_us: {:int64, :optional},
      liveview_mount_queries: {:int64, :optional},
      liveview_params_count: {:int64, :optional},
      liveview_params_duration_us: {:int64, :optional},
      liveview_params_queries: {:int64, :optional},
      liveview_event_count: {:int64, :optional},
      liveview_event_duration_us: {:int64, :optional},
      liveview_event_queries: {:int64, :optional},
      liveview_info_count: {:int64, :optional},
      liveview_info_duration_us: {:int64, :optional},
      liveview_info_queries: {:int64, :optional}
    ]
  )

  defevent("marshall.observability_health",
    trace: false,
    message: "Observability producer health observed",
    metadata: [
      trace_available: :int64,
      trace_pending: :int64,
      trace_queue_dropped: :int64,
      trace_export_failed: :int64
    ]
  )

  defevent("scim.configuration_changed",
    message: "SCIM configuration changed",
    metadata: [enabled: :atom]
  )

  defevent("scim.team_retirement_started",
    message: "Native team retirement started for SCIM",
    metadata: [team_id: :uuid]
  )

  defevent("scim.team_authority_revoked",
    message: "SCIM team authority revoked",
    metadata: [team_id: :uuid]
  )

  defevent("scim.request_refused",
    level: :warning,
    message: "SCIM request refused",
    metadata: [reason: :atom]
  )

  defevent("scim.machine_suspended",
    message: "Machine suspended for SCIM user retirement",
    metadata: [user_id: :uuid, vm_id: :uuid]
  )

  defevent("scim.machine_suspension_failed",
    level: :warning,
    message: "Machine suspension for SCIM user retirement refused",
    metadata: [user_id: :uuid, vm_id: :uuid, reason: :atom]
  )

  defevent("scim.user_machines_resumed",
    message: "SCIM-suspended machines resumed after reactivation",
    metadata: [user_id: :uuid, resumed_count: :int]
  )

  defevent("scim.user_finalized",
    message: "SCIM user retirement finalized",
    metadata: [user_id: :uuid]
  )

  defevent("scim.user_retirement_failed",
    level: :warning,
    message: "SCIM user retirement step failed and will be retried",
    metadata: [user_id: :uuid, reason: :atom]
  )

  defevent("agent.message_board_machine_purged",
    message: "Machine message-board history purged",
    metadata: [vm_id: :uuid, state: :atom, purged_count: :int]
  )

  defevent("attachment.chunks_deleted",
    message: "Attachment chunks deleted",
    metadata: [attachment_id: :uuid, thread_id: :uuid, deleted_count: :int]
  )
end
