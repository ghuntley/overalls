# Refuses third-party fixed-output hashes outside the pin registry.
#
# Usage: elixir scripts/check_pins.exs [ROOT]
# Every hash MUST come from nix/domains/artifacts/dependency-hashes.json (via
# pins.nix) or from a reviewed ecosystem lock file; every registry key MUST be
# read. Exits non-zero listing each violation.
Code.require_file("pins.ex", __DIR__)

root = List.first(System.argv()) || File.cwd!()

case Overalls.Pins.check(root) do
  [] ->
    IO.puts("Pins come only from #{Overalls.Pins.registry()} and lock files")

  violations ->
    for violation <- violations do
      message =
        case violation do
          {:inline, path, line, _} ->
            "#{path}:#{line}: inline fixed-output hash; move it to the registry"

          {:unused, key} ->
            "#{Overalls.Pins.registry()}: key #{key} is never read"

          {:unknown, path, line, key} ->
            "#{path}:#{line}: registry has no key #{key}"
        end

      IO.puts(:stderr, message)
    end

    System.halt(1)
end
