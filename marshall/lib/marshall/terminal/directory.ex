defmodule Marshall.Terminal.Directory do
  @moduledoc "PostgreSQL-authoritative expiring stream locations for independent frontends."
  alias Marshall.Terminal.Location
  require Ash.Query
  require Marshall.Events

  @spec uri() :: String.t() | nil
  def uri, do: Application.get_env(:marshall, :terminal_peer_url)

  # @cc [owner:ghuntley,label:security;recovery] directory-metadata-only
  # Locations MUST contain only host identity, server-configured TLS origin,
  # incarnation nonce and expiry. No terminal bytes, credentials or guest
  # controls may be persisted. Renewal MUST fail after a successor takes over.
  @spec publish(String.t(), String.t()) :: :ok | {:error, term()}
  def publish(host_id, nonce) do
    if is_nil(uri()) do
      :ok
    else
      with %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil, path: path} <-
             URI.parse(uri()),
           true <- is_binary(host) and path in [nil, "", "/"],
           {:ok, _} <-
             Ash.create(
               Location,
               %{
                 host_id: host_id,
                 nonce: nonce,
                 uri: uri(),
                 expires_at: DateTime.add(Marshall.Compute.Ledger.now(), 15)
               },
               actor: Marshall.Authorization.SystemActor.compute()
             ) do
        published(host_id)
        :ok
      else
        _ -> {:error, :invalid_stream_location}
      end
    end
  end

  # @cc [owner:ghuntley,label:security] stream-publication-host-lock
  # Authenticated publication MUST hold the execution host lock while checking
  # session/credential authority and publishing its directory nonce. A delayed
  # hello MUST NOT replace a successor after its execution session is fenced.
  @spec publish_authenticated(String.t(), String.t(), String.t(), pos_integer()) ::
          :ok | {:error, atom()}
  def publish_authenticated(host_id, nonce, session_id, epoch) do
    case Marshall.Compute.Ledger.transaction(fn ->
           Marshall.Compute.Ledger.lock!(Marshall.Compute.Host, host_id)

           unless current_execution?(host_id, session_id, epoch),
             do: Marshall.Compute.Ledger.rollback(:stale_connection)

           case publish(host_id, nonce) do
             :ok -> :ok
             _ -> Marshall.Compute.Ledger.rollback(:stream_unavailable)
           end
         end) do
      {:ok, :ok} ->
        published(host_id)
        :ok

      _ ->
        {:error, :stream_unavailable}
    end
  end

  @spec lookup(String.t()) :: {:ok, Location.t()} | {:error, :stream_unavailable}
  def lookup(host_id) do
    case Ash.get(Location, host_id, actor: Marshall.Authorization.SystemActor.compute()) do
      {:ok, %Location{} = location} ->
        if DateTime.compare(location.expires_at, Marshall.Compute.Ledger.now()) == :gt,
          do: {:ok, location},
          else: {:error, :stream_unavailable}

      _ ->
        {:error, :stream_unavailable}
    end
  end

  @spec published(String.t()) :: :ok
  defp published(host_id) do
    unless Marshall.Repo.in_transaction?(),
      do: Marshall.Events.emit("terminal.directory_published", host_id: host_id)

    :ok
  end

  # @cc [owner:ghuntley,label:security] stream-execution-credential-renewal
  # A live stream MUST stop renewing when its execution session is replaced or
  # the current host credential expires/is revoked. Database failure MUST deny
  # renewal; neither the directory lease nor a local PID is authentication.
  @spec current_execution?(String.t(), String.t(), pos_integer()) :: boolean()
  def current_execution?(host_id, session_id, epoch) do
    case Ecto.Adapters.SQL.query(
           Marshall.Repo,
           """
           SELECT 1 FROM compute_hosts h JOIN compute_host_credentials c ON c.host_id = h.id
           WHERE h.id = $1 AND h.connection_session_id = $2 AND h.connection_epoch = $3
             AND h.maintenance_mode <> 'retired'
             AND c.archived_at IS NULL AND c.expires_at > clock_timestamp()
           LIMIT 1
           """,
           [Ecto.UUID.dump!(host_id), Ecto.UUID.dump!(session_id), epoch],
           log: false
         ) do
      {:ok, %{rows: [[1]]}} -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @spec renew(String.t(), String.t()) :: :ok | {:error, term()}
  def renew(host_id, nonce) do
    if is_nil(uri()) do
      :ok
    else
      case Ash.transact(Location, fn ->
             location =
               Location
               |> Ash.Query.filter(host_id == ^host_id)
               |> Ash.Query.lock(:for_update)
               |> Ash.read_one!(actor: Marshall.Authorization.SystemActor.compute())

             if location && location.nonce == nonce do
               Ash.update!(
                 location,
                 %{expires_at: DateTime.add(Marshall.Compute.Ledger.now(), 15)},
                 action: :renew,
                 actor: Marshall.Authorization.SystemActor.compute()
               )

               :ok
             else
               Marshall.Repo.rollback(:replaced)
             end
           end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
