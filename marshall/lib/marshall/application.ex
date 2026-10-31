defmodule Marshall.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  # @cc [owner:ghuntley,label:verification] antithesis-bootstrap-reachable
  # Only a harness-built release emits this literal after successful supervision.
  # The production module has no SDK call or runtime switch.
  if System.get_env("ANTITHESIS_HARNESS") == "1" do
    Code.eval_quoted(
      quote location: :keep do
        require OverallsAntithesis.SDK

        @spec harness_started(GenServer.on_start()) :: GenServer.on_start()
        defp harness_started(result) do
          if match?({:ok, _pid}, result) and
               OverallsAntithesis.SDK.declare_catalog([__MODULE__]) == :written do
            OverallsAntithesis.SDK.reachable("Overalls Marshall application started")
          end

          result
        end
      end,
      [],
      __ENV__
    )
  else
    @spec harness_started(GenServer.on_start()) :: GenServer.on_start()
    defp harness_started(result), do: result
  end

  # @cc [owner:ghuntley,label:security] application-privacy-before-children
  # Terminal, authentication/mail and operator privacy filters MUST be installed
  # before any supervised child can emit startup or request diagnostics.

  # @cc [owner:ghuntley,label:architecture] application-operator-isolation
  # Operator mode MUST start persistence, encryption and authorization with Oban
  # insertion available but queues/plugins/leadership/staging disabled. It MUST
  # initialize the non-serving endpoint for authentication URL configuration
  # without starting listeners or consuming the fleet's background work. Neither
  # application mode may run migrations implicitly at startup.
  @impl true
  def start(_type, _args) do
    :ok = Marshall.OTPReports.install()
    :ok = MarshallWeb.TerminalLogFilter.install()
    :ok = Marshall.Mailer.LogFilter.install()
    :ok = Marshall.Operations.Privacy.install()
    :ok = Marshall.Operations.Health.install()
    :ok = Marshall.Compute.HostLiveness.check_windows!()
    %Marshall.Control.Concurrency{} = Marshall.Control.Concurrency.fetch!()

    children =
      if Application.get_env(:marshall, :operator_mode, false) do
        # Standalone release commands need persistence and authorization, but must
        # not bind a serving node's ports or consume its background jobs.
        if Application.get_env(:marshall, MarshallWeb.Endpoint)[:server] != false,
          do: raise("operator mode requires a disabled web endpoint")

        [
          Marshall.Repo,
          Marshall.Vault,
          Marshall.Authorization.Cedar,
          {Oban,
           Application.fetch_env!(:marshall, Oban)
           |> Keyword.merge(queues: false, plugins: false, peer: false, stager: false)},
          {Phoenix.PubSub, name: Marshall.PubSub},
          MarshallWeb.Endpoint
        ]
      else
        serving_children()
      end

    harness_started(
      Supervisor.start_link(children, strategy: :one_for_one, name: Marshall.Supervisor)
    )
  end

  defp serving_children do
    Overalls.RequestAccounting.Producer.children(Marshall.RequestRecorder) ++
      Overalls.RequestAccounting.Producer.children(Marshall.LiveRecorder, "_MARSHALL_LIVE") ++
      [
        MarshallWeb.Telemetry,
        Marshall.Observability,
        {Marshall.SLO, path: System.get_env("MARSHALL_SLO_SNAPSHOT")},
        Marshall.Repo,
        Marshall.Vault,
        Marshall.Authorization.Cedar,
        {Marshall.Compute.ServiceLevelPublisher,
         directory: System.get_env("MARSHALL_SERVICE_LEVEL_DIRECTORY")},
        {DNSCluster, query: Application.get_env(:marshall, :dns_cluster_query) || :ignore},
        {Oban,
         AshOban.config(
           Application.fetch_env!(:marshall, :ash_domains),
           Application.fetch_env!(:marshall, Oban)
         )},
        {Phoenix.PubSub, name: Marshall.PubSub},
        # Fleet-wide authority invalidation hints (ADR-0140).
        Marshall.Control.Hints.Relay,
        # Control WebSocket request tasks (ADR-0142).
        {Task.Supervisor, name: Marshall.Control.TaskSupervisor},
        Marshall.Terminal.PeerBudget,
        Marshall.Terminal.Metrics,
        Marshall.Terminal.Relay,
        Marshall.Android.DisplayRegistry,
        # Terminal openings run off the LiveView process (ADR-0140 phase 7).
        {Task.Supervisor, name: Marshall.Terminal.OpeningTasks},
        # Start a worker by calling: Marshall.Worker.start_link(arg)
        # {Marshall.Worker, arg},
        # Start to serve requests, typically the last entry
        MarshallWeb.Endpoint,
        {AshAuthentication.Supervisor, [otp_app: :marshall]}
      ] ++ agent_children() ++ fleet_children() ++ artifact_children()
  end

  defp agent_children do
    if Application.get_env(:marshall, :agent_loop_enabled, true),
      do: [
        Marshall.Agents.Loop,
        {Task.Supervisor, name: Marshall.Agents.SearchTasks},
        Marshall.Agents.WebSearch,
        Marshall.Agents.ThreadDelivery,
        Marshall.Agents.AttachmentCleanup
      ],
      else: []
  end

  # @cc [owner:ghuntley,label:security] application-fleet-serving-only
  # The machine listener MUST start only in serving mode with explicit validated
  # options. It MUST use FleetEndpoint independently of the browser endpoint;
  # operator mode MUST NOT bind its socket.
  defp fleet_children do
    Enum.map(Application.get_env(:marshall, :fleet_listeners, []), fn options ->
      Supervisor.child_spec({Bandit, options},
        id: {MarshallWeb.FleetEndpoint, options[:ip], options[:port]}
      )
    end)
  end

  # @cc [owner:ghuntley,label:security] application-artifact-content-listener
  # The artifact content listener MUST start only from validated serving
  # configuration and only with ArtifactContentEndpoint, independently of the
  # browser and fleet endpoints.
  defp artifact_children do
    (Application.get_env(:marshall, :artifact_content) || %{})
    |> Map.get(:listeners, [])
    |> Enum.map(fn options ->
      Supervisor.child_spec({Bandit, options},
        id: {MarshallWeb.ArtifactContentEndpoint, options[:ip], options[:port]}
      )
    end)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MarshallWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
