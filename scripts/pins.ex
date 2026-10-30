# Shared by scripts/check_pins.exs and its regression tests.
defmodule Overalls.Pins do
  @moduledoc false

  @registry "nix/domains/artifacts/dependency-hashes.json"
  @pins "nix/domains/artifacts/pins.nix"

  # Hash literal assigned to a fixed-output attribute (`hash`, `sha256`,
  # `outputHash`, `vendorHash`, `cargoHash`, `npmHash`, `*Hash`, `*Sha256`).
  @literal ~r/\b([A-Za-z0-9_]*(?:[hH]ash|[sS]ha256))\s*[=?]\s*"(sha256-[A-Za-z0-9+\/=]{44}|[0-9a-f]{64}|[0-9a-z]{52})"/

  # Reviewed exemptions. Each entry names why the literal is not a third-party
  # pin that belongs in the registry; anything else is a violation.
  @exempt %{
    # Sealed Overalls outputs: these pin our own published artifacts, not
    # third-party sources, and are asserted again by their evaluation checks.
    "nix/domains/artifacts/guest/windows/published.nix" => :sealed_output,
    "nix/domains/artifacts/guest/native-promotion/freebsd.nix" => :sealed_output,
    "nix/domains/artifacts/guest/native-promotion/freebsd-14.3-db752667.nix" => :sealed_output,
    "nix/domains/artifacts/guest/native-promotion/freebsd-14.3-db752667-f0d9275b.nix" =>
      :sealed_output,
    "nix/domains/artifacts/guest/native-promotion/omnios.nix" => :sealed_output,
    "nix/domains/artifacts/guest/native-promotion/omnios-r151050-a96f291b.nix" => :sealed_output,
    "nix/verification/tests/evaluation/windows-guest.nix" => :sealed_output,
    # The illumos SDK package table is a domain lock (name, version, digest).
    "nix/domains/artifacts/guest/native-kernels/illumos/sdk.nix" => :domain_lock,
    # The Windows editor release id hashes this recipe's text, so moving its
    # literals would invalidate the sealed native editor bundle; move them with
    # the next editor source bump.
    "nix/domains/artifacts/vscode-web/windows-source.nix" => :sealed_recipe,
    # Expected digest of the stock image's Python, asserted inside the guest;
    # it identifies an installed binary rather than pinning a fetch.
    "nix/domains/artifacts/guest/omnios/candidate.nix" => :identity_digest
  }

  @type violation ::
          {:inline, Path.t(), pos_integer(), String.t()}
          | {:unused, String.t()}
          | {:unknown, Path.t(), pos_integer(), String.t()}
          | {:cargo_lock, Path.t()}
          | :no_root_cargo_lock

  @spec registry() :: Path.t()
  def registry, do: @registry

  @spec exempt?(Path.t()) :: boolean()
  def exempt?(path), do: Map.has_key?(@exempt, path)

  @doc "Inline fixed-output hash literals outside the registry and the exemptions."
  @spec inline([{Path.t(), binary()}]) :: [violation()]
  def inline(files) do
    for {path, text} <- files,
        not exempt?(path),
        {line, number} <- Enum.with_index(String.split(text, "\n"), 1),
        not String.starts_with?(String.trim_leading(line), "#"),
        [_, _attr, literal] <- Regex.scan(@literal, line),
        do: {:inline, path, number, literal}
  end

  # @cc [owner:ghuntley,label:build;security] pin-registry-consumed
  # Every registry key MUST be read by some Nix file through pins.nix (or the
  # registry's established direct readers); a key nobody reads is a stale pin
  # that refresh tooling would update without effect.
  @doc "Registry keys that no Nix file reads, and pins.nix reads of missing keys."
  @spec registry_use(%{String.t() => String.t()}, [{Path.t(), binary()}]) :: [violation()]
  def registry_use(registry, files) do
    readers = for {path, text} <- files, path != @pins, do: {path, text}
    all = Enum.map_join(readers, "\n", &elem(&1, 1))

    unused =
      for key <- Map.keys(registry) |> Enum.sort(),
          not used?(key, all),
          do: {:unused, key}

    unknown =
      for {path, text} <- readers,
          {line, number} <- Enum.with_index(String.split(text, "\n"), 1),
          [_, key] <- Regex.scan(~r/pins\.nix\)\.([A-Za-z0-9_]+)/, line),
          not Map.has_key?(registry, key),
          do: {:unknown, path, number, key}

    unused ++ unknown
  end

  # Mix application keys are read as `hashes.${application}` by the release
  # hub; every other key is read by name.
  @spec used?(String.t(), String.t()) :: boolean()
  defp used?(key, all) do
    String.contains?(all, "pins.nix).#{key}") or String.contains?(all, "hashes.#{key}") or
      String.contains?(all, "\"#{key}\"")
  end

  # @cc [owner:ghuntley,label:build;security] single-cargo-lock
  # First-party Rust MUST resolve through exactly one Cargo.lock, the root
  # workspace lock (ADR-0273). Vendored third-party trees and Mix dependency
  # checkouts are out of scope; any other tracked lock is a violation.
  @doc "Cargo lock roots other than the root workspace lock, or its absence."
  @spec cargo_locks([Path.t()]) :: [violation()]
  def cargo_locks(paths) do
    locks =
      paths
      |> Enum.filter(&(Path.basename(&1) == "Cargo.lock"))
      |> Enum.reject(fn path ->
        segments = Path.split(path)
        Enum.any?(["vendor", "deps", "target"], &(&1 in segments))
      end)
      |> Enum.sort()

    extra = for lock <- locks, lock != "Cargo.lock", do: {:cargo_lock, lock}
    if "Cargo.lock" in locks, do: extra, else: [:no_root_cargo_lock | extra]
  end

  @spec check(Path.t()) :: [violation()]
  def check(root) do
    paths = tracked(root)

    files =
      paths
      |> Enum.filter(&String.ends_with?(&1, ".nix"))
      |> Enum.reject(&String.contains?(&1, "/deps/"))
      |> Enum.map(fn path -> {path, File.read!(Path.join(root, path))} end)

    registry = root |> Path.join(@registry) |> File.read!() |> JSON.decode!()
    inline(files) ++ registry_use(registry, files) ++ cargo_locks(paths)
  end

  @spec tracked(Path.t()) :: [Path.t()]
  defp tracked(root) do
    # The Nix check runs on the flake source (already the tracked files) with
    # no Git checkout, so fall back to walking the tree.
    with git when is_binary(git) <- System.find_executable("git"),
         true <- File.exists?(Path.join(root, ".git")),
         {output, 0} <- System.cmd(git, ["-C", root, "ls-files", "-z"], stderr_to_stdout: true) do
      String.split(output, <<0>>, trim: true)
    else
      _ ->
        root
        |> Path.join("**/{*.nix,Cargo.lock}")
        |> Path.wildcard()
        |> Enum.map(&Path.relative_to(&1, root))
    end
  end
end
