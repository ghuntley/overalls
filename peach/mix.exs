defmodule Peach.MixProject do
  use Mix.Project

  @spec project() :: keyword()
  def project do
    [
      app: :peach,
      version: "0.1.0",
      elixir: "== 1.20.4",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: deps(),
      dialyzer: [plt_add_apps: [:ex_unit]],
      aliases: aliases()
    ]
  end

  def application,
    do: [extra_applications: [:logger, :crypto, :ssl], mod: {Peach.Application, []}]

  defp deps do
    [
      {:covenant, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      {:overalls_protocol, path: "../protocol"},
      {:overalls_diagnostics, path: "../elixir/diagnostics"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "toolchain.check": [fn _ -> Code.eval_file("../scripts/check_toolchain.exs", __DIR__) end],
      "architecture.check": [&check_adrs/1],
      "contracts.check": [fn _ -> Code.eval_file("../scripts/check_contracts.exs", __DIR__) end],
      "logging.check": [fn _ -> Code.eval_file("../scripts/check_logging.exs", __DIR__) end]
    ]
  end

  defp check_adrs(_args) do
    Code.require_file("../scripts/adr_validator.ex", __DIR__)

    case Overalls.ADRValidator.check(Path.expand("..", __DIR__)) do
      {:ok, count} -> Mix.shell().info("ADR check passed (#{count} decisions).")
      {:error, errors} -> Mix.raise(Enum.join(errors, "\n"))
    end
  end
end
