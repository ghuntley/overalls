defmodule Porsche.Client do
  @moduledoc """
  Bounded transport to Marshall's SSH management requests over the control
  WebSocket (ADR-0142). The struct names the `OverallsProtocol.Control.Client`
  that `Porsche.Control.Link` owns.
  """
  alias OverallsProtocol.SSHManagement
  require Porsche.Events
  @derive {Inspect, except: [:token]}
  @enforce_keys [:origin, :token]
  defstruct [:origin, :token, :cacertfile, control: Porsche.ControlClient]

  # Prompt, answer and revision payloads reach 64 KiB before JSON escaping.
  @maximum_request 409_600
  @maximum_response 1_048_576
  @conflict_errors Map.new(
                     [
                       :insufficient_capacity,
                       :host_unavailable,
                       :clone_already_published,
                       :clone_not_retryable,
                       :clone_in_progress,
                       :idempotency_conflict,
                       :workload_not_stable,
                       :checkpoint_unavailable,
                       :vm_busy,
                       :source_unavailable,
                       :transfer_busy,
                       :source_cleanup_pending,
                       :resize_in_progress,
                       :relocation_in_progress,
                       :relocation_committed,
                       :relocation_finished,
                       :relocation_retry_unavailable,
                       :placement_changed,
                       :name_unavailable,
                       :machine_pinned,
                       :machine_failed,
                       :pin_limit,
                       :push_disabled,
                       :device_limit,
                       :thread_not_ready,
                       :thread_busy,
                       :stale_proposal,
                       :stale_question,
                       :already_answered,
                       :already_implemented,
                       :invalid_answers,
                       :awaiting_answers,
                       :machine_unavailable,
                       :revision_conflict,
                       :reserved_editor_port,
                       :web_not_allowed,
                       :terminal_unavailable,
                       :terminal_open_pending,
                       :unknown_session,
                       :too_many_terminal_sessions,
                       :opening_expired
                     ],
                     &{Atom.to_string(&1), &1}
                   )
  @type t :: %__MODULE__{
          origin: String.t(),
          token: String.t(),
          cacertfile: String.t() | nil,
          control: GenServer.server()
        }
  @type error ::
          :invalid_configuration
          | :invalid_request
          | :transport_error
          | :message_too_large
          | :invalid_response
          | :unauthorized
          | :forbidden
          | :not_found
          | :conflict
          | :insufficient_capacity
          | :host_unavailable
          | :clone_already_published
          | :clone_not_retryable
          | :clone_in_progress
          | :idempotency_conflict
          | :workload_not_stable
          | :checkpoint_unavailable
          | :vm_busy
          | :source_unavailable
          | :transfer_busy
          | :source_cleanup_pending
          | :resize_in_progress
          | :relocation_in_progress
          | :relocation_committed
          | :relocation_finished
          | :relocation_retry_unavailable
          | :placement_changed
          | :name_unavailable
          | :machine_pinned
          | :machine_failed
          | :pin_limit
          | :push_disabled
          | :device_limit
          | :thread_not_ready
          | :thread_busy
          | :stale_proposal
          | :stale_question
          | :already_answered
          | :already_implemented
          | :invalid_answers
          | :awaiting_answers
          | :machine_unavailable
          | :revision_conflict
          | :reserved_editor_port
          | :web_not_allowed
          | :terminal_unavailable
          | :terminal_open_pending
          | :unknown_session
          | :too_many_terminal_sessions
          | :opening_expired
          | :rate_limited
          | :unsupported_version
          | :temporarily_unavailable
          | :http_error

  # @cc [owner:ghuntley,label:security] porsche-control-ipv4-only
  # Control origins MUST reject IPv6 literals. Outbound transport MUST disable
  # IPv6 even when the configured DNS hostname has both address families.
  @spec new(term(), term(), keyword()) :: {:ok, t()} | {:error, :invalid_configuration}
  def new(origin, token, options \\ []) do
    with true <- is_binary(origin) and is_binary(token),
         true <- valid_token?(token),
         {:ok, uri} <- URI.new(origin),
         true <-
           uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
             not String.contains?(uri.host, ":") and
             uri.userinfo == nil and uri.query == nil and uri.fragment == nil and
             uri.path in [nil, "/"] and is_integer(uri.port) and uri.port in 1..65_535,
         true <- Keyword.keys(options) -- [:cacertfile, :control] == [],
         certificate = Keyword.get(options, :cacertfile),
         true <- is_nil(certificate) or (is_binary(certificate) and certificate != ""),
         control = Keyword.get(options, :control, Porsche.ControlClient),
         true <- is_atom(control) do
      {:ok,
       %__MODULE__{
         origin: String.trim_trailing(origin, "/"),
         token: token,
         cacertfile: certificate,
         control: control
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] porsche-bounded-single-submission
  # request/3 MUST validate the closed route envelope before sending credentials,
  # bound response bytes while streaming, and return fixed errors without remote
  # bodies or exceptions. A lost response MUST NOT trigger automatic redelivery.
  @spec request(t(), binary(), term(), keyword()) :: {:ok, map()} | {:error, error()}
  def request(%__MODULE__{} = client, route, message, options \\ []) do
    result =
      Porsche.Observability.measure(:http, fn -> perform(client, route, message, options) end)

    case result do
      {:error, reason} ->
        Porsche.Events.emit("porsche.exchange_failed", reason: exchange_reason(reason))

      _ ->
        :ok
    end

    result
  end

  defp perform(client, route, message, options) do
    timeout = Keyword.get(options, :timeout, 5000)

    with :ok <- request_options(options, timeout),
         {:ok, _} <- SSHManagement.request(route, message),
         body = JSON.encode!(message),
         true <- byte_size(body) <= @maximum_request do
      client.control
      |> OverallsProtocol.Control.Client.request("porsche." <> route, message, timeout)
      |> response(client)
    else
      false -> {:error, :message_too_large}
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :transport_error}
  catch
    :exit, _ -> {:error, :transport_error}
  end

  defp request_options(options, timeout) when is_integer(timeout) and timeout in 1..5000 do
    if Keyword.keys(options) -- [:timeout] == [], do: :ok, else: :error
  end

  defp request_options(_, _), do: :error

  defp valid_token?("porsche_gateway_" <> encoded) when byte_size(encoded) == 43 do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, bytes} when byte_size(bytes) == 32 ->
        Base.url_encode64(bytes, padding: false) == encoded

      _ ->
        false
    end
  end

  defp valid_token?(_), do: false

  # Marshall's closed refusal names, each in exactly one HTTPS status class.
  @classes %{
    "invalid_request" => :invalid_request,
    "invalid_public_key" => :invalid_request,
    "invalid_command" => :invalid_request,
    "unauthorized" => :unauthorized,
    "approval_required" => :unauthorized,
    "forbidden" => :forbidden,
    "https_required" => :forbidden,
    "not_found" => :not_found,
    "request_not_found" => :not_found,
    "key_not_found" => :not_found,
    "device_not_found" => :not_found,
    "message_too_large" => :message_too_large,
    "unsupported_version" => :unsupported_version,
    "session_limit" => :rate_limited,
    "approval_limit" => :rate_limited,
    "temporarily_unavailable" => :temporarily_unavailable
  }
  @other_conflicts ~w(conflict vm_deleted image_unavailable image_requirements_not_met
                      invalid_vm_size disk_not_reserved generation_exhausted owner_protected
                      recipient_not_registered workspace_source_not_allowed
                      invalid_workspace_source resize_not_retryable resize_not_cancellable
                      stop_unconfirmed stale_generation)

  defp response({:ok, value}, _client) when is_map(value) do
    if byte_size(JSON.encode!(value)) <= @maximum_response,
      do: {:ok, value},
      else: {:error, :message_too_large}
  end

  # @cc [owner:ghuntley,label:security;recovery] porsche-closed-conflict-reasons
  # Only predefined host/capacity/clone/name-custody, checkpoint and busy-machine
  # reasons (`checkpoint_unavailable`, `vm_busy`), machine-pin reasons
  # (`machine_pinned`, `machine_failed`, `pin_limit`), push-device reasons
  # (`push_disabled`, `device_limit`) and the thread, terminal and web reasons
  # of ADR-0222 and ADR-0223 may refine a conflict; other conflict names
  # stay generic and unknown names are an http_error. Remote values MUST NOT
  # create atoms or trigger automatic request redelivery.
  defp response({:error, name}, _client) when is_binary(name) do
    cond do
      Map.has_key?(@conflict_errors, name) -> {:error, Map.fetch!(@conflict_errors, name)}
      name in @other_conflicts -> {:error, :conflict}
      true -> {:error, Map.get(@classes, name, :http_error)}
    end
  end

  # @cc [owner:ghuntley,label:protocol;recovery] porsche-pending-version-refusal
  # Pending unproven or disconnected calls MUST preserve unsupported_version
  # when the owning client stops for that reason. Other losses remain transport
  # errors and MUST NOT trigger automatic redelivery.
  defp response({:error, reason}, client) when reason in [:disconnected, :unproven] do
    case OverallsProtocol.Control.Client.status(client.control) do
      {:disconnected, :unsupported_version} -> {:error, :unsupported_version}
      _ -> {:error, :transport_error}
    end
  end

  defp response(_result, _client), do: {:error, :transport_error}

  @conflict_reasons [:conflict | Map.values(@conflict_errors)]

  # @cc [owner:ghuntley,label:security] porsche-command-conflict-classification
  # Command exit classification MUST use the same closed 409 reasons as the
  # HTTPS parser. Unknown terms MUST NOT become recognized command conflicts.
  @spec conflict?(term()) :: boolean()
  def conflict?(reason), do: reason in @conflict_reasons

  defp exchange_reason(:unauthorized), do: :unauthorized
  defp exchange_reason(:forbidden), do: :forbidden
  defp exchange_reason(:rate_limited), do: :rate_limited

  defp exchange_reason(reason) when reason in @conflict_reasons, do: :conflict

  defp exchange_reason(_), do: :transport
end
