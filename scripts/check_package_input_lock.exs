# Refuses a devenv.lock that pins a shared input differently from flake.lock.
#
# Usage: elixir scripts/check_package_input_lock.exs [FLAKE_LOCK DEVENV_LOCK]
# Both locks carry the application nixpkgs and nix-compact. The development
# shell and the builds must use the same revisions of both.
defmodule Overalls.PackageInputLock do
  @moduledoc false

  # @cc [owner:ghuntley,label:build] package-input-lock-agreement
  # flake.lock's buildNixpkgs and nix-compact MUST pin the same owner, repo and
  # rev as devenv.lock's nixpkgs and nix-compact; any mismatch fails with both
  # pins named. This is the Buck2 //:package-input-lock target and replaces the
  # inline flake check's logic (ADR-0267, ADR-0269).
  @shared [{"buildNixpkgs", "nixpkgs"}, {"nix-compact", "nix-compact"}]

  @type lock :: %{optional(String.t()) => term()}

  @spec mismatches(lock(), lock()) :: [String.t()]
  def mismatches(flake, devenv) do
    for {flake_name, devenv_name} <- @shared,
        flake_pin = pinned(flake, flake_name),
        devenv_pin = pinned(devenv, devenv_name),
        flake_pin != devenv_pin do
      "flake.lock #{flake_name} (#{flake_pin}) differs from devenv.lock #{devenv_name} (#{devenv_pin})"
    end
  end

  @spec pinned(lock(), String.t()) :: String.t()
  defp pinned(%{"nodes" => nodes}, name) do
    node = get_in(nodes, ["root", "inputs", name]) || raise "lock has no root input #{name}"
    %{"owner" => owner, "repo" => repo, "rev" => rev} = get_in(nodes, [node, "locked"])
    "#{owner}/#{repo}/#{rev}"
  end

  @spec read!(Path.t()) :: lock()
  def read!(path), do: path |> File.read!() |> JSON.decode!()
end

{flake, devenv} =
  case System.argv() do
    [] -> {"flake.lock", "devenv.lock"}
    [flake, devenv] -> {flake, devenv}
    _ -> raise "usage: check_package_input_lock.exs [FLAKE_LOCK DEVENV_LOCK]"
  end

case Overalls.PackageInputLock.mismatches(
       Overalls.PackageInputLock.read!(flake),
       Overalls.PackageInputLock.read!(devenv)
     ) do
  [] ->
    IO.puts("devenv.lock agrees with flake.lock on nixpkgs and nix-compact")

  found ->
    Enum.each(found, &IO.puts(:stderr, &1))
    System.halt(1)
end
