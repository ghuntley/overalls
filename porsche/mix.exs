defmodule Porsche.MixProject do
  use Mix.Project

  def project do
    [
      app: :porsche,
      version: "0.1.0",
      elixir: "== 1.20.4",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :ssh],
      mod: {Porsche.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp deps do
    [
      {:covenant, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:logger_json, "~> 7.0"},
      {:gettext, "~> 1.0"},
      {:localize, "~> 1.3"},
      {:overalls_protocol, path: "../protocol"},
      {:overalls_diagnostics, path: "../elixir/diagnostics"},
      {:overalls_request_accounting, path: "../elixir/request_accounting"},
      {:telemetry, "~> 1.4"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:hegel_ex,
       git: "https://github.com/ghuntley/hegel-erlang.git",
       ref: "b0dec2a",
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
      "gettext.check": [&check_gettext/1],
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
        "gettext.check",
        "dialyzer --force-check"
      ]
    ]
  end

  # @cc [owner:ghuntley,label:verification] porsche-gettext-check-own-vm
  # The catalog freshness gate MUST run `mix gettext.extract --check-up-to-date`
  # in a separate test-environment VM and MUST fail precommit when it fails.
  # In the precommit VM its forced recompile runs with protocols already
  # consolidated. That records "already consolidated" warnings in the compile
  # manifest, and the next `compile --warnings-as-errors` on that _build
  # replays them and fails.
  @spec check_gettext([String.t()]) :: :ok
  defp check_gettext(_args) do
    mix = System.find_executable("mix") || Mix.raise("cannot find the `mix` executable on PATH")

    case System.cmd(mix, ["gettext.extract", "--check-up-to-date"],
           env: [{"MIX_ENV", "test"}],
           into: IO.stream(:stdio, :line),
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {_, status} ->
        Mix.raise("gettext.extract --check-up-to-date failed (exit status #{status})")
    end
  end

  defp check_adrs(_args) do
    Code.require_file("../scripts/adr_validator.ex", __DIR__)

    case Overalls.ADRValidator.check(Path.expand("..", __DIR__)) do
      {:ok, count} -> Mix.shell().info("ADR check passed (#{count} decisions).")
      {:error, errors} -> Mix.raise(Enum.join(errors, "\n"))
    end
  end
end
