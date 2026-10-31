defmodule Marshall.ControlStubService do
  @moduledoc """
  A test-only control service with Lilly's in_flight and running limits.

  `stub.wait` reports `{:control_stub_started, n, pid}` to the test and blocks
  until that pid receives `:release`. `stub.db` serializes on one advisory
  transaction lock through the dynamic repo named in the identity, the way
  Lilly exchanges serialize on their host row, and reports start and finish so
  the test can measure concurrency. Neither touches credentials or hints.
  """
  @behaviour Marshall.Control.Service

  @typedoc "The bound test identity: the observing test process and an optional repo."
  @type identity :: %{required(:test) => pid(), optional(:repo) => pid()}

  @impl true
  @spec authenticate(binary()) :: :refused
  def authenticate(_token), do: :refused

  @impl true
  @spec bind(identity(), map()) :: {:ok, identity(), []}
  def bind(identity, _bind), do: {:ok, identity, []}

  @impl true
  @spec limits() :: %{in_flight: pos_integer(), running: pos_integer()}
  def limits, do: Map.take(Marshall.Control.Services.Lilly.limits(), [:in_flight, :running])

  @impl true
  @spec handle_request(String.t(), map(), identity()) :: {:ok, map()} | {:error, String.t()}
  def handle_request("stub.wait", %{"n" => n}, %{test: test}) when is_integer(n) do
    send(test, {:control_stub_started, n, self()})

    receive do
      :release -> {:ok, %{"n" => n}}
    end
  end

  def handle_request("stub.db", %{"n" => n}, %{test: test, repo: repo}) when is_integer(n) do
    Marshall.Repo.put_dynamic_repo(repo)
    send(test, {:control_stub_started, n, self()})

    try do
      {:ok, _} =
        Marshall.Repo.transaction(fn ->
          Marshall.Repo.query!("SELECT pg_advisory_xact_lock(274274)", [], log: false)
          Marshall.Repo.query!("SELECT pg_sleep(0.05)", [], log: false)
        end)

      {:ok, %{"n" => n}}
    rescue
      error in DBConnection.ConnectionError ->
        if error.reason == :queue_timeout,
          do: {:error, "queue_timeout"},
          else: {:error, "connection_error"}
    after
      send(test, {:control_stub_finished, n})
    end
  end

  def handle_request(_op, _body, _identity), do: {:error, "invalid_request"}
end

defmodule Marshall.ControlSocketDriver do
  @moduledoc """
  Drives `Marshall.Control.Socket` callbacks from the test process, which owns
  the request tasks exactly as the socket process does in production.
  """
  alias Marshall.Control.Socket
  alias OverallsProtocol.Control.Envelope

  @typedoc "A decoded response: request id and its result."
  @type response :: {integer(), {:ok, map()} | {:error, String.t()}}

  @doc "Opens and binds a stub socket for `identity`."
  @spec bound(Marshall.ControlStubService.identity()) :: map()
  def bound(identity) do
    {:ok, state} =
      Socket.init(%{service: "lilly", module: Marshall.ControlStubService, principal: identity})

    hello = Envelope.encode({:hello, %{service: "lilly", bind: %{}}})
    {:push, {:text, _welcome}, state} = Socket.handle_in({hello, [opcode: :text]}, state)
    state
  end

  @doc "Sends one request frame; returns the new state and any immediate responses."
  @spec request(map(), integer(), String.t()) :: {map(), [response()]}
  def request(state, id, op) do
    frame = Envelope.encode({:req, %{id: id, op: op, body: %{"n" => id}}})
    result(Socket.handle_in({frame, [opcode: :text]}, state))
  end

  @doc "Feeds one task reply or monitor message into the socket."
  @spec deliver(map(), term()) :: {map(), [response()]}
  def deliver(state, message), do: result(Socket.handle_info(message, state))

  @spec result(WebSock.handle_result()) :: {map(), [response()]}
  defp result({:ok, state}), do: {state, []}
  defp result({:push, frames, state}), do: {state, frames |> List.wrap() |> Enum.map(&decode/1)}

  @spec decode(WebSock.message()) :: response()
  defp decode({:text, text}) do
    {:ok, {:res, %{id: id, result: result}}} = Envelope.decode(text)
    {id, result}
  end
end
