defmodule Marshall.Redaction.Run do
  @moduledoc "Durable scrub state machine and progress projection."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Redaction,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine]

  postgres do
    table "redaction_runs"
    repo Marshall.Repo
  end

  cedar do
    internal [:read, :open, :start, :pause, :resume, :cancel, :complete, :progress, :fail]
  end

  state_machine do
    initial_states [:queued]
    state_attribute :state

    transitions do
      transition :start, from: :queued, to: :running
      transition :pause, from: [:running], to: :paused
      transition :resume, from: [:paused], to: :running
      transition :cancel, from: [:queued, :running, :paused], to: :cancelled
      transition :complete, from: [:running], to: :completed
      transition :fail, from: [:queued, :running, :paused], to: :failed
    end
  end

  actions do
    defaults [:read]

    create :open do
      accept [:scope, :profile_digest, :high_water_mark]
    end

    update :start do
      accept [:high_water_mark]
      change transition_state(:running)
    end

    update :pause do
      accept []
      change transition_state(:paused)
    end

    update :resume do
      accept []
      change transition_state(:running)
    end

    update :cancel do
      accept []
      change transition_state(:cancelled)
    end

    update :complete do
      accept [:processed, :changed, :skipped, :failed]
      change transition_state(:completed)
    end

    update :progress do
      accept [:processed, :changed, :skipped, :failed]
    end

    update :fail do
      accept [:failed]
      change transition_state(:failed)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :scope, :map, allow_nil?: false
    attribute :profile_digest, :string, allow_nil?: false
    attribute :high_water_mark, :uuid

    attribute :state, :atom,
      allow_nil?: false,
      default: :queued,
      constraints: [one_of: [:queued, :running, :paused, :completed, :failed, :cancelled]]

    attribute :processed, :integer, allow_nil?: false, default: 0
    attribute :changed, :integer, allow_nil?: false, default: 0
    attribute :skipped, :integer, allow_nil?: false, default: 0
    attribute :failed, :integer, allow_nil?: false, default: 0
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  @spec create(String.t(), Marshall.Redaction.scope(), Marshall.Accounts.User.t() | nil) ::
          {:ok, t()} | {:error, term()}
  def create(id, scope, actor) do
    Ash.create(
      __MODULE__,
      %{
        id: id,
        scope: scope_map(scope),
        profile_digest: Marshall.Redaction.Scanner.profile_digest()
      },
      action: :open,
      actor: actor
    )
  end

  defp scope_map(:all_inactive), do: %{kind: :all_inactive}
  defp scope_map({:thread, id}), do: %{kind: :thread, thread_id: id}
end
