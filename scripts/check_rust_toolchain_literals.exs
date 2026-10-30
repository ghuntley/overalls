# Refuses a workflow Rust toolchain literal that differs from the repository's
# single Rust toolchain.
#
# Usage: elixir scripts/check_rust_toolchain_literals.exs [ROOT]
defmodule Overalls.RustToolchainLiterals do
  @moduledoc false

  # @cc [owner:ghuntley,label:build] rust-toolchain-literal-agreement
  # Every `toolchain:` input of a rustup toolchain action in .github/workflows
  # and .github/actions MUST equal the `version` that nix/rust-toolchain.nix
  # pins (ADR-0273). Runners without Nix keep the literal; this check is the
  # only place that ties it to the single toolchain, and any drift fails with
  # the file and line named.

  @toolchain_file "nix/rust-toolchain.nix"
  @version ~r/^\s*version = "(?<version>[0-9]+\.[0-9]+\.[0-9]+)";\s*$/m
  @literal ~r/^\s*toolchain:\s*["']?(?<value>[^"'\s#]+)/

  @type finding :: String.t()

  @spec expected!(Path.t()) :: String.t()
  def expected!(root) do
    source = File.read!(Path.join(root, @toolchain_file))

    case Regex.named_captures(@version, source) do
      %{"version" => version} -> version
      nil -> raise "#{@toolchain_file} has no `version = \"X.Y.Z\";` line"
    end
  end

  @spec workflow_files(Path.t()) :: [Path.t()]
  def workflow_files(root) do
    [
      ".github/workflows/*.yml",
      ".github/workflows/*.yaml",
      ".github/actions/**/*.yml",
      ".github/actions/**/*.yaml"
    ]
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.sort()
  end

  @spec findings(Path.t(), String.t(), String.t()) :: [finding()]
  def findings(path, contents, expected) do
    contents
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, number} ->
      case Regex.named_captures(@literal, line) do
        %{"value" => ^expected} ->
          []

        %{"value" => value} ->
          [
            "#{path}:#{number}: Rust toolchain #{value}, expected #{expected} (#{@toolchain_file})"
          ]

        nil ->
          []
      end
    end)
  end

  @spec run(Path.t()) :: [finding()]
  def run(root) do
    expected = expected!(root)

    Enum.flat_map(workflow_files(root), fn file ->
      findings(Path.relative_to(file, root), File.read!(file), expected)
    end)
  end
end

root =
  case System.argv() do
    [] -> "."
    [root] -> root
    _ -> raise "usage: check_rust_toolchain_literals.exs [ROOT]"
  end

case Overalls.RustToolchainLiterals.run(root) do
  [] ->
    IO.puts(
      "Workflow Rust toolchain literals match #{Overalls.RustToolchainLiterals.expected!(root)}"
    )

  found ->
    Enum.each(found, &IO.puts(:stderr, &1))
    System.halt(1)
end
