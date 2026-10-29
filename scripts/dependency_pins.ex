# Shared by the scheduled security upgrade scripts and their regression tests:
# scripts/mix_security_upgrades.exs and scripts/cargo_security_upgrades.exs.
defmodule Overalls.DependencyPins do
  @moduledoc false

  # @cc [owner:ghuntley,label:security;build] security-upgrades-scope
  # Scheduled upgrades MUST update only packages that the ecosystem's audit
  # reports with a security advisory (or, for Hex, a security retirement).
  # Every lock change MUST refresh the fixed-output hashes of each affected
  # entry in the flake's `lib.dependencyPins` and be followed by a successful
  # build of that entry before anything is committed. Findings that no allowed
  # version fixes MUST fail the scheduled run after fixable updates are pushed.
  # A hash written by these jobs is checked only by that build, not by human
  # review of the fetched source.

  defmodule Finding do
    @moduledoc false
    @enforce_keys [:kind, :package, :version, :id]
    defstruct [:kind, :package, :version, :id, :severity, :summary]

    @type kind :: :advisory | :retirement
    @type t :: %__MODULE__{
            kind: kind(),
            package: String.t(),
            version: String.t(),
            id: String.t(),
            severity: String.t() | nil,
            summary: String.t() | nil
          }
  end

  defmodule HashMismatch do
    @moduledoc false
    @enforce_keys [:drv_path, :specified, :got]
    defstruct [:drv_path, :specified, :got]

    @type t :: %__MODULE__{drv_path: String.t(), specified: String.t(), got: String.t()}
  end

  @typedoc "One `lib.dependencyPins.<ecosystem>` entry: its lock files and hash keys to FOD drvPaths."
  @type target :: %{locks: [Path.t()], hashes: %{String.t() => String.t()}}
  @type ecosystem :: :mix | :cargo

  @hash_file "nix/domains/artifacts/dependency-hashes.json"
  @fake_hash "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  @max_builds 4
  @ansi ~r/\e\[[0-9;]*m/
  @mismatch ~r/hash mismatch in fixed-output derivation '([^']+\.drv)':\s*specified:\s*(\S+)\s*got:\s*(\S+)/
  @eval_apply ~S"""
  pins: builtins.mapAttrs (_: pin: {
    inherit (pin) locks;
    hashes = builtins.mapAttrs (_: fod: fod.drvPath) pin.hashes;
  }) pins
  """

  @spec fake_hash() :: String.t()
  def fake_hash, do: @fake_hash

  @spec strip_ansi(String.t()) :: String.t()
  def strip_ansi(text), do: String.replace(text, @ansi, "")

  @doc "Distinct package names to update for the given findings."
  @spec packages([Finding.t()]) :: [String.t()]
  def packages(findings), do: findings |> Enum.map(& &1.package) |> Enum.uniq() |> Enum.sort()

  @doc "Fixed-output hash mismatches reported by a Nix build log."
  @spec parse_hash_mismatches(String.t()) :: [HashMismatch.t()]
  def parse_hash_mismatches(log) do
    @mismatch
    |> Regex.scan(strip_ansi(log))
    |> Enum.map(fn [_, drv, specified, got] ->
      %HashMismatch{drv_path: drv, specified: specified, got: got}
    end)
    |> Enum.uniq()
  end

  @doc "Validates the JSON evaluated from one `lib.dependencyPins` ecosystem."
  @spec targets(term()) :: {:ok, %{String.t() => target()}} | {:error, String.t()}
  def targets(decoded) when is_map(decoded) do
    Enum.reduce_while(decoded, {:ok, %{}}, fn
      {name, %{"locks" => [_ | _] = locks, "hashes" => hashes}}, {:ok, acc}
      when is_binary(name) and is_map(hashes) ->
        cond do
          not Enum.all?(locks, &is_binary/1) ->
            {:halt, {:error, "#{name}: locks must be paths"}}

          not Enum.all?(hashes, fn {k, v} ->
            is_binary(k) and is_binary(v) and String.ends_with?(v, ".drv")
          end) ->
            {:halt, {:error, "#{name}: hashes must map keys to .drv paths"}}

          true ->
            {:cont, {:ok, Map.put(acc, name, %{locks: locks, hashes: hashes})}}
        end

      {name, _}, _ ->
        {:halt, {:error, "#{inspect(name)}: expected non-empty locks and hashes"}}
    end)
  end

  def targets(_), do: {:error, "lib.dependencyPins entries must evaluate to an attribute set"}

  @doc "Names of targets that build from any of the changed lock files."
  @spec affected(%{String.t() => target()}, [Path.t()]) :: [String.t()]
  def affected(targets, changed) do
    for {name, %{locks: locks}} <- Enum.sort(targets),
        Enum.any?(locks, &(&1 in changed)),
        do: name
  end

  @doc "Lock files no target builds from."
  @spec uncovered(%{String.t() => target()}, [Path.t()]) :: [Path.t()]
  def uncovered(targets, locks) do
    covered = targets |> Map.values() |> Enum.flat_map(& &1.locks) |> MapSet.new()
    Enum.reject(locks, &MapSet.member?(covered, &1))
  end

  @doc "Replaces the value of each given key in the dependency-hash JSON text, keeping its layout."
  @spec put_hashes(String.t(), %{String.t() => String.t()}) ::
          {:ok, String.t()} | {:error, String.t()}
  def put_hashes(json, updates) do
    Enum.reduce_while(updates, {:ok, json}, fn {key, hash}, {:ok, text} ->
      pattern = ~r/("#{Regex.escape(key)}"\s*:\s*")[^"]*(")/

      if Regex.match?(pattern, text),
        do: {:cont, {:ok, Regex.replace(pattern, text, "\\g{1}#{hash}\\g{2}", global: false)}},
        else: {:halt, {:error, "dependency-hashes.json has no #{key} entry"}}
    end)
  end

  @spec describe([Finding.t()]) :: String.t()
  def describe(findings) do
    Enum.map_join(findings, "\n", fn
      %Finding{kind: :advisory, severity: nil} = f ->
        "- #{f.package} #{f.version}: #{f.id} #{f.summary}"

      %Finding{kind: :advisory} = f ->
        "- #{f.package} #{f.version}: #{f.id} (#{f.severity}) #{f.summary}"

      %Finding{kind: :retirement} = f ->
        "- #{f.package} #{f.version}: retired for security #{f.summary}"
    end)
  end

  @doc "Markdown summary of per-lock findings, unresolved findings and refreshed hash keys."
  @spec summary(String.t(), [{Path.t(), [Finding.t()], [Finding.t()], boolean()}], [String.t()]) ::
          String.t()
  def summary(label, results, refreshed) do
    case Enum.filter(results, fn {_, findings, _, _} -> findings != [] end) do
      [] ->
        "No #{label} security findings in #{length(results)} lock files.\n"

      flagged ->
        body =
          Enum.map_join(flagged, "\n\n", fn {lock, findings, unresolved, changed} ->
            still =
              if unresolved == [],
                do: "",
                else: "\nStill vulnerable (no allowed fixed version):\n#{describe(unresolved)}"

            "#{lock}#{if changed, do: "", else: " (unchanged)"}:\n#{describe(findings)}#{still}"
          end)

        hashes =
          case Enum.uniq(refreshed) do
            [] -> ""
            keys -> "\n\nRefreshed Nix dependency hashes: #{Enum.join(Enum.sort(keys), ", ")}"
          end

        "#{label} security findings and updates:\n\n#{body}#{hashes}\n"
    end
  end

  # Side effects below are used only by the CLI scripts.

  @doc "Evaluates `lib.dependencyPins.<ecosystem>` from the flake at `root`."
  @spec targets!(Path.t(), ecosystem()) :: %{String.t() => target()}
  def targets!(root, ecosystem) do
    {json, _} =
      run!(
        root,
        "nix",
        ["eval", "--json", ".#lib.dependencyPins.#{ecosystem}", "--apply", @eval_apply],
        echo: false,
        # Warnings such as "Git tree is dirty" go to stderr and must not
        # corrupt the JSON on stdout.
        stderr: false
      )

    with {:ok, decoded} <- JSON.decode(json),
         {:ok, targets} <- targets(decoded) do
      targets
    else
      {:error, reason} -> fail("cannot read lib.dependencyPins.#{ecosystem}: #{inspect(reason)}")
    end
  end

  @doc """
  Fakes every hash the target fetches, so a fixed-output path already in the
  store cannot satisfy the new lock, then builds until each mismatch has
  revealed its real hash. Matching on the evaluated drvPath keeps keys that
  share a value apart. Returns the refreshed keys.
  """
  @spec refresh!(Path.t(), ecosystem(), String.t()) :: [String.t()]
  def refresh!(root, ecosystem, name) do
    keys = Map.keys(Map.fetch!(targets!(root, ecosystem), name).hashes)
    write_hashes!(root, Map.new(keys, &{&1, @fake_hash}))
    build!(root, ecosystem, name, 1)
    keys
  end

  @spec build!(Path.t(), ecosystem(), String.t(), pos_integer()) :: :ok
  defp build!(_root, _ecosystem, name, attempt) when attempt > @max_builds,
    do: fail("#{name}: hashes did not converge after #{@max_builds} builds")

  defp build!(root, ecosystem, name, attempt) do
    IO.puts("==> #{name}: nix build (attempt #{attempt})")
    attr = ".#lib.dependencyPins.#{ecosystem}.#{name}.build"

    {log, status} =
      run!(root, "nix", ["build", "--no-link", "--print-build-logs", attr], allow_failure: true)

    case {status, parse_hash_mismatches(log)} do
      {0, _} ->
        :ok

      {_, []} ->
        fail("#{name}: build failed")

      {_, mismatches} ->
        by_drv =
          Map.new(Map.fetch!(targets!(root, ecosystem), name).hashes, fn {key, drv} ->
            {drv, key}
          end)

        updates =
          Map.new(mismatches, fn %HashMismatch{drv_path: drv, got: got} ->
            {Map.get(by_drv, drv) || fail("#{name}: mismatch in unexpected derivation #{drv}"),
             got}
          end)

        write_hashes!(root, updates)
        build!(root, ecosystem, name, attempt + 1)
    end
  end

  @spec write_hashes!(Path.t(), %{String.t() => String.t()}) :: :ok
  defp write_hashes!(root, updates) do
    path = Path.join(root, @hash_file)

    case put_hashes(File.read!(path), updates) do
      {:ok, json} -> File.write!(path, json)
      {:error, reason} -> fail(reason)
    end
  end

  @doc "Writes the summary and unresolved findings where the caller asked, then exits 0."
  @spec finish!(keyword(), String.t(), [Finding.t()]) :: no_return()
  def finish!(opts, summary, unresolved) do
    IO.puts(summary)
    if path = opts[:summary], do: File.write!(path, summary)

    if unresolved != [] and opts[:unresolved],
      do: File.write!(opts[:unresolved], describe(unresolved) <> "\n")

    System.halt(0)
  end

  @spec run!(Path.t(), String.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def run!(dir, command, args, opts \\ []) do
    echo = Keyword.get(opts, :echo, true)

    {output, status} =
      System.cmd(command, args, cd: dir, stderr_to_stdout: Keyword.get(opts, :stderr, true))

    if echo, do: IO.write(output)

    if status != 0 and not Keyword.get(opts, :allow_failure, false) do
      unless echo, do: IO.write(output)
      fail("#{dir}: `#{command} #{Enum.join(Enum.take(args, 2), " ")}` exited #{status}")
    end

    {output, status}
  end

  @spec fail(String.t()) :: no_return()
  def fail(message) do
    IO.puts(:stderr, "error: #{message}")
    System.halt(1)
  end
end
