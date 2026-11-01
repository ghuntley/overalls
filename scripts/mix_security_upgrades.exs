# Applies Hex security updates to every Mix project and refreshes Nix hashes.
#
# Usage: elixir scripts/mix_security_upgrades.exs [--summary PATH] [--unresolved PATH]
# Run from the repository root inside `devenv shell`. Every directory with a
# mix.lock is audited with `mix hex.audit`; only packages reported with a
# security advisory or a security retirement are updated. Each changed library
# without a Nix build compiles with warnings as errors. Each entry of the
# flake's `lib.dependencyPins.mix` whose lock changed gets fresh fixed-output
# hashes in nix/domains/artifacts/dependency-hashes.json and must then build.
# The script never commits; it exits non-zero on any failure and leaves the
# working tree for inspection. The Markdown summary goes to --summary. Findings
# that no allowed version fixes are listed in the summary and, when present,
# written to --unresolved so the caller can keep the fixable updates and still
# fail.
Code.require_file("dependency_pins.ex", __DIR__)
Code.require_file("mix_security_upgrades.ex", __DIR__)

defmodule Overalls.MixSecurityUpgrades.CLI do
  @moduledoc false
  alias Overalls.{DependencyPins, MixSecurityUpgrades}
  alias Overalls.DependencyPins.Finding
  import DependencyPins, only: [fail: 1, run!: 3, run!: 4]

  @type result :: {Path.t(), [Finding.t()], [Finding.t()], boolean()}

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    {opts, [], []} = OptionParser.parse(argv, strict: [summary: :string, unresolved: :string])
    root = File.cwd!()
    File.exists?(Path.join(root, "flake.nix")) || fail("run from the repository root")
    check_hex!(root)

    results = Enum.map(MixSecurityUpgrades.projects(root), &audit_and_update(root, &1))
    changed = for {lock, _, _, true} <- results, do: lock
    refreshed = if changed == [], do: [], else: verify!(root, changed)
    unresolved = Enum.flat_map(results, fn {_, _, unresolved, _} -> unresolved end)
    DependencyPins.finish!(opts, DependencyPins.summary("Hex", results, refreshed), unresolved)
  end

  @spec check_hex!(Path.t()) :: :ok
  defp check_hex!(root) do
    {info, _} = run!(root, "mix", ["hex.info"], echo: false)

    MixSecurityUpgrades.supported_hex?(info) ||
      fail(
        "Hex #{MixSecurityUpgrades.minimum_hex()} or newer is required for advisories; run scripts/install_mix_tools.sh"
      )

    :ok
  end

  @spec audit_and_update(Path.t(), Path.t()) :: result()
  defp audit_and_update(root, project) do
    dir = Path.join(root, project)
    lock = Path.join(project, "mix.lock")
    before = File.read!(Path.join(root, lock))
    IO.puts("==> #{project}: auditing")
    run!(dir, "mix", ["deps.get"], allow_failure: true)

    case audit!(dir) do
      [] ->
        {lock, [], [], false}

      findings ->
        packages = DependencyPins.packages(findings)
        IO.puts("==> #{project}: updating #{Enum.join(packages, ", ")}")
        run!(dir, "mix", ["deps.update" | packages])
        {lock, findings, audit!(dir), File.read!(Path.join(root, lock)) != before}
    end
  end

  # hex.audit also exits non-zero for non-security retirements; those are
  # reported but never updated. Any other failure stops the run.
  @spec audit!(Path.t()) :: [Finding.t()]
  defp audit!(dir) do
    {output, status} = run!(dir, "mix", ["hex.audit"], allow_failure: true)
    findings = MixSecurityUpgrades.parse_audit(output)

    cond do
      status == 0 or findings != [] -> findings
      String.contains?(output, "Found retired packages") -> []
      true -> fail("#{dir}: mix hex.audit failed")
    end
  end

  # Libraries without a pinned Nix build compile in the dev shell; pinned
  # applications are proven by their source release build after the refresh.
  @spec verify!(Path.t(), [Path.t()]) :: [String.t()]
  defp verify!(root, changed) do
    targets = DependencyPins.targets!(root, :mix)

    for lock <- DependencyPins.uncovered(targets, changed) do
      project = Path.dirname(lock)
      IO.puts("==> #{project}: compiling")
      run!(Path.join(root, project), "mix", ["compile", "--warnings-as-errors", "--force"])
    end

    Enum.flat_map(
      DependencyPins.affected(targets, changed),
      &DependencyPins.refresh!(root, :mix, &1)
    )
  end
end

Overalls.MixSecurityUpgrades.CLI.main(System.argv())
