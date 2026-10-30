defmodule Lilly.Host.ImagePrewarm do
  @moduledoc "Asynchronous bounded prewarming; failed builds retain durable recovery state."
  use GenServer
  alias Lilly.Host.ImageTemplate
  require Lilly.Events

  @spec start_link(Lilly.Control.Config.t()) :: GenServer.on_start()
  def start_link(config), do: GenServer.start_link(__MODULE__, config)

  @impl true
  def init(config), do: {:ok, config, {:continue, :prewarm}}

  # @cc [owner:ghuntley,label:capacity;concurrency] bounded-image-prewarm
  # Prewarming MUST return from startup before bulk I/O and use at most one
  # builder at a time. It MUST skip over-budget artifacts and the dedicated
  # Inception image, and never prevent the ordinary verified creation path.
  @impl true
  def handle_continue(:prewarm, config) do
    # Templates of images no longer configured (including builds interrupted
    # mid-way) are retired first, so they never hold space or withhold a pool.
    sweep(config)

    for pool <- config.pools,
        image <- config.images,
        image.id != config.execution.inception_image_id do
      started = System.monotonic_time(:millisecond)
      # Prewarm waits for a long build rather than reporting it busy.
      result = ImageTemplate.ensure(pool, image, max(4 * pool.image_io_timeout_ms, 120_000))

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
    end

    {:noreply, config}
  end

  # A sweep that met transient contention (a reader's lease, the pool lock)
  # retries periodically instead of waiting for the next Lilly start.
  @impl true
  def handle_info(:sweep, config) do
    sweep(config)
    {:noreply, config}
  end

  def handle_info(_message, config), do: {:noreply, config}

  @sweep_interval 600_000
  defp sweep(config) do
    configured = Enum.map(config.images, & &1.id)

    for pool <- config.pools, do: ImageTemplate.retire_unconfigured(pool, configured)

    Process.send_after(self(), :sweep, @sweep_interval)
  end
end
