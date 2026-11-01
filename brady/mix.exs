defmodule Brady.MixProject do
  use Mix.Project

  def project do
    [
      app: :brady,
      version: "0.1.0",
      elixir: "== 1.20.4",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application,
    do: [extra_applications: [:logger, :crypto, :ssl, :inets], mod: {Brady.Application, []}]

  defp deps do
    [
      {:covenant, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:overalls_protocol, path: "../protocol"},
      {:overalls_diagnostics, path: "../elixir/diagnostics"},
      {:overalls_request_accounting, path: "../elixir/request_accounting"},
      {:x509, "~> 0.9.2"},
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
      "architecture.check": [fn _ -> Code.eval_file("../scripts/check_adrs.exs", __DIR__) end],
      "contracts.check": [fn _ -> Code.eval_file("../scripts/check_contracts.exs", __DIR__) end],
      "logging.check": [fn _ -> Code.eval_file("../scripts/check_logging.exs", __DIR__) end]
    ]
  end
end
