defmodule Enrico.MixProject do
  use Mix.Project

  def project do
    [
      app: :enrico,
      version: "0.1.0",
      elixir: "== 1.20.4",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl],
      mod: {Enrico.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp deps do
    [
      {:covenant, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:bandit, "~> 1.12"},
      {:logger_json, "~> 7.0"},
      {:req, "~> 0.7.4"},
      {:overalls_protocol, path: "../protocol"},
      {:overalls_diagnostics, path: "../elixir/diagnostics"},
      {:overalls_request_accounting, path: "../elixir/request_accounting"},
      {:telemetry, "~> 1.4"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:hegel_ex,
       git: "https://github.com/ghuntley/hegel-erlang.git",
       ref: "44b4c8e",
       subdir: "packages/hegel_ex",
       only: [:dev, :test],
       runtime: false}
    ] ++ antithesis_deps()
  end

  defp antithesis_deps do
    if System.get_env("ANTITHESIS_HARNESS") == "1" do
      [{:overalls_antithesis_sdk, path: "../antithesis/sdk"}]
    else
      []
    end
  end

  defp aliases do
    [
      "toolchain.check": [fn _ -> Code.eval_file("../scripts/check_toolchain.exs", __DIR__) end],
      "architecture.check": [&check_adrs/1],
      "contracts.check": [fn _ -> Code.eval_file("../scripts/check_contracts.exs", __DIR__) end],
      "logging.check": [fn _ -> Code.eval_file("../scripts/check_logging.exs", __DIR__) end],
      precommit: [
        "toolchain.check",
        "architecture.check",
        "contracts.check",
        "logging.check",
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "test --warnings-as-errors",
        "covenant.check --no-run",
        "dialyzer --force-check"
      ]
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
