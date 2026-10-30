defmodule Marshall.Terminal.Tickets do
  @moduledoc "Single-use terminal attach tickets bound to one registry session and mode."

  import Ash.Expr
  require Ash.Query

  alias Marshall.Terminal.Ticket

  @ttl_seconds 30

  @type claim :: %{
          session_id: String.t(),
          actor_id: String.t(),
          mode: :rw | :ro,
          ssh_session_id: String.t() | nil
        }

  # @cc [owner:ghuntley,label:security] tickets-single-use-and-bound
  # issue/4 MUST mint a random 256-bit ticket bound to one session, actor and
  # mode (and, for SSH attach, one SSH session) with a short fixed expiry; only
  # its SHA-256 digest may be persisted. consume/1 MUST atomically remove it so
  # a replay cannot open another attachment on this or any connected replica.
  @spec issue(String.t(), String.t(), :rw | :ro, String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def issue(session_id, actor_id, mode, ssh_session_id \\ nil)
      when mode in [:rw, :ro] and (is_nil(ssh_session_id) or is_binary(ssh_session_id)) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    attributes = %{
      token_hash: digest(token),
      session_id: session_id,
      actor_id: actor_id,
      mode: mode,
      ssh_session_id: ssh_session_id,
      expires_at: DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)
    }

    case Marshall.Terminal.create_ticket(attributes,
           actor: Marshall.Authorization.SystemActor.compute()
         ) do
      {:ok, _ticket} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec consume(String.t()) :: {:ok, claim()} | {:error, :invalid_ticket}
  def consume(token) when is_binary(token) and byte_size(token) in 20..64 do
    result =
      Marshall.Repo.transaction(fn ->
        query =
          Ticket
          |> Ash.Query.filter(expr(token_hash == ^digest(token)))
          |> Ash.Query.lock("FOR UPDATE")

        with {:ok, %Ticket{} = ticket} <-
               Ash.read_one(query, actor: Marshall.Authorization.SystemActor.compute()),
             :gt <- DateTime.compare(ticket.expires_at, DateTime.utc_now()),
             :ok <- Ash.destroy(ticket, actor: Marshall.Authorization.SystemActor.compute()) do
          %{
            session_id: ticket.session_id,
            actor_id: ticket.actor_id,
            mode: ticket.mode,
            ssh_session_id: ticket.ssh_session_id
          }
        else
          _ -> Marshall.Repo.rollback(:invalid_ticket)
        end
      end)

    case result do
      {:ok, claim} -> {:ok, claim}
      {:error, _reason} -> {:error, :invalid_ticket}
    end
  end

  def consume(_), do: {:error, :invalid_ticket}

  defp digest(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
end
