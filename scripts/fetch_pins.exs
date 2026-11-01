# Refreshes the fixed-output hashes of lib.dependencyPins.fetch entries.
#
# Usage: elixir scripts/fetch_pins.exs [--changed PATH]... [--entry NAME]...
#                                      [--all] [--summary PATH]
# Run from the repository root inside `devenv shell`. It first refuses a
# registry key in nix/domains/artifacts/dependency-hashes.json that no mix,
# cargo or fetch entry claims, or that two entries claim, and a tracked
# `*.lock.json` under nix/ that no lib.dependencyPins.domain entry names (or a
# registered lock, updater or procedure that does not exist). It then refreshes
# every entry named by --entry, every entry whose `locks` include a --changed
# path (the scheduled nix upgrade passes the lock files it changed), or every
# entry with --all. Each refreshed key is replaced by a placeholder, its
# fetches are rebuilt to learn the real hash, and the fetches must then build
# with the recorded hash. Only those fetches are built, not their consumers.
# A refreshed hash is checked only by that fetch, not by human review of the
# fetched source. The script never commits; it exits non-zero on any failure
# and writes a Markdown summary of changed keys to --summary.
Code.require_file("dependency_pins.ex", __DIR__)

defmodule Overalls.FetchPins.CLI do
  @moduledoc false
  alias Overalls.DependencyPins
  import DependencyPins, only: [fail: 1]

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    {opts, [], []} =
      OptionParser.parse(argv,
        strict: [changed: :keep, entry: :keep, all: :boolean, summary: :string]
      )

    root = File.cwd!()
    File.exists?(Path.join(root, "flake.nix")) || fail("run from the repository root")

    fetch = DependencyPins.fetch_targets!(root)
    registry = DependencyPins.registry!(root)

    case DependencyPins.coverage(Map.keys(registry), DependencyPins.claims!(root, fetch)) do
      %{uncovered: [], duplicated: [], unknown: []} ->
        :ok

      %{uncovered: uncovered, duplicated: duplicated, unknown: unknown} ->
        fail(
          "lib.dependencyPins must claim each registry key once; " <>
            "unclaimed: #{inspect(uncovered)}, claimed twice: #{inspect(duplicated)}, " <>
            "not in the registry: #{inspect(unknown)}"
        )
    end

    {listing, _} = DependencyPins.run!(root, "git", ["ls-files", "-z", "--", "nix"], echo: false)

    case DependencyPins.domain_problems(
           DependencyPins.domain_targets!(root),
           String.split(listing, <<0>>, trim: true),
           &File.exists?(Path.join(root, &1))
         ) do
      [] -> :ok
      problems -> fail(Enum.join(problems, "; "))
    end

    entries = Keyword.get_values(opts, :entry)

    case entries -- Map.keys(fetch) do
      [] -> :ok
      unknown -> fail("no lib.dependencyPins.fetch entries #{Enum.join(unknown, ", ")}")
    end

    selected =
      if opts[:all],
        do: Map.keys(fetch),
        else:
          entries ++ DependencyPins.affected_fetches(fetch, Keyword.get_values(opts, :changed))

    changes =
      selected
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&{&1, DependencyPins.refresh_fetch!(root, &1)})

    summary = summary(changes)
    IO.puts(summary)
    if path = opts[:summary], do: File.write!(path, summary)
    System.halt(0)
  end

  @spec summary([{String.t(), %{String.t() => {String.t(), String.t()}}}]) :: String.t()
  defp summary([]), do: "No fetch pins refreshed.\n"

  defp summary(changes) do
    lines =
      for {entry, keys} <- changes, {key, {old, new}} <- Enum.sort(keys) do
        if old == new,
          do: "- #{entry}: #{key} unchanged",
          else: "- #{entry}: #{key} #{old} -> #{new}"
      end

    "Refreshed fetch pins:\n\n" <> Enum.join(lines, "\n") <> "\n"
  end
end

Overalls.FetchPins.CLI.main(System.argv())
