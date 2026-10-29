Code.require_file("adr_validator.ex", __DIR__)

case Overalls.ADRValidator.check(Path.expand("..", __DIR__)) do
  {:ok, count} ->
    IO.puts("ADR check passed (#{count} decisions; structure and ADR references only).")

  {:error, errors} ->
    Enum.each(errors, &IO.puts(:stderr, "- #{&1}"))
    System.halt(1)
end
