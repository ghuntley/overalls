defmodule Lilly.VM.BootGenerationAdoptionPropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Lilly.Host.{Lock, PrivateFiles}
  alias Lilly.VM.{Boot, Intent}

  @placement "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"
  @moduletag :tmp_dir

  # @cc [owner:ghuntley,label:verification;recovery] continuing-boot-journal-history
  # Generated journal models MUST preserve nonce/epoch and reject old generation
  # authority after adoption, including duplicate adoption and durable rereads.
  # These isolated file histories MUST NOT establish confined VMM or guest proof;
  # production callers' physical preconditions require separate native evidence.
  @tag :hegel
  # The full 100-case budget measured 15-28 s under the parallel suite on
  # 8 local CPUs; the slower CI runner exceeded the 60 s default.
  @tag timeout: 180_000
  test "logical adoption preserves the boot but fences every older generation", %{
    tmp_dir: dir
  } do
    Hegel.check(
      fn ->
        epoch = draw("epoch", integer(1..100))
        initial = draw("initial", integer(1..100))
        advances = draw("advances", list_of(integer(1..8), min_length: 1, max_length: 6))
        path = sample_directory(dir)

        owned(path, fn ->
          {:ok, intent} = Intent.set(path, @placement, {epoch, initial}, :running)
          {:ok, original} = Boot.prepare(path, intent)
          fingerprint = :crypto.hash(:sha256, original.boot_challenge)

          Enum.reduce(advances, initial, fn advance, previous ->
            generation = previous + advance
            {:ok, current} = Intent.set(path, @placement, {epoch, generation}, :running)

            assert {:error, :boot_identity_unconfirmed} =
                     Boot.current(path, @placement, {epoch, generation})

            assert {:ok, adopted} = Boot.adopt_generation(path, current)
            assert adopted.generation == generation
            assert adopted.execution_epoch == epoch
            assert adopted.placement_id == @placement
            assert :crypto.hash(:sha256, adopted.boot_challenge) == fingerprint
            assert {:ok, ^adopted} = Boot.read(path)
            assert {:ok, ^adopted} = Boot.current(path, @placement, {epoch, generation})

            assert {:error, :boot_identity_unconfirmed} =
                     Boot.current(path, @placement, {epoch, previous})

            before_replay = File.read!(Path.join(path, "boot.json"))
            assert {:ok, ^adopted} = Boot.adopt_generation(path, current)
            assert File.read!(Path.join(path, "boot.json")) == before_replay
            generation
          end)

          :ok
        end)
      end,
      test_cases: 100
    )
  end

  # @cc [owner:ghuntley,label:verification;security] adoption-refuses-foreign-boot
  # Epoch changes and foreign placement, future-generation or corrupt journals
  # MUST remain refused and byte-identical; adoption cannot mint a new boot.
  @tag :hegel
  test "adoption cannot replace a different or unconfirmed physical boot", %{tmp_dir: dir} do
    Hegel.check(
      fn ->
        epoch = draw("epoch", integer(1..100))
        generation = draw("generation", integer(1..100))

        fault =
          draw("fault", member_of([:epoch, :placement, :future_generation, :corrupt, :missing]))

        path = sample_directory(dir)

        owned(path, fn ->
          {:ok, intent} = Intent.set(path, @placement, {epoch, generation}, :running)
          {:ok, _} = Boot.prepare(path, intent)
          boot_path = Path.join(path, "boot.json")
          original = File.read!(boot_path)

          current =
            case fault do
              :epoch ->
                {:ok, changed} = Intent.set(path, @placement, {epoch + 1, generation}, :running)
                changed

              :placement ->
                body = JSON.decode!(original) |> Map.put("placement_id", @other) |> JSON.encode!()
                :ok = PrivateFiles.write(path, "boot.json", body)
                intent

              :future_generation ->
                body =
                  JSON.decode!(original)
                  |> Map.put("generation", generation + 1)
                  |> JSON.encode!()

                :ok = PrivateFiles.write(path, "boot.json", body)
                intent

              :corrupt ->
                :ok = PrivateFiles.write(path, "boot.json", "invalid")
                intent

              :missing ->
                File.rm!(boot_path)
                intent
            end

          before = File.read(boot_path)
          assert {:error, :boot_identity_unconfirmed} = Boot.adopt_generation(path, current)
          assert File.read(boot_path) == before
          :ok
        end)
      end,
      test_cases: 100
    )
  end

  test "adoption requires ownership and the exact current running intent", %{tmp_dir: dir} do
    path = sample_directory(dir)

    owned(path, fn ->
      {:ok, old} = Intent.set(path, @placement, {1, 1}, :running)
      {:ok, _} = Boot.prepare(path, old)
      {:ok, current} = Intent.set(path, @placement, {1, 2}, :running)
      assert {:error, :boot_identity_unconfirmed} = Boot.adopt_generation(path, old)
      {:ok, stopped} = Intent.set(path, @placement, {1, 3}, :stopped)
      assert {:error, :boot_identity_unconfirmed} = Boot.adopt_generation(path, stopped)
      assert {:error, :boot_identity_unconfirmed} = Boot.adopt_generation(path, current)
      :ok
    end)

    {:ok, stopped} = Intent.read(path)
    assert {:error, :boot_identity_unconfirmed} = Boot.adopt_generation(path, stopped)
  end

  @spec sample_directory(Path.t()) :: Path.t()
  defp sample_directory(root) do
    path = Path.join(root, "adoption-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    path
  end

  @spec owned(Path.t(), (-> :ok)) :: :ok
  defp owned(path, callback) do
    {:ok, port} = Lock.acquire(Path.join(path, "owner.lock"))

    try do
      callback.()
    after
      Lock.release(port)
    end
  end
end
