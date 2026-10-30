defmodule Lilly.Host.ImagePrewarm do
  @moduledoc "Asynchronous bounded prewarming; failed builds retain durable recovery state."
  use GenServer
  alias Lilly.Host.{Image, ImageTemplate, Pool}
  require Lilly.Events

  @type ensure :: (Pool.t(), Image.t(), pos_integer() -> ImageTemplate.result() | :uncached)
  @type option ::
          {:ensure, ensure()}
          | {:sweep, (Lilly.Control.Config.t() -> term())}
          | {:retry_ms, pos_integer()}
          | {:max_retry_ms, pos_integer()}
          | {:max_attempts, pos_integer()}

  @typep state :: %{
           config: Lilly.Control.Config.t(),
           ensure: ensure(),
           sweep: (Lilly.Control.Config.t() -> term()),
           retry_ms: pos_integer(),
           max_retry_ms: pos_integer(),
           max_attempts: pos_integer()
         }

  @sweep_interval 600_000
  @retry_ms 5_000
  @max_retry_ms 60_000
  # 5 + 10 + 20 + 40 + 60 × 5 s: about six minutes of busy retries per image.
  @max_attempts 10

  @spec start_link(Lilly.Control.Config.t(), [option()]) :: GenServer.on_start()
  def start_link(config, options \\ []), do: GenServer.start_link(__MODULE__, {config, options})

  @impl true
  @spec init({Lilly.Control.Config.t(), [option()]}) :: {:ok, state(), {:continue, :prewarm}}
  def init({config, options}) do
    {:ok,
     %{
       config: config,
       ensure: Keyword.get(options, :ensure, &ImageTemplate.ensure/3),
       sweep: Keyword.get(options, :sweep, &retire_unconfigured/1),
       retry_ms: Keyword.get(options, :retry_ms, @retry_ms),
       max_retry_ms: Keyword.get(options, :max_retry_ms, @max_retry_ms),
       max_attempts: Keyword.get(options, :max_attempts, @max_attempts)
     }, {:continue, :prewarm}}
  end

  # @cc [owner:ghuntley,label:capacity;concurrency] bounded-image-prewarm
  # Prewarming MUST return from startup before bulk I/O and use at most one
  # builder at a time. It MUST skip over-budget artifacts and the dedicated
  # Inception image, and never prevent the ordinary verified creation path.
  @impl true
  def handle_continue(:prewarm, state) do
    # Templates of images no longer configured (including builds interrupted
    # mid-way) are retired first, so they never hold space or withhold a pool.
    sweep(state)

    for pool <- state.config.pools,
        image <- state.config.images,
        image.id != state.config.execution.inception_image_id do
      prewarm(state, pool, image, 1)
    end

    {:noreply, state}
  end

  # A sweep that met transient contention (a reader's lease, the pool lock)
  # retries periodically instead of waiting for the next Lilly start.
  @impl true
  def handle_info(:sweep, state) do
    sweep(state)
    {:noreply, state}
  end

  def handle_info({:retry, pool_id, image_id, attempt}, state) do
    with %Pool{} = pool <- Enum.find(state.config.pools, &(&1.id == pool_id)),
         %Image{} = image <- Enum.find(state.config.images, &(&1.id == image_id)) do
      prewarm(state, pool, image, attempt)
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # @cc [owner:ghuntley,label:capacity;recovery] image-prewarm-retries-busy
  # A prewarm attempt that reports storage_busy (pool-lock or steward-wait
  # contention) MUST be retried from this process after a doubling delay capped
  # at max_retry_ms, at most max_attempts attempts in all. Ready, uncached and
  # any other outcome MUST NOT be retried. Retries MUST stay sequential in this
  # process and end with it; a busy prewarm MUST NOT be reported as a failure.
  defp prewarm(state, pool, image, attempt) do
    started = System.monotonic_time(:millisecond)
    # Prewarm waits for a long build rather than reporting it busy.
    result = state.ensure.(pool, image, max(4 * pool.image_io_timeout_ms, 120_000))

    outcome =
      case result do
        :ok -> :ready
        :uncached -> :uncached
        {:error, :storage_busy} -> :busy
        _ -> :unconfirmed
      end

    Lilly.Events.emit("lilly.image_prewarm_finished",
      pool_id: pool.id,
      outcome: outcome,
      duration_ms: max(System.monotonic_time(:millisecond) - started, 0)
    )

    if outcome == :busy and attempt < state.max_attempts do
      delay = min(state.retry_ms * Integer.pow(2, attempt - 1), state.max_retry_ms)

      Lilly.Events.emit("lilly.image_prewarm_retry_scheduled",
        pool_id: pool.id,
        attempt: attempt + 1,
        delay_ms: delay
      )

      Process.send_after(self(), {:retry, pool.id, image.id, attempt + 1}, delay)
    end

    :ok
  end

  defp sweep(state) do
    state.sweep.(state.config)
    Process.send_after(self(), :sweep, @sweep_interval)
  end

  defp retire_unconfigured(config) do
    configured = Enum.map(config.images, & &1.id)
    for pool <- config.pools, do: ImageTemplate.retire_unconfigured(pool, configured)
  end
end
