defmodule Marshall.Compute.GitIdentity do
  @moduledoc "Allocation-time account Git identity snapshot."
  alias Marshall.Accounts.User
  alias Marshall.Compute.{Image, Ledger}

  # @cc [owner:ghuntley,label:product;security] allocation-current-git-identity
  # New machines MUST snapshot the current account preference inside admission;
  # browser-supplied identity and later preference changes MUST NOT replace it.
  @spec snapshot!(String.t()) :: map()
  def snapshot!(user_id) do
    user =
      Ash.get!(User, user_id,
        action: :internal_lookup,
        actor: Marshall.Authorization.SystemActor.compute()
      )

    case OverallsProtocol.GitIdentity.validate(%{
           name: user.git_username,
           email: to_string(user.git_email)
         }) do
      {:ok, identity} -> OverallsProtocol.GitIdentity.encode(identity)
      _ -> Ledger.rollback(:invalid_git_identity)
    end
  end

  # @cc [owner:ghuntley,label:security;protocol] git-identity-image-capability
  # Identity-bearing allocation and commands MUST require an explicit Git identity
  # version 1 capability from the durable manifest matching its catalog image ID.
  # Missing or invalid capability MUST refuse before allocation or dispatch;
  # package presence and caller hints MUST NOT grant support.
  @spec require_image!(String.t()) :: :ok
  def require_image!(image_id) do
    with [image] <- Ledger.read!(Image, id: image_id),
         {:ok, %{id: ^image_id, git_identity_version: 1}} <-
           OverallsProtocol.ImageManifest.validate(image.manifest) do
      :ok
    else
      _ -> Ledger.rollback(:git_identity_unavailable)
    end
  end
end
