# Shared by the scheduled security upgrade scripts and their regression tests:
# scripts/mix_security_upgrades.exs and scripts/cargo_security_upgrades.exs.
defmodule Overalls.DependencyPins do
  @moduledoc false
  import Bitwise, only: [|||: 2]

  # @cc [owner:ghuntley,label:security;build] security-upgrades-scope
  # Scheduled upgrades MUST update only packages that the ecosystem's audit
  # reports with a security advisory (or, for Hex, a security retirement).
  # Every lock change MUST refresh the fixed-output hashes of each affected
  # entry in the flake's `lib.dependencyPins` and be followed by a successful
  # build of that entry (its fixed-output fetches, then its Buck2 targets)
  # before anything is committed. Findings that no allowed
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

  @typedoc """
  One `lib.dependencyPins.<ecosystem>` entry: its lock files, hash keys to FOD
  drvPaths, and the Buck2 targets that build against those fetches.
  """
  @type target :: %{
          locks: [Path.t()],
          hashes: %{String.t() => String.t()},
          buck_targets: [String.t()]
        }
  @typedoc "One `lib.dependencyPins.fetch` entry: the files declaring its fetches and its registry keys."
  @type fetch_target :: %{locks: [Path.t()], keys: [String.t()]}
  @type ecosystem :: :mix | :cargo
  @typedoc "How a registry value is written: an SRI string or bare base-16."
  @type hash_format :: :sri | :base16

  @hash_file "nix/domains/artifacts/dependency-hashes.json"
  @fake_hash "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  @max_builds 4
  @ansi ~r/\e\[[0-9;]*m/
  @mismatch ~r/hash mismatch in fixed-output derivation '([^']+\.drv)':\s*specified:\s*(\S+)\s*got:\s*(\S+)/
  @eval_apply ~S"""
  pins: builtins.mapAttrs (_: pin: {
    inherit (pin) locks;
    hashes = builtins.mapAttrs (_: fod: fod.drvPath) pin.hashes;
    buckTargets = pin.buckTargets or [ ];
  }) pins
  """

  @spec fake_hash() :: String.t()
  def fake_hash, do: @fake_hash

  @nix32 ~c"0123456789abcdfghijklmnpqrsvwxyz"
  @download_mismatch ~r/hash mismatch in file downloaded from '([^']+)':\s*specified:\s*(\S+)\s*got:\s*(\S+)/

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
      {name, %{"locks" => [_ | _] = locks, "hashes" => hashes, "buckTargets" => buck_targets}},
      {:ok, acc}
      when is_binary(name) and is_map(hashes) and is_list(buck_targets) ->
        cond do
          not Enum.all?(locks, &is_binary/1) ->
            {:halt, {:error, "#{name}: locks must be paths"}}

          not Enum.all?(hashes, fn {k, v} ->
            is_binary(k) and is_binary(v) and String.ends_with?(v, ".drv")
          end) ->
            {:halt, {:error, "#{name}: hashes must map keys to .drv paths"}}

          not Enum.all?(buck_targets, &buck_label?/1) ->
            {:halt, {:error, "#{name}: buckTargets must be root// target labels"}}

          true ->
            {:cont,
             {:ok,
              Map.put(acc, name, %{locks: locks, hashes: hashes, buck_targets: buck_targets})}}
        end

      {name, _}, _ ->
        {:halt, {:error, "#{inspect(name)}: expected non-empty locks, hashes and buckTargets"}}
    end)
  end

  def targets(_), do: {:error, "lib.dependencyPins entries must evaluate to an attribute set"}

  @doc "Validates the JSON evaluated from `lib.dependencyPins.fetch`."
  @spec fetch_targets(term()) :: {:ok, %{String.t() => fetch_target()}} | {:error, String.t()}
  def fetch_targets(decoded) when is_map(decoded) do
    Enum.reduce_while(decoded, {:ok, %{}}, fn
      {name, %{"locks" => [_ | _] = locks, "keys" => [_ | _] = keys}}, {:ok, acc}
      when is_binary(name) ->
        if Enum.all?(locks ++ keys, &is_binary/1),
          do: {:cont, {:ok, Map.put(acc, name, %{locks: locks, keys: keys})}},
          else: {:halt, {:error, "#{name}: locks and keys must be strings"}}

      {name, _}, _ ->
        {:halt, {:error, "#{inspect(name)}: expected non-empty locks and keys"}}
    end)
  end

  def fetch_targets(_), do: {:error, "lib.dependencyPins.fetch must evaluate to an attribute set"}

  @doc """
  Registry keys that no ecosystem refreshes, and keys claimed more than once.
  `claims` lists every key each entry of every ecosystem names.
  """
  @spec coverage([String.t()], [String.t()]) :: %{
          uncovered: [String.t()],
          duplicated: [String.t()],
          unknown: [String.t()]
        }
  def coverage(registry_keys, claims) do
    claimed = MapSet.new(claims)
    registry = MapSet.new(registry_keys)

    %{
      uncovered: registry |> MapSet.difference(claimed) |> Enum.sort(),
      duplicated:
        claims
        |> Enum.frequencies()
        |> Enum.filter(fn {_, n} -> n > 1 end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort(),
      unknown: claimed |> MapSet.difference(registry) |> Enum.sort()
    }
  end

  @typedoc "One `lib.dependencyPins.domain` entry: guest domain locks and how they are regenerated."
  @type domain_target :: %{locks: [Path.t()], updater: Path.t() | nil, procedure: Path.t()}

  @doc "Validates the JSON evaluated from `lib.dependencyPins.domain`."
  @spec domain_targets(term()) :: {:ok, %{String.t() => domain_target()}} | {:error, String.t()}
  def domain_targets(decoded) when is_map(decoded) do
    Enum.reduce_while(decoded, {:ok, %{}}, fn
      {name, %{"locks" => [_ | _] = locks, "updater" => updater, "procedure" => procedure}},
      {:ok, acc}
      when is_binary(name) and (is_binary(updater) or is_nil(updater)) and is_binary(procedure) ->
        if Enum.all?(locks, &is_binary/1),
          do:
            {:cont,
             {:ok, Map.put(acc, name, %{locks: locks, updater: updater, procedure: procedure})}},
          else: {:halt, {:error, "#{name}: locks must be paths"}}

      {name, _}, _ ->
        {:halt, {:error, "#{inspect(name)}: expected locks, updater (or null) and procedure"}}
    end)
  end

  def domain_targets(_),
    do: {:error, "lib.dependencyPins.domain must evaluate to an attribute set"}

  @doc """
  Problems with the domain registry: tracked `*.lock.json` files under `nix/`
  that no entry names, and registered locks, updaters or procedures for which
  `exists?` is false.
  """
  @spec domain_problems(%{String.t() => domain_target()}, [Path.t()], (Path.t() -> boolean())) ::
          [String.t()]
  def domain_problems(targets, tracked, exists?) do
    registered = targets |> Map.values() |> Enum.flat_map(& &1.locks) |> MapSet.new()

    unregistered =
      for path <- Enum.sort(tracked),
          String.starts_with?(path, "nix/"),
          String.ends_with?(path, ".lock.json"),
          not MapSet.member?(registered, path),
          do: "#{path} is a domain lock no lib.dependencyPins.domain entry names"

    missing =
      for {name, target} <- Enum.sort(targets),
          path <- target.locks ++ [target.updater, target.procedure],
          is_binary(path),
          not exists?.(path),
          do: "#{name}: #{path} does not exist"

    unregistered ++ missing
  end

  @domain_apply ~S"""
  pins: builtins.mapAttrs (_: pin: { inherit (pin) locks updater procedure; }) pins
  """

  @doc "Evaluates `lib.dependencyPins.domain` from the flake at `root`."
  @spec domain_targets!(Path.t()) :: %{String.t() => domain_target()}
  def domain_targets!(root) do
    {json, _} =
      run!(
        root,
        "nix",
        ["eval", "--json", ".#lib.dependencyPins.domain", "--apply", @domain_apply],
        echo: false,
        stderr: false
      )

    with {:ok, decoded} <- JSON.decode(json),
         {:ok, targets} <- domain_targets(decoded) do
      targets
    else
      {:error, reason} -> fail("cannot read lib.dependencyPins.domain: #{inspect(reason)}")
    end
  end

  @doc "Keys that are neither already resolved nor matched to a fetch derivation."
  @spec missing_keys([String.t()], [String.t()], [String.t()]) :: [String.t()]
  def missing_keys(keys, resolved, matched), do: (keys -- resolved) -- matched

  @doc "Names of fetch entries whose declaring files include any changed path."
  @spec affected_fetches(%{String.t() => fetch_target()}, [Path.t()]) :: [String.t()]
  def affected_fetches(targets, changed) do
    for {name, %{locks: locks}} <- Enum.sort(targets),
        Enum.any?(locks, &(&1 in changed)),
        do: name
  end

  @doc """
  Decodes a SHA-256 written as SRI (`sha256-<base64>`), `sha256:<nix32>`,
  bare base-16 or bare nix32 into its 32 digest bytes.
  """
  @spec digest(String.t()) :: {:ok, <<_::256>>} | :error
  def digest("sha256-" <> base64) do
    case Base.decode64(base64) do
      {:ok, <<_::256>> = bytes} -> {:ok, bytes}
      _ -> :error
    end
  end

  def digest("sha256:" <> rest), do: digest(rest)

  def digest(text) when byte_size(text) == 64 do
    case Base.decode16(text, case: :mixed) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> :error
    end
  end

  def digest(text) when byte_size(text) == 52, do: nix32_decode(text)
  def digest(_), do: :error

  @spec nix32_decode(String.t()) :: {:ok, <<_::256>>} | :error
  defp nix32_decode(text) do
    chars = String.to_charlist(text)

    if Enum.all?(chars, &(&1 in @nix32)) do
      # Nix writes the least significant 5-bit group last.
      value =
        chars
        |> Enum.reverse()
        |> Enum.with_index()
        |> Enum.reduce(0, fn {char, n}, acc ->
          acc ||| Bitwise.bsl(Enum.find_index(@nix32, &(&1 == char)), n * 5)
        end)

      if value < Bitwise.bsl(1, 256),
        do: {:ok, :binary.encode_unsigned(value, :little) |> pad_digest()},
        else: :error
    else
      :error
    end
  end

  defp pad_digest(bytes), do: bytes <> :binary.copy(<<0>>, 32 - byte_size(bytes))

  @doc "The registry format of a value; the refresh writes a new hash in the same format."
  @spec hash_format(String.t()) :: {:ok, hash_format()} | :error
  def hash_format(value) do
    cond do
      String.starts_with?(value, "sha256-") and digest(value) != :error -> {:ok, :sri}
      byte_size(value) == 64 and digest(value) != :error -> {:ok, :base16}
      true -> :error
    end
  end

  @spec encode(<<_::256>>, hash_format()) :: String.t()
  def encode(bytes, :sri), do: "sha256-" <> Base.encode64(bytes)
  def encode(bytes, :base16), do: Base.encode16(bytes, case: :lower)

  @doc """
  A placeholder hash unique to `key`. Faking each key with its own value lets
  a reported mismatch name its key without knowing the derivation in advance,
  and no store path can already satisfy it.
  """
  @spec fake_digest(String.t()) :: <<_::256>>
  def fake_digest(key), do: :crypto.hash(:sha256, "overalls-fetch-pin-placeholder:" <> key)

  @doc "Evaluation-time download mismatches (`builtins.fetchTarball`) as specified/got pairs."
  @spec parse_download_mismatches(String.t()) :: [{String.t(), String.t()}]
  def parse_download_mismatches(log) do
    @download_mismatch
    |> Regex.scan(strip_ansi(log))
    |> Enum.map(fn [_, _url, specified, got] -> {specified, got} end)
    |> Enum.uniq()
  end

  @doc """
  Fixed-output derivations in `nix derivation show --recursive` JSON whose
  output hash is one of `by_digest`'s digests, mapped to that digest's key.
  """
  @spec hashed_derivations(term(), %{binary() => String.t()}) :: %{
          String.t() => String.t()
        }
  def hashed_derivations(%{"derivations" => derivations}, by_digest)
      when is_map(derivations) do
    hashed_derivations(
      Map.new(derivations, fn {name, drv} -> {Path.join("/nix/store", name), drv} end),
      by_digest
    )
  end

  def hashed_derivations(derivations, by_digest) when is_map(derivations) do
    for {path, %{"outputs" => %{"out" => %{"hash" => hash}}}} <- derivations,
        is_binary(hash),
        {:ok, bytes} <- [digest(hash)],
        key = Map.get(by_digest, bytes),
        key != nil,
        into: %{},
        do: {path, key}
  end

  # A plain `root//package:name` label: no flags, patterns or spaces reach argv.
  @spec buck_label?(term()) :: boolean()
  defp buck_label?(label),
    do: is_binary(label) and Regex.match?(~r{\Aroot//[A-Za-z0-9_./-]*:[A-Za-z0-9_.+-]+\z}, label)

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
    build_buck!(root, name, Map.fetch!(targets!(root, ecosystem), name).buck_targets)
    keys
  end

  # The Buck2 builds that consume the refreshed fetches (ADR-0269): Buck2 is
  # the build entry point, so a release or suite against the new lock is
  # proved here rather than by a Nix build of it.
  @spec build_buck!(Path.t(), String.t(), [String.t()]) :: :ok
  defp build_buck!(_root, _name, []), do: :ok

  defp build_buck!(root, name, labels) do
    IO.puts("==> #{name}: tools/buck2 build #{Enum.join(labels, " ")}")
    {_, 0} = run!(root, Path.join(root, "tools/buck2"), ["build" | labels])
    :ok
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

  @fetch_apply ~S"""
  pins: builtins.mapAttrs (_: pin: { inherit (pin) locks keys; }) pins
  """

  @doc "Evaluates `lib.dependencyPins.fetch` from the flake at `root`."
  @spec fetch_targets!(Path.t()) :: %{String.t() => fetch_target()}
  def fetch_targets!(root) do
    {json, _} =
      run!(root, "nix", ["eval", "--json", ".#lib.dependencyPins.fetch", "--apply", @fetch_apply],
        echo: false,
        stderr: false
      )

    with {:ok, decoded} <- JSON.decode(json),
         {:ok, targets} <- fetch_targets(decoded) do
      targets
    else
      {:error, reason} -> fail("cannot read lib.dependencyPins.fetch: #{inspect(reason)}")
    end
  end

  @doc "The decoded registry."
  @spec registry!(Path.t()) :: %{String.t() => String.t()}
  def registry!(root) do
    case JSON.decode(File.read!(Path.join(root, @hash_file))) do
      {:ok, %{} = registry} -> registry
      other -> fail("#{@hash_file}: #{inspect(other)}")
    end
  end

  @doc "Every registry key claimed by a mix, cargo or fetch entry, once per claim."
  @spec claims!(Path.t(), %{String.t() => fetch_target()}) :: [String.t()]
  def claims!(root, fetch) do
    locked =
      for ecosystem <- [:mix, :cargo],
          {_, %{hashes: hashes}} <- targets!(root, ecosystem),
          key <- Map.keys(hashes),
          do: key

    locked ++ Enum.flat_map(Map.values(fetch), & &1.keys)
  end

  @doc """
  Refreshes one fetch entry: writes a placeholder per key (in the key's own
  format), resolves evaluation-time downloads, finds the placeholder
  fixed-output derivations in the entry's closure, builds them to learn the
  real hashes and builds the fetches again with those hashes. Returns each
  key's previous and new value.
  """
  @spec refresh_fetch!(Path.t(), String.t()) :: %{String.t() => {String.t(), String.t()}}
  def refresh_fetch!(root, name) do
    %{keys: keys} = Map.fetch!(fetch_targets!(root), name)
    registry = registry!(root)

    formats =
      Map.new(keys, fn key ->
        with value when is_binary(value) <- Map.get(registry, key),
             {:ok, format} <- hash_format(value) do
          {key, format}
        else
          _ -> fail("#{name}: #{key} is not a SHA-256 in #{@hash_file}")
        end
      end)

    by_digest = Map.new(keys, &{fake_digest(&1), &1})
    write_hashes!(root, Map.new(keys, &{&1, encode(fake_digest(&1), formats[&1])}))

    found = resolve_fetches!(root, name, keys, by_digest, formats, %{}, 1)
    write_hashes!(root, found)

    verify_fetches!(
      root,
      name,
      Map.new(found, fn {key, value} -> {elem(digest(value), 1), key} end)
    )

    Map.new(found, fn {key, value} -> {key, {registry[key], value}} end)
  end

  # One round evaluates the closure (resolving evaluation-time downloads),
  # finds the fetches still carrying a placeholder and builds them. A fetch
  # that depends on another placeholder fetch (a Go or Cargo vendor of a
  # source) can only report its hash in a later round, after its source's
  # real hash is written.
  @spec resolve_fetches!(
          Path.t(),
          String.t(),
          [String.t()],
          %{binary() => String.t()},
          %{String.t() => hash_format()},
          %{String.t() => String.t()},
          pos_integer()
        ) :: %{String.t() => String.t()}
  defp resolve_fetches!(root, name, keys, by_digest, formats, found, attempt) do
    pending = Map.reject(by_digest, fn {_, key} -> Map.has_key?(found, key) end)
    found = resolve_downloads!(root, name, pending, formats, found, 1)
    pending = Map.reject(pending, fn {_, key} -> Map.has_key?(found, key) end)
    fods = hashed_derivations(show_derivations!(root, closure_drv!(root, name)), pending)

    case missing_keys(Map.values(pending), [], Map.values(fods)) do
      [] -> :ok
      missing -> fail("#{name}: no fetch in its closure uses #{Enum.join(missing, ", ")}")
    end

    updates = build_placeholders!(root, name, fods, pending, formats)
    write_hashes!(root, updates)
    found = Map.merge(found, updates)

    case missing_keys(keys, Map.keys(found), []) do
      [] ->
        found

      missing when updates == %{} or attempt >= @max_builds ->
        fail("#{name}: Nix reported no hash for #{Enum.join(missing, ", ")}")

      _ ->
        resolve_fetches!(root, name, keys, by_digest, formats, found, attempt + 1)
    end
  end

  # Evaluating the closure performs evaluation-time downloads; each mismatch
  # names a placeholder and the real hash.
  @spec resolve_downloads!(
          Path.t(),
          String.t(),
          %{binary() => String.t()},
          %{String.t() => hash_format()},
          %{String.t() => String.t()},
          pos_integer()
        ) :: %{String.t() => String.t()}
  defp resolve_downloads!(_root, name, _by_digest, _formats, _found, attempt)
       when attempt > @max_builds,
       do: fail("#{name}: evaluation-time downloads did not converge")

  defp resolve_downloads!(root, name, by_digest, formats, found, attempt) do
    {log, status} = eval_closure(root, name)

    case {status, parse_download_mismatches(log)} do
      {0, _} ->
        found

      {_, []} ->
        IO.write(log)
        fail("#{name}: cannot evaluate its closure")

      {_, mismatches} ->
        updates = mismatch_updates!(name, mismatches, by_digest, formats)
        write_hashes!(root, updates)
        resolve_downloads!(root, name, by_digest, formats, Map.merge(found, updates), attempt + 1)
    end
  end

  @spec eval_closure(Path.t(), String.t()) :: {String.t(), non_neg_integer()}
  defp eval_closure(root, name) do
    run!(root, "nix", ["eval", "--raw", ".#lib.dependencyPins.fetch.#{name}.closure.drvPath"],
      echo: false,
      allow_failure: true
    )
  end

  @spec closure_drv!(Path.t(), String.t()) :: String.t()
  defp closure_drv!(root, name) do
    {out, _} =
      run!(root, "nix", ["eval", "--raw", ".#lib.dependencyPins.fetch.#{name}.closure.drvPath"],
        echo: false,
        stderr: false
      )

    out
  end

  @spec show_derivations!(Path.t(), String.t()) :: term()
  defp show_derivations!(root, drv) do
    {json, _} =
      run!(root, "nix", ["derivation", "show", "--recursive", drv], echo: false, stderr: false)

    case JSON.decode(json) do
      {:ok, decoded} -> decoded
      {:error, reason} -> fail("cannot read derivations of #{drv}: #{inspect(reason)}")
    end
  end

  @spec mismatch_updates!(
          String.t(),
          [{String.t(), String.t()}],
          %{binary() => String.t()},
          %{String.t() => hash_format()}
        ) :: %{String.t() => String.t()}
  defp mismatch_updates!(name, mismatches, by_digest, formats) do
    Map.new(mismatches, fn {specified, got} ->
      with {:ok, placeholder} <- digest(specified),
           key when is_binary(key) <- Map.get(by_digest, placeholder),
           {:ok, bytes} <- digest(got) do
        {key, encode(bytes, formats[key])}
      else
        _ -> fail("#{name}: unexpected hash mismatch #{specified} -> #{got}")
      end
    end)
  end

  @spec build_placeholders!(
          Path.t(),
          String.t(),
          %{String.t() => String.t()},
          %{binary() => String.t()},
          %{String.t() => hash_format()}
        ) :: %{String.t() => String.t()}
  defp build_placeholders!(_root, _name, fods, _by_digest, _formats) when fods == %{}, do: %{}

  defp build_placeholders!(root, name, fods, by_digest, formats) do
    IO.puts("==> #{name}: fetching #{map_size(fods)} placeholder derivations")

    {log, _} =
      run!(
        root,
        "nix",
        ["build", "--no-link", "--keep-going", "--print-build-logs"] ++
          Enum.map(Map.keys(fods), &(&1 <> "^out")),
        allow_failure: true
      )

    log
    |> parse_hash_mismatches()
    |> Enum.map(fn %HashMismatch{specified: specified, got: got} -> {specified, got} end)
    |> then(&mismatch_updates!(name, &1, by_digest, formats))
  end

  # The real hashes must now fetch: find each key's derivation by its new
  # hash and build it.
  @spec verify_fetches!(Path.t(), String.t(), %{binary() => String.t()}) :: :ok
  defp verify_fetches!(root, name, by_digest) do
    {_, 0} = resolve_or_fail(root, name)
    fods = hashed_derivations(show_derivations!(root, closure_drv!(root, name)), by_digest)
    IO.puts("==> #{name}: verifying #{map_size(fods)} fetches")

    if fods != %{} do
      run!(
        root,
        "nix",
        ["build", "--no-link", "--print-build-logs"] ++
          Enum.map(Map.keys(fods), &(&1 <> "^out"))
      )
    end

    :ok
  end

  @spec resolve_or_fail(Path.t(), String.t()) :: {String.t(), 0}
  defp resolve_or_fail(root, name) do
    case eval_closure(root, name) do
      {out, 0} ->
        {out, 0}

      {log, _} ->
        IO.write(log)
        fail("#{name}: closure does not evaluate with the new hashes")
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
