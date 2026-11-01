defmodule Overalls.MixFailingFixture.MixProject do
  use Mix.Project

  # A deliberately failing suite for //buck:mix_test_failure_uncached. It
  # reuses request_accounting's lock, and so its fixed-output dependencies.
  @spec project() :: keyword()
  def project do
    [
      app: :overalls_mix_failing_fixture,
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
      ]
    ]
  end
end
