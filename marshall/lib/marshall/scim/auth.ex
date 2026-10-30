defmodule Marshall.Scim.Auth do
  @moduledoc "Digest-backed bearer authentication for the SCIM endpoint."
  @behaviour AshScim.Auth
  require Ash.Query

  @impl true
  @spec authenticate(Plug.Conn.t(), keyword()) ::
          {:ok, Plug.Conn.t(), Marshall.Authorization.SystemActor.t()} | {:error, String.t()}
  def authenticate(conn, _opts) do
    with true <- Marshall.Scim.enabled?(),
         {:ok, token} <- bearer_token(conn),
         true <- byte_size(token) > 0,
         {:ok, config} <- configuration(),
         true <- is_binary(config.token_digest),
         true <- Plug.Crypto.secure_compare(digest(token), config.token_digest) do
      {:ok, conn, Marshall.Authorization.SystemActor.service(:scim)}
    else
      _ -> {:error, "invalid or unavailable SCIM credentials"}
    end
  end

  @spec digest(String.t()) :: String.t()
  def digest(token), do: :crypto.hash(:sha256, token) |> Base.encode64()

  defp bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      ["bearer " <> token] when token != "" -> {:ok, token}
      _ -> {:error, :missing_bearer}
    end
  end

  defp configuration do
    Marshall.Scim.Configuration
    |> Ash.Query.filter(state == :enabled)
    |> Ash.read(actor: Marshall.Authorization.SystemActor.compute())
    |> case do
      {:ok, [config]} -> {:ok, config}
      _ -> {:error, :disabled}
    end
  end
end
