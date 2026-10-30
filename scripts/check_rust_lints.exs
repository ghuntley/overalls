# Enforces the ADR-0265 Rust lint policy across every non-vendored crate.
#
# Usage: elixir scripts/check_rust_lints.exs [--strict] [PATH...]
# Adopted crates must carry scripts/rust/lints.toml verbatim, a byte-identical
# clippy.toml and a reason on every allow/expect attribute. Without --strict,
# crates that have not adopted the policy yet are listed but do not fail.
Code.require_file("rust_lints.ex", __DIR__)

{flags, paths} = Enum.split_with(System.argv(), &String.starts_with?(&1, "--"))
strict? = "--strict" in flags

paths =
  if paths == [],
    do: Overalls.RustLints.tracked(),
    else: Enum.map(paths, &(&1 |> Path.expand() |> Path.relative_to_cwd()))

{pending, findings} = Overalls.RustLints.check(paths, strict?)

for path <- pending, not strict?, do: IO.puts("pending ADR-0265 adoption: #{path}")

case findings do
  [] ->
    IO.puts("Rust lint policy holds (#{length(pending)} crates pending adoption)")

  found ->
    for {path, line, message} <- found do
      location = if line, do: "#{path}:#{line}", else: path
      IO.puts(:stderr, "#{location}: #{message}")
    end

    System.halt(1)
end
