defmodule Ziggy.Events do
  @moduledoc """
  Catalog of reviewed structured-log events under ADR-0042.

  Ziggy modules emit events through `Ziggy.Events.emit/2`, which the
  shared catalog machinery validates at caller compile time (event
  name and metadata keys) and at runtime (UUID, fixed-atom and bounded
  integer shapes). Message text is fixed here; call sites never interpolate
  payloads. Provider credentials, request bodies, model names and completion
  content must never be passed as event metadata; there is deliberately no
  string-valued metadata type.
  """

  # @cc [owner:ghuntley,label:security] ziggy-structured-events-through-catalog
  # Production Ziggy modules MUST emit diagnostic structured events only
  # through Ziggy.Events.emit/2 with catalogued names and metadata keys.
  # Provider credentials, request/response content and model identifiers
  # MUST NOT be passed as event metadata under any event.
  use Overalls.Diagnostics.Events.Catalog, service: :ziggy

  defevent("ziggy.inference_admitted",
    message: "Inference admitted",
    metadata: [request_id: :uuid, host_id: {:uuid, :optional}, vm_id: {:uuid, :optional}]
  )

  defevent("ziggy.inference_completed",
    message: "Inference completed",
    metadata: [
      request_id: :uuid,
      host_id: {:uuid, :optional},
      vm_id: {:uuid, :optional},
      reason: {:atom, :optional},
      status: {:int, :optional},
      duration_ms: {:int, :optional},
      request_bytes: {:int, :optional},
      response_bytes: {:int, :optional}
    ]
  )

  defevent("ziggy.inference_interrupted",
    level: :warning,
    message: "Inference interrupted",
    metadata: [
      request_id: :uuid,
      host_id: {:uuid, :optional},
      vm_id: {:uuid, :optional},
      reason: :atom
    ]
  )

  defevent("ziggy.upstream_outcome",
    message: "Upstream provider outcome",
    metadata: [request_id: :uuid, reason: :atom]
  )

  defevent("ziggy.control_exchange_failed",
    level: :warning,
    message: "Control exchange failed",
    metadata: [request_id: {:uuid, :optional}, host_id: {:uuid, :optional}, reason: :atom]
  )

  defevent("ziggy.control_version_refused",
    level: :error,
    message: "Control API version refused",
    metadata: [reason: :atom]
  )

  defevent("ziggy.agent_model_finished",
    message: "Host agent model call finished",
    metadata: [request_id: :uuid, reason: :atom]
  )

  defevent("ziggy.lease_revoked",
    level: :warning,
    message: "Admission lease revoked",
    metadata: [request_id: :uuid, reason: :atom]
  )

  defevent("ziggy.spool_failed",
    level: :error,
    message: "Durable accounting spool failed",
    metadata: [reason: :atom]
  )

  defevent("ziggy.spool_recovered", message: "Durable accounting spool recovered", metadata: [])

  defevent("ziggy.spool_ack_failed",
    level: :warning,
    message: "Durable accounting acknowledgement failed",
    metadata: [request_id: {:uuid, :optional}]
  )

  defevent("ziggy.accounting_reported",
    message: "Accounting completion reported",
    metadata: [request_id: :uuid]
  )

  defevent("ziggy.accounting_retry",
    level: :warning,
    message: "Accounting report retry",
    metadata: [request_id: :uuid, reason: :atom]
  )

  defevent("ziggy.catalog_refreshed",
    message: "Provider catalog refreshed",
    metadata: []
  )

  defevent("ziggy.catalog_failed",
    level: :warning,
    message: "Provider catalog refresh failed",
    metadata: [reason: :atom]
  )

  defevent("ziggy.admission_rejected",
    level: :warning,
    message: "Spool admission rejected",
    metadata: [request_id: {:uuid, :optional}, reason: :atom]
  )

  defevent("ziggy.startup_configuration_rejected",
    level: :error,
    message: "Startup configuration rejected",
    metadata: [reason: :atom]
  )

  defevent("ziggy.slo_publication_failed",
    level: :warning,
    message: "SLO snapshot publication unavailable",
    metadata: []
  )

  defevent("ziggy.slo_publication_recovered",
    message: "SLO snapshot publication recovered",
    metadata: []
  )

  defevent("ziggy.observability_health",
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
