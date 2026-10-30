defmodule Marshall.MixProject do
  use Mix.Project

  def project do
    [
      app: :marshall,
      version: "0.1.0",
      elixir: "== 1.20.4",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      dialyzer: [
        # Earmark is runtime:false but its Markdown AST API is analyzed here.
        plt_add_apps: [:ex_unit, :hegel, :hegel_ex, :audi, :lilly, :earmark],
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true
      ],
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev,
      # Shared SCIM Team fixtures are loaded with Code.require_file/2 by their
      # tests. Without this, `mix test --warnings-as-errors` reports the file as
      # misnamed and exits 1 after an otherwise passing suite.
      test_ignore_filters: ["test/marshall/scim/team_fixture.exs"]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Marshall.Application, []},
      extra_applications: [:logger, :runtime_tools, :ssl, :ssh]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"] ++ antithesis_paths()
  defp elixirc_paths(_), do: ["lib"] ++ antithesis_paths()

  defp antithesis_paths do
    if System.get_env("ANTITHESIS_HARNESS") == "1",
      do: [Path.expand("../antithesis/marshall/lib", __DIR__)],
      else: []
  end

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:covenant, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:rustler, "~> 0.38.0", runtime: false},
      # IANA zone data compiled in at build time; nothing is fetched at runtime.
      {:tz, "~> 0.28.4"},
      {:yaml_elixir, "~> 2.12"},
      {:overalls_protocol, path: "../protocol"},
      {:overalls_diagnostics, path: "../elixir/diagnostics"},
      {:overalls_request_accounting, path: "../elixir/request_accounting"},
      {:lilly, path: "../lilly", only: :test, runtime: false},
      {:porsche, path: "../porsche", only: :test, runtime: false},
      {:audi, path: "../audi", only: :test, runtime: false},
      {:logger_json, "~> 7.0"},
      {:earmark, "~> 1.4.49"},
      {:picosat_elixir, "~> 0.2"},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:oban, "~> 2.0"},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:ash_cloak, "~> 0.4"},
      {:cloak, "~> 1.0"},
      {:ash_paper_trail, "~> 0.7"},
      {:live_debugger, "~> 1.0", only: [:dev]},
      {:ash_archival, "~> 2.0"},
      {:ash_state_machine, "~> 0.2"},
      {:oban_web, "~> 2.0"},
      {:ash_oban, "~> 0.8"},
      {:ash_admin, "~> 1.0"},
      {:ash_authentication_phoenix, "== 3.0.0-rc.11"},
      {:ash_authentication, "== 5.0.0-rc.14"},
      {:ash_scim, path: "../vendor/ash_scim"},
      {:wax_, "~> 0.7"},
      {:ash_postgres, "~> 2.0"},
      {:ash_phoenix, "~> 2.0"},
      {:ash, "~> 3.0"},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:phoenix, "~> 1.8.14"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:hegel_ex,
       git: "https://github.com/ghuntley/hegel-erlang.git",
       ref: "b0dec2a",
       subdir: "packages/hegel_ex",
       only: [:dev, :test],
       runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:swoosh, "~> 1.16"},
      {:gen_smtp, "~> 1.3.0"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      # CLDR-backed formatting and Phoenix request helpers. Locale data is
      # bundled by the packages and is never downloaded at runtime.
      {:localize, "~> 1.3"},
      {:localize_web, "~> 1.1"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ] ++ antithesis_deps()
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp antithesis_deps do
    if System.get_env("ANTITHESIS_HARNESS") == "1" do
      [{:overalls_antithesis_sdk, path: "../antithesis/sdk"}]
    else
      []
    end
  end

  defp aliases do
    [
      setup: ["deps.get", "ash.setup", "assets.setup", "assets.build", "run priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": ["compile", "esbuild marshall"],
      "assets.deploy": [
        "compile",
        "esbuild marshall --minify",
        "phx.digest"
      ],
      "architecture.check": [&check_adrs/1],
      "contracts.check": [fn _ -> Code.eval_file("../scripts/check_contracts.exs", __DIR__) end],
      "logging.check": [fn _ -> Code.eval_file("../scripts/check_logging.exs", __DIR__) end],
      "toolchain.check": [&check_toolchain/1],
      "terminal.check": [&check_terminal/1],
      "workspace.check": [&check_workspace/1],
      "monospace.check": [&check_monospace/1],
      "localization.catalogs": ["run --no-start scripts/check_locale_catalogs.exs --strict"],
      "localization.documentation": ["run --no-start scripts/extract_documentation.exs --check"],
      "localization.data": [fn _ -> Code.eval_file("scripts/check_locale_data.exs", __DIR__) end],
      precommit:
        [
          "toolchain.check",
          "architecture.check",
          "contracts.check",
          "logging.check",
          "compile --warnings-as-errors",
          "deps.unlock --unused",
          "format"
        ] ++
          precommit_tests() ++
          [
            "terminal.check",
            "workspace.check",
            "monospace.check",
            "localization.data",
            "localization.documentation",
            "localization.catalogs",
            "gettext.extract --check-up-to-date",
            "dialyzer --force-check"
          ]
    ]
  end

  # @cc [owner:ghuntley,label:verification] marshall-precommit-test-partitions
  # With MARSHALL_TEST_PARTITIONS unset or empty, precommit MUST run the whole suite with
  # distributed tests and check Covenant against those results. With it set to
  # an integer N >= 2, precommit MUST run `mix test --partitions N` (the slice
  # chosen by MIX_TEST_PARTITION, still including distributed tests) and MUST
  # rerun the complete contract suite through `covenant.check`, so contract
  # coverage never depends on which slice ran. Any other value MUST fail.
  @spec precommit_tests() :: [String.t()]
  defp precommit_tests do
    test = "test --include distributed --warnings-as-errors"

    case System.get_env("MARSHALL_TEST_PARTITIONS", "") do
      "" ->
        [test, "covenant.check --no-run"]

      value ->
        case Integer.parse(value) do
          {count, ""} when count >= 2 ->
            ["#{test} --partitions #{count}", "covenant.check"]

          _ ->
            Mix.raise("MARSHALL_TEST_PARTITIONS must be an integer of at least 2")
        end
    end
  end

  @spec check_monospace([String.t()]) :: :ok
  defp check_monospace(_args) do
    case System.cmd("elixir", ["scripts/check_monospace.exs"], stderr_to_stdout: true) do
      {output, 0} -> Mix.shell().info(output)
      {output, _} -> Mix.raise(output)
    end
  end

  @spec check_workspace([String.t()]) :: :ok
  defp check_workspace(_args) do
    case System.cmd(
           "node",
           [
             "--test",
             "test/browser/repository_launch_test.mjs",
             "test/browser/localization_test.mjs",
             "test/browser/admin_elevation_test.mjs",
             "test/browser/browser_extension_presence_test.mjs"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} -> Mix.shell().info(output)
      {output, _} -> Mix.raise(output)
    end

    checker = "../tools/code-contracts/node_modules/typescript/bin/tsc"

    case System.cmd("node", [checker, "-p", "assets/tsconfig.workspace.json"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> Mix.shell().info(output)
      {output, _} -> Mix.raise(output)
    end
  end

  @spec check_terminal([String.t()]) :: :ok
  defp check_terminal(_args) do
    case System.cmd(
           "node",
           [
             "--test",
             "test/browser/terminals_test.mjs",
             "test/browser/xterm_accessibility_test.mjs"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} -> Mix.shell().info(output)
      {output, _} -> Mix.raise(output)
    end
  end

  defp check_adrs(_args) do
    Code.require_file("../scripts/adr_validator.ex", __DIR__)

    case Overalls.ADRValidator.check(Path.expand("..", __DIR__)) do
      {:ok, count} -> Mix.shell().info("ADR check passed (#{count} decisions).")
      {:error, errors} -> Mix.raise(Enum.join(errors, "\n"))
    end
  end

  defp check_toolchain(_args) do
    Code.eval_file("../scripts/check_toolchain.exs", __DIR__)
  end
end
