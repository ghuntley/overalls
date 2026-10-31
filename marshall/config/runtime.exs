import Config

case Marshall.Operations.GitHubConfig.from_env(System.get_env(),
       allow_loopback: config_env() in [:dev, :test]
     ) do
  {:ok, nil} -> :ok
  {:ok, settings} -> config :marshall, settings
  {:error, _} -> raise "Invalid GitHub OAuth configuration"
end

case System.get_env("MARSHALL_GITHUB_TOOLS_MANIFEST_FILE") do
  nil ->
    :ok

  "/nix/store/" <> _ = path ->
    unless Path.expand(path) == path and Path.basename(path) == "manifest.json",
      do: raise("Invalid managed GitHub tool manifest configuration")

    config :marshall, github_tools_manifest_file: path

  _ ->
    raise "Invalid managed GitHub tool manifest configuration"
end

case System.get_env("MARSHALL_EXECUTOR_BOOTSTRAP_MANIFEST_FILE") do
  nil ->
    :ok

  "/nix/store/" <> _ = path ->
    unless Path.expand(path) == path and Path.basename(path) == "manifest.json",
      do: raise("Invalid executor bootstrap manifest configuration")

    config :marshall, executor_bootstrap_manifest_file: path

  _ ->
    raise "Invalid executor bootstrap manifest configuration"
end

case Marshall.Agents.ContextPolicy.from_env(System.get_env()) do
  {:ok, policy} -> config :marshall, agent_context_policy: policy
  {:error, _} -> raise "Invalid agent context policy configuration"
end

if policy = System.get_env("MARSHALL_SSH_HOST_TRUST") do
  with {:ok, value} when is_map(value) <- JSON.decode(policy),
       value =
         Map.put(value, "management_host", System.get_env("PHX_HOST") || value["management_host"]),
       {:ok, _} <- OverallsProtocol.SSHTrust.parse(value) do
    config :marshall,
      ssh_host_trust: value,
      ssh_host_ca_key_file: System.fetch_env!("MARSHALL_SSH_HOST_CA_KEY_FILE")
  else
    _ -> raise("Invalid SSH host trust configuration")
  end
end

# The service token is read by the client from a systemd credential on each
# request; no credential bytes enter application configuration or diagnostics.
# Native tests only: a file of control ops to refuse as unavailable (ADR-0142).
if fault_gate = System.get_env("MARSHALL_CONTROL_FAULT_GATE_FILE") do
  config :marshall, control_fault_gate_file: fault_gate
end

# Lilly control requests running at once per host socket (ADR-0275). The value
# stays a string here; Marshall.Control.Concurrency validates it at boot.
if lilly_running = System.get_env("MARSHALL_CONTROL_LILLY_RUNNING") do
  config :marshall, Marshall.Control.Concurrency, lilly_running: lilly_running
end

if enrico_url = System.get_env("MARSHALL_ENRICO_URL") do
  config :marshall,
    enrico_url: enrico_url,
    enrico_token_file: System.fetch_env!("MARSHALL_ENRICO_TOKEN_FILE"),
    enrico_ca_file: System.fetch_env!("MARSHALL_ENRICO_CA_FILE")
end

if serper_key_file = System.get_env("MARSHALL_SERPER_KEY_FILE") do
  config :marshall,
    serper_key_file: serper_key_file,
    serper_origin: System.get_env("MARSHALL_SERPER_ORIGIN", "https://google.serper.dev")
end

for {variable, key} <- [
      {"MARSHALL_TERMINAL_PEER_URL", :terminal_peer_url},
      {"MARSHALL_TERMINAL_PEER_CA_CERTFILE", :terminal_peer_ca}
    ] do
  case System.get_env(variable) do
    value when is_binary(value) and value != "" -> config :marshall, key, value
    _ -> :ok
  end
end

for {name, key, default} <- [
      {"MARSHALL_INFERENCE_DETAIL_DAYS", :inference_detail_days, "90"},
      {"MARSHALL_INFERENCE_AGGREGATE_DAYS", :inference_aggregate_days, "365"}
    ] do
  case Integer.parse(System.get_env(name, default)) do
    {days, ""} when days in 1..36500 -> config :marshall, [{key, days}]
    _ -> raise "Invalid inference retention configuration"
  end
end

# services.marshall.notifications.enable (ADR-0225). Unset means enabled; any
# value other than "true" or "false" refuses startup.
case System.get_env("MARSHALL_NOTIFICATIONS_ENABLED", "true") do
  "true" -> config :marshall, notifications_enabled: true
  "false" -> config :marshall, notifications_enabled: false
  _ -> raise "Invalid MARSHALL_NOTIFICATIONS_ENABLED (expected true or false)"
end

case Marshall.Operations.RuntimeConfig.inception_public(System.get_env()) do
  {:ok, settings} -> config :marshall, inception_public: settings
  {:error, _} -> raise "Invalid Inception public settings"
end

if zone = System.get_env("MARSHALL_INGRESS_ZONE") do
  unless MarshallWeb.IngressKnownHosts.valid_zone?(zone),
    do: raise("Invalid MARSHALL_INGRESS_ZONE")

  config :marshall, ingress_zone: zone
end

if registry = System.get_env("MARSHALL_INGRESS_EDITOR_RELEASES") do
  # @cc [owner:ghuntley,label:protocol;reliability] editor-runtime-zone-boundary
  # A nonempty editor registry's explicitly configured zone MUST satisfy the
  # protocol's canonical multi-label boundary before application startup.
  # An empty registry MUST preserve generic ingress's existing zone contract.
  with true <- byte_size(registry) <= 4096,
       {:ok, value} <- JSON.decode(registry),
       {:ok, releases} <- Marshall.Editor.Releases.decode(value) do
    if map_size(releases) > 0 and System.get_env("MARSHALL_INGRESS_ZONE") != nil do
      unless OverallsProtocol.EditorConnect.zone?(System.fetch_env!("MARSHALL_INGRESS_ZONE")),
        do: raise("Invalid editor MARSHALL_INGRESS_ZONE")
    end

    config :marshall, ingress_editor_releases: value
  else
    _ -> raise "Invalid MARSHALL_INGRESS_EDITOR_RELEASES"
  end
end

case Marshall.Ingress.FleetACMEConfig.from_env(System.get_env()) do
  {:ok, nil} ->
    :ok

  {:ok, settings} ->
    config :marshall, fleet_acme: settings

    config :marshall, Oban,
      queues: [
        default: 10,
        provisioning: 10,
        mail: 2,
        maintenance: 2,
        github: 2,
        notifications: 5,
        redaction: 2,
        agent_tools: 10,
        artifacts: 5,
        certificates: 1
      ]

  {:error, _} ->
    raise "Invalid fleet ACME issuer configuration"
end

for {name, key, default, maximum} <- [
      {"MARSHALL_INGRESS_HTTPS_PORT", :ingress_https_port, "443", 65535}
    ] do
  case Integer.parse(System.get_env(name, default)) do
    {value, ""} when value >= 1 and value <= maximum -> config :marshall, [{key, value}]
    _ -> raise "Invalid Audi ingress integer configuration"
  end
end

case Marshall.Operations.RuntimeConfig.default_image(System.get_env()) do
  {:ok, image_id} -> config :marshall, default_image_id: image_id
  {:error, _} -> raise "Invalid MARSHALL_DEFAULT_IMAGE_ID (expected a canonical image digest)"
end

case Marshall.Operations.RuntimeConfig.inception_image(System.get_env()) do
  {:ok, image_id} -> config :marshall, inception_image_id: image_id
  {:error, _} -> raise "Invalid MARSHALL_INCEPTION_IMAGE_ID (expected a canonical image digest)"
end

case Integer.parse(System.get_env("MARSHALL_RELOCATION_READINESS_TIMEOUT_MS", "120000")) do
  {timeout, ""} when timeout in 1..600_000 ->
    config :marshall, relocation_readiness_timeout_ms: timeout

  _ ->
    raise "Invalid MARSHALL_RELOCATION_READINESS_TIMEOUT_MS (expected 1..600000)"
end

case Integer.parse(System.get_env("MARSHALL_CLONE_CLEANUP_DEADLINE_MS", "300000")) do
  {deadline, ""} when deadline in 1..3_600_000 ->
    config :marshall, clone_cleanup_deadline_ms: deadline

  _ ->
    raise "Invalid MARSHALL_CLONE_CLEANUP_DEADLINE_MS (expected 1..3600000)"
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/marshall start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if config_env() != :prod do
  config :marshall, MarshallWeb.Endpoint,
    server: System.get_env("PHX_SERVER") == "true",
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]

  case {System.get_env("MARSHALL_TLS_CERTFILE"), System.get_env("MARSHALL_TLS_KEYFILE")} do
    {nil, nil} ->
      :ok

    {certificate, key} when is_binary(certificate) and is_binary(key) ->
      config :marshall, MarshallWeb.Endpoint,
        https: [
          port: String.to_integer(System.get_env("MARSHALL_TLS_PORT", "4443")),
          certfile: certificate,
          keyfile: key
        ]

    _ ->
      raise "configure both MARSHALL_TLS_CERTFILE and MARSHALL_TLS_KEYFILE"
  end
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :marshall, MarshallWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Gettext translations
        ~r"priv/gettext/.*\.po$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/marshall_web/router\.ex$",
        ~r"lib/marshall_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

# @cc [owner:ghuntley,label:security] validated-production-runtime
# The production branch MUST use RuntimeConfig.from_env before installing
# endpoint/Repo configuration and fail startup on invalid deployment settings.
# Production MUST require signing secrets and validated remote or explicitly
# selected loopback mail configuration.
if config_env() == :prod do
  deployment =
    case Marshall.Operations.RuntimeConfig.from_env(System.get_env()) do
      {:ok, config} ->
        config

      _ ->
        raise "Invalid production deployment configuration: configure database TLS, replica/connection budgets, instance identity and serving TLS listeners"
    end

  config :marshall, Marshall.Repo, deployment.repo
  config :marshall, :fleet_listeners, deployment.fleet_listeners
  config :marshall, :artifact_content, deployment.artifact_content

  config :marshall,
         :deployment,
         Map.take(deployment, [:replicas, :connection_budget, :instance_id])

  secret_key_base = System.get_env("SECRET_KEY_BASE") || raise "SECRET_KEY_BASE is required"
  host = System.get_env("PHX_HOST") || raise "PHX_HOST is required for production sign-in URLs"
  config :marshall, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :marshall,
         MarshallWeb.Endpoint,
         Keyword.merge(deployment.endpoint,
           url: [host: host, port: 443, scheme: "https"],
           secret_key_base: secret_key_base
         )

  config :marshall,
    token_signing_secret:
      System.get_env("TOKEN_SIGNING_SECRET") || raise("TOKEN_SIGNING_SECRET is required")

  case Marshall.Mailer.Config.from_env(System.get_env()) do
    {:ok, smtp, from} ->
      config :marshall, Marshall.Mailer, smtp
      config :marshall, mail_from: from

    {:error, _} ->
      raise "Invalid production mail configuration: configure verified authenticated SMTP or explicit loopback relay transport and a sender"
  end
end
