defmodule Overalls.RequestAccounting.MixProject do
  use Mix.Project

  def project do
    [
      app: :overalls_request_accounting,
      version: "0.1.0",
      elixir: "== 1.20.4",
      deps: [
        {:covenant, "~> 0.2.0", only: [:dev, :test], runtime: false},
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
        ]
      ]
    ]
  end

  def application, do: [extra_applications: [:crypto]]
end
