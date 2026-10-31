defmodule Marshall.Control.Service do
  @moduledoc """
  A service reachable over the control WebSocket (ADR-0142).

  The socket authenticates the credential at upgrade, binds the hello, then
  dispatches requests. Every callback calls existing domain functions, so
  transactions, locks, idempotency and fencing are those of the domain.
  """

  alias Marshall.Control.Hints
  alias OverallsProtocol.Control.Close

  @type principal :: term()
  @type identity :: term()
  @type subscription :: {Hints.kind(), String.t() | :all}

  @doc """
  Authenticates a bearer credential presented at upgrade. `:unavailable`
  means the check could not be completed (e.g. an undecryptable stored
  secret) and is answered as 503, never as a credential refusal.
  """
  @callback authenticate(token :: binary()) :: {:ok, principal()} | :refused | :unavailable

  @doc "Binds the hello to the authenticated principal and names the hints to deliver."
  @callback bind(principal(), bind :: map()) ::
              {:ok, identity(), [subscription()]} | {:close, Close.reason()}

  @doc "Handles one request; errors are closed snake-case names."
  @callback handle_request(op :: String.t(), body :: map(), identity()) ::
              {:ok, map()} | {:error, String.t()}

  @type limits :: %{
          frame: pos_integer(),
          inbound: pos_integer(),
          in_flight: pos_integer(),
          running: pos_integer()
        }

  @doc """
  Per-connection limits: the largest server-to-client frame (advertised in the
  welcome), the largest client-to-server frame (enforced at upgrade), the most
  accepted requests (`in_flight`, advertised) and the most of those running at
  once (`running`, server-side only; ADR-0275). Accepted requests beyond
  `running` wait in FIFO order in the socket. `running` defaults to and never
  exceeds `in_flight`. A service names only the limits it changes.
  """
  @callback limits() ::
              %{optional(:frame | :inbound | :in_flight | :running) => pos_integer()}

  @optional_callbacks limits: 0

  @default_limits %{frame: 1_048_576, inbound: 1_048_576, in_flight: 8}

  @services %{
    "audi" => Marshall.Control.Services.Audi,
    "galileo" => Marshall.Control.Services.Galileo,
    "lilly" => Marshall.Control.Services.Lilly,
    "porsche" => Marshall.Control.Services.Porsche,
    "ziggy" => Marshall.Control.Services.Ziggy,
    "peach" => Marshall.Control.Services.Peach
  }

  @doc "The limits of a service module over the defaults."
  @spec limits(module()) :: limits()
  def limits(module) do
    # function_exported?/3 does not load modules; an unloaded service would
    # otherwise silently fall back to the defaults.
    declared =
      if Code.ensure_loaded?(module) and function_exported?(module, :limits, 0),
        do: module.limits(),
        else: %{}

    limits = Map.merge(@default_limits, declared)
    Map.put(limits, :running, min(Map.get(limits, :running, limits.in_flight), limits.in_flight))
  end

  @doc "The service module for a declared service name."
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) when is_binary(name), do: Map.fetch(@services, name)
  def fetch(_name), do: :error
end
