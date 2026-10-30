defmodule Lilly.Application do
  # See https://hexdocs.pm/elixir/Application.html
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

        @spec harness_started() :: :ok
        defp harness_started do
          if OverallsAntithesis.SDK.declare_catalog([__MODULE__]) == :written do
            OverallsAntithesis.SDK.reachable("Overalls Lilly application started")
          end

          :ok
        end
      end,
      [],
      __ENV__
    )
  else
    @spec harness_started() :: :ok
    defp harness_started, do: :ok
  end

  require Lilly.Events

  @impl true
  # @cc [owner:ghuntley,label:security] invalid-config-fails-startup
  # Application.start/2 MUST fail startup when LILLY_CONFIG_FILE is set but invalid; it must not
  # silently start an unconfigured runtime or include file contents/credentials in the startup
  # error.
  def start(_type, _args) do
    :ok = Lilly.OTPReports.install()

    children =
      case System.get_env("LILLY_CONFIG_FILE") do
        nil ->
          []

        path ->
          case Lilly.Control.Config.load(path) do
            {:ok, config} ->
              [
                {Lilly.Control.Link, config.client},
                {Lilly.Control.Runtime, config: config, name: Lilly.Control.Runtime},
                {Lilly.Host.ImagePrewarm, config}
              ] ++
                ingress_children(config) ++
                private_children(config) ++
                attribution_children(config) ++
                status_child() ++
                image_catalog_child(config) ++
                pool_observer_child(config)

            _ ->
              raise "invalid LILLY_CONFIG_FILE; expected a private, valid provisioner configuration"
          end
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :rest_for_one, name: Lilly.Supervisor]

    with {:ok, pid} <-
           Supervisor.start_link(
             [
               Lilly.Host.Hostd,
               Lilly.Observability,
               Lilly.Terminal.Metrics,
               Lilly.Execution,
               Lilly.Host.PoolQueue,
               Lilly.Host.TemplateSteward
             ] ++
               Lilly.VM.WorkspaceSource.child_specs() ++ children,
             opts
           ) do
      Lilly.Events.emit("lilly.started", [])
      :ok = harness_started()
      {:ok, pid}
    end
  end

  # @cc [owner:ghuntley,label:capacity;recovery] pool-observer-supervision
  # Configured ZFS pools MUST be observed by Lilly.Host.PoolObserver, started
  # last under rest-for-one so its restart restarts no other child. A pool
  # without a published observation MUST be reported busy, never by stalling
  # the host report.
  @spec pool_observer_child(Lilly.Control.Config.t()) :: [{module(), term()}]
  def pool_observer_child(config) do
    case Enum.filter(config.pools, &(&1.backend == :zfs)) do
      [] -> []
      pools -> [{Lilly.Host.PoolObserver, {pools, []}}]
    end
  end

  # @cc [owner:ghuntley,label:recovery] ingress-runtime-supervision
  # The real connector MUST start after Runtime under rest-for-one supervision,
  # so loss of Runtime closes relayed streams and restarts admission; detached
  # bridges (ADR-0187) outlive it and the restarted connector re-adopts or ends
  # them. The backend MUST remain the local execution guardian, never a
  # configuration-selected module.
  @spec ingress_children(Lilly.Control.Config.t()) :: [{module(), keyword()}]
  def ingress_children(%{execution: %{network: %{ingress: false}}}), do: []
  def ingress_children(%{ingress: nil}), do: []

  def ingress_children(%{ingress: options, client: %{host_id: host}}) do
    [
      {Lilly.Ingress.Server,
       options ++
         [
           host_id: host,
           backend: {Lilly.Ingress.Backend, {Lilly.Control.Runtime, Lilly.Execution.view()}}
         ]}
    ]
  end

  defp private_children(%{
         execution: %{network: %{private_services: true}},
         ingress: options,
         client: %{host_id: host}
       })
       when is_list(options) do
    [
      {Lilly.Private.Server,
       path: Path.join(Path.dirname(options[:path]), "private.sock"),
       audi_uid: options[:audi_uid],
       host_id: host}
    ]
  end

  defp private_children(_), do: []

  # @cc [owner:ghuntley,label:security] attribution-fixed-local-backend
  # Enabled Brady MUST use the configured proxy UID and the fixed local kernel/
  # runtime/actor resolver. Peer data MUST NOT select a backend or socket path.
  @spec attribution_children(Lilly.Control.Config.t()) :: [{module(), keyword()}]
  def attribution_children(%{execution: %{network: %{brady: nil}}}), do: []

  def attribution_children(%{execution: %{network: network}, client: %{host_id: host}}) do
    [
      {Lilly.Network.AttributionServer,
       path: "/run/lilly-brady/attribution.sock",
       brady_uid: network.brady["uid"],
       host_id: host,
       lookup: &Lilly.Network.Attribution.resolve(network, &1)}
    ]
  end

  # @cc [owner:ghuntley,label:recovery] startup-independent-of-image-hashing
  # Application start MUST NOT hash image artifacts. Digest verification runs in
  # the last rest-for-one child, so its duration or failure cannot delay or
  # restart Runtime, ingress, private services or Brady attribution.
  @spec image_catalog_child(Lilly.Control.Config.t()) :: [{module(), keyword()}]
  def image_catalog_child(%{images: images, state_dir: state_dir}),
    do: [
      {Lilly.Host.ImageCatalog,
       images: images, digest_cache: Path.join([state_dir, "images", "digests.json"])}
    ]

  defp status_child do
    case System.get_env("LILLY_STATUS_SOCKET") do
      nil ->
        []

      path ->
        [
          {Lilly.Control.StatusServer, path: path},
          Supervisor.child_spec(
            {Lilly.Control.StatusServer,
             path: Path.join(Path.dirname(path), "terminal-metrics.sock"), kind: :terminal_metrics},
            id: :terminal_metrics_socket
          )
        ]
    end
  end
end
