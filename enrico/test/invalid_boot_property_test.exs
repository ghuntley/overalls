defmodule Enrico.InvalidBootPropertyTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen

  # A full matrix takes tens of seconds in fresh VMs; preserve all 100 cases.
  # The aggregate budget includes shared-host headroom; each boot stays bounded.
  @moduletag timeout: 10_800_000
  # Every probe VM is pinned to two schedulers; bound the fan-out to the host.
  @boot_concurrency min(8, max(1, div(System.schedulers_online(), 2)))
  # A boot is bounded at 30 s plus a 5 s kill grace by timeout(1); the await
  # only backstops that bound.
  @boot_await_ms 45_000
  @probe Path.expand("../scripts/invalid_boot_probe.exs", __DIR__)
  @fields ~w(bind port state_dir token_file certificate_file key_file status_socket)
  @paths ~w(state_dir token_file certificate_file key_file status_socket)
  @cases [
           :missing,
           :malformed,
           :non_object,
           :invalid_bind,
           :port_low,
           :port_high,
           :port_type,
           :token_missing,
           :token_empty,
           :token_length,
           :token_newline,
           :token_cr,
           :missing_cert,
           :missing_key,
           :state_file
         ] ++
           Enum.map([nil, false, 42, [], %{}], &{:bind_type, &1}) ++
           Enum.map(@paths, &{:relative, &1}) ++ Enum.map(@fields, &{:missing_field, &1})

  @type json_value :: nil | boolean() | number() | String.t() | [json_value()] | json_object()
  @type json_object :: %{String.t() => json_value()}
  @type mutation ::
          :missing
          | :malformed
          | :non_object
          | :invalid_bind
          | :port_low
          | :port_high
          | :port_type
          | :token_missing
          | :token_empty
          | :token_length
          | :token_newline
          | :token_cr
          | :missing_cert
          | :missing_key
          | :state_file
          | {:bind_type, json_value()}
          | {:relative, String.t()}
          | {:missing_field, String.t()}
  @type fixture_snapshot :: [
          {String.t(), atom(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
           non_neg_integer(), binary()}
        ]
  @type boot_projection :: %{String.t() => String.t() | boolean()}

  # @cc [owner:ghuntley,label:security;verification] generated-enrico-boot-refusal
  # Invalid configured runtimes MUST reject fresh OTP startup before the named
  # supervisor or reviewed Tasks/Manager/Bandit startup entry points are called.
  # Refusal MUST preserve recursive fixture contents and custody and exclude
  # credentials and fixture paths from diagnostics. Unset is an empty boot.
  property "generated invalid Enrico configurations refuse fresh OTP startup",
    profile: :ci,
    print_blob: false do
    root = private_directory("k-eb-")
    Hegel.on_cleanup(fn -> File.rm_rf!(root) end)

    order = draw("order", shuffle(@cases))
    token = draw("token", string(:alphanumeric, length: 32))
    valid_length = draw("valid_length", member_of([32, 33, 255, 256]))
    invalid_length = draw("invalid_length", member_of([31, 257, 512]))

    credential = String.slice(String.duplicate(token, 8), 0, valid_length)

    prepared =
      for mutation <- order do
        directory = Path.join(root, Integer.to_string(System.unique_integer([:positive])))
        File.mkdir!(directory)
        File.chmod!(directory, 0o700)
        config = configuration(directory, credential)
        path = Path.join(directory, "config.json")
        write_config(path, config)
        assert {:ok, _} = Enrico.Config.load(path)
        mutate(mutation, path, config, invalid_length)
        credentials = credential_bytes(config["token_file"])
        {directory, path, config["status_socket"], credentials, snapshot(directory)}
      end

    # Each mutation owns a private directory and a fresh VM, so boots are
    # independent; running them concurrently keeps every case and oracle
    # while the serial matrix (3,300 one-second boots) outran the CI job.
    booted =
      Task.async_stream(
        prepared,
        fn {_directory, path, socket, _credentials, _before} -> boot(path, socket) end,
        max_concurrency: @boot_concurrency,
        ordered: true,
        timeout: @boot_await_ms
      )

    for {{directory, _path, _socket, credentials, before}, result} <- Enum.zip(prepared, booted) do
      assert {:ok, {output, status}} = result
      assert status == 0
      assert projection(output) == expected("rejected", false, true)

      private? =
        not Enum.any?([credential, directory | credentials], &String.contains?(output, &1))

      assert private?, "boot diagnostics exposed fixture paths or credentials"
      assert snapshot(directory) == before
    end
  end

  test "unset Enrico configuration starts only an empty supervisor" do
    root = private_directory("k-eu-")
    on_exit(fn -> File.rm_rf!(root) end)
    {output, status} = boot(nil, Path.join(root, "socket"))
    assert status == 0
    assert projection(output) == expected("started", true, false)
  end

  # @cc [owner:ghuntley,label:security;verification] enrico-bind-loader-refusal
  # Generated non-string JSON bind values MUST return fixed loader refusal
  # without an exception or creation of the configured state directory.
  property "generated non-string bind values refuse without loader side effects",
    profile: :ci do
    root = private_directory("k-el-")
    Hegel.on_cleanup(fn -> File.rm_rf!(root) end)

    value =
      draw(
        "value",
        member_of([nil, false, true, 0, 42, 1.5, [], ["127.0.0.1"], %{}, %{"x" => 1}])
      )

    token = draw("token", string(:alphanumeric, length: 32))

    config = configuration(root, token)
    state = config["state_dir"]
    refute File.exists?(state)
    path = Path.join(root, "config.json")
    write_config(path, Map.put(config, "bind", value))
    before = snapshot(root)
    rejected? = match?({:error, :invalid_configuration}, Enrico.Config.load(path))
    assert rejected?, "non-string bind did not return fixed loader refusal"
    refute File.exists?(state)
    assert snapshot(root) == before
  end

  @spec private_directory(String.t()) :: Path.t()
  defp private_directory(prefix) do
    root = Path.join(System.tmp_dir!(), prefix <> Base.encode16(:crypto.strong_rand_bytes(8)))
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    root
  end

  @spec expected(String.t(), boolean(), boolean()) :: boot_projection()
  defp expected(outcome, started, rejected) do
    %{
      "outcome" => outcome,
      "start_attempted" => started,
      "serving_attempted" => false,
      "rejection_event" => rejected,
      "supervisor" => started,
      "empty_supervisor" => started,
      "tasks" => false,
      "manager" => false,
      "socket" => false
    }
  end

  # @cc [owner:ghuntley,label:verification] fresh-boot-operation-deadline
  # Each probe MUST run in a fresh VM with the complete startup oracle. A boot
  # exceeding 30 seconds MUST fail; its process group gets at most five seconds
  # to terminate before forced cleanup, independently of the aggregate budget.
  # A case MAY run its independent probes concurrently, bounded by host
  # schedulers, but MUST assert every probe's oracle in drawn order.
  @spec boot(Path.t() | nil, Path.t()) :: {String.t(), non_neg_integer()}
  defp boot(path, socket) do
    System.cmd(
      "timeout",
      [
        "--signal=TERM",
        "--kill-after=5s",
        "30s",
        "mix",
        "run",
        "--no-start",
        "--no-compile",
        "--no-deps-check",
        @probe
      ],
      env: [
        {"MIX_ENV", "test"},
        {"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1"},
        {"OVERALLS_BOOT_PROBE", "test"},
        {"OVERALLS_PROBE_ROOT", Path.dirname(socket)},
        {"OVERALLS_PROBE_SOCKET", socket},
        {"ENRICO_CONFIG_FILE", path}
      ],
      stderr_to_stdout: true
    )
  end

  @spec projection(String.t()) :: boot_projection()
  defp projection(output) do
    lines = output |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "BOOT_PROBE:"))

    decoded =
      case lines do
        [line] -> JSON.decode(String.replace_prefix(line, "BOOT_PROBE:", ""))
        _ -> :invalid
      end

    case decoded do
      {:ok, %{"outcome" => outcome} = value}
      when map_size(value) == 9 and outcome in ["rejected", "started", "other"] ->
        fields = Map.delete(value, "outcome")

        valid? =
          Enum.sort(Map.keys(fields)) ==
            Enum.sort(
              ~w(start_attempted serving_attempted rejection_event supervisor empty_supervisor tasks manager socket)
            ) and Enum.all?(Map.values(fields), &is_boolean/1)

        assert valid?, "invalid boot probe projection"
        value

      _ ->
        flunk("invalid boot probe projection")
    end
  end

  @spec configuration(Path.t(), String.t()) :: json_object()
  defp configuration(root, token) do
    File.write!(Path.join(root, "token"), token)
    File.chmod!(Path.join(root, "token"), 0o600)
    File.write!(Path.join(root, "cert"), "synthetic-certificate")
    File.write!(Path.join(root, "key"), "synthetic-key")

    %{
      "bind" => "127.0.0.1",
      "port" => 5445,
      "state_dir" => Path.join(root, "state"),
      "token_file" => Path.join(root, "token"),
      "certificate_file" => Path.join(root, "cert"),
      "key_file" => Path.join(root, "key"),
      "status_socket" => Path.join(root, "socket")
    }
  end

  @spec snapshot(Path.t()) :: fixture_snapshot()
  defp snapshot(root) do
    stat = File.lstat!(root)

    [
      {".", stat.type, stat.mode, stat.links, stat.uid, stat.gid, :crypto.hash(:sha256, "")}
      | snapshot_entries(root, "")
    ]
  end

  @spec snapshot_entries(Path.t(), String.t()) :: fixture_snapshot()
  defp snapshot_entries(root, relative) do
    root
    |> Path.join(relative)
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      child = Path.join(relative, name)
      path = Path.join(root, child)
      stat = File.lstat!(path)

      {bytes, descendants} =
        case stat.type do
          :regular -> {File.read!(path), []}
          :directory -> {"", snapshot_entries(root, child)}
          :symlink -> {File.read_link!(path), []}
          _ -> flunk("boot changed fixture file types")
        end

      [
        {child, stat.type, stat.mode, stat.links, stat.uid, stat.gid,
         :crypto.hash(:sha256, bytes)}
        | descendants
      ]
    end)
  end

  @spec credential_bytes(Path.t()) :: [String.t()]
  defp credential_bytes(path) do
    case File.read(path) do
      {:ok, ""} -> []
      {:ok, bytes} -> [bytes, String.trim_trailing(String.trim_trailing(bytes, "\n"), "\r")]
      {:error, :enoent} -> []
    end
  end

  @spec write_config(Path.t(), json_object()) :: :ok
  defp write_config(path, config), do: File.write!(path, JSON.encode!(config))

  @spec mutate(mutation(), Path.t(), json_object(), pos_integer()) :: :ok
  defp mutate(:missing, path, _, _), do: File.rm!(path)
  defp mutate(:malformed, path, _, _), do: File.write!(path, "{invalid")
  defp mutate(:non_object, path, _, _), do: File.write!(path, "[]")
  defp mutate(:token_missing, _, config, _), do: File.rm!(config["token_file"])
  defp mutate(:token_empty, _, config, _), do: File.write!(config["token_file"], "")

  defp mutate(:token_length, _, config, length),
    do: File.write!(config["token_file"], String.duplicate("x", length))

  defp mutate(:token_newline, _, config, _),
    do: File.write!(config["token_file"], File.read!(config["token_file"]) <> "\n")

  defp mutate(:token_cr, _, config, _),
    do: File.write!(config["token_file"], File.read!(config["token_file"]) <> "\r")

  defp mutate(:missing_cert, _, config, _), do: File.rm!(config["certificate_file"])
  defp mutate(:missing_key, _, config, _), do: File.rm!(config["key_file"])

  defp mutate(:state_file, _, config, _) do
    File.rmdir!(config["state_dir"])
    File.write!(config["state_dir"], "not-a-directory")
  end

  defp mutate({:bind_type, value}, path, config, _),
    do: write_config(path, Map.put(config, "bind", value))

  defp mutate({:relative, field}, path, config, _),
    do: write_config(path, Map.put(config, field, "relative"))

  defp mutate({:missing_field, field}, path, config, _),
    do: write_config(path, Map.delete(config, field))

  defp mutate(kind, path, config, _) do
    {field, value} =
      case kind do
        :invalid_bind -> {"bind", "not-an-address"}
        :port_low -> {"port", 0}
        :port_high -> {"port", 65_536}
        :port_type -> {"port", "5445"}
      end

    write_config(path, Map.put(config, field, value))
  end
end
