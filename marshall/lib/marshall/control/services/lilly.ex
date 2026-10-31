defmodule Marshall.Control.Services.Lilly do
  @moduledoc """
  Lilly's control requests over the control WebSocket (ADR-0142).

  Requests carry the closed provisioner documents and run
  through `Marshall.Compute.ProvisionerRequests`. Every exchange
  re-authenticates the host credential under the host lock and checks the
  session and epoch its document carries, so fencing is unchanged. Errors keep
  their closed names; unexpected failures are uniformly unavailable.
  """
  @behaviour Marshall.Control.Service
  require Marshall.Events

  alias Marshall.Compute.{Credentials, ProvisionerRequests}

  # Bodies are bounded by OverallsProtocol.max_body/0; the envelope adds a few
  # bytes. Every relocation, clone and inception loop may have one
  # exchange in flight beside the execution exchange. Only `running` of them
  # execute at once (ADR-0275): each exchange holds this host's row lock for
  # its whole transaction, so the rest would only park pooled connections.
  @limits %{
    frame: OverallsProtocol.max_body() + 4_096,
    inbound: OverallsProtocol.max_body() + 4_096,
    in_flight: 64
  }

  @impl true
  def authenticate(token) when is_binary(token) and byte_size(token) == 80 do
    case Credentials.with_host(token, & &1.id) do
      {:ok, host_id} -> {:ok, %{token: token, host_id: host_id}}
      {:error, :temporarily_unavailable} -> :unavailable
      _ -> :refused
    end
  end

  def authenticate(_token), do: :refused

  # @cc [owner:ghuntley,label:security] control-lilly-bind
  # A Lilly hello MUST name exactly the host its credential holds; any other
  # bind closes as refused before a request or hint is served. Execution
  # session and epoch stay in each document and are fenced by the domain.
  @impl true
  def bind(%{host_id: host_id} = principal, %{"host_id" => host_id} = bind)
      when map_size(bind) == 1,
      do: {:ok, principal, [{:host, host_id}, {:host_commands, host_id}]}

  def bind(_principal, _bind), do: {:close, :refused}

  @impl true
  def limits,
    do: Map.put(@limits, :running, Marshall.Control.Concurrency.fetch!().lilly_running)

  @impl true
  def handle_request("lilly." <> route, body, %{token: token}) do
    case ProvisionerRequests.handle(route, token, body) do
      {:ok, value} -> {:ok, value |> JSON.encode!() |> JSON.decode!()}
      result -> {:error, error_name(result)}
    end
  end

  def handle_request(_op, _body, _identity), do: {:error, "invalid_request"}

  # @cc [owner:ghuntley,label:security;protocol] control-lilly-error-names
  # Socket errors MUST carry the HTTPS route's closed reason names, with the
  # same unauthorized diagnostics, and any non-atom failure MUST become the
  # fixed "temporarily_unavailable" with the fixed transaction-failed event.
  @spec error_name(term()) :: String.t()
  defp error_name({:error, reason})
       when reason in [:unauthorized, :machine_identity_mismatch] do
    Marshall.Events.emit("api.request_unauthorized", reason: reason)
    Atom.to_string(reason)
  end

  defp error_name({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)

  # @cc [owner:ghuntley,label:security] opaque-provisioner-failure
  # Unexpected transaction errors MUST become the fixed temporarily_unavailable
  # name and fixed log event, never exposing or logging the error term or body.
  defp error_name(_result) do
    Marshall.Events.emit("provisioner.transaction_failed", [])
    "temporarily_unavailable"
  end
end
