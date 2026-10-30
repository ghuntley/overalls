# Applies RustSec security updates to the root Cargo.lock and refreshes Nix hashes.
#
# Usage: elixir scripts/cargo_security_upgrades.exs [--summary PATH] [--unresolved PATH]
# Run from the repository root inside `devenv shell` with `cargo-audit` on PATH.
# The repository tracks exactly one Cargo.lock, the root workspace lock
# (ADR-0273); any other tracked lock is refused before anything changes. It is
# audited with `cargo audit` from the repository root (so a reviewed
# `.cargo/audit.toml` there can ignore an advisory); only crates with a
# vulnerability are updated, with `cargo update --package NAME@VERSION`.
# The lock MUST belong to an entry of the flake's
# `lib.dependencyPins.cargo`; each entry whose lock changed gets fresh
# fixed-output hashes in nix/domains/artifacts/dependency-hashes.json and must
# then build. The script never commits; it exits non-zero on any failure. The
# Markdown summary goes to --summary; findings that no allowed version fixes
# are written to --unresolved so the caller can keep the fixable updates and
# still fail.
Code.require_file("dependency_pins.ex", __DIR__)
Code.require_file("cargo_security_upgrades.ex", __DIR__)

defmodule Overalls.CargoSecurityUpgrades.CLI do
  @moduledoc false
  alias Overalls.{CargoSecurityUpgrades, DependencyPins}
  alias Overalls.DependencyPins.Finding
  import DependencyPins, only: [fail: 1, run!: 3, run!: 4]

  @type result :: {Path.t(), [Finding.t()], [Finding.t()], boolean()}

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    {opts, [], []} = OptionParser.parse(argv, strict: [summary: :string, unresolved: :string])
    root = File.cwd!()
    File.exists?(Path.join(root, "flake.nix")) || fail("run from the repository root")

    {listing, _} = run!(root, "git", ["ls-files", "-z", "--", "*Cargo.lock"], echo: false)
    locks = CargoSecurityUpgrades.lock_paths(listing)

    case CargoSecurityUpgrades.single_root_lock(locks) do
      :ok ->
        :ok

      {:error, extra} ->
        fail(
          "ADR-0273 allows only the root Cargo.lock; merge these into the workspace: " <>
            Enum.join(extra, ", ")
        )
    end

    # Refuse before updating anything: an unregistered lock could change
    # without any Nix build proving the software still compiles.
    targets = DependencyPins.targets!(root, :cargo)

    case DependencyPins.uncovered(targets, locks) do
      [] ->
        :ok

      missing ->
        fail(
          "add these Cargo.lock files to lib.dependencyPins.cargo: #{Enum.join(missing, ", ")}"
        )
    end

    results = Enum.map(locks, &audit_and_update(root, &1))
    changed = for {lock, _, _, true} <- results, do: lock

    refreshed =
      Enum.flat_map(
        DependencyPins.affected(targets, changed),
        &DependencyPins.refresh!(root, :cargo, &1)
      )

    unresolved = Enum.flat_map(results, fn {_, _, unresolved, _} -> unresolved end)

    DependencyPins.finish!(
      opts,
      DependencyPins.summary("RustSec", results, refreshed),
      unresolved
    )
  end

  @spec audit_and_update(Path.t(), Path.t()) :: result()
  defp audit_and_update(root, lock) do
    dir = Path.join(root, Path.dirname(lock))
    before = File.read!(Path.join(root, lock))
    IO.puts("==> #{lock}: auditing")

    case audit!(dir) do
      [] ->
        {lock, [], [], false}

      findings ->
        IO.puts("==> #{lock}: updating #{Enum.join(DependencyPins.packages(findings), ", ")}")
        run!(dir, "cargo", ["update" | CargoSecurityUpgrades.update_specs(findings)])
        {lock, findings, audit!(dir), File.read!(Path.join(root, lock)) != before}
    end
  end

  # cargo audit exits 1 when it finds vulnerabilities; the JSON report on
  # stdout is authoritative, and anything unparseable stops the run.
  @spec audit!(Path.t()) :: [Finding.t()]
  defp audit!(dir) do
    {json, _status} =
      run!(dir, "cargo", ["audit", "--json"], allow_failure: true, echo: false, stderr: false)

    case CargoSecurityUpgrades.parse_audit(json) do
      {:ok, findings} -> findings
      {:error, reason} -> fail("#{dir}: #{reason}")
    end
  end
end

Overalls.CargoSecurityUpgrades.CLI.main(System.argv())
