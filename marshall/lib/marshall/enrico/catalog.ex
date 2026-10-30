defmodule Marshall.Enrico.Catalog do
  @moduledoc "Authenticated read and administrator mutation boundary for Git mirrors."
  alias Marshall.Enrico.{Repository, AuditEvent}
  alias Marshall.Enrico.EnricoSource
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Accounts.{Security, User}
  require Ash.Query

  @spec list(User.t()) :: [Repository.t()]
  def list(%User{} = user) do
    if live?(user),
      do:
        Repository
        |> Ash.Query.limit(100)
        |> Ash.read!(actor: SystemActor.compute()),
      else: []
  end

  @spec audit(User.t()) :: [AuditEvent.t()]
  def audit(%User{} = user) do
    if live?(user) and
         Marshall.Authorization.control_plane?(user, "admin_read") do
      AuditEvent
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(100)
      |> Ash.read!(actor: SystemActor.compute())
    else
      []
    end
  end

  @spec get(User.t(), binary(), binary()) :: Repository.t() | nil
  def get(%User{} = user, owner, name) do
    if live?(user) do
      owner = String.downcase(owner)
      name = String.downcase(name)

      Repository
      |> Ash.Query.filter(
        namespace == "github" and owner == ^owner and name == ^name and phase != :removing
      )
      |> Ash.read_one!(actor: SystemActor.compute())
    end
  end

  # @cc [owner:ghuntley,label:security] enrico-admin-registration
  # Catalog mutations MUST hold the current actor row through commit, recheck
  # recent elevation and administrator authority after locking, and serialize
  # repository eligibility checks with refresh and removal transitions.
  @spec register(User.t(), binary(), binary()) :: {:ok, Repository.t()} | {:error, term()}
  def register(%User{} = user, owner, name) do
    admin_transaction(user, fn ->
      unless EnricoSource.valid?(owner, name), do: Ledger.rollback(:invalid_source)

      repo =
        Ledger.create!(Repository, :register, %{
          namespace: "github",
          owner: String.downcase(owner),
          name: String.downcase(name),
          registered_by_id: user.id
        })

      audit!(repo.id, user.id, :registered)
      audit!(repo.id, user.id, :refresh_requested)
      enqueue!(repo.id, "refresh")
      repo
    end)
  end

  @spec refresh(User.t(), binary()) :: {:ok, Repository.t()} | {:error, term()}
  def refresh(%User{} = user, id) do
    admin_transaction(user, fn ->
      repo = Ledger.lock!(Repository, id) || Ledger.rollback(:not_found)

      case refreshable(repo) do
        :ok -> :ok
        {:error, reason} -> Ledger.rollback(reason)
      end

      audit!(id, user.id, :refresh_requested)
      enqueue!(id, "refresh")
      repo
    end)
  end

  @spec remove(User.t(), binary()) :: :ok | {:error, term()}
  def remove(%User{} = user, id) do
    case admin_transaction(user, fn ->
           repo = Ledger.lock!(Repository, id) || Ledger.rollback(:not_found)
           if repo.phase == :removing, do: Ledger.rollback(:removing)
           audit!(id, user.id, :remove_requested)
           Ledger.update!(repo, :request_remove, %{})
           enqueue!(id, "remove")
         end) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @spec audit!(String.t(), String.t(), atom()) :: AuditEvent.t()
  defp audit!(id, actor_id, kind),
    do: Ledger.create!(AuditEvent, :record, %{repository_id: id, actor_id: actor_id, kind: kind})

  @spec enqueue!(String.t(), String.t()) :: Oban.Job.t()
  defp enqueue!(id, operation) do
    {:ok, job} = Marshall.Enrico.Worker.new(%{"id" => id, "op" => operation}) |> Oban.insert()
    job
  end

  @spec inspect(User.t(), Repository.t(), binary(), map()) :: Marshall.Enrico.Client.response()
  def inspect(%User{} = user, %Repository{} = repo, operation, params) do
    if live?(user) do
      case Ledger.read!(Repository, id: repo.id) do
        [%Repository{phase: phase, head: head}] when phase != :removing and is_binary(head) ->
          Marshall.Enrico.Client.request(:get, repo.id, operation, params)

        _ ->
          {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  defp live?(user), do: match?(%User{deleted_at: nil, active: true}, Security.current(user.id))

  defp refreshable(%Repository{phase: :removing}), do: {:error, :removing}
  defp refreshable(%Repository{phase: :refreshing}), do: {:error, :already_refreshing}
  defp refreshable(_), do: :ok

  @spec admin_transaction(User.t(), (-> result)) :: {:ok, result} | {:error, term()}
        when result: term()
  defp admin_transaction(user, operation) do
    result =
      Ledger.transaction(
        fn ->
          current = user.id |> Security.lock_user!() |> Security.bind(Security.jti(user))
          unless Security.recent?(current), do: Ledger.rollback(:forbidden)
          Security.require_admin!(current)
          operation.()
        end,
        user
      )

    case result do
      {:error, reason} when reason in [:unauthorized, :mfa_required] -> {:error, :forbidden}
      other -> other
    end
  end
end

defmodule Marshall.Enrico.EnricoSource do
  @moduledoc false
  @spec valid?(term(), term()) :: boolean()
  def valid?(owner, repo) when is_binary(owner) and is_binary(repo) do
    Regex.match?(~r/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/, owner) and
      Regex.match?(~r/^[A-Za-z0-9._-]{1,100}$/, repo) and repo not in [".", ".."] and
      not String.ends_with?(repo, ".git")
  end

  def valid?(_, _), do: false
end
