defmodule Lilly.MixProject do
  use Mix.Project

  def project do
    [
      app: :lilly,
      version: "0.1.0",
      elixir: "== 1.20.4",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [plt_add_apps: [:ex_unit]],
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"] ++ antithesis_sources()
  defp elixirc_paths(_env), do: ["lib"] ++ antithesis_sources()

  defp antithesis_sources do
    if System.get_env("ANTITHESIS_HARNESS") == "1",
      do: [Path.expand("../antithesis/lilly/lib", __DIR__)],
      else: []
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :ssl],
      mod: {Lilly.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp deps do
    [
      {:covenant, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:ash, "== 3.33.6"},
      {:ash_state_machine, "== 0.2.13"},
      {:logger_json, "~> 7.0"},
      {:overalls_protocol, path: "../protocol"},
      {:overalls_diagnostics, path: "../elixir/diagnostics"},
      {:req, "~> 0.7.4"},
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
