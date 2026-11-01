defmodule Lilly.Control.InvalidBootPropertyTest do
  use ExUnit.Case, async: false
  require Hegel
  import Hegel.Gen

  alias Lilly.Control.Config

  @moduletag :tmp_dir
  # A complete 100-boot mutation measured 224 seconds under concurrent fleet suites.
  # Keep the full exploration budget and a separate 30-second child deadline.
  @moduletag timeout: 360_000
  @id "11111111-1111-4111-8111-111111111111"
  @probe Path.expand("../../../scripts/invalid_boot_probe.exs", __DIR__)
  @mutations [
    :missing,
    :malformed,
    :oversized,
    :public_file,
    :symlink,
    :hardlink,
    :wrong_version,
    :credential_conflict,
    :relative_state,
    :overlapping_state,
    :wrong_cgroup,
    :missing_ingress,
    :invalid_rate
  ]

  @type json_value :: nil | boolean() | number() | String.t() | [json_value()] | json_object()
  @type json_object :: %{String.t() => json_value()}
  @type boot_projection :: %{
          String.t() => String.t() | boolean()
        }
  @type mutation ::
          :missing
          | :malformed
          | :oversized
          | :public_file
          | :symlink
          | :hardlink
          | :wrong_version
          | :credential_conflict
          | :relative_state
          | :overlapping_state
          | :wrong_cgroup
          | :missing_ingress
          | :invalid_rate

  # @cc [owner:ghuntley,label:security;verification] generated-invalid-lilly-boot
  # Every generated invalid private configuration MUST reject actual OTP startup
  # in a fresh BEAM before creating Runtime, supervisor or status sockets. The
  # rejection MUST preserve fixture files and exclude synthetic credentials.
  # Every mutation gets a complete exploration budget in its own fresh-boot test.
  for mutation <- @mutations do
    @mutation mutation
    @tag :hegel
    test "generated invalid #{@mutation} configuration rejects fresh OTP boot before serving", %{
      tmp_dir: directory
    } do
      File.chmod!(directory, 0o700)
      tools = execution_tools()
      mutation = @mutation

      Hegel.check(
        fn test_case ->
          :hegel.note(test_case, "credential suffix = <redacted>")
          suffix = :hegel.draw_silent(test_case, string(:alphanumeric, length: 43))

          invalid_rate =
            :hegel.draw(test_case, "invalid rate", member_of([0, -1, 1_073_741_825, "1024", nil]))

          root =
            Path.join(System.tmp_dir!(), "k-lb-" <> Base.encode16(:crypto.strong_rand_bytes(8)))

          File.mkdir!(root)
          File.chmod!(root, 0o700)
          Hegel.on_cleanup(fn -> File.rm_rf!(root) end)
          token = @id <> ":" <> suffix
          config = configuration(root, token, tools)
          path = Path.join(root, "config.json")
          write_private(path, config)
          assert {:ok, _} = Config.load(path)

          mutate(mutation, path, config, invalid_rate)
          inventory = root |> File.ls!() |> Enum.sort()
          contents = File.read(path)

          {output, status} = boot(path, root)
          assert status == 0

          assert projection(output) == %{
                   "outcome" => "rejected",
                   "child_start_attempted" => false,
                   "supervisor" => false,
                   "runtime" => false,
                   "status_socket" => false,
                   "terminal_socket" => false
                 }

          credential_free? = not String.contains?(output, token)
          started_marker_absent? = not String.contains?(output, "lilly.started")
          assert credential_free?, "boot output contained a synthetic credential"
          assert started_marker_absent?, "rejected boot emitted a started event"
          assert Enum.sort(File.ls!(root)) == inventory
          unchanged? = File.read(path) == contents
          assert unchanged?
          refute File.exists?(Path.join(root, "state"))
          refute File.exists?(Path.join(root, "vms"))
          refute File.exists?(Path.join(root, "network"))
        end,
        test_cases: 100,
        # Each case boots a fresh BEAM (several seconds). Under a loaded host
        # the engine's wall-clock `too_slow` health check (fewer than about
        # ten inputs in 30 s) failed 2 to 8 of these mutations on 2026-11-01
        # although every boot was correct. The shipped `ci` profile
        # suppresses only that check (and derandomizes, as the gate does);
        # HEGEL_DERANDOMIZE and HEGEL_SEED still override it.
        profile: :ci
      )
    end
  end

  test "an unset configuration starts only the deliberate unconfigured application", %{
    tmp_dir: root
  } do
    {output, 0} = boot(nil, root)

    assert projection(output) == %{
             "outcome" => "started",
             "child_start_attempted" => true,
             "supervisor" => true,
             "runtime" => false,
             "status_socket" => false,
             "terminal_socket" => false
           }
  end

  # @cc [owner:ghuntley,label:verification] fresh-boot-operation-deadline
  # Each probe MUST run in a fresh VM with the complete startup oracle. A boot
  # exceeding 30 seconds MUST fail; its process group gets at most five seconds
  # to terminate before forced cleanup, independently of the aggregate budget.
  @spec boot(Path.t() | nil, Path.t()) :: {String.t(), non_neg_integer()}
  defp boot(path, root) do
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
        {"OVERALLS_BOOT_PROBE", "test"},
        {"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1"},
        {"LILLY_CONFIG_FILE", path},
        {"LILLY_STATUS_SOCKET", Path.join(root, "status.sock")}
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
      {:ok,
       %{
         "outcome" => outcome,
         "child_start_attempted" => attempted,
         "supervisor" => supervisor,
         "runtime" => runtime,
         "status_socket" => status,
         "terminal_socket" => terminal
       } = value}
      when map_size(value) == 6 and outcome in ["rejected", "started", "other"] and
             is_boolean(attempted) and
             is_boolean(supervisor) and is_boolean(runtime) and is_boolean(status) and
             is_boolean(terminal) ->
        value

      _ ->
        flunk("invalid boot probe projection")
    end
  end

  @spec configuration(Path.t(), String.t(), %{String.t() => String.t()}) :: json_object()
  defp configuration(root, token, tools) do
    %{
      "version" => 4,
      "control_plane" => "https://example.test",
      "host_id" => @id,
      "credential" => token,
      "state_dir" => Path.join(root, "state"),
      "cgroup_path" => "/sys/fs/cgroup/lilly.slice",
      "execution" =>
        Map.merge(tools, %{
          "state_dir" => Path.join(root, "vms"),
          "network_state_dir" => Path.join(root, "network"),
          "egress_interface" => "eth0",
          "protected_cidrs" => []
        }),
      "pools" => []
    }
  end

  @spec execution_tools() :: %{String.t() => String.t()}
  defp execution_tools do
    Map.new(~w(firecracker jailer unshare), fn name ->
      path =
        if name in ["firecracker", "jailer"],
          do: Path.join(System.fetch_env!("OVERALLS_TEST_VMM_DIR"), name),
          else: System.find_executable(name)

      {output, 0} = System.cmd("realpath", [path])
      {name, String.trim(output)}
    end)
  end

  @spec write_private(Path.t(), json_object()) :: :ok
  defp write_private(path, value) do
    File.write!(path, JSON.encode!(value))
    File.chmod!(path, 0o600)
  end

  @spec mutate(mutation(), Path.t(), json_object(), json_value()) :: :ok
  defp mutate(:missing, path, _, _), do: File.rm!(path)

  defp mutate(:malformed, path, config, _),
    do: File.write!(path, "{invalid-json:" <> config["credential"])

  defp mutate(:oversized, path, config, _),
    do: File.write!(path, JSON.encode!(config) <> String.duplicate(" ", 65_537))

  defp mutate(:public_file, path, _, _), do: File.chmod!(path, 0o644)

  defp mutate(:symlink, path, _, _) do
    File.rename!(path, path <> ".target")
    File.ln_s!(path <> ".target", path)
  end

  defp mutate(:hardlink, path, _, _), do: File.ln!(path, path <> ".link")

  defp mutate(:wrong_version, path, config, _),
    do: write_private(path, Map.put(config, "version", 1))

  defp mutate(:credential_conflict, path, config, _),
    do: write_private(path, Map.put(config, "credential_file", path <> ".credential"))

  defp mutate(:relative_state, path, config, _),
    do: write_private(path, Map.put(config, "state_dir", "relative"))

  defp mutate(:overlapping_state, path, config, _),
    do: write_private(path, put_in(config, ["execution", "state_dir"], config["state_dir"]))

  defp mutate(:wrong_cgroup, path, config, _),
    do: write_private(path, Map.put(config, "cgroup_path", "/sys/fs/cgroup"))

  defp mutate(:missing_ingress, path, config, _),
    do: write_private(path, put_in(config, ["execution", "audi_ingress"], true))

  defp mutate(:invalid_rate, path, config, rate),
    do: write_private(path, Map.put(config, "transfer_bytes_per_second", rate))
end
