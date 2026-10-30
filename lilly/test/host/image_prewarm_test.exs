defmodule Lilly.Host.ImagePrewarmTest do
  use ExUnit.Case, async: true
  alias Lilly.Control.Config
  alias Lilly.Host.{Image, ImagePrewarm, Pool}

  @spec config(Image.t()) :: Config.t()
  defp config(image),
    do: %Config{
      client: nil,
      state_dir: "/prewarm-test",
      cgroup_path: "/prewarm-test",
      pools: [%Pool{id: Lilly.UUID.generate(), path: "/prewarm-test", filesystem_id: "zfs:1:2"}],
      images: [image],
      execution: %{inception_image_id: nil}
    }

  @spec image() :: Image.t()
  defp image,
    do: %Image{
      id: "sha256:" <> String.duplicate("a", 64),
      path: "/nonexistent",
      manifest: %{},
      files: %{}
    }

  # Answers each prewarm attempt from `results` in order (the last repeats)
  # and reports every attempt to the test process.
  @spec scripted([Lilly.Host.ImageTemplate.result() | :uncached]) :: ImagePrewarm.ensure()
  defp scripted(results) do
    parent = self()
    {:ok, agent} = Agent.start_link(fn -> results end)

    fn _pool, _image, _wait ->
      result =
        Agent.get_and_update(agent, fn
          [only] -> {only, [only]}
          [next | rest] -> {next, rest}
        end)

      send(parent, {:attempt, result})
      result
    end
  end

  @spec start([ImagePrewarm.option()]) :: pid()
  defp start(options) do
    {:ok, pid} =
      ImagePrewarm.start_link(
        config(image()),
        [sweep: fn _config -> :ok end, retry_ms: 5, max_retry_ms: 20] ++ options
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  # @cc [owner:ghuntley,label:verification;capacity] image-prewarm-busy-retried
  # A prewarm that meets storage_busy (the pool lock held by a startup
  # snapshot) MUST be attempted again until the template is ready, and MUST
  # stop retrying once it is.
  test "a busy pool lock is retried until the template is ready" do
    start(ensure: scripted([{:error, :storage_busy}, {:error, :storage_busy}, :ok]))

    assert_receive {:attempt, {:error, :storage_busy}}, 1_000
    assert_receive {:attempt, {:error, :storage_busy}}, 1_000
    assert_receive {:attempt, :ok}, 1_000
    refute_receive {:attempt, _}, 200
  end

  test "busy retries stop at the attempt bound" do
    start(ensure: scripted([{:error, :storage_busy}]), max_attempts: 3)

    for _ <- 1..3, do: assert_receive({:attempt, {:error, :storage_busy}}, 1_000)
    refute_receive {:attempt, _}, 200
  end

  test "an unconfirmed build and an uncached image are not retried" do
    start(ensure: scripted([{:error, :template_unconfirmed}]))
    assert_receive {:attempt, {:error, :template_unconfirmed}}, 1_000
    refute_receive {:attempt, _}, 200

    start(ensure: scripted([:uncached]))
    assert_receive {:attempt, :uncached}, 1_000
    refute_receive {:attempt, _}, 200
  end

  test "stopping prewarm cancels a scheduled retry" do
    pid = start(ensure: scripted([{:error, :storage_busy}]), retry_ms: 300, max_retry_ms: 300)
    assert_receive {:attempt, {:error, :storage_busy}}, 1_000
    GenServer.stop(pid)
    refute_receive {:attempt, _}, 500
  end
end
