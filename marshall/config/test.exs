import Config
config :marshall, Oban, testing: :manual
config :marshall, ingress_zone: "apps.example.test"
config :marshall, agent_loop_enabled: false
# The SQL sandbox already owns the outer transaction, so batches cannot set
# their isolation level; memoization still runs inside the sandbox transaction.
config :marshall, decision_snapshot_isolation: false
config :marshall, token_signing_secret: "FWwv4aGprYO94yAJrGNixx/NGJNKpmpq"
config :bcrypt_elixir, log_rounds: 1
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
transport =
  case System.get_env("PGHOST") do
    socket when is_binary(socket) ->
      if String.starts_with?(socket, "/"),
        do: [socket_dir: socket, username: System.get_env("PGUSER", System.get_env("USER"))],
        else: [hostname: socket, username: System.get_env("PGUSER", System.get_env("USER"))]

    _ ->
      [hostname: "localhost", username: "postgres"]
  end

config :marshall,
       Marshall.Repo,
       [
         password: System.get_env("PGPASSWORD", "postgres"),
         maintenance_database: System.get_env("MARSHALL_MAINTENANCE_DATABASE", "postgres"),
         ssl:
           if(System.get_env("PGSSLMODE") == "require", do: [verify: :verify_none], else: false),
         port:
           String.to_integer(
             System.get_env("MARSHALL_TEST_PORT", System.get_env("PGPORT", "5432"))
           ),
         database:
           System.get_env(
             "MARSHALL_TEST_DATABASE",
             "marshall_test#{System.get_env("MIX_TEST_PARTITION")}"
           ),
         pool: Ecto.Adapters.SQL.Sandbox,
         # Capped below PostgreSQL's default max_connections (100): on a
         # 96-core host twice the schedulers took every connection, and the
         # tests that start their own small pool could never connect.
         pool_size: min(System.schedulers_online() * 2, 64)
       ] ++ transport

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :marshall, MarshallWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "aifbBCqsV2imlQD30HeHxKZJpw2Yyikk6XFvAQ+my37u00KEpBA/+YC9Ol7570BM",
  server: false

# In test we don't send emails
config :marshall, Marshall.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Susan's origin is a compiled constant; only MIX_ENV=test reads this override
# (ADR-0225). Requests go to an in-process Req.Test stub, never the network.
config :marshall, Marshall.Notifications.Susan,
  origin: "https://susan.test",
  req_options: [plug: {Req.Test, Marshall.Notifications.Susan}]
