defmodule Overalls.Diagnostics.MixProject do
  use Mix.Project

  # @cc [owner:ghuntley,label:verification;security] reviewed-trace-schema-gate
  # Precommit MUST fail when production literals differ from the generated trace
  # vocabulary. The check MUST NOT rewrite the schema or start application services.
  @spec project() :: keyword()
  def project do
    [
      app: :overalls_diagnostics,
      version: "0.1.0",
      elixir: "== 1.20.4",
      deps: [
        {:covenant, "~> 0.2.0", only: [:dev, :test], runtime: false},
        {:opentelemetry, "~> 1.7"},
        {:opentelemetry_api, "~> 1.5"},
        {:opentelemetry_exporter, "~> 1.11"},
        {:req, "~> 0.7.4"},
        {:jason, "~> 1.4"},
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
        {:hegel_ex,
         git: "https://github.com/ghuntley/hegel-erlang.git",
         ref: "44b4c8e",
         subdir: "packages/hegel_ex",
         only: [:dev, :test],
         runtime: false}
      ],
      aliases: [
        "toolchain.check": [
          fn _ -> Code.eval_file("../../scripts/check_toolchain.exs", __DIR__) end
        ],
        "architecture.check": [
          fn _ -> Code.eval_file("../../scripts/check_adrs.exs", __DIR__) end
        ],
        "contracts.check": [
          fn _ -> Code.eval_file("../../scripts/check_contracts.exs", __DIR__) end
        ],
        "schema.check": ["run --no-start generate_schema.exs --check"]
      ]
    ]
  end

  @spec application() :: keyword()
  def application,
    do: [
      extra_applications: [:logger, :crypto, :ssl],
      mod: {Overalls.Diagnostics.Application, []}
    ]
end
