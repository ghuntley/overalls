defmodule Marshall.Accounts.MagicLinkSignIn do
  @moduledoc "Fences magic-link sign-in issuance inside the identity commit boundary."
  use Ash.Resource.Change
  alias Marshall.Accounts.Token

  # @cc [owner:ghuntley,label:security;concurrency] magic-link-fenced-issuance
  # The magic-link action MUST mint the authoritative browser login inside the
  # sign-in transaction, which holds the installation latch and upsert lock
  # until commit, so a revocation ordered after that commit observes and revokes
  # it. The upstream post-commit token MUST be revoked unconditionally and MUST
  # NOT remain in the returned metadata: it is stored after those locks release
  # and could otherwise commit after a revocation's token UPDATE.
  @impl true
  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
          Ash.Changeset.t()
  def change(changeset, _options, context) do
    opts = Ash.Context.to_opts(context)

    changeset
    |> Ash.Changeset.after_action(fn _changeset, user ->
      case AshAuthentication.Jwt.token_for_user(
             user,
             changeset.context[:extra_token_claims] || %{},
             opts
           ) do
        {:ok, fenced, _claims} ->
          {:ok, Ash.Resource.put_metadata(user, :fenced_session_token, fenced)}

        {:error, error} ->
          {:error, error}
      end
    end)
    |> Ash.Changeset.after_transaction(fn
      _changeset, {:ok, user} ->
        case Ash.Resource.get_metadata(user, :fenced_session_token) do
          fenced when is_binary(fenced) ->
            unfenced = Ash.Resource.get_metadata(user, :token)

            if is_binary(unfenced) and unfenced != fenced do
              case revoke_unfenced(unfenced) do
                :ok ->
                  {:ok, Ash.Resource.put_metadata(user, :token, fenced)}

                {:error, error} ->
                  {:error, error}
              end
            else
              {:ok, Ash.Resource.put_metadata(user, :token, fenced)}
            end

          _ ->
            {:ok, user}
        end

      _changeset, result ->
        result
    end)
  end

  @spec revoke_unfenced(String.t()) :: :ok | {:error, term()}
  defp revoke_unfenced(token) do
    AshAuthentication.TokenResource.Actions.revoke(Token, token, store_all_tokens?: true)
  end
end
