defmodule Marshall.Control.Concurrency do
  @moduledoc """
  Typed configuration for how many control requests one socket runs at once
  (ADR-0275).

  A Lilly host socket accepts up to its advertised `in_flight` requests but runs
  at most `lilly_running` of them; the rest wait in FIFO order in the socket
  process. Every Lilly exchange serializes on its host row, so running more of
  them at once only parks pooled database connections behind that row lock.
  A queued request that waited `queue_deadline_ms` is refused as
  `temporarily_unavailable` instead of being started: by then Lilly's own
  5 s request deadline has (nearly) passed, so starting it would produce a
  domain effect whose answer nobody receives.
  """

  @enforce_keys [:lilly_running, :queue_deadline_ms]
  defstruct @enforce_keys

  @typedoc "Validated control-socket concurrency settings."
  @type t :: %__MODULE__{lilly_running: 1..64, queue_deadline_ms: 1..5_000}

  @defaults [lilly_running: 2, queue_deadline_ms: 4_000]

  # @cc [owner:ghuntley,label:capacity;reliability] control-concurrency-validated
  # The running bound MUST be an integer in 1..64 (64 is Lilly's advertised
  # in_flight, so a bound never refuses more than before) and the queue
  # deadline an integer in 1..5000 ms (never later than Lilly's 5 s request
  # deadline). Any other configured value MUST fail Marshall's boot rather than
  # fall back silently.
  @doc "Reads and validates `config :marshall, #{inspect(__MODULE__)}`; raises on invalid values."
  @spec fetch!() :: t()
  def fetch! do
    case :marshall |> Application.get_env(__MODULE__, []) |> parse() do
      {:ok, config} -> config
      :error -> raise ArgumentError, "invalid #{inspect(__MODULE__)} configuration"
    end
  end

  @doc "Validates a keyword configuration over the defaults."
  @spec parse(term()) :: {:ok, t()} | :error
  def parse(options) when is_list(options) do
    if Keyword.keyword?(options) and Keyword.keys(options) -- Keyword.keys(@defaults) == [] do
      options = Keyword.merge(@defaults, options)

      with {:ok, running} <- integer(options[:lilly_running], 1..64),
           {:ok, deadline} <- integer(options[:queue_deadline_ms], 1..5_000) do
        {:ok, %__MODULE__{lilly_running: running, queue_deadline_ms: deadline}}
      end
    else
      :error
    end
  end

  def parse(_options), do: :error

  # Release environment values arrive as decimal strings.
  @spec integer(term(), Range.t()) :: {:ok, integer()} | :error
  defp integer(value, %Range{first: first, last: last})
       when is_integer(value) and value >= first and value <= last,
       do: {:ok, value}

  defp integer(value, range) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer(integer, range)
      _ -> :error
    end
  end

  defp integer(_value, _range), do: :error
end
